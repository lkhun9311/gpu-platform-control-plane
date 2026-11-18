package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

const calibrationArtifactFile = bench.CalibrationArtifactFile

// versionCalibrate runs the registered ladder against treatment A's engine and writes the calibration artifact.
//
// Every rung's rows and observation are written as the rung ends, so a stopped session keeps the evidence of the rungs it ran.
func versionCalibrate(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("version-calibrate", flag.ContinueOnError)
	dir := fs.String("dir", "", "campaign directory; calibration.json and one file per rung are written here, never replaced")
	study := fs.String("study", bench.StudyVersionAsync, "registered version study id")
	engineURL := fs.String("engine-url", "", "base URL of treatment A's engine, started with VLLM_SERVER_DEV_MODE=1 so its identity can be read")
	metricsURL := fs.String("metrics-url", "", "the engine's Prometheus metrics URL, read to start every rung drained")
	model := fs.String("model", "", "served model name the requests carry")
	poll := fs.Duration("poll", 2*time.Second, "how often the drained check reads the engine")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" || *engineURL == "" || *metricsURL == "" || *model == "" {
		return errors.New("-dir, -engine-url, -metrics-url and -model are required")
	}
	st, ok := bench.LookupStudy(*study)
	if !ok || st.Version == nil || st.Sampling == nil {
		return fmt.Errorf("study %q is not a version study", *study)
	}
	if err := st.Version.PreflightRefusal(); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(*dir, calibrationArtifactFile)); err == nil {
		return fmt.Errorf("%s exists; a campaign is calibrated once", filepath.Join(*dir, calibrationArtifactFile))
	}
	sender := bench.NewHTTPSender(*engineURL, *model, nil, time.Duration(st.Version.TimeoutMs)*time.Millisecond,
		bench.SenderConn{MaxIdleConnsPerHost: 256, DrainForReuse: true})
	if err := sender.SetSampling(st.Sampling); err != nil {
		return err
	}
	runner := &bench.RungRunner{
		Design:    *st.Version,
		Sender:    sender,
		Sampling:  *st.Sampling,
		Queue:     bench.HTTPEngineQueue(&http.Client{Timeout: 10 * time.Second}, *metricsURL),
		PollEvery: *poll,
	}
	// The ladder's registered ceiling is enforced, not only computed: past it the session's context ends and the ladder stops unresolved.
	// An operator or supervisor stop ends the same context, so the ladder writes its unresolved artifact instead of leaving a directory nobody can read.
	ctx, stop := cancelOnSignal(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, time.Duration(st.Version.Calibration.MaxSeconds())*time.Second)
	defer cancel()
	client := &http.Client{Timeout: 30 * time.Second}
	res, err := calibrateTreatmentA(ctx, *dir, *st.Version, client, *engineURL, runner, func(ctx context.Context, rate float64, ordinal int) bench.RungClass {
		return runner.Probe(ctx, rate, ordinal)
	})
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(out, "identity: the engine reports A's release, revisions and settings; not proven by its responses: %s (see %s)\n",
		strings.Join(res.unproven, ", "), bench.CalibrationIdentityFile); err != nil {
		return err
	}
	if res.Resolved {
		_, err = fmt.Fprintf(out, "calibration resolved: λ0 %v req/s after %d rungs\n", res.Rate, len(res.Rungs))
	} else {
		_, err = fmt.Fprintf(out, "%s after %d rungs; the session stops\n", res.Reason, len(res.Rungs))
	}
	return err
}

// cancelOnSignal returns a context that ends, with a cause naming the signal, when one of sigs arrives.
//
// The cause is what the ladder's reason prints, so the record says an operator stopped the session and not that the engine failed.
// The handler is removed after the first signal, so a second one takes its default action and an operator can still force the process down.
func cancelOnSignal(parent context.Context, sigs ...os.Signal) (context.Context, func()) {
	ctx, cancel := context.WithCancelCause(parent)
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, sigs...)
	done := make(chan struct{})
	go func() {
		select {
		case sig := <-ch:
			signal.Stop(ch)
			cancel(fmt.Errorf("stopped by signal: %v", sig))
		case <-done:
		}
	}()
	return ctx, func() {
		signal.Stop(ch)
		close(done)
		cancel(context.Canceled)
	}
}

