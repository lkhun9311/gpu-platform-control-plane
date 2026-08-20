package main

import (
	"strings"
	"testing"
	"time"
)

// findingFor picks one quantity out of a comparison, since every arm pair now produces several.
// checkSensitivity2 keeps the dose-factor call site short in tests.
func checkSensitivity2(recs []runRecord) (doseSensitivity, error) {
	return checkSensitivity(recs, factorDose)
}

func findingFor(t *testing.T, c comparison, quantity string) finding {
	t.Helper()
	for _, f := range c.Findings {
		if f.Quantity == quantity {
			return f
		}
	}
	t.Fatalf("the comparison reports no %s finding", quantity)
	return finding{}
}

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
	waste := findingFor(t, c, "wastedGPUSeconds")
	if !waste.Resolved {
		t.Fatalf("a 41s difference against a 3.918s difference floor must resolve: %+v", waste)
	}
	if strings.Contains(waste.Statement, "CONFOUNDED") {
		t.Fatalf("alternating runs reported as confounded: %s", waste.Statement)
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
	waste := findingFor(t, c, "wastedGPUSeconds")
	if waste.Resolved {
		t.Fatalf("0.94s resolved against a 3.918s difference floor: %+v", waste)
	}
	if !strings.Contains(waste.Statement, "NOT RESOLVED") ||
		!strings.Contains(waste.Statement, "not a noise level") {
		t.Fatalf("statement does not tell the reader repetition will not help: %s", waste.Statement)
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
	if c.WorstRunFloorSeconds != 6 {
		t.Fatalf("worst-run floor = %v, want the coarsest contributor's 6s", c.WorstRunFloorSeconds)
	}
	// The finding is tested against the SUM of the two arms' floors, not the larger, because the difference
	// carries both errors: 0.1 + 6 = 6.1 s here.
	if findingFor(t, c, "wastedGPUSeconds").Resolved {
		t.Fatal("a 5s difference resolved against a 6.1s difference floor")
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
	if c.Bounded || findingFor(t, c, "wastedGPUSeconds").Resolved {
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
	if !strings.Contains(findingFor(t, c, "wastedGPUSeconds").Statement, "CONFOUNDED") {
		t.Fatalf("the confound is missing from the finding a reader quotes: %s",
			findingFor(t, c, "wastedGPUSeconds").Statement)
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

// withOwnerWait attaches an owner restoration time to a comparison fixture.
func withOwnerWait(r runRecord, seconds float64) runRecord {
	ns := int64(seconds * float64(time.Second))
	r.Measurement.OwnerAdmitToReadyNs = &ns
	return r
}

// The number a reclaim promise is judged on. The lab measured it from the first run and never carried it out
// of the reconstruction, so answering "how long did the owner wait" meant parsing the ledger by hand -- the
// state this tool exists to end.
func TestCompareReportsWhatTheQuotaOwnerWaited(t *testing.T) {
	c, err := compareRecords([]runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T00:57:03Z", 21.336, 1878*int64(time.Millisecond)), 2.740),
		withOwnerWait(cmpRec("gi1", "A-ignore", "grace-bounded", "2026-08-20T00:59:29Z", 51.315, 1878*int64(time.Millisecond)), 30.806),
		withOwnerWait(cmpRec("gh2", "A-honor", "grace-bounded", "2026-08-20T01:02:21Z", 21.288, 1878*int64(time.Millisecond)), 2.792),
		withOwnerWait(cmpRec("gi2", "A-ignore", "grace-bounded", "2026-08-20T01:04:48Z", 51.278, 1878*int64(time.Millisecond)), 30.807),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	var owner *finding
	for i := range c.Findings {
		if c.Findings[i].Quantity == "ownerAdmitToReadySeconds" {
			owner = &c.Findings[i]
		}
	}
	if owner == nil {
		t.Fatal("the comparison reports the borrower's loss and not the owner's wait")
	}
	if !owner.Resolved {
		t.Fatalf("a 28 s difference against a 3.756 s difference floor did not resolve: %+v", owner)
	}
	if !strings.Contains(owner.Statement, "reclaim promise is judged on") {
		t.Fatalf("the statement does not say which of the two numbers is the promise: %s", owner.Statement)
	}
	for _, a := range c.Arms {
		if a.OwnerWaitRuns != 2 {
			t.Fatalf("arm %s counted %d restored runs, want 2", a.Arm, a.OwnerWaitRuns)
		}
	}
}

// An arm whose owner never came back has no wait to average, and averaging the runs that did would report
// the best case of an arm defined by its worst.
func TestCompareRefusesToAverageAwayAnOwnerThatNeverReturned(t *testing.T) {
	c, err := compareRecords([]runRecord{
		withOwnerWait(cmpRec("h1", "A-honor", "self-completing", "2026-08-20T00:45:14Z", 41.0, int64(time.Second)), 2.5),
		cmpRec("i1", "A-ignore", "self-completing", "2026-08-20T00:47:57Z", 0.0, int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	var owner *finding
	for i := range c.Findings {
		if c.Findings[i].Quantity == "ownerAdmitToReadySeconds" {
			owner = &c.Findings[i]
		}
	}
	if owner == nil || owner.Resolved {
		t.Fatalf("a comparison resolved an owner wait one arm never produced: %+v", owner)
	}
	if !strings.Contains(owner.Statement, "NOT COMPUTED") {
		t.Fatalf("the statement does not say it could not be computed: %s", owner.Statement)
	}
	if !strings.Contains(renderComparison(c), "NONE of 1 runs restored the quota owner") {
		t.Fatalf("the render hides an arm that never restored its owner:\n%s", renderComparison(c))
	}
}

// The check that decides whether the real-GPU session has a baseline at all, with its own positive control
// beside it. A test that only ever reports "no response" would prove nothing, so both arms are asserted: the
// honouring one must come back inside the floor and the ignoring one must come back outside it.
func TestDoseSensitivitySeparatesABaselineFromAQuantityTheDoseDetermines(t *testing.T) {
	honor := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T02:42:43Z", 21.349, 1876*int64(time.Millisecond)), 2.729),
		withOwnerWait(cmpRec("gh2", "A-honor", "grace-bounded", "2026-08-20T02:47:58Z", 21.283, 1000*int64(time.Millisecond)), 2.789),
		withOwnerWait(cmpRec("sh1", "A-honor", "self-completing", "2026-08-20T02:44:00Z", 41.503, 1672*int64(time.Millisecond)), 2.589),
		withOwnerWait(cmpRec("sh2", "A-honor", "self-completing", "2026-08-20T02:49:00Z", 41.414, 1762*int64(time.Millisecond)), 2.685),
	}
	d, err := checkSensitivity2(honor)
	if err != nil {
		t.Fatalf("dose sensitivity: %v", err)
	}
	if d.MovesWithDose {
		t.Fatalf("the honouring arm's restoration moved with the dose: %+v", d)
	}
	if !strings.Contains(d.Statement, "not proof that it does not") {
		t.Fatalf("a negative result was stated as proof of no response: %s", d.Statement)
	}

	// Positive control. In the ignoring arm the owner's wait IS the dose-dependent quantity -- what the victim
	// had left, bounded by grace -- so a check that could not see this one respond could not see anything.
	ignore := []runRecord{
		withOwnerWait(cmpRec("gi1", "A-ignore", "grace-bounded", "2026-08-20T02:45:05Z", 51.262, 1938*int64(time.Millisecond)), 30.846),
		withOwnerWait(cmpRec("gi2", "A-ignore", "grace-bounded", "2026-08-20T02:50:20Z", 51.233, 1000*int64(time.Millisecond)), 30.891),
		withOwnerWait(cmpRec("si1", "A-ignore", "self-completing", "2026-08-20T02:46:00Z", 0.0, 1280*int64(time.Millisecond)), 19.665),
		withOwnerWait(cmpRec("si2", "A-ignore", "self-completing", "2026-08-20T02:51:00Z", 0.0, 2364*int64(time.Millisecond)), 19.733),
	}
	di, err := checkSensitivity2(ignore)
	if err != nil {
		t.Fatalf("dose sensitivity: %v", err)
	}
	if !di.MovesWithDose {
		t.Fatalf("an 11 s response against a 2.364 s floor was not seen; the check cannot detect anything: %+v", di)
	}
	if !strings.Contains(di.Statement, "cannot be quoted as a property of the platform") {
		t.Fatalf("the statement does not say what the response costs: %s", di.Statement)
	}
}

// Holding the arm fixed is the whole method. Pooling arms would measure the arm difference and report it as a
// dose response, which is exactly the confusion the GPU session's baseline must not inherit.
func TestDoseSensitivityRefusesToPoolArms(t *testing.T) {
	mixed := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T02:42:43Z", 21.3, int64(time.Second)), 2.729),
		withOwnerWait(cmpRec("si1", "A-ignore", "self-completing", "2026-08-20T02:46:00Z", 0.0, int64(time.Second)), 19.665),
	}
	if _, err := checkSensitivity2(mixed); err == nil {
		t.Fatal("two arms were pooled into a dose response")
	}

	// One regime is not a variation.
	same := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T02:42:43Z", 21.3, int64(time.Second)), 2.729),
		withOwnerWait(cmpRec("gh2", "A-honor", "grace-bounded", "2026-08-20T02:47:58Z", 21.2, int64(time.Second)), 2.789),
	}
	if _, err := checkSensitivity2(same); err == nil {
		t.Fatal("a single dose regime produced a dose-sensitivity result")
	}

	// A regime where the owner never came back has no wait to test, and averaging the other regime's runs
	// would answer a question nobody asked.
	absent := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T02:42:43Z", 21.3, int64(time.Second)), 2.729),
		cmpRec("sh1", "A-honor", "self-completing", "2026-08-20T02:44:00Z", 41.5, int64(time.Second)),
	}
	if _, err := checkSensitivity2(absent); err == nil {
		t.Fatal("a regime whose owner never returned was folded into a dose response")
	}
}

// A difference between two arms carries BOTH of their errors, and they can lean opposite ways, so the
// resolution of the difference is the sum of the two floors and never the larger.
//
// Mutation that turns this red: return max(a.FloorSeconds, b.FloorSeconds) from differenceFloor.
func TestTheDifferenceFloorIsTheSumOfBothArms(t *testing.T) {
	c, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "2026-08-20T05:00:00Z", 10.0, 2*int64(time.Second)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-20T05:05:00Z", 7.0, 2*int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	// 3 s of difference against two 2 s arms. Under the larger-of-the-two rule this resolved; it must not.
	if findingFor(t, c, "wastedGPUSeconds").Resolved {
		t.Fatal("a 3 s difference resolved against two arms each bounded at 2 s; the error budget is 4 s")
	}
	// And 5 s does clear it, so the rule is a bound rather than a refusal to ever conclude.
	c2, err := compareRecords([]runRecord{
		cmpRec("a1", "A-honor", "self-completing", "2026-08-20T05:00:00Z", 10.0, 2*int64(time.Second)),
		cmpRec("b1", "A-ignore", "self-completing", "2026-08-20T05:05:00Z", 5.0, 2*int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	if !findingFor(t, c2, "wastedGPUSeconds").Resolved {
		t.Fatal("a 5 s difference did not clear a 4 s budget; the floor has stopped being a bound")
	}
}

// A mean over the runs whose owner came back omits the slow tail, and the tail is exactly what a reader
// worried about an arm wants to see. The figures stay; the verdict does not.
func TestASurvivorMeanIsNeverResolved(t *testing.T) {
	c, err := compareRecords([]runRecord{
		withOwnerWait(cmpRec("a1", "A-honor", "self-completing", "2026-08-20T05:00:00Z", 41.0, int64(time.Second)), 2.5),
		withOwnerWait(cmpRec("a2", "A-honor", "self-completing", "2026-08-20T05:10:00Z", 41.0, int64(time.Second)), 2.6),
		withOwnerWait(cmpRec("b1", "A-ignore", "self-completing", "2026-08-20T05:05:00Z", 0.0, int64(time.Second)), 30.0),
		cmpRec("b2", "A-ignore", "self-completing", "2026-08-20T05:15:00Z", 0.0, int64(time.Second)),
	})
	if err != nil {
		t.Fatalf("compare: %v", err)
	}
	owner := findingFor(t, c, "ownerAdmitToReadySeconds")
	if owner.Resolved {
		t.Fatal("a 27 s difference resolved while one arm's mean was over its survivors only")
	}
	if !strings.Contains(owner.Statement, "SURVIVOR MEAN") {
		t.Fatalf("the statement does not name the bias: %s", owner.Statement)
	}
}

// The dose check refuses a regime that did not restore its owner every time, rather than reporting a mean
// with a known direction of bias. It licenses a baseline for a session nobody can re-run cheaply.
func TestDoseSensitivityRefusesASurvivorMean(t *testing.T) {
	recs := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.7),
		withOwnerWait(cmpRec("gh2", "A-honor", "grace-bounded", "2026-08-20T05:10:00Z", 21.3, int64(time.Second)), 2.8),
		withOwnerWait(cmpRec("sh1", "A-honor", "self-completing", "2026-08-20T05:05:00Z", 41.5, int64(time.Second)), 2.6),
		cmpRec("sh2", "A-honor", "self-completing", "2026-08-20T05:15:00Z", 41.4, int64(time.Second)),
	}
	if _, err := checkSensitivity2(recs); err == nil {
		t.Fatal("a regime that restored its owner once out of twice produced a dose verdict")
	}
}

// Blocked regimes are confounded with whatever changed between the blocks, and this document had no such
// check while the arm comparison did — in the direction where its absence hurts most, since "no response" is
// the verdict that licenses a baseline.
func TestDoseSensitivityReportsWhetherTheRegimesAlternated(t *testing.T) {
	blocked := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.7),
		withOwnerWait(cmpRec("gh2", "A-honor", "grace-bounded", "2026-08-20T05:05:00Z", 21.3, int64(time.Second)), 2.8),
		withOwnerWait(cmpRec("sh1", "A-honor", "self-completing", "2026-08-20T09:00:00Z", 41.5, int64(time.Second)), 2.6),
		withOwnerWait(cmpRec("sh2", "A-honor", "self-completing", "2026-08-20T09:05:00Z", 41.4, int64(time.Second)), 2.65),
	}
	d, err := checkSensitivity2(blocked)
	if err != nil {
		t.Fatalf("dose sensitivity: %v", err)
	}
	if d.Interleaved {
		t.Fatal("two blocks of runs were reported as alternating")
	}
	if !strings.Contains(renderDoseSensitivity(d), "NOT INTERLEAVED") {
		t.Fatalf("the render hides the confound:\n%s", renderDoseSensitivity(d))
	}

	// And the alternating case is reported as such, or the check is a constant.
	alternating := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.7),
		withOwnerWait(cmpRec("sh1", "A-honor", "self-completing", "2026-08-20T05:05:00Z", 41.5, int64(time.Second)), 2.6),
		withOwnerWait(cmpRec("gh2", "A-honor", "grace-bounded", "2026-08-20T05:10:00Z", 21.3, int64(time.Second)), 2.8),
		withOwnerWait(cmpRec("sh2", "A-honor", "self-completing", "2026-08-20T05:15:00Z", 41.4, int64(time.Second)), 2.65),
	}
	da, err := checkSensitivity2(alternating)
	if err != nil {
		t.Fatalf("dose sensitivity: %v", err)
	}
	if !da.Interleaved {
		t.Fatal("alternating regimes were reported as blocked")
	}
}

// nodeRec puts a record on a named worker, which the baseline and the node-sensitivity check group by.
func nodeRec(r runRecord, node string) runRecord {
	r.Qualification = &qualification{Node: node}
	return r
}

// The last hand-typed number in this lab, as an artifact. It refuses more than the comparisons do, because a
// baseline is quoted long after its runs are gone by someone who will not re-derive it — which is exactly
// what happened to the figure this replaces.
func TestBaselineNamesEverythingBehindIt(t *testing.T) {
	recs := []runRecord{
		nodeRec(withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, 1876*int64(time.Millisecond)), 2.729), "platform-worker"),
		nodeRec(withOwnerWait(cmpRec("sh1", "A-honor", "self-completing", "2026-08-20T05:05:00Z", 41.5, 1672*int64(time.Millisecond)), 2.589), "platform-worker"),
		nodeRec(withOwnerWait(cmpRec("gh2", "A-honor", "grace-bounded", "2026-08-20T05:10:00Z", 21.3, 1000*int64(time.Millisecond)), 2.789), "platform-worker2"),
		nodeRec(withOwnerWait(cmpRec("sh2", "A-honor", "self-completing", "2026-08-20T05:15:00Z", 41.4, 1762*int64(time.Millisecond)), 2.685), "platform-worker2"),
	}
	b, err := computeBaseline(recs)
	if err != nil {
		t.Fatalf("baseline: %v", err)
	}
	if b.N != 4 || len(b.RunIDs) != 4 {
		t.Fatalf("n=%d runs=%v, want all four named", b.N, b.RunIDs)
	}
	if len(b.Doses) != 2 || len(b.Nodes) != 2 {
		t.Fatalf("doses=%v nodes=%v; a baseline must name what it spans", b.Doses, b.Nodes)
	}
	if b.OwnerWaitSecondsMin != 2.589 || b.OwnerWaitSecondsMax != 2.789 {
		t.Fatalf("min=%v max=%v, want the observed extremes", b.OwnerWaitSecondsMin, b.OwnerWaitSecondsMax)
	}
	if b.DeviceEvidence != deviceNotObserved {
		t.Fatalf("device axis = %q on a fake device plugin", b.DeviceEvidence)
	}
	out := renderBaseline(b)
	if !strings.Contains(out, "control-plane figure and not a statement about hardware") {
		t.Fatalf("the render lets a fake-plugin baseline read as hardware:\n%s", out)
	}
	if !strings.Contains(b.Statement, "add its own floor") {
		t.Fatalf("the statement does not tell a later session how to difference against it: %s", b.Statement)
	}
}

