package main

import (
	"strings"
	"testing"
	"time"
)

// cmpRec builds a minimal admissible record for the comparison tests.
func cmpRec(runID, arm, dose, startedAt string, waste float64, floorNs int64) runRecord {
	m := &measurement{WastedGPUSeconds: waste}
	if floorNs > 0 {
		m.Resolution = &observationResolution{Samples: 2, ResolvedToNs: floorNs, QuantisationNs: int64(time.Second)}
	}
	return runRecord{
		SchemaVersion: recordSchemaVersion,
		RunID:         runID,
		Arm:           arm,
		Dose:          dose,
		StartedAt:     startedAt,
		Measurement:   m,
		Validity:      validity{Verdict: verdictAdmissible, DeviceEvidence: deviceNotObserved},
	}
}

// The difference the lab actually supports: an order of magnitude against a two-second floor.
func TestCompareResolvesTheCategoricalDifference(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("r001", "A-honor", "self-completing", "2026-08-19T05:45:57Z", 41.0, 1959*int64(time.Millisecond)),
		cmpRec("r002", "A-ignore", "self-completing", "2026-08-19T05:48:56Z", 0.0, 1959*int64(time.Millisecond)),
		cmpRec("r003", "A-honor", "self-completing", "2026-08-19T05:52:50Z", 40.9, 1959*int64(time.Millisecond)),
		cmpRec("r004", "A-ignore", "self-completing", "2026-08-19T05:55:30Z", 0.0, 1959*int64(time.Millisecond)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if !c.Bounded || !c.Interleaved {
		t.Fatalf("bounded=%v interleaved=%v, want both true", c.Bounded, c.Interleaved)
	}
	if len(c.Findings) != 1 || !c.Findings[0].Resolved {
		t.Fatalf("a 41s difference against a 1.959s floor must resolve: %+v", c.Findings)
	}
	if strings.Contains(c.Findings[0].Statement, "CONFOUNDED") {
		t.Fatalf("alternating runs reported as confounded: %s", c.Findings[0].Statement)
	}
}

// The retracted claim, as a test: a sub-second difference against this lab's own floor must come back NOT
// RESOLVED, and the statement must say why repeating the runs would not help.
func TestCompareRefusesADifferenceInsideTheFloor(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "2026-08-19T05:00:00Z", 41.0, 1959*int64(time.Millisecond)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-19T05:05:00Z", 40.06, 1959*int64(time.Millisecond)),
		cmpRec("a2", "A-honor", "self-completing", "2026-08-19T05:10:00Z", 41.0, 1959*int64(time.Millisecond)),
		cmpRec("b2", "A-ignore", "self-completing", "2026-08-19T05:15:00Z", 40.06, 1959*int64(time.Millisecond)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if c.Findings[0].Resolved {
		t.Fatalf("0.94s resolved against a 1.959s floor: %+v", c.Findings[0])
	}
	if !strings.Contains(c.Findings[0].Statement, "NOT RESOLVED") ||
		!strings.Contains(c.Findings[0].Statement, "not a noise level") {
		t.Fatalf("statement does not tell the reader repetition will not help: %s", c.Findings[0].Statement)
	}
}

// The floor is the WORST among contributors, because that run's coarseness is inside every difference it
// contributes to. Taking the best would let one well-resolved run launder a poorly-resolved one.
func TestComparePoolsTheCoarsestFloor(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "2026-08-19T05:00:00Z", 41.0, 100*int64(time.Millisecond)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-19T05:05:00Z", 36.0, 6*int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if c.FloorSeconds != 6 {
		t.Fatalf("pooled floor = %v, want the coarsest contributor's 6s", c.FloorSeconds)
	}
	if c.Findings[0].Resolved {
		t.Fatal("a 5s difference resolved against a 6s floor")
	}
}

// One unbounded run makes the whole comparison unbounded: there is no bound to pool.
func TestCompareIsUnboundedWhenAnyRunBoundedNothing(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "2026-08-19T05:00:00Z", 41.0, int64(time.Second)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-19T05:05:00Z", 0.0, 0),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if c.Bounded || c.Findings[0].Resolved {
		t.Fatalf("an unbounded contributor produced a resolved finding: %+v", c)
	}
	if !strings.Contains(renderComparison(c), "UNBOUNDED") {
		t.Fatal("the render did not say the comparison was unbounded")
	}
}

