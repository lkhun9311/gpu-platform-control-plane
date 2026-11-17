package bench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// The engine-readiness preflight (#594): how long the version study's engines take to become ready on one A10G.
//
// The registration's worst case is mostly engine readiness, bounded at 600 s per start and never measured on a warm
// instance (spec, "Budget and the $20 stop rule").
// This file measures it with the study's own containers (DockerEngine) and the study's own readiness rule: /health
// returns 200, and one priming request per input x output class is answered, all within the registered bound.
// Image pull and model download are timed as their own steps, so neither is read as part of a start.

// The preflight's step bounds outside the registered readiness bound.
//
// hack/version-readiness-session.sh sizes the instance's hard stop from these, so changing one changes the session's cost.
const (
	// ReadinessPullBound bounds one image pull.
	// Each registered image is about 9.1 GB compressed in 33 to 40 layers; on 2026-11-16 A's pull on g5.xlarge was
	// still running when a 600 s bound killed it, so this allows 6 MB/s with extraction.
	ReadinessPullBound = 1500 * time.Second
	// ReadinessModelBound bounds the model download into the persistent cache.
	// The weights are about 6 GB; the same download took 105 s on 2026-11-16 run 2 and was still running at a 300 s
	// bound on run 5 (unauthenticated Hugging Face Hub), so this allows 7 MB/s.
	ReadinessModelBound = 900 * time.Second
	// ReadinessCaptureBound bounds saving one ready engine's identity endpoints, all of them together.
	ReadinessCaptureBound = 20 * time.Second
	// ReadinessStopBound bounds reading one start's engine log and removing its container.
	ReadinessStopBound = 30 * time.Second
	// ReadinessWarmStarts is how many starts follow each treatment's first one.
	ReadinessWarmStarts = 2
)

// The outcomes a start can have.
const (
	// ReadinessReady is /health 200 and every priming request answered conformingly, inside the bound.
	ReadinessReady = "ready"
	// ReadinessMissed is a start the bound ran out on, which the study would record as an unavailable engine.
	ReadinessMissed = "missed"
	// ReadinessFailed is a start that ended inside the bound without becoming ready: a priming request that failed, or an engine that exited.
	ReadinessFailed = "failed"
)

// StepRecord is one timed setup step: an image pull or the model download.
type StepRecord struct {
	Step      string    `json:"step"`
	Image     string    `json:"image,omitempty"`
	StartedAt time.Time `json:"startedAt"`
	EndedAt   time.Time `json:"endedAt"`
	// Seconds is EndedAt minus StartedAt on the monotonic clock.
	Seconds float64 `json:"seconds"`
	Error   string  `json:"error,omitempty"`
	// Output is what the step's command printed, kept even when it failed, so a slow pull shows which layers it reached.
	Output string `json:"output,omitempty"`
}

// PrimingRecord is one priming request of a start.
type PrimingRecord struct {
	InputTokens  int       `json:"inputTokens"`
	OutputTokens int       `json:"outputTokens"`
	SentAt       time.Time `json:"sentAt"`
	// AnsweredAt is when the request ended, conforming or not; Disposition says which.
	AnsweredAt time.Time `json:"answeredAt"`
	// AnsweredSeconds is AnsweredAt measured from the start's DockerRunAt on the monotonic clock.
	AnsweredSeconds float64 `json:"answeredSeconds"`
	// Disposition is the study's disposition of the row, empty when the row was no outcome of the engine.
	Disposition string `json:"disposition,omitempty"`
	Error       string `json:"error,omitempty"`
}

