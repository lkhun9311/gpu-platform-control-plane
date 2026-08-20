package queuelab

import (
	"testing"
	"time"
)

// skewed builds an event carrying an observed skew, which is the only field these tests read.
func skewed(ns int64) LifecycleEvent {
	v := ns
	return LifecycleEvent{ObservedSkewNs: &v}
}

// A uniformly late harness measures intervals exactly, so the floor must come from the spread and never
// from the median. This is the test that fails if someone "simplifies" FloorNs to MedianNs, which is the
// number a reader reaches for first and the wrong one.
func TestSpreadOfFloorIgnoresHowLateTheHarnessIs(t *testing.T) {
	late := SpreadOf([]LifecycleEvent{skewed(9 * int64(time.Second)), skewed(9 * int64(time.Second))})
	if late == nil {
		t.Fatal("two samples must bound something")
	}
	if late.MedianNs != 9*int64(time.Second) {
		t.Fatalf("median = %d, want 9s", late.MedianNs)
	}
	if late.FloorNs != int64(time.Second) {
		t.Fatalf("floor = %d, want the quantisation floor: a constant lag cancels in a difference", late.FloorNs)
	}
}

// A spread wider than the quantisation is what actually limits the run, so it must win.
func TestSpreadOfFloorTakesTheSpreadWhenItExceedsQuantisation(t *testing.T) {
	s := SpreadOf([]LifecycleEvent{
		skewed(430 * int64(time.Millisecond)),
		skewed(1200 * int64(time.Millisecond)),
		skewed(2389 * int64(time.Millisecond)),
	})
	want := 1959 * int64(time.Millisecond)
	if s.FloorNs != want {
		t.Fatalf("floor = %d, want %d (2389ms - 430ms)", s.FloorNs, want)
	}
}

// One reading has a spread of zero, and zero would be the strongest claim the struct can make. Refusing is
// the point: a single observation has nothing to be spread against.
func TestSpreadOfRefusesASingleSample(t *testing.T) {
	if s := SpreadOf([]LifecycleEvent{skewed(50)}); s != nil {
		t.Fatalf("one sample bounded a spread: %+v", s)
	}
	if s := SpreadOf(nil); s != nil {
		t.Fatalf("no samples bounded a spread: %+v", s)
	}
}

// The published mistake, as a test: a sub-second residual against the run's own 0.4-2.4s spread is not a
// measurement, and Resolves is what has to say so.
func TestResolvesRejectsTheResidualThisLabOncePublished(t *testing.T) {
	s := SpreadOf([]LifecycleEvent{
		skewed(430 * int64(time.Millisecond)),
		skewed(2389 * int64(time.Millisecond)),
	})
	if s.Resolves(940 * int64(time.Millisecond)) {
		t.Fatal("0.94s was reported as the control plane's cost against this spread; it must not resolve")
	}
	// The categorical difference the lab does support: 41 GPU-seconds against 0.
	if !s.Resolves(41 * int64(time.Second)) {
		t.Fatal("an order-of-magnitude difference must survive the floor, or the gate is useless")
	}
}

// Sign must not decide the answer: a residual is as unresolved when the observation runs early as when it
// runs late.
func TestResolvesIsSymmetricAboutZero(t *testing.T) {
	s := SpreadOf([]LifecycleEvent{skewed(0), skewed(3 * int64(time.Second))})
	if s.Resolves(-2 * int64(time.Second)) {
		t.Fatal("a negative residual inside the floor resolved")
	}
	if !s.Resolves(-4 * int64(time.Second)) {
		t.Fatal("a negative residual beyond the floor did not resolve")
	}
}

// A nil spread means no bound was established, and the safe reading of no bound is that nothing resolves.
func TestNilSpreadResolvesNothing(t *testing.T) {
	var s *ObservationSpread
	if s.Resolves(int64(time.Hour)) {
		t.Fatal("an unbounded run resolved an hour; absent evidence must not read as good evidence")
	}
}
