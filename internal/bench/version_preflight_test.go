package bench

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// fakePreflight is the instance a preflight or calibration runs on: fakeInstance's engine, plus the readiness, identity,
// replay and evidence steps, every call logged in order.
type fakePreflight struct {
	*fakeInstance
	// notReady, refuse and fail name the treatment whose readiness, identity or one request goes wrong.
	notReady string
	refuse   string
	fail     string
	// block makes readiness or replay wait until its context ends, as an engine that never answers does.
	blockReady  bool
	blockReplay bool
	writeErr    error
	current     string
}

func newFakePreflight() *fakePreflight { return &fakePreflight{fakeInstance: &fakeInstance{}} }

func (f *fakePreflight) Start(ctx context.Context, d VersionStudyDesign, treatment, visit string) (EngineStart, error) {
	f.current = treatment
	return f.fakeInstance.Start(ctx, d, treatment, visit)
}

func (f *fakePreflight) ready(ctx context.Context) error {
	f.log = append(f.log, "ready "+f.current)
	if f.blockReady {
		<-ctx.Done()
		return ctx.Err()
	}
	if f.notReady == f.current {
		return errors.New("health never 200")
	}
	return nil
}

func (f *fakePreflight) runtime(context.Context) (RuntimeIdentity, error) {
	return RuntimeIdentity{VLLMVersion: f.current}, nil
}

func (f *fakePreflight) check(treatment string, rt RuntimeIdentity) error {
	f.log = append(f.log, "check "+treatment)
	if rt.VLLMVersion != treatment {
		return fmt.Errorf("checked %s against the identity of %s", treatment, rt.VLLMVersion)
	}
	if f.refuse == treatment {
		return errors.New("engine reports v0.31.0")
	}
	return nil
}

func (f *fakePreflight) replay(ctx context.Context, treatment string, trace []TraceRow) []RawRow {
	f.log = append(f.log, "replay "+treatment)
	if f.blockReplay {
		<-ctx.Done()
	}
	rows := make([]RawRow, 0, len(trace))
	for _, tr := range trace {
		r := conformingRow(tr)
		r.ScheduledOffsetMs, r.Tenant = tr.OffsetMs, tr.Tenant
		if ctx.Err() != nil {
			r.Disposition, r.ErrorKind = errKindCancelled, errKindCancelled
		}
		rows = append(rows, r)
	}
	if f.fail == treatment {
		rows[7].Disposition, rows[7].ErrorKind, rows[7].HTTPStatus, rows[7].StreamTerminated = "http", "http", 500, false
	}
	return rows
}

func (f *fakePreflight) WriteIdentity(treatment string, _ RuntimeIdentity) error {
	f.log = append(f.log, "identity "+treatment)
	return nil
}

func (f *fakePreflight) WriteRows(treatment string, _ []RawRow) error {
	f.log = append(f.log, "rows "+treatment)
	return f.writeErr
}

func (f *fakePreflight) preflight() Preflight {
	return Preflight{
		Design: versionAsyncDesign(), Sampling: *versionStudySampling(), Engine: f,
		Ready: f.ready, Runtime: f.runtime, Check: f.check, Replay: f.replay, IO: f,
	}
}

// passed is one treatment's whole preflight, as the log records it.
func passed(t string) string {
	return fmt.Sprintf("start preflight-%s|ready %s|identity %s|check %s|replay %s|rows %s|stop preflight-%s", t, t, t, t, t, t, t)
}

// TestPreflightTrace: thirty requests, every input × output class five times, each carrying the frozen token count.
func TestPreflightTrace(t *testing.T) {
	d := versionAsyncDesign()
	trace, err := d.PreflightTrace()
	if err != nil {
		t.Fatal(err)
	}
	if len(trace) != 30 {
		t.Fatalf("%d rows, want 30", len(trace))
	}
	classes := map[[2]int]int{}
	for i, r := range trace {
		if r.Index != i || r.OffsetMs != int64(i)*1000 || r.MinOutputTokens != r.MaxOutputTokens || r.ExactInputTokens == 0 {
			t.Fatalf("row %d %+v", i, r)
		}
		classes[[2]int{r.ExactInputTokens, r.MaxOutputTokens}]++
	}
	if len(classes) != 6 {
		t.Fatalf("classes %v, want six", classes)
	}
	for c, n := range classes {
		if n != 5 {
			t.Fatalf("class %v sent %d times, want 5", c, n)
		}
	}
	d.OutputTokens = append(d.OutputTokens, LengthWeight{128, 0})
	if _, err := d.PreflightTrace(); err == nil {
		t.Fatal("thirty requests over nine classes were accepted")
	}
}

// TestPreflightRunsEachTreatmentOnItsOwnEngine: A, B, C in that order, each started, checked, sent and stopped before the next starts.
func TestPreflightRunsEachTreatmentOnItsOwnEngine(t *testing.T) {
	f := newFakePreflight()
	res, err := f.preflight().Run(context.Background())
	if err != nil || res.Stop != "" || strings.Join(res.Passed, "") != "ABC" {
		t.Fatalf("result %+v err %v", res, err)
	}
	want := strings.Join([]string{passed("A"), passed("B"), passed("C")}, "|")
	if got := strings.Join(f.log, "|"); got != want {
		t.Fatalf("calls\n %s\nwant\n %s", got, want)
	}
}