// ReadinessStart is the record of one engine start, written when the start has ended and its container is gone.
type ReadinessStart struct {
	Treatment string `json:"treatment"`
	// Ordinal counts the treatment's starts from 1; the first is the one that ran on the least-warmed compile cache.
	Ordinal int    `json:"ordinal"`
	Image   string `json:"image"`
	// CompileCacheWarmedBy lists the treatments that had already started on this image's compile cache, in order.
	//
	// Empty means the cache was empty, a cold start; B and C share one image and so one cache, so C's first start follows B's.
	CompileCacheWarmedBy []string `json:"compileCacheWarmedBy"`
	ContainerID          string   `json:"containerID,omitempty"`
	RunArgs              []string `json:"runArgs,omitempty"`
	BoundSeconds         int      `json:"boundSeconds"`
	// DockerRunAt is taken before `docker run` is invoked, so every offset below includes container creation and can only overstate readiness.
	DockerRunAt time.Time `json:"dockerRunAt"`
	// ContainerStartedSeconds is when `docker run --detach` returned, from DockerRunAt; absent when it failed.
	ContainerStartedSeconds *float64 `json:"containerStartedSeconds,omitempty"`
	// HealthSeconds is the first /health 200, from DockerRunAt; absent when none came.
	HealthSeconds *float64        `json:"healthSeconds,omitempty"`
	Priming       []PrimingRecord `json:"priming"`
	// ReadySeconds is the last priming answer, from DockerRunAt, present only for a ready start.
	ReadySeconds *float64 `json:"readySeconds,omitempty"`
	Outcome      string   `json:"outcome"`
	Reason       string   `json:"reason,omitempty"`
	// LogFile names the engine's own log, kept beside the record; LogError says why it could not be read.
	LogFile  string `json:"logFile,omitempty"`
	LogError string `json:"logError,omitempty"`
	// Capture is the ready engine's identity endpoints, saved raw; CaptureSkipped says why a start has none.
	Capture        []CaptureRecord `json:"capture"`
	CaptureSkipped string          `json:"captureSkipped,omitempty"`
}

// CaptureRecord is one identity endpoint's raw answer, saved unparsed beside the start's record.
//
// No key of /server_info has been seen from a live server, so nothing here reads one; the files are the evidence a later identity check is written against.
type CaptureRecord struct {
	Name   string `json:"name"`
	Method string `json:"method"`
	Path   string `json:"path"`
	// RequestFile holds the exact body sent, for a request that has one.
	RequestFile string `json:"requestFile,omitempty"`
	// File holds the response body as it arrived, whatever its status.
	File   string `json:"file,omitempty"`
	Status int    `json:"status,omitempty"`
	Error  string `json:"error,omitempty"`
}

// ReadinessTreatment summarises one treatment's starts.
type ReadinessTreatment struct {
	Treatment string `json:"treatment"`
	// FirstSeconds is the first start's readiness, absent unless it was ready.
	FirstSeconds         *float64 `json:"firstSeconds,omitempty"`
	FirstOutcome         string   `json:"firstOutcome"`
	FirstCompileWarmedBy []string `json:"firstCompileCacheWarmedBy"`
	WarmStarts           int      `json:"warmStarts"`
	WarmReady            int      `json:"warmReady"`
	// WarmMaxSeconds and WarmMedianSeconds are given only when every warm start was ready.
	//
	// A missed start's readiness is only known to exceed the bound, so a maximum or median over it would be a number the evidence does not hold.
	WarmMaxSeconds    *float64 `json:"warmMaxSeconds,omitempty"`
	WarmMedianSeconds *float64 `json:"warmMedianSeconds,omitempty"`
	Missed            int      `json:"missed"`
	Failed            int      `json:"failed"`
}

// ReadinessSummary is the preflight's result, written last.
type ReadinessSummary struct {
	Study         string               `json:"study"`
	BoundSeconds  int                  `json:"boundSeconds"`
	Pulls         []StepRecord         `json:"pulls"`
	ModelDownload StepRecord           `json:"modelDownload"`
	Treatments    []ReadinessTreatment `json:"treatments"`
	// AllReady is true only when every start of every treatment was ready inside the bound.
	AllReady bool `json:"allReady"`
}

// ReadinessRun measures every treatment's engine starts on one instance.
type ReadinessRun struct {
	Study  string
	Design VersionStudyDesign
	Engine *DockerEngine
	// EngineURL is the base URL the started engine answers on.
	EngineURL string
	Sampling  SamplingPolicy
	// NewSender gives each start a sender of its own, so no connection to a removed container is reused.
	NewSender func() (Sender, error)
	// Health is the client /health is polled with; its timeout bounds one poll.
	Health *http.Client
	// Logs returns a container's own log, standard error included.
	Logs func(ctx context.Context, containerID string) ([]byte, error)
	// Out is the directory every record is written to; it must exist and be empty.
	Out string
	// PollEvery is how often /health is polled, so a start's health time is late by at most this.
	PollEvery time.Duration
	// StateEvery is how often the container's state is read while /health fails, so an engine that exited ends its start rather than waiting out the bound.
	StateEvery time.Duration
	// PullBound bounds one image pull; zero means ReadinessPullBound.
	// The SRPF sweep pulls a larger image from a slower registry, so it sets its own.
	PullBound time.Duration
}