// Blocked runs -- all of one arm, then all of the other -- are confounded with whatever changed between the
// two blocks, and the comparison has to say so on the finding itself, not only in a header a reader skips.
func TestCompareFlagsArmsThatDidNotAlternate(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "2026-08-19T05:00:00Z", 41.0, int64(time.Second)),
		cmpRec("a2", "A-honor", "self-completing", "2026-08-19T05:05:00Z", 41.0, int64(time.Second)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-19T09:00:00Z", 0.0, int64(time.Second)),
		cmpRec("b2", "A-ignore", "self-completing", "2026-08-19T09:05:00Z", 0.0, int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if c.Interleaved {
		t.Fatal("A,A,B,B was reported as interleaved")
	}
	if !strings.Contains(c.Findings[0].Statement, "CONFOUNDED") {
		t.Fatalf("the confound is missing from the finding a reader quotes: %s", c.Findings[0].Statement)
	}
}

// A record missing its start time cannot rule the confound out, and unknown must read as not interleaved.
func TestCompareTreatsAnUnknownRunOrderAsConfounded(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "", 41.0, int64(time.Second)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-19T05:05:00Z", 0.0, int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if c.Interleaved {
		t.Fatal("a record with no start time let the comparison claim interleaving")
	}
}

// Refusal, not exclusion: a comparison whose file list does not describe its evidence is the failure this
// tool exists to prevent.
func TestCompareRefusesRatherThanSilentlyDropping(t *testing.T) {
	refused := cmpRec("bad", "A-ignore", "self-completing", "2026-08-19T05:05:00Z", 0.0, int64(time.Second))
	refused.Validity = validity{Verdict: verdictRefused, Failures: []string{failureObservation}}
	good := cmpRec("a1", "A-honor", "self-completing", "2026-08-19T05:00:00Z", 41.0, int64(time.Second))
	if _, err := compareRecords([]runRecord{good, refused}); err == nil {
		t.Fatal("a refused record was folded into a comparison")
	}

	// Two regimes measure different quantities, so their difference answers no single question.
	other := cmpRec("gb1", "A-ignore", "grace-bounded", "2026-08-19T05:05:00Z", 51.5, int64(time.Second))
	if _, err := compareRecords([]runRecord{good, other}); err == nil {
		t.Fatal("records from two dose regimes were compared")
	}

	// One arm is not a comparison.
	same := cmpRec("a2", "A-honor", "self-completing", "2026-08-19T05:05:00Z", 41.0, int64(time.Second))
	if _, err := compareRecords([]runRecord{good, same}); err == nil {
		t.Fatal("a single arm produced a comparison")
	}
}

// The render leads with the limits, because a reader who stops after one screen must not leave holding only
// the headline.
func TestRenderComparisonLeadsWithWhatItDoesNotEstablish(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "2026-08-19T05:00:00Z", 41.0, int64(time.Second)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-19T05:05:00Z", 0.0, int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	out := renderComparison(c)
	noEffect := strings.Index(out, "no effect is claimed")
	headline := strings.Index(out, "wastedGPUSeconds")
	if noEffect < 0 || headline < 0 || noEffect > headline {
		t.Fatalf("the disclaimer must precede the finding:\n%s", out)
	}
}

// A comparison over runs that observed no device must say the GPU-seconds are reservation, on the same
// screen as the numbers. Without it the headline reads as a statement about hardware nothing touched.
func TestCompareStatesThatNoDeviceWasObserved(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "2026-08-19T05:00:00Z", 41.0, int64(time.Second)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-19T05:05:00Z", 0.0, int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if c.DeviceEvidence != deviceNotObserved {
		t.Fatalf("device axis = %q over runs on a fake device plugin", c.DeviceEvidence)
	}
	if !strings.Contains(renderComparison(c), "second of RESERVATION") {
		t.Fatalf("the render did not say what the GPU-seconds are:\n%s", renderComparison(c))
	}
}

// One run that observed nothing makes the whole comparison observe nothing: the strongest contributor must
// not launder the weakest one's silence.
func TestCompareTakesTheWeakestDeviceAxis(t *testing.T) {
	strong := cmpRec("a1", "A-honor", "self-completing", "2026-08-19T05:00:00Z", 41.0, int64(time.Second))
	strong.Validity.DeviceEvidence = deviceWorkObserved
	weak := cmpRec("b1", "A-ignore", "self-completing", "2026-08-19T05:05:00Z", 0.0, int64(time.Second))
	c, err := compareRecords([]runRecord{strong, weak})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if c.DeviceEvidence != deviceNotObserved {
		t.Fatalf("one silent run was laundered into %q", c.DeviceEvidence)
	}
}