// calibrationIdentity is the record of the engine a calibration ran against, written before its first rung (#645).
//
// It keeps the engine's own responses, so the check can be redone from them, and names what they could not prove.
type calibrationIdentity struct {
	Treatment string    `json:"treatment"`
	EngineURL string    `json:"engineURL"`
	ReadAt    time.Time `json:"readAt"`
	// Unproven is what the responses do not carry and the check therefore did not compare.
	Unproven []string              `json:"unproven"`
	Runtime  bench.RuntimeIdentity `json:"runtime"`
	// ServerInfo and Version are the engine's /server_info?config_format=json and /version bodies.
	//
	// They are bytes, written as base64, because a json.RawMessage would be re-encoded and the record would no longer hold what the engine sent.
	ServerInfo []byte `json:"serverInfo"`
	Version    []byte `json:"version"`
}

// calibrationRun is a ladder's result with the identity fields its engine left unproven.
type calibrationRun struct {
	bench.CalibrationResult
	unproven []string
}

// calibrateTreatmentA confirms that the engine at engineURL is treatment A, then runs the ladder against it.
//
// Only A's capacity may become λ0, and B and C serve the same model at the same URL shape, so an engine is identified by what it reports before any rung (#645).
// A refused or unreadable engine gets no rung and leaves dir untouched, so the campaign can still be calibrated against the right one.
// The responses cannot prove the image, the chat template or the command line, so the check is CheckObservedRuntime and the gap is recorded beside the rungs.
// The engine is read again after every rung, and a change, its instance id included, ends the ladder unresolved, so a replaced engine never decides λ0.
func calibrateTreatmentA(ctx context.Context, dir string, d bench.VersionStudyDesign, client *http.Client, engineURL string, runner *bench.RungRunner, probe func(ctx context.Context, rate float64, ordinal int) bench.RungClass) (calibrationRun, error) {
	read := func(ctx context.Context) (bench.VLLMIdentityResponses, bench.RuntimeIdentity, []string, error) {
		resp, err := bench.FetchVLLMIdentity(ctx, client, engineURL)
		if err != nil {
			return resp, bench.RuntimeIdentity{}, nil, fmt.Errorf("reading the engine's identity: %w", err)
		}
		rt, err := bench.ParseVLLMRuntime(resp.ServerInfo, resp.Version)
		if err != nil {
			return resp, rt, nil, fmt.Errorf("reading the engine's identity: %w", err)
		}
		unproven, err := d.CheckObservedRuntime(bench.TreatmentA, rt)
		if err != nil {
			return resp, rt, nil, fmt.Errorf("the engine at %s is not treatment A, so it is not calibrated: %w", engineURL, err)
		}
		return resp, rt, unproven, nil
	}
	resp, rt, unproven, err := read(ctx)
	if err != nil {
		return calibrationRun{}, err
	}
	rec, err := json.MarshalIndent(calibrationIdentity{
		Treatment: bench.TreatmentA, EngineURL: engineURL, ReadAt: time.Now().UTC(),
		Unproven: unproven, Runtime: rt, ServerInfo: resp.ServerInfo, Version: resp.Version,
	}, "", "  ")
	if err != nil {
		return calibrationRun{}, err
	}
	// Ending the ladder's context is how a rung is kept from deciding it: RunContext halts the ladder after a rung its context cut, unresolved.
	lctx, stopLadder := context.WithCancelCause(ctx)
	defer stopLadder(nil)
	checked := func(ctx context.Context, rate float64, ordinal int) bench.RungClass {
		cls := probe(ctx, rate, ordinal)
		// The engine is read after the rung, so one replaced before or during it is caught before its class counts.
		_, again, _, err := read(ctx)
		switch {
		case err != nil:
			stopLadder(fmt.Errorf("after rung %d: %w", ordinal, err))
		case again.InstanceID != rt.InstanceID:
			stopLadder(fmt.Errorf("after rung %d the engine is instance %s, not the checked instance %s", ordinal, again.InstanceID, rt.InstanceID))
		case !reflect.DeepEqual(again, rt):
			stopLadder(fmt.Errorf("after rung %d the engine reports another identity than the one checked", ordinal))
		}
		return cls
	}
	res, err := runVersionCalibration(lctx, dir, d.Calibration, runner, checked, append(rec, '\n'))
	return calibrationRun{CalibrationResult: res, unproven: unproven}, err
}