// PrimingRows are one request per registered input x output class, in a fixed order, stamped as the study stamps its traces.
func (d VersionStudyDesign) PrimingRows() ([]TraceRow, error) {
	chars, err := d.promptChars()
	if err != nil {
		return nil, err
	}
	var rows []TraceRow
	for _, in := range d.InputTokens {
		for _, out := range d.OutputTokens {
			rows = append(rows, TraceRow{
				Index: len(rows), Tenant: PremiumTenant,
				PromptLenChars: chars[in.Tokens], MaxOutputTokens: out.Tokens, MinOutputTokens: out.Tokens,
			})
		}
	}
	if len(rows) == 0 {
		return nil, errors.New("the design registers no input x output class to prime")
	}
	stampExactTokens(rows)
	return rows, nil
}

// Run pulls each image, downloads the model, runs every treatment's starts in A, B, C order, and writes the summary.
//
// A missed or failed start is an outcome and the run goes on; a write error, a pull or download that failed, or a
// container that cannot be removed ends the run, because what follows would be unmeasured or contaminated.
func (r *ReadinessRun) Run(ctx context.Context) (ReadinessSummary, error) {
	if err := r.refuse(); err != nil {
		return ReadinessSummary{}, err
	}
	sum := ReadinessSummary{Study: r.Study, BoundSeconds: r.Design.Bounds.ReadinessSeconds}
	var images []string
	for _, t := range versionStudyTreatments {
		if img := r.Design.Engines[t].Image; !slices.Contains(images, img) {
			images = append(images, img)
		}
	}
	for i, img := range images {
		rec, err := r.pull(ctx, img)
		sum.Pulls = append(sum.Pulls, rec)
		if wErr := r.writeJSON(fmt.Sprintf("pull-%d.json", i+1), rec); wErr != nil {
			return sum, wErr
		}
		if err != nil {
			return sum, err
		}
	}
	rec, err := r.downloadModel(ctx, images[0])
	sum.ModelDownload = rec
	if wErr := r.writeJSON("model-download.json", rec); wErr != nil {
		return sum, wErr
	}
	if err != nil {
		return sum, err
	}
	warmedBy := map[string][]string{}
	sum.AllReady = true
	for _, t := range versionStudyTreatments {
		img := r.Design.Engines[t].Image
		var starts []ReadinessStart
		for n := 1; n <= 1+ReadinessWarmStarts; n++ {
			s, err := r.start(ctx, t, n, slices.Clone(warmedBy[img]))
			if wErr := r.writeJSON(fmt.Sprintf("start-%s-%d.json", t, n), s); wErr != nil {
				return sum, errors.Join(err, wErr)
			}
			if err != nil {
				return sum, err
			}
			if !slices.Contains(warmedBy[img], t) {
				warmedBy[img] = append(warmedBy[img], t)
			}
			starts = append(starts, s)
		}
		tr := SummarizeReadiness(t, starts)
		sum.Treatments = append(sum.Treatments, tr)
		if tr.FirstOutcome != ReadinessReady || tr.WarmReady != tr.WarmStarts {
			sum.AllReady = false
		}
	}
	return sum, r.writeJSON("summary.json", sum)
}