// TestPreflightStops: every way a treatment fails stops the session before calibration, and no later treatment starts.
func TestPreflightStops(t *testing.T) {
	run := func(t *testing.T, f *fakePreflight, p Preflight) (PreflightResult, string, error) {
		t.Helper()
		res, err := p.Run(context.Background())
		return res, strings.Join(f.log, "|"), err
	}
	t.Run("an engine that misses readiness stops the session, and the next treatment never starts", func(t *testing.T) {
		f := newFakePreflight()
		f.notReady = TreatmentB
		res, got, err := run(t, f, f.preflight())
		if err != nil || !strings.Contains(res.Stop, "treatment B") || !strings.Contains(res.Stop, "not ready") ||
			got != passed("A")+"|start preflight-B|ready B|stop preflight-B" {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("an identity the registration refuses stops the session before any request, on record", func(t *testing.T) {
		f := newFakePreflight()
		f.refuse = TreatmentA
		res, got, err := run(t, f, f.preflight())
		if err != nil || !strings.Contains(res.Stop, "identity: engine reports v0.31.0") ||
			got != "start preflight-A|ready A|identity A|check A|stop preflight-A" {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("one failed request of thirty stops the session, its rows kept", func(t *testing.T) {
		f := newFakePreflight()
		f.fail = TreatmentC
		res, got, err := run(t, f, f.preflight())
		if err != nil || !strings.Contains(res.Stop, "treatment C") || !strings.Contains(res.Stop, "row 7 ended http-error") ||
			strings.Join(res.Passed, "") != "AB" || !strings.HasSuffix(got, "rows C|stop preflight-C") {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("a start that left nothing behind stops the session, and nothing is stopped", func(t *testing.T) {
		f := newFakePreflight()
		f.startErr = func(int) error { return errors.New("docker run: image pull failed") }
		res, got, err := run(t, f, f.preflight())
		if err != nil || !strings.Contains(res.Stop, "did not start") || got != "start preflight-A" {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("a start whose container could not be removed is an error", func(t *testing.T) {
		f := newFakePreflight()
		f.startErr = func(int) error {
			return errors.Join(errors.New("docker run failed"), fmt.Errorf("%w: container still present", ErrEngineCleanup))
		}
		if _, got, err := run(t, f, f.preflight()); !errors.Is(err, ErrEngineCleanup) || got != "start preflight-A" {
			t.Fatalf("err %v calls %s", err, got)
		}
	})
	t.Run("an engine that cannot be confirmed removed is an error, and no other engine joins it", func(t *testing.T) {
		f := newFakePreflight()
		f.stopErr = fmt.Errorf("%w: container still present", ErrEngineCleanup)
		res, got, err := run(t, f, f.preflight())
		if !errors.Is(err, ErrEngineCleanup) || len(res.Passed) != 0 || got != passed("A") {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("a cleanup failure after a stop keeps the stop's reason", func(t *testing.T) {
		f := newFakePreflight()
		f.refuse = TreatmentA
		f.stopErr = fmt.Errorf("%w: container still present", ErrEngineCleanup)
		_, _, err := run(t, f, f.preflight())
		if !errors.Is(err, ErrEngineCleanup) || !strings.Contains(fmt.Sprint(err), "engine reports v0.31.0") {
			t.Fatalf("err %v", err)
		}
	})
	t.Run("a failed evidence write is an error, and the engine is still stopped", func(t *testing.T) {
		f := newFakePreflight()
		f.writeErr = errors.New("no space left on device")
		_, got, err := run(t, f, f.preflight())
		if err == nil || got != passed("A") {
			t.Fatalf("err %v calls %s", err, got)
		}
	})
	t.Run("the per-treatment bound cuts the requests, and the cut is not charged to the engine", func(t *testing.T) {
		f := newFakePreflight()
		f.blockReplay = true
		p := f.preflight()
		p.Design.Bounds.PreflightSecondsPerTreatment = 1
		began := time.Now()
		res, got, err := run(t, f, p)
		if err != nil || !strings.Contains(res.Stop, "preflight bound passed during the preflight requests") ||
			strings.Contains(res.Stop, "ended") || got != passed("A") || time.Since(began) > 5*time.Second {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("the per-treatment bound covers readiness too", func(t *testing.T) {
		f := newFakePreflight()
		f.blockReady = true
		p := f.preflight()
		p.Design.Bounds.PreflightSecondsPerTreatment = 1
		res, got, err := run(t, f, p)
		if err != nil || !strings.Contains(res.Stop, "preflight bound passed during start and readiness") ||
			got != "start preflight-A|ready A|stop preflight-A" {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("a session stop is named as the session's, not the treatment's", func(t *testing.T) {
		f := newFakePreflight()
		f.blockReplay = true
		ctx, cancel := context.WithCancelCause(context.Background())
		f.cancel = func() { cancel(errors.New("stopped by signal: terminated")) }
		p := f.preflight()
		replay := p.Replay
		p.Replay = func(ctx context.Context, tr string, trace []TraceRow) []RawRow {
			f.cancel()
			return replay(ctx, tr, trace)
		}
		res, err := p.Run(ctx)
		if err != nil || !strings.Contains(res.Stop, "the session stopped during the preflight requests: stopped by signal") {
			t.Fatalf("result %+v err %v", res, err)
		}
	})
}
