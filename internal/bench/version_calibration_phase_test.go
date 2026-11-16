package bench

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// calibrationPhase builds the phase on f with a ladder that resolves at once and records its artifact in the log.
func (f *fakePreflight) calibrationPhase() CalibrationPhase {
	return CalibrationPhase{
		Design: versionAsyncDesign(), Engine: f, Ready: f.ready, Runtime: f.runtime, Check: f.check,
		WriteIdentity: func(RuntimeIdentity) error { return f.WriteIdentity(f.current, RuntimeIdentity{}) },
		Calibrate: func(context.Context) (CalibrationResult, error) {
			f.log = append(f.log, "ladder", "artifact")
			return CalibrationResult{Resolved: true, Rate: 4}, nil
		},
	}
}

// oneRungRule is a ladder of one one-second rung, so its MaxSeconds bound is a second.
func oneRungRule() CalibrationRule {
	return CalibrationRule{StartRate: 1, Growth: 2, MaxExpansion: 1, TargetRatio: 1.05, WindowSeconds: 1}
}

// TestCalibrationPhaseRunsTheLadderOnItsOwnEngineOfA: a fresh A, ready and checked, the ladder, then A stopped.
func TestCalibrationPhaseRunsTheLadderOnItsOwnEngineOfA(t *testing.T) {
	f := newFakePreflight()
	res, err := f.calibrationPhase().Run(context.Background())
	if err != nil || res.Stop != "" || !res.Calibration.Resolved {
		t.Fatalf("result %+v err %v", res, err)
	}
	want := "start calibration-A|ready A|identity A|check A|ladder|artifact|stop calibration-A"
	if got := strings.Join(f.log, "|"); got != want {
		t.Fatalf("calls\n %s\nwant\n %s", got, want)
	}
}

// TestCalibrationPhaseStops: what each event makes of calibration, and that A never outlives the phase.
func TestCalibrationPhaseStops(t *testing.T) {
	run := func(t *testing.T, f *fakePreflight, c CalibrationPhase) (CalibrationPhaseResult, string, error) {
		t.Helper()
		res, err := c.Run(context.Background())
		return res, strings.Join(f.log, "|"), err
	}
	t.Run("an A that misses readiness stops the session before any rung", func(t *testing.T) {
		f := newFakePreflight()
		f.notReady = TreatmentA
		res, got, err := run(t, f, f.calibrationPhase())
		if err != nil || !strings.Contains(res.Stop, "not ready") || got != "start calibration-A|ready A|stop calibration-A" {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("an A the registration refuses stops the session before any rung", func(t *testing.T) {
		f := newFakePreflight()
		f.refuse = TreatmentA
		res, got, err := run(t, f, f.calibrationPhase())
		if err != nil || !strings.Contains(res.Stop, "identity") || got != "start calibration-A|ready A|identity A|check A|stop calibration-A" {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
	t.Run("an unresolved ladder stops the session with the ladder's own reason", func(t *testing.T) {
		f := newFakePreflight()
		c := f.calibrationPhase()
		c.Calibrate = func(context.Context) (CalibrationResult, error) {
			return CalibrationResult{Reason: "calibration unresolved: no upper bracket"}, nil
		}
		res, _, err := run(t, f, c)
		if err != nil || res.Stop != "calibration unresolved: no upper bracket" {
			t.Fatalf("result %+v err %v", res, err)
		}
	})
	t.Run("a recorder failure in the ladder is an error, and A is stopped", func(t *testing.T) {
		f := newFakePreflight()
		c := f.calibrationPhase()
		c.Calibrate = func(context.Context) (CalibrationResult, error) {
			return CalibrationResult{Resolved: true, Rate: 4}, errors.New("rung evidence: no space left on device")
		}
		_, got, err := run(t, f, c)
		if err == nil || !strings.HasSuffix(got, "stop calibration-A") {
			t.Fatalf("err %v calls %s", err, got)
		}
	})
	t.Run("an A that cannot be confirmed removed is an error even after a resolved ladder", func(t *testing.T) {
		f := newFakePreflight()
		f.stopErr = fmt.Errorf("%w: container still present", ErrEngineCleanup)
		if _, _, err := run(t, f, f.calibrationPhase()); !errors.Is(err, ErrEngineCleanup) {
			t.Fatalf("err %v", err)
		}
	})
	t.Run("the bound cuts the ladder, which ends unresolved and is recorded by the ladder's own path", func(t *testing.T) {
		f := newFakePreflight()
		c := f.calibrationPhase()
		c.Design.Calibration = oneRungRule()
		var recorded CalibrationResult
		// The recorder stands for runVersionCalibration: RunContext over the probe, then the artifact from its result.
		c.Calibrate = func(ctx context.Context) (CalibrationResult, error) {
			res := c.Design.Calibration.RunContext(ctx, func(ctx context.Context, _ float64, _ int) RungClass {
				<-ctx.Done()
				return RungStable
			})
			recorded = res
			f.log = append(f.log, "artifact")
			return res, nil
		}
		began := time.Now()
		res, got, err := run(t, f, c)
		if err != nil || res.Calibration.Resolved || !strings.Contains(res.Stop, "calibration reached its 1s bound") ||
			recorded.Reason != res.Stop || !strings.HasSuffix(got, "artifact|stop calibration-A") || time.Since(began) > 5*time.Second {
			t.Fatalf("result %+v recorded %+v err %v calls %s", res, recorded, err, got)
		}
	})
	t.Run("the bound counts A's start and readiness too", func(t *testing.T) {
		f := newFakePreflight()
		f.blockReady = true
		c := f.calibrationPhase()
		c.Design.Calibration = oneRungRule()
		res, got, err := run(t, f, c)
		if err != nil || !strings.Contains(res.Stop, "before A was ready: calibration reached its 1s bound") ||
			got != "start calibration-A|ready A|stop calibration-A" {
			t.Fatalf("result %+v err %v calls %s", res, err, got)
		}
	})
}