// refuse checks, before anything is pulled, that every timing the run takes would mean what its record says.
func (r *ReadinessRun) refuse() error {
	if err := r.Design.PaidRunRefusal(); err != nil {
		return err
	}
	if err := r.Design.PreflightRefusal(); err != nil {
		return err
	}
	if r.Design.Bounds.ReadinessSeconds <= 0 {
		return errors.New("the design registers no readiness bound")
	}
	if r.Engine == nil || r.NewSender == nil || r.Health == nil || r.Logs == nil || r.EngineURL == "" || r.PollEvery <= 0 || r.StateEvery <= 0 {
		return errors.New("the readiness run is missing its engine, sender, health client, log reader, URL or poll intervals")
	}
	// An out directory already holding records would mix two runs' evidence.
	if err := emptyOrAbsent(r.Out, false); err != nil {
		return fmt.Errorf("out directory: %w", err)
	}
	// A compile cache filled before the run would make the first start look cold when it is not.
	if err := emptyOrAbsent(r.Engine.CompileCacheRoot, true); err != nil {
		return fmt.Errorf("compile cache: %w", err)
	}
	// A model already cached would make the download step time nothing.
	if err := emptyOrAbsent(r.Engine.HFCache, true); err != nil {
		return fmt.Errorf("model cache: %w", err)
	}
	return nil
}

// emptyOrAbsent refuses a directory holding anything; absent is accepted only where the step creates it.
func emptyOrAbsent(dir string, absentOK bool) error {
	if dir == "" {
		return errors.New("no directory named")
	}
	entries, err := os.ReadDir(dir)
	switch {
	case err != nil && absentOK && errors.Is(err, os.ErrNotExist):
		return nil
	case err != nil:
		return err
	case len(entries) > 0:
		return fmt.Errorf("%s already holds %s", dir, entries[0].Name())
	}
	return nil
}

// pull times `docker pull` of one image, refusing an image already present, whose pull would time nothing.
func (r *ReadinessRun) pull(ctx context.Context, image string) (StepRecord, error) {
	if _, err := r.Engine.Run(ctx, "docker", "image", "inspect", "--format={{.Id}}", image); err == nil {
		return StepRecord{Step: "pull", Image: image}, fmt.Errorf("image %s is already present, so its pull cannot be timed", image)
	} else if !dockerNotFound(err) {
		return StepRecord{Step: "pull", Image: image}, fmt.Errorf("cannot tell whether image %s is present: %w", image, err)
	}
	bound := r.PullBound
	if bound == 0 {
		bound = ReadinessPullBound
	}
	pctx, cancel := context.WithTimeout(ctx, bound)
	defer cancel()
	rec := StepRecord{Step: "pull", Image: image}
	var out []byte
	rec, err := r.timed(rec, func() error {
		var err error
		out, err = r.Engine.Run(pctx, "docker", "pull", image)
		return err
	})
	rec.Output = string(out)
	return rec, err
}

// downloadModel fills the persistent model cache with the registered revision, inside image so no tool is installed on the host.
func (r *ReadinessRun) downloadModel(ctx context.Context, image string) (StepRecord, error) {
	mctx, cancel := context.WithTimeout(ctx, ReadinessModelBound)
	defer cancel()
	script := fmt.Sprintf("from huggingface_hub import snapshot_download; print(snapshot_download(repo_id=%q, revision=%q))",
		r.Design.Model, r.Design.ModelRevision)
	// A fresh token per attempt, so a failed run can only ever remove the container it created itself.
	name := r.Engine.NamePrefix + "-model-download-" + r.Engine.token()
	return r.timed(StepRecord{Step: "model-download", Image: image}, func() error {
		_, err := r.Engine.Run(mctx, "docker", "run", "--rm", "--name="+name,
			"--volume="+r.Engine.HFCache+":/root/.cache/huggingface",
			"--entrypoint=python3", image, "-c", script)
		if err != nil {
			// The deadline kills the docker CLI, not the container the daemon runs, which would go on downloading.
			return errors.Join(err, r.removeContainer(name))
		}
		return nil
	})
}

// removeContainer force-removes a container by name on its own context, since the step's context may be what expired.
//
// A container that never existed, or that --rm already removed, is gone, which is what is wanted.
func (r *ReadinessRun) removeContainer(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), dockerCleanupTimeout)
	defer cancel()
	if _, err := r.Engine.Run(ctx, "docker", "rm", "--force", name); err != nil && !dockerNotFound(err) {
		return fmt.Errorf("docker rm %s after a failed step: %w", name, err)
	}
	return nil
}

// timed runs step and records its wall span; a failed step keeps its span and its error.
func (r *ReadinessRun) timed(rec StepRecord, step func() error) (StepRecord, error) {
	start := time.Now()
	err := step()
	end := time.Now()
	rec.StartedAt, rec.EndedAt, rec.Seconds = start.UTC(), end.UTC(), end.Sub(start).Seconds()
	if err != nil {
		rec.Error = err.Error()
		return rec, fmt.Errorf("%s %s: %w", rec.Step, rec.Image, err)
	}
	return rec, nil
}