// A run whose owner never came back cannot contribute to a floor: averaging the ones that did produces the
// platform's best case wearing the name of its baseline.
func TestBaselineRefusesARunThatNeverRestoredItsOwner(t *testing.T) {
	recs := []runRecord{
		nodeRec(withOwnerWait(cmpRec("h1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.7), "platform-worker"),
		nodeRec(cmpRec("h2", "A-honor", "grace-bounded", "2026-08-20T05:10:00Z", 21.3, int64(time.Second)), "platform-worker"),
	}
	if _, err := computeBaseline(recs); err == nil {
		t.Fatal("a baseline was pooled over a run whose owner never returned")
	}

	// And two arms are never one baseline.
	mixed := []runRecord{
		nodeRec(withOwnerWait(cmpRec("h1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.7), "platform-worker"),
		nodeRec(withOwnerWait(cmpRec("i1", "A-ignore", "grace-bounded", "2026-08-20T05:10:00Z", 51.3, int64(time.Second)), 30.8), "platform-worker"),
	}
	if _, err := computeBaseline(mixed); err == nil {
		t.Fatal("two arms were averaged into one baseline, erasing the difference they exist to show")
	}
}

// The node is the factor "one cluster, one pinned worker" left unqualified on every figure this lab has
// produced. Varying it requires holding the dose fixed, or a node difference gets published as a dose one.
func TestNodeSensitivityHoldsTheDoseFixed(t *testing.T) {
	varied := []runRecord{
		nodeRec(withOwnerWait(cmpRec("a", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.7), "platform-worker"),
		nodeRec(withOwnerWait(cmpRec("b", "A-honor", "self-completing", "2026-08-20T05:05:00Z", 41.5, int64(time.Second)), 2.6), "platform-worker2"),
	}
	if _, err := checkSensitivity(varied, factorNode); err == nil {
		t.Fatal("the node and the dose varied together and a node response was reported")
	}

	held := []runRecord{
		nodeRec(withOwnerWait(cmpRec("a1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.70), "platform-worker"),
		nodeRec(withOwnerWait(cmpRec("b1", "A-honor", "grace-bounded", "2026-08-20T05:05:00Z", 21.3, int64(time.Second)), 2.75), "platform-worker2"),
		nodeRec(withOwnerWait(cmpRec("a2", "A-honor", "grace-bounded", "2026-08-20T05:10:00Z", 21.3, int64(time.Second)), 2.72), "platform-worker"),
		nodeRec(withOwnerWait(cmpRec("b2", "A-honor", "grace-bounded", "2026-08-20T05:15:00Z", 21.3, int64(time.Second)), 2.78), "platform-worker2"),
	}
	d, err := checkSensitivity(held, factorNode)
	if err != nil {
		t.Fatalf("node sensitivity: %v", err)
	}
	if d.Factor != factorNode || len(d.Doses) != 2 {
		t.Fatalf("factor=%q levels=%d, want node over two workers", d.Factor, len(d.Doses))
	}
	if d.MovesWithDose {
		t.Fatalf("a 60 ms difference between nodes resolved against a %.3f s floor", d.FloorSeconds)
	}
	if !strings.Contains(renderDoseSensitivity(d), "SENSITIVITY TO NODE") {
		t.Fatalf("the render does not name the factor:\n%s", renderDoseSensitivity(d))
	}
}

// The lab's central claim, as arithmetic. Two regimes put the victim on opposite sides of the grace period,
// so the same model must predict a 30 s hold in one and a 20 s hold in the other — a model fitted to either
// alone would miss the other by ten seconds.
func TestTheModelPredictsBothRegimesFromOneRule(t *testing.T) {
	// Honouring: restoration with nothing holding the device. Ignoring: the model's subject.
	// grace-bounded leaves 40 s remaining against a 30 s grace, so grace binds: 30 + 2.76 = 32.76.
	// self-completing leaves 20 s, so the victim's own service binds: 20 + 2.76 = 22.76.
	recs := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.73),
		withOwnerWait(cmpRec("gh2", "A-honor", "grace-bounded", "2026-08-20T05:05:00Z", 21.3, int64(time.Second)), 2.79),
		withOwnerWait(cmpRec("sh1", "A-honor", "self-completing", "2026-08-20T05:10:00Z", 41.5, int64(time.Second)), 2.73),
		withOwnerWait(cmpRec("sh2", "A-honor", "self-completing", "2026-08-20T05:15:00Z", 41.4, int64(time.Second)), 2.79),
		withOwnerWait(cmpRec("gi1", "A-ignore", "grace-bounded", "2026-08-20T05:20:00Z", 51.3, int64(time.Second)), 32.7),
		withOwnerWait(cmpRec("gi2", "A-ignore", "grace-bounded", "2026-08-20T05:25:00Z", 51.3, int64(time.Second)), 32.8),
		withOwnerWait(cmpRec("si1", "A-ignore", "self-completing", "2026-08-20T05:30:00Z", 0.0, int64(time.Second)), 22.7),
		withOwnerWait(cmpRec("si2", "A-ignore", "self-completing", "2026-08-20T05:35:00Z", 0.0, int64(time.Second)), 22.8),
	}
	m, err := checkModel(recs)
	if err != nil {
		t.Fatalf("model: %v", err)
	}
	if !m.Holds {
		t.Fatalf("the model failed on data generated from it: %+v", m.Cases)
	}
	if len(m.Cases) != 2 {
		t.Fatalf("cases = %d, want one per regime", len(m.Cases))
	}
	byDose := map[string]modelCase{}
	for _, c := range m.Cases {
		byDose[c.Dose] = c
	}
	if byDose["grace-bounded"].BindingTerm != "termination grace" {
		t.Fatalf("40 s of remaining service against a 30 s grace must bind on grace: %+v", byDose["grace-bounded"])
	}
	if byDose["self-completing"].BindingTerm != "remaining service" {
		t.Fatalf("20 s of remaining service against a 30 s grace must bind on service: %+v", byDose["self-completing"])
	}
	// The protocol's constants are printed, because the record does not carry them and a build with different
	// ones would mispredict silently.
	if !strings.Contains(renderModel(m), "grace=30s") {
		t.Fatalf("the render does not state the arithmetic's inputs:\n%s", renderModel(m))
	}
}

// And it can fail. A refutation nobody can trigger is not one — this is the test that the check is a test.
func TestTheModelCanBeRefuted(t *testing.T) {
	recs := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.73),
		withOwnerWait(cmpRec("sh1", "A-honor", "self-completing", "2026-08-20T05:10:00Z", 41.5, int64(time.Second)), 2.79),
		// The grace-bounded victim held its device for a minute rather than the grace period.
		withOwnerWait(cmpRec("gi1", "A-ignore", "grace-bounded", "2026-08-20T05:20:00Z", 51.3, int64(time.Second)), 62.7),
		withOwnerWait(cmpRec("si1", "A-ignore", "self-completing", "2026-08-20T05:30:00Z", 0.0, int64(time.Second)), 22.7),
	}
	m, err := checkModel(recs)
	if err != nil {
		t.Fatalf("model: %v", err)
	}
	if m.Holds {
		t.Fatal("a victim that held its device for twice the grace period did not refute the model")
	}
	if !strings.Contains(m.Statement, "REFUTED") {
		t.Fatalf("the statement does not say it was refuted: %s", m.Statement)
	}
}

// One regime can be fitted by any model, so the check refuses to conclude from one.
func TestTheModelRefusesASingleRegime(t *testing.T) {
	recs := []runRecord{
		withOwnerWait(cmpRec("gh1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 2.73),
		withOwnerWait(cmpRec("gi1", "A-ignore", "grace-bounded", "2026-08-20T05:20:00Z", 51.3, int64(time.Second)), 32.7),
	}
	if _, err := checkModel(recs); err == nil {
		t.Fatal("one regime produced a model verdict; any model fits a single point")
	}
}

// The statement's spread is in milliseconds and the field is in seconds, which is exactly the kind of unit
// slip that ships. It shipped once: a 930 ms spread printed as "a spread of 1 ms" in the sentence a reader
// quotes, beside the correct figure in the line below it.
func TestBaselineStatementReportsTheSpreadInMilliseconds(t *testing.T) {
	recs := []runRecord{
		nodeRec(withOwnerWait(cmpRec("h1", "A-honor", "grace-bounded", "2026-08-20T05:00:00Z", 21.3, int64(time.Second)), 1.688), "platform-worker"),
		nodeRec(withOwnerWait(cmpRec("h2", "A-honor", "grace-bounded", "2026-08-20T05:10:00Z", 21.3, int64(time.Second)), 2.619), "platform-worker"),
	}
	b, err := computeBaseline(recs)
	if err != nil {
		t.Fatalf("baseline: %v", err)
	}
	if !strings.Contains(b.Statement, "931 ms") {
		t.Fatalf("the statement's spread is not the 931 ms the runs show: %s", b.Statement)
	}
}