// runVersionCalibration runs the ladder with probe, writes every rung's evidence as it ends, and writes the artifact last.
//
// The artifact is written for an unresolved ladder too, because "calibration unresolved, stop" is a registered outcome and must be on record.
// identity is the engine's checked identity record, written right after the reservation so no rung exists without it.
func runVersionCalibration(ctx context.Context, dir string, rule bench.CalibrationRule, runner *bench.RungRunner, probe func(ctx context.Context, rate float64, ordinal int) bench.RungClass, identity []byte) (bench.CalibrationResult, error) {
	if len(identity) == 0 {
		return bench.CalibrationResult{}, errors.New("no engine identity to record; a ladder is never run against an engine nobody identified")
	}
	// The destination is checked before the first request, because a rung whose evidence cannot be kept is paid for and lost.
	if err := reserveCalibration(dir); err != nil {
		return bench.CalibrationResult{}, err
	}
	if err := writeNew(filepath.Join(dir, bench.CalibrationIdentityFile), identity); err != nil {
		return bench.CalibrationResult{}, fmt.Errorf("recording the engine's identity: %w", err)
	}
	var writeErr error
	runner.OnRung = func(ordinal int, rows []bench.RawRow, o bench.RungObservation, cls bench.RungClass, err error) {
		rec := bench.CalibrationRungRecord{Ordinal: ordinal, Class: cls, Observation: o}
		if err != nil {
			rec.Error = err.Error()
		}
		data, mErr := json.MarshalIndent(rec, "", "  ")
		if mErr == nil {
			mErr = writeNew(filepath.Join(dir, bench.CalibrationRungFile(ordinal)), append(data, '\n'))
		}
		var buf bytes.Buffer
		for _, r := range rows {
			line, lErr := json.Marshal(r)
			if lErr != nil {
				mErr = errors.Join(mErr, lErr)
				break
			}
			buf.Write(append(line, '\n'))
		}
		if mErr == nil {
			mErr = writeNew(filepath.Join(dir, bench.CalibrationRungRowsFile(ordinal)), buf.Bytes())
		}
		writeErr = errors.Join(writeErr, mErr)
	}
	// After a failed write every later rung is refused without being sent; the ladder's invalid bound then ends it at no cost.
	res := rule.RunContext(ctx, func(ctx context.Context, rate float64, ordinal int) bench.RungClass {
		if writeErr != nil {
			return bench.RungInvalid
		}
		return probe(ctx, rate, ordinal)
	})
	if writeErr != nil {
		return res, fmt.Errorf("rung evidence: %w", writeErr)
	}
	art := bench.CalibrationArtifact{Resolved: res.Resolved, StableRateRequestsPerSec: res.Rate, Reason: res.Reason, Rungs: res.Rungs}
	data, err := json.MarshalIndent(art, "", "  ")
	if err != nil {
		return res, err
	}
	return res, writeNew(filepath.Join(dir, calibrationArtifactFile), append(data, '\n'))
}

// writeNew creates path durably with data, refusing a file that already exists.
//
// Calibration evidence decides λ0, so a crash must leave each record whole or absent, never a torn file under its final name.
func writeNew(path string, data []byte) error {
	return bench.WriteNewFileDurably(path, data)
}

const calibrationLockFile = bench.CalibrationLockFile

// reserveCalibration refuses a directory that is missing or already holds calibration evidence, then reserves it atomically.
//
// The reservation is an exclusive create, so of two calibrations started together exactly one sends traffic.
func reserveCalibration(dir string) error {
	info, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("calibration directory: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("calibration directory %s is not a directory", dir)
	}
	existing, err := filepath.Glob(filepath.Join(dir, "calibration*"))
	if err != nil {
		return err
	}
	if len(existing) > 0 {
		return fmt.Errorf("%s already holds calibration evidence (%s); a campaign is calibrated once, into an empty place", dir, filepath.Base(existing[0]))
	}
	if err := writeNew(filepath.Join(dir, calibrationLockFile), []byte(time.Now().UTC().Format(time.RFC3339)+"\n")); err != nil {
		return fmt.Errorf("reserve calibration directory %s: %w", dir, err)
	}
	return nil
}