// start runs one engine start to its outcome, then reads its log and removes its container.
//
// The returned error is only for what makes later starts unsafe to measure: a container that could not be started
// cleanly or removed.
// The engine not becoming ready is the start's outcome, not an error.
func (r *ReadinessRun) start(ctx context.Context, treatment string, ordinal int, warmedBy []string) (ReadinessStart, error) {
	if warmedBy == nil {
		warmedBy = []string{}
	}
	bound := time.Duration(r.Design.Bounds.ReadinessSeconds) * time.Second
	s := ReadinessStart{
		Treatment: treatment, Ordinal: ordinal, Image: r.Design.Engines[treatment].Image,
		CompileCacheWarmedBy: warmedBy, BoundSeconds: r.Design.Bounds.ReadinessSeconds, Priming: []PrimingRecord{},
	}
	t0 := time.Now()
	s.DockerRunAt = t0.UTC()
	since := func(t time.Time) *float64 { v := t.Sub(t0).Seconds(); return &v }
	// The bound runs from before docker run, so the container's creation is inside it, as the process start is in the study.
	sctx, cancel := context.WithDeadline(ctx, t0.Add(bound))
	defer cancel()
	visit := fmt.Sprintf("ready-%s-%d", treatment, ordinal)
	es, err := r.Engine.Start(sctx, r.Design, treatment, visit)
	if err != nil {
		s.Outcome, s.Reason = ReadinessFailed, err.Error()
		return s, fmt.Errorf("start %s #%d: %w", treatment, ordinal, err)
	}
	s.ContainerID, s.RunArgs = es.ContainerID, es.RunArgs
	s.ContainerStartedSeconds = since(time.Now())

	s.Outcome, s.Reason = r.becomeReady(sctx, &s, t0, es)
	if ctx.Err() != nil {
		// The run itself was stopped, which says nothing about the engine, so the start is not given an outcome.
		s.Outcome, s.Reason = "", "the run was stopped during this start"
		return s, errors.Join(fmt.Errorf("start %s #%d: the run was stopped: %w", treatment, ordinal, ctx.Err()), r.finish(ctx, &s, es))
	}
	if s.Outcome == ReadinessReady && time.Since(t0) > bound {
		// An answer that arrived after the bound is not readiness the study would accept.
		s.Outcome, s.Reason = ReadinessMissed, "every priming request answered, but after the bound"
		s.ReadySeconds = nil
	}
	s.Capture = []CaptureRecord{}
	if s.Outcome == ReadinessReady {
		// Taken after ready is stamped, so its requests never count toward readiness.
		r.capture(ctx, &s)
	} else {
		s.CaptureSkipped = "the engine was not ready, so its identity endpoints were not read"
	}
	return s, r.finish(ctx, &s, es)
}

// identityPrompt is the one user message /tokenize renders, fixed so every start's answer is comparable byte for byte.
const identityPrompt = "Identity check: reply with the word ready."

// maxCaptureBytes bounds one saved response, so a misbehaving endpoint cannot exhaust memory.
const maxCaptureBytes = 16 << 20

