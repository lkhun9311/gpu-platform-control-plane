/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Command capacityrun drives the single-A10G capacity study (experiments/a10g-capacity/CONTRACT.md).
//
// It has three subcommands, and every one reads the committed contract.json rather than taking the workload as flags:
//
//	engine-args  checks the contract against this build's pinned image, profile and token table, and prints the vLLM command
//	stage        replays one open-loop Poisson trace of one or more rate segments and writes its raw rows
//	restart      kills and restarts the engine and times the first successful response after the kill
//
// The sender is bench.HTTPSender, the scheduler bench.Replay, and the ledger check bench.ReconcileRecording, so the
// rows mean what they mean everywhere else in this repository.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/engineargs"
)

// Contract is the part of contract.json this command needs.
type Contract struct {
	ID       string `json:"contract"`
	Workload struct {
		Model           string  `json:"model"`
		ModelRevision   string  `json:"model_revision"`
		ServedModelName string  `json:"served_model_name"`
		EngineImage     string  `json:"engine_image"`
		EngineProfile   string  `json:"engine_profile"`
		EnginePort      int32   `json:"engine_port"`
		PrefixCaching   string  `json:"prefix_caching"`
		InputTokens     int     `json:"input_tokens"`
		InputChars      int     `json:"input_chars"`
		OutputTokens    int     `json:"output_tokens"`
		Temperature     float64 `json:"temperature"`
		TopP            float64 `json:"top_p"`
		RepPenalty      float64 `json:"repetition_penalty"`
		IgnoreEOS       bool    `json:"ignore_eos"`
		MinEqualsMax    bool    `json:"min_tokens_equals_max_tokens"`
		// Stream is decoded only to be checked: the sender always streams, so a contract saying otherwise is refused.
		Stream       bool   `json:"stream"`
		ArrivalModel string `json:"arrival_model"`
		TimeoutS     int    `json:"request_timeout_s"`
	} `json:"workload"`
	Restart struct {
		Count             int `json:"count"`
		ProbeOutputTokens int `json:"probe_output_tokens"`
		ProbeIntervalMs   int `json:"probe_interval_ms"`
		ProbeTimeoutS     int `json:"probe_timeout_s"`
		BoundS            int `json:"bound_s"`
	} `json:"restart"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: capacityrun engine-args|stage|restart [flags]")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "engine-args":
		err = engineArgsCmd(os.Args[2:], os.Stdout)
	case "stage":
		err = stageCmd(os.Args[2:], os.Stdout)
	case "restart":
		err = restartCmd(os.Args[2:], os.Stdout)
	default:
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		// Exit 3 marks a recording that was written but does not reconcile, so the kit can keep the rows and still stop.
		if errors.Is(err, errUnreconciled) {
			os.Exit(3)
		}
		os.Exit(1)
	}
}

// LoadContract reads contract.json and refuses one this build cannot honour.
//
// The checks are against the repository's own pins, so a contract that names another image, profile or prompt length
// is refused before any request rather than run as if it were the committed one.
func LoadContract(path string) (Contract, error) {
	var c Contract
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, fmt.Errorf("contract %s: %w", path, err)
	}
	return c, c.Check()
}

// Check compares the contract's workload to the pins this build carries.
func (c Contract) Check() error {
	w := c.Workload
	var problems []string
	add := func(format string, a ...any) { problems = append(problems, fmt.Sprintf(format, a...)) }
	if w.EngineImage != platformv1.VLLMV0271Image {
		add("engine_image %q is not VLLMV0271Image %q", w.EngineImage, platformv1.VLLMV0271Image)
	}
	if w.EngineProfile != platformv1.VLLMProfileV0271A10G {
		add("engine_profile %q is not %q", w.EngineProfile, platformv1.VLLMProfileV0271A10G)
	}
	// The profile renders --no-enable-prefix-caching, so a contract that says otherwise describes another engine.
	if w.PrefixCaching != "off" {
		add("prefix_caching %q, but the %s profile turns it off", w.PrefixCaching, platformv1.VLLMProfileV0271A10G)
	}
	r, ok := bench.ResolveInputTokens(w.InputTokens)
	switch {
	case !ok:
		add("input_tokens %d has no measured character length in the bench table", w.InputTokens)
	case r.Chars != w.InputChars:
		add("input_chars %d, but the bench table resolves %d tokens to %d characters", w.InputChars, w.InputTokens, r.Chars)
	}
	if w.OutputTokens <= 0 || c.Restart.ProbeOutputTokens <= 0 {
		add("output_tokens %d and probe_output_tokens %d must be positive", w.OutputTokens, c.Restart.ProbeOutputTokens)
	}
	if w.Temperature != 0 || w.TopP != 1 || w.RepPenalty != 1 || !w.IgnoreEOS || !w.MinEqualsMax {
		add("the generation fields are not the exact-cap greedy policy (temperature 0, top_p 1, repetition_penalty 1, ignore_eos, min = max)")
	}
	if w.ArrivalModel != "poisson-open-loop" {
		add("arrival_model %q is not poisson-open-loop", w.ArrivalModel)
	}
	if w.TimeoutS <= 0 || w.EnginePort <= 0 || w.ServedModelName == "" || len(w.ModelRevision) != 40 {
		add("timeout, port, served name and a 40-character model revision are all required")
	}
	if !w.Stream {
		add("stream is not true, but the sender only streams")
	}
	// A restart kills the engine before it probes, so timing that could not probe is refused before anything is run.
	if r := c.Restart; r.Count < 1 || r.ProbeIntervalMs <= 0 || r.ProbeTimeoutS <= 0 || r.BoundS <= 0 {
		add("restart count, probe_interval_ms, probe_timeout_s and bound_s must all be positive")
	}
	if len(problems) > 0 {
		return fmt.Errorf("contract %s does not match this build: %s", c.ID, strings.Join(problems, "; "))
	}
	return nil
}

// Sampling is the contract's generation policy as the sender applies it.
func (c Contract) Sampling() *bench.SamplingPolicy {
	return &bench.SamplingPolicy{
		Temperature:       c.Workload.Temperature,
		TopP:              c.Workload.TopP,
		RepetitionPenalty: c.Workload.RepPenalty,
		Seed:              bench.SeedOmitGreedy,
		IgnoreEOS:         c.Workload.IgnoreEOS,
		Length:            bench.LengthExactCap,
	}
}

// EngineCommand is the argument list after the image: the controller's own rendering of the profile.
func (c Contract) EngineCommand() ([]string, error) {
	profile, err := engineargs.ProfileArgs(platformv1.VLLMReleaseV0271, false)
	if err != nil {
		return nil, err
	}
	return engineargs.Command(profile, engineargs.Deployment{
		Model: c.Workload.Model, Port: c.Workload.EnginePort,
		ServedName: c.Workload.ServedModelName, Revision: c.Workload.ModelRevision,
	}), nil
}

func engineArgsCmd(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("engine-args", flag.ContinueOnError)
	contract := fs.String("contract", "", "contract.json")
	if err := fs.Parse(args); err != nil {
		return err
	}
	c, err := LoadContract(*contract)
	if err != nil {
		return err
	}
	cmd, err := c.EngineCommand()
	if err != nil {
		return err
	}
	// One argument per line, so the kit reads them into an array with no word splitting.
	_, err = fmt.Fprintln(out, strings.Join(cmd, "\n"))
	return err
}

// Segment is one rate of a stage trace.
type Segment struct {
	Name      string  `json:"name"`
	RateRPS   float64 `json:"rateRps"`
	DurationS float64 `json:"durationS"`
	// StartMs and EndMs are the segment's span on the trace's offset axis, end exclusive.
	StartMs int64 `json:"startMs"`
	EndMs   int64 `json:"endMs"`
	Planned int   `json:"planned"`
}

// ParseSegments reads name:rate:seconds[,...].
func ParseSegments(s string) ([]Segment, error) {
	var segs []Segment
	var at int64
	seen := map[string]bool{}
	for part := range strings.SplitSeq(s, ",") {
		f := strings.Split(part, ":")
		if len(f) != 3 || f[0] == "" {
			return nil, fmt.Errorf("segment %q is not name:rate:seconds", part)
		}
		rate, err1 := strconv.ParseFloat(f[1], 64)
		dur, err2 := strconv.ParseFloat(f[2], 64)
		if err1 != nil || err2 != nil || !(rate > 0) || !(dur > 0) || math.IsInf(rate, 0) || math.IsInf(dur, 0) {
			return nil, fmt.Errorf("segment %q needs a positive finite rate and duration", part)
		}
		if seen[f[0]] {
			return nil, fmt.Errorf("segment name %q appears twice", f[0])
		}
		seen[f[0]] = true
		end := at + int64(math.Round(dur*1000))
		segs = append(segs, Segment{Name: f[0], RateRPS: rate, DurationS: dur, StartMs: at, EndMs: end})
		at = end
	}
	if len(segs) == 0 {
		return nil, errors.New("no segments")
	}
	return segs, nil
}

// BuildTrace draws each segment's Poisson arrivals from one seeded stream, segment after segment.
//
// The segment name goes in the tenant field, so bench.ReconcileRecording checks every row's stage as well as its offset.
// Offsets are whole milliseconds, the trace format's unit, and a draw that rounds onto the segment's end is dropped so
// that no row belongs to the next segment.
func BuildTrace(segs []Segment, seed uint64, inputChars, inputTokens, outputTokens int) ([]bench.TraceRow, []Segment) {
	rng := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
	var rows []bench.TraceRow
	out := make([]Segment, len(segs))
	copy(out, segs)
	for i := range out {
		s := &out[i]
		t := float64(s.StartMs)
		for {
			t += rng.ExpFloat64() / s.RateRPS * 1000
			ms := int64(math.Floor(t))
			if ms >= s.EndMs {
				break
			}
			rows = append(rows, bench.TraceRow{
				Index: len(rows), OffsetMs: ms, Tenant: s.Name,
				PromptLenChars: inputChars, ExactInputTokens: inputTokens, MaxOutputTokens: outputTokens,
			})
			s.Planned++
		}
	}
	return rows, out
}

var errUnreconciled = errors.New("the recording does not reconcile with its trace")

// StageMeta is written beside the raw rows, so the analysis knows each segment's span and planned count from the run itself.
type StageMeta struct {
	Contract     string    `json:"contract"`
	Seed         uint64    `json:"seed"`
	Target       string    `json:"target"`
	OutputTokens int       `json:"outputTokens"`
	TimeoutS     int       `json:"timeoutS"`
	PoolSize     int       `json:"poolSize"`
	Segments     []Segment `json:"segments"`
	StartedUTC   string    `json:"startedUtc"`
	EndedUTC     string    `json:"endedUtc,omitempty"`
	Rows         int       `json:"rows"`
	Reconciled   *bool     `json:"reconciled,omitempty"`
	Unreconciled string    `json:"unreconciled,omitempty"`
}

func stageCmd(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("stage", flag.ContinueOnError)
	contract := fs.String("contract", "", "contract.json")
	segments := fs.String("segments", "", "name:rate:seconds[,...], contiguous")
	seed := fs.Uint64("seed", 0, "arrival seed")
	target := fs.String("target", "", "engine base URL")
	dir := fs.String("out", "", "directory for trace.jsonl, raw.jsonl and meta.json; must not exist")
	idPrefix := fs.String("request-id-prefix", "", "X-Request-Id prefix, unique per stage")
	// The engine takes no key; the gateway on kind does, and its measurement replays the same stages through it.
	apiKey := fs.String("api-key", "", "bearer key sent with every request; empty sends none")
	if err := fs.Parse(args); err != nil {
		return err
	}
	c, err := LoadContract(*contract)
	if err != nil {
		return err
	}
	segs, err := ParseSegments(*segments)
	if err != nil {
		return err
	}
	if *target == "" || *dir == "" || *idPrefix == "" || *seed == 0 {
		return errors.New("--target, --out, --request-id-prefix and a non-zero --seed are required")
	}
	// A new directory each time, so a rerun can never leave an earlier run's rows for the analysis to read.
	if err := os.Mkdir(*dir, 0o755); err != nil {
		return fmt.Errorf("stage directory: %w", err)
	}
	w := c.Workload
	rows, segs := BuildTrace(segs, *seed, w.InputChars, w.InputTokens, w.OutputTokens)
	if len(rows) == 0 {
		return errors.New("the trace has no rows")
	}
	timeout := time.Duration(w.TimeoutS) * time.Second
	conn, err := bench.SenderConnForMode(bench.SenderModePooled, rows, timeout)
	if err != nil {
		return err
	}
	meta := StageMeta{Contract: c.ID, Seed: *seed, Target: *target, OutputTokens: w.OutputTokens, TimeoutS: w.TimeoutS,
		PoolSize: conn.MaxIdleConnsPerHost, Segments: segs, StartedUTC: time.Now().UTC().Format(time.RFC3339Nano), Rows: len(rows)}
	if err := writeJSONLines(*dir+"/trace.jsonl", rows); err != nil {
		return err
	}
	if err := writeJSON(*dir+"/meta.json", meta); err != nil {
		return err
	}
	// The sender looks a key up by the row's tenant, which here is its segment, so every segment gets the one key.
	var keys map[string]string
	if *apiKey != "" {
		keys = map[string]string{}
		for _, s := range segs {
			keys[s.Name] = *apiKey
		}
	}
	sender := bench.NewHTTPSender(*target, w.ServedModelName, keys, timeout, conn)
	sender.SetRequestIDPrefix(*idPrefix)
	if err := sender.SetSampling(c.Sampling()); err != nil {
		return err
	}
	// Rows are appended as each request ends, so a session that dies mid-stage still leaves every finished row behind.
	live, err := os.OpenFile(*dir+"/raw.live.jsonl", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(live)
	var liveErr error
	raw := bench.Replay(context.Background(), sender, rows, bench.ReplayOptions{
		Study: c.ID, Arm: "a10g", RequestIDPrefix: *idPrefix, RecordTiming: true,
		OnRow: func(r bench.RawRow) {
			if err := enc.Encode(r); err != nil && liveErr == nil {
				liveErr = err
			}
		},
	})
	if err := live.Close(); err != nil && liveErr == nil {
		liveErr = err
	}
	f, err := os.Create(*dir + "/raw.jsonl")
	if err != nil {
		return err
	}
	if err := bench.WriteRawRows(f, raw); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	meta.EndedUTC = time.Now().UTC().Format(time.RFC3339Nano)
	rerr := bench.ReconcileRecording(rows, raw)
	ok := rerr == nil
	meta.Reconciled = &ok
	if rerr != nil {
		meta.Unreconciled = rerr.Error()
	}
	if err := writeJSON(*dir+"/meta.json", meta); err != nil {
		return err
	}
	if liveErr != nil {
		return fmt.Errorf("the live row file is incomplete: %w", liveErr)
	}
	if rerr != nil {
		return fmt.Errorf("%w: %w", errUnreconciled, rerr)
	}
	_, err = fmt.Fprintf(out, "stage %s: %d rows over %d segment(s) to %s\n", *idPrefix, len(raw), len(segs), *dir)
	return err
}

// Probe is one restart probe's outcome.
type Probe struct {
	SentMs     float64 `json:"sentMs"`
	ReturnedMs float64 `json:"returnedMs"`
	EndMs      float64 `json:"endMs,omitempty"`
	HTTPStatus int     `json:"httpStatus"`
	ErrorKind  string  `json:"errorKind,omitempty"`
	Terminated bool    `json:"streamTerminated"`
	Prompt     int     `json:"promptTokens"`
	Completion int     `json:"completionTokens"`
	Finish     string  `json:"finishReason,omitempty"`
	OK         bool    `json:"ok"`
}

// RestartRecord is one restart's evidence; every time is milliseconds after the instant just before the kill.
type RestartRecord struct {
	Contract   string  `json:"contract"`
	Index      int     `json:"index"`
	KillAtUTC  string  `json:"killAtUtc"`
	KillCmd    string  `json:"killCmd"`
	StartCmd   string  `json:"startCmd"`
	KillRetMs  float64 `json:"killReturnedMs"`
	KillErr    string  `json:"killError,omitempty"`
	StartRetMs float64 `json:"startReturnedMs"`
	StartErr   string  `json:"startError,omitempty"`
	Probes     []Probe `json:"probes"`
	// WindowMs is the end of the first successful probe; nil when none succeeded inside the bound.
	WindowMs *float64 `json:"windowMs,omitempty"`
	Outcome  string   `json:"outcome"`
}

// probeOK is the contract's successful probe: a completed stream with the token counts and finish reason it asked for.
func probeOK(res bench.SendResult, inputTokens, outputTokens int) bool {
	return res.ErrorKind == "" && res.HTTPStatus == 200 && res.StreamTerminated && res.StreamError == "" &&
		res.PromptTokens == inputTokens && res.EngineOutputTokens == outputTokens && res.FinishReason == "length"
}

// Shell runs one kit-supplied command line; tests replace it.
var Shell = func(ctx context.Context, line string) error {
	cmd := exec.CommandContext(ctx, "bash", "-c", line)
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	return cmd.Run()
}

// Restart kills and restarts the engine through the kit's commands and probes until one probe succeeds or the bound passes.
//
// The clock starts just before the kill command, so the window includes the kill itself, the restart and the load.
// Each probe dials a new connection, because a pooled one would point at the killed process and its failure would say
// nothing about the new one.
func Restart(ctx context.Context, c Contract, target, killCmd, startCmd string, index int) RestartRecord {
	w := c.Workload
	rs := c.Restart
	rec := RestartRecord{Contract: c.ID, Index: index, KillCmd: killCmd, StartCmd: startCmd, Probes: []Probe{}}
	t0 := time.Now()
	ms := func(t time.Time) float64 { return float64(t.Sub(t0).Microseconds()) / 1000 }
	rec.KillAtUTC = t0.UTC().Format(time.RFC3339Nano)
	if err := Shell(ctx, killCmd); err != nil {
		rec.KillErr = err.Error()
	}
	rec.KillRetMs = ms(time.Now())
	if err := Shell(ctx, startCmd); err != nil {
		rec.StartErr = err.Error()
	}
	rec.StartRetMs = ms(time.Now())
	if rec.KillErr != "" || rec.StartErr != "" {
		rec.Outcome = "command failed"
		return rec
	}
	sender := bench.NewHTTPSender(target, w.ServedModelName, nil, time.Duration(rs.ProbeTimeoutS)*time.Second,
		bench.SenderConn{CloseEachRequest: true})
	if err := sender.SetSampling(c.Sampling()); err != nil {
		rec.Outcome = "sampling refused: " + err.Error()
		return rec
	}
	row := bench.TraceRow{PromptLenChars: w.InputChars, ExactInputTokens: w.InputTokens, MaxOutputTokens: rs.ProbeOutputTokens}
	bound := t0.Add(time.Duration(rs.BoundS) * time.Second)
	interval := time.Duration(rs.ProbeIntervalMs) * time.Millisecond
	for i := 0; ; i++ {
		sent := time.Now()
		if !sent.Before(bound) {
			break
		}
		row.Index = i
		res := sender.Send(ctx, row, sent.UnixNano())
		ret := time.Now()
		p := Probe{SentMs: ms(sent), ReturnedMs: ms(ret), HTTPStatus: res.HTTPStatus, ErrorKind: res.ErrorKind,
			Terminated: res.StreamTerminated, Prompt: res.PromptTokens, Completion: res.EngineOutputTokens, Finish: res.FinishReason}
		if !res.EndAt.IsZero() {
			p.EndMs = ms(res.EndAt)
		}
		p.OK = probeOK(res, w.InputTokens, rs.ProbeOutputTokens)
		rec.Probes = append(rec.Probes, p)
		// A success after the bound is recorded but does not count, so the bound is the same for every restart.
		if p.OK && p.EndMs > 0 && res.EndAt.Before(bound) {
			v := p.EndMs
			rec.WindowMs = &v
			rec.Outcome = "serving"
			return rec
		}
		if wait := time.Until(sent.Add(interval)); wait > 0 {
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				rec.Outcome = "cancelled"
				return rec
			}
		}
	}
	rec.Outcome = fmt.Sprintf("not serving within %d s", rs.BoundS)
	return rec
}

func restartCmd(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("restart", flag.ContinueOnError)
	contract := fs.String("contract", "", "contract.json")
	target := fs.String("target", "", "engine base URL")
	killCmd := fs.String("kill-cmd", "", "command line that kills the engine")
	startCmd := fs.String("start-cmd", "", "command line that starts the same engine again")
	index := fs.Int("index", 0, "restart number, from 1")
	path := fs.String("out", "", "record file; must not exist")
	if err := fs.Parse(args); err != nil {
		return err
	}
	c, err := LoadContract(*contract)
	if err != nil {
		return err
	}
	if *target == "" || *killCmd == "" || *startCmd == "" || *path == "" || *index < 1 {
		return errors.New("--target, --kill-cmd, --start-cmd, --out and --index >= 1 are required")
	}
	// The record file is created before the kill, so a destination that cannot be written stops the restart while the engine still runs.
	f, err := os.OpenFile(*path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("restart record: %w", err)
	}
	rec := Restart(context.Background(), c, *target, *killCmd, *startCmd, *index)
	b, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		_ = f.Close()
		return err
	}
	if _, err := f.Write(append(b, '\n')); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if rec.Outcome != "serving" {
		return fmt.Errorf("restart %d: %s", *index, rec.Outcome)
	}
	_, err = fmt.Fprintf(out, "restart %d: serving %.0f ms after the kill, %d probe(s)\n", *index, *rec.WindowMs, len(rec.Probes))
	return err
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

func writeJSONLines[T any](path string, rows []T) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	for _, r := range rows {
		if err := enc.Encode(r); err != nil {
			_ = f.Close()
			return err
		}
	}
	return f.Close()
}