// capture saves the ready engine's identity endpoints raw, beside the start's record.
//
// Readiness is the preflight's primary measurement, so a capture that fails, including a file that cannot be written,
// is recorded on its endpoint and the run goes on; only the start record and the engine log are fatal to lose.
func (r *ReadinessRun) capture(parent context.Context, s *ReadinessStart) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), ReadinessCaptureBound)
	defer cancel()
	tokenize, err := json.Marshal(map[string]any{
		"model":                 r.Engine.ServedName,
		"messages":              []map[string]string{{"role": "user", "content": identityPrompt}},
		"add_generation_prompt": true,
		"add_special_tokens":    false,
	})
	if err != nil {
		s.CaptureSkipped = err.Error()
		return
	}
	prefix := fmt.Sprintf("start-%s-%d.capture.", s.Treatment, s.Ordinal)
	for _, ep := range []struct {
		name, method, path string
		body               []byte
	}{
		{"version", http.MethodGet, "/version", nil},
		{"models", http.MethodGet, "/v1/models", nil},
		{"server-info", http.MethodGet, "/server_info?config_format=json", nil},
		{"metrics", http.MethodGet, "/metrics", nil},
		{"tokenize", http.MethodPost, "/tokenize", tokenize},
	} {
		rec := CaptureRecord{Name: ep.name, Method: ep.method, Path: ep.path}
		var errs []error
		if ep.body != nil {
			rec.RequestFile = prefix + ep.name + ".request"
			errs = append(errs, WriteNewFileDurably(filepath.Join(r.Out, rec.RequestFile), ep.body))
		}
		status, body, err := r.fetch(ctx, ep.method, ep.path, ep.body)
		rec.Status = status
		errs = append(errs, err)
		if body != nil {
			rec.File = prefix + ep.name
			errs = append(errs, WriteNewFileDurably(filepath.Join(r.Out, rec.File), body))
		}
		if err == nil && status != http.StatusOK {
			errs = append(errs, fmt.Errorf("status %d", status))
		}
		if e := errors.Join(errs...); e != nil {
			rec.Error = e.Error()
		}
		s.Capture = append(s.Capture, rec)
	}
}

// fetch sends one request to the engine and returns its status and body as they arrived.
func (r *ReadinessRun) fetch(ctx context.Context, method, path string, body []byte) (int, []byte, error) {
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(r.EngineURL, "/")+path, rd)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := r.Health.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxCaptureBytes+1))
	if err == nil && len(data) > maxCaptureBytes {
		err = fmt.Errorf("response over %d bytes; the saved file is cut there", maxCaptureBytes)
		data = data[:maxCaptureBytes]
	}
	return resp.StatusCode, data, err
}

// becomeReady polls /health, then sends the priming requests one at a time, and returns the start's outcome.
//
// The requests go one at a time, so each answer is its own time and the slowest order is measured, not a concurrent best case.
func (r *ReadinessRun) becomeReady(ctx context.Context, s *ReadinessStart, t0 time.Time, es EngineStart) (string, string) {
	since := func(t time.Time) *float64 { v := t.Sub(t0).Seconds(); return &v }
	missed := func(what string) (string, string) {
		return ReadinessMissed, fmt.Sprintf("%s within the %d s bound", what, s.BoundSeconds)
	}
	healthAt, exited, err := r.waitHealthy(ctx, es)
	switch {
	case exited != "":
		return ReadinessFailed, "the engine container " + exited + " before /health returned 200"
	case err != nil:
		return missed("no /health 200")
	}
	s.HealthSeconds = since(healthAt)

	rows, err := r.Design.PrimingRows()
	if err != nil {
		return ReadinessFailed, err.Error()
	}
	sender, err := r.NewSender()
	if err != nil {
		return ReadinessFailed, err.Error()
	}
	prefix := fmt.Sprintf("ready-%s-%d", s.Treatment, s.Ordinal)
	if ps, ok := sender.(interface{ SetRequestIDPrefix(string) }); ok {
		ps.SetRequestIDPrefix(prefix)
	}
	exact := versionStudyExactTokens()
	var last time.Time
	for _, tr := range rows {
		rec := PrimingRecord{InputTokens: exact[tr.PromptLenChars], OutputTokens: tr.MaxOutputTokens, SentAt: time.Now().UTC()}
		got := Replay(ctx, sender, []TraceRow{tr}, ReplayOptions{Study: r.Study, Arm: s.Treatment, RequestIDPrefix: prefix})
		end := time.Now()
		rec.AnsweredAt, rec.AnsweredSeconds = end.UTC(), end.Sub(t0).Seconds()
		disp, dErr := StudyDisposition(r.Sampling, got[0], tr)
		rec.Disposition = string(disp)
		switch {
		case dErr != nil:
			rec.Error = dErr.Error()
		case disp != DispositionSuccess:
			rec.Error = fmt.Sprintf("disposition %s (raw %s %s)", disp, got[0].Disposition, got[0].ErrorKind)
		}
		s.Priming = append(s.Priming, rec)
		if rec.Error != "" {
			if ctx.Err() != nil {
				return missed(fmt.Sprintf("the (%d, %d) priming request not answered", rec.InputTokens, rec.OutputTokens))
			}
			return ReadinessFailed, fmt.Sprintf("the (%d, %d) priming request: %s", rec.InputTokens, rec.OutputTokens, rec.Error)
		}
		last = end
	}
	s.ReadySeconds = since(last)
	return ReadinessReady, ""
}

// waitHealthy polls /health until it returns 200, the container exits, or ctx ends.
//
// It reports the time of the first 200, or the container's state if it stopped running.
func (r *ReadinessRun) waitHealthy(ctx context.Context, es EngineStart) (time.Time, string, error) {
	url := strings.TrimRight(r.EngineURL, "/") + "/health"
	lastState := time.Now()
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return time.Time{}, "", err
		}
		if resp, err := r.Health.Do(req); err == nil {
			at := time.Now()
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return at, "", nil
			}
		}
		if time.Since(lastState) >= r.StateEvery {
			lastState = time.Now()
			out, err := r.Engine.Run(ctx, "docker", "inspect", "--format={{.State.Status}}", es.ContainerID)
			if st := strings.TrimSpace(string(out)); err == nil && st != "running" && st != "created" {
				return time.Time{}, "was " + st, nil
			}
		}
		select {
		case <-ctx.Done():
			return time.Time{}, "", ctx.Err()
		case <-time.After(r.PollEvery):
		}
	}
}

// finish keeps the engine's log and removes the container, on a context of its own so a start that ran out its bound still cleans up.
func (r *ReadinessRun) finish(parent context.Context, s *ReadinessStart, es EngineStart) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), ReadinessStopBound)
	defer cancel()
	logs, err := r.Logs(ctx, es.ContainerID)
	if err != nil {
		s.LogError = err.Error()
	}
	if len(logs) > 0 {
		name := fmt.Sprintf("start-%s-%d.engine.log", s.Treatment, s.Ordinal)
		if err := WriteNewFileDurably(filepath.Join(r.Out, name), logs); err != nil {
			// The container is still removed, so the next start is not refused for a GPU this one holds.
			return errors.Join(fmt.Errorf("engine log: %w", err), r.Engine.Stop(ctx, es))
		}
		s.LogFile = name
	}
	if err := r.Engine.Stop(ctx, es); err != nil {
		return fmt.Errorf("stop %s #%d: %w", s.Treatment, s.Ordinal, err)
	}
	return nil
}

// writeJSON writes one record durably and never over another.
func (r *ReadinessRun) writeJSON(name string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Errorf("encode %s: %w", name, err)
	}
	if err := WriteNewFileDurably(filepath.Join(r.Out, name), append(data, '\n')); err != nil {
		return fmt.Errorf("write %s: %w", name, err)
	}
	return nil
}

// SummarizeReadiness reduces one treatment's starts, first start first, to the figures the budget amendment reads.
//
// The median of an even count is the mean of the middle two, the usual definition; with two warm starts that is their mean.
func SummarizeReadiness(treatment string, starts []ReadinessStart) ReadinessTreatment {
	t := ReadinessTreatment{Treatment: treatment, FirstCompileWarmedBy: []string{}}
	var warm []float64
	for i, s := range starts {
		switch s.Outcome {
		case ReadinessMissed:
			t.Missed++
		case ReadinessFailed:
			t.Failed++
		}
		if i == 0 {
			t.FirstOutcome, t.FirstCompileWarmedBy = s.Outcome, s.CompileCacheWarmedBy
			if s.Outcome == ReadinessReady {
				t.FirstSeconds = s.ReadySeconds
			}
			continue
		}
		t.WarmStarts++
		if s.Outcome == ReadinessReady && s.ReadySeconds != nil {
			t.WarmReady++
			warm = append(warm, *s.ReadySeconds)
		}
	}
	if t.WarmStarts > 0 && t.WarmReady == t.WarmStarts {
		slices.Sort(warm)
		mx := warm[len(warm)-1]
		med := warm[len(warm)/2]
		if len(warm)%2 == 0 {
			med = (warm[len(warm)/2-1] + warm[len(warm)/2]) / 2
		}
		t.WarmMaxSeconds, t.WarmMedianSeconds = &mx, &med
	}
	return t
}
