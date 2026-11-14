package bench

import (
	"slices"
	"strings"
	"testing"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// TestVersionStudyCountsEngineTokens is finding 1 of the 2026-11-15 audit: the newer engine may put two tokens in one frame.
func TestVersionStudyCountsEngineTokens(t *testing.T) {
	if got := OutputCountForStudy(StudyVersionAsync); got != OutputCountEngineTokens {
		t.Fatalf("study %s counts output under %q, want %q", StudyVersionAsync, got, OutputCountEngineTokens)
	}
}

// TestVersionStudyArmsAreLiteral pins the six arm names the runner and the report will spell.
//
// Written out rather than rebuilt with VersionStudyArm, so a changed format string is a deliberate edit here.
func TestVersionStudyArmsAreLiteral(t *testing.T) {
	st, ok := LookupStudy(StudyVersionAsync)
	if !ok {
		t.Fatalf("study %s is not registered", StudyVersionAsync)
	}
	want := []string{"A-l060", "A-l090", "B-l060", "B-l090", "C-l060", "C-l090"}
	if !slices.Equal(st.Arms, want) {
		t.Fatalf("arms = %v, want %v", st.Arms, want)
	}
}

// TestVersionStudyRegistration pins the registered properties the spec names as fixed now.
func TestVersionStudyRegistration(t *testing.T) {
	st, _ := LookupStudy(StudyVersionAsync)
	if st.MinRepetitions != 5 || !st.PublishesInterval || !st.TracesVaryByRepetition {
		t.Errorf("floor %d, interval %v, traces vary %v; want 5, true, true", st.MinRepetitions, st.PublishesInterval,
			st.TracesVaryByRepetition)
	}
	if !st.FixesOutputAtCap || !st.RecordsReplayTiming {
		t.Errorf("fixes output at cap %v, records replay timing %v; want both", st.FixesOutputAtCap, st.RecordsReplayTiming)
	}
	if st.ManifestSchema != ManifestSchemaV3 {
		t.Errorf("manifest schema = %q, want %q", st.ManifestSchema, ManifestSchemaV3)
	}
	if st.Sampling == nil || st.Version == nil {
		t.Fatalf("sampling %v, design %v; the study must register both", st.Sampling, st.Version)
	}
	if err := st.Sampling.Validate(); err != nil {
		t.Errorf("registered sampling policy is invalid: %v", err)
	}
}

// TestVersionStudyEnginesDifferOnlyWhereRegistered checks what may and may not differ between the treatments.
//
// A and B may differ only in version and image; B and C only in async scheduling.
func TestVersionStudyEnginesDifferOnlyWhereRegistered(t *testing.T) {
	d := versionAsyncDesign()
	a, b, c := d.Engines[TreatmentA], d.Engines[TreatmentB], d.Engines[TreatmentC]

	if a.AsyncScheduling == nil || *a.AsyncScheduling || b.AsyncScheduling == nil || *b.AsyncScheduling {
		t.Errorf("A and B must both run with async scheduling off")
	}
	if c.AsyncScheduling == nil || !*c.AsyncScheduling {
		t.Errorf("C must run with async scheduling on")
	}
	bAsA := b
	bAsA.VLLMVersion, bAsA.Image = a.VLLMVersion, a.Image
	if diff := a.Diff(bAsA); diff != "" {
		t.Errorf("A and B differ beyond version and image: %s", diff)
	}
	cAsB := c
	cAsB.AsyncScheduling = b.AsyncScheduling
	if diff := b.Diff(cAsB); diff != "" {
		t.Errorf("B and C differ beyond async scheduling: %s", diff)
	}
	// A is the validated profile, so its image is the digest the CRD pins.
	if !strings.HasSuffix(a.Image, "@"+platformv1.VLLMV0271Digest) {
		t.Errorf("A image = %q, want the v0.27.1 digest %s", a.Image, platformv1.VLLMV0271Digest)
	}
}

// TestVersionStudyNamesWhatIsNotYetFrozen keeps the owner's open decisions visible and refusing.
//
// The list is literal so that freezing a value is a visible edit here as well as in the registry.
func TestVersionStudyNamesWhatIsNotYetFrozen(t *testing.T) {
	d := versionAsyncDesign()
	want := []string{
		"treatment B vLLM version",
		"treatment B image digest",
		"treatment C vLLM version",
		"treatment C image digest",
		"SLO TTFT",
		"SLO TPOT",
		"equivalence margin ttft_p99",
		"equivalence margin tpot_p99",
		"equivalence margin e2e_p99",
		"equivalence margin goodput",
	}
	if got := d.Unfrozen(); !slices.Equal(got, want) {
		t.Fatalf("unfrozen = %v, want %v", got, want)
	}
	if err := d.PreflightRefusal(); err == nil || !strings.Contains(err.Error(), "SLO TTFT") {
		t.Fatalf("preflight = %v, want a refusal naming the unfrozen items", err)
	}
	frozen := frozenVersionDesignFixture()
	if err := frozen.PreflightRefusal(); err != nil {
		t.Fatalf("a fully frozen design was refused: %v", err)
	}
}

// TestArmOrderIsASeededPermutation checks the order is reproducible, a permutation, and distinct across six blocks.
func TestArmOrderIsASeededPermutation(t *testing.T) {
	seen := map[string]bool{}
	for block := 1; block <= 6; block++ {
		order := ArmOrder(20261115, block)
		again := ArmOrder(20261115, block)
		if !slices.Equal(order, again) {
			t.Fatalf("block %d order is not reproducible: %v then %v", block, order, again)
		}
		sorted := slices.Clone(order)
		slices.Sort(sorted)
		if !slices.Equal(sorted, []string{TreatmentA, TreatmentB, TreatmentC}) {
			t.Fatalf("block %d order %v is not a permutation of A, B, C", block, order)
		}
		key := strings.Join(order, "")
		if seen[key] {
			t.Errorf("block %d repeats order %s within the first six blocks", block, key)
		}
		seen[key] = true
	}
	if slices.Equal(ArmOrder(1, 1), ArmOrder(2, 1)) && slices.Equal(ArmOrder(1, 2), ArmOrder(2, 2)) &&
		slices.Equal(ArmOrder(1, 3), ArmOrder(2, 3)) {
		t.Errorf("the order does not depend on the seed")
	}
}

// TestArmOrderIsPinned freezes the generator's output, so a library change cannot reorder a registered campaign.
func TestArmOrderIsPinned(t *testing.T) {
	got := [][]string{}
	for block := 1; block <= 3; block++ {
		got = append(got, ArmOrder(20261115, block))
	}
	want := pinnedArmOrder20261115
	for i := range want {
		if !slices.Equal(got[i], want[i]) {
			t.Fatalf("block %d order = %v, want %v", i+1, got[i], want[i])
		}
	}
}

// TestWorkloadSeedSharedAcrossArmsDistinctAcrossCells is finding 21: one workload per block and load, never one for all.
func TestWorkloadSeedSharedAcrossArmsDistinctAcrossCells(t *testing.T) {
	seen := map[int64]string{}
	for block := 1; block <= 7; block++ {
		for _, load := range []string{LoadL060, LoadL090} {
			s, err := WorkloadSeed(20261115, block, load)
			if err != nil {
				t.Fatal(err)
			}
			again, _ := WorkloadSeed(20261115, block, load)
			if s != again {
				t.Fatalf("seed for block %d %s is not reproducible", block, load)
			}
			if prev, dup := seen[s]; dup {
				t.Fatalf("block %d %s shares seed %d with %s", block, load, s, prev)
			}
			seen[s] = load
		}
	}
	if _, err := WorkloadSeed(1, 1, "l120"); err == nil {
		t.Errorf("an unregistered load level was given a seed")
	}
	if _, err := WorkloadSeed(1, 0, LoadL060); err == nil {
		t.Errorf("block 0 was given a seed; blocks count from 1")
	}
}

// TestPhaseBoundaryIsByIntendedArrival checks warm-up exclusion is decided by the trace offset, not completion time.
func TestPhaseBoundaryIsByIntendedArrival(t *testing.T) {
	d := frozenVersionDesignFixture()
	w := int64(d.WarmupSeconds) * 1000
	m := int64(d.MeasureSeconds(4.0)) * 1000
	for _, c := range []struct {
		offset int64
		want   Phase
	}{
		{0, PhaseWarmup},
		{w - 1, PhaseWarmup},
		{w, PhaseMeasure},
		{w + m - 1, PhaseMeasure},
		{w + m, PhaseOutside},
		{-1, PhaseOutside},
	} {
		if got := d.PhaseOf(c.offset, 4.0); got != c.want {
			t.Errorf("offset %d ms: phase %q, want %q", c.offset, got, c.want)
		}
	}
}

// TestMeasureWindowReachesTheTailFloor checks the window grows so a pooled p99 rests on at least 1,000 requests.
func TestMeasureWindowReachesTheTailFloor(t *testing.T) {
	d := frozenVersionDesignFixture()
	if got := d.MeasureSeconds(10); got != d.MinMeasureSeconds {
		t.Errorf("at 10 req/s window = %d s, want the floor %d s", got, d.MinMeasureSeconds)
	}
	// 5 blocks x 0.6 x 0.2 req/s = 0.6 req/s pooled, so 1,000 requests need 1,667 s.
	if got := d.MeasureSeconds(0.2); got != 1667 {
		t.Errorf("at 0.2 req/s window = %d s, want 1667 s", got)
	}
	if got := d.MeasureSeconds(0); got != 0 {
		t.Errorf("an unmeasured capacity produced a window of %d s, want 0", got)
	}
}

// TestBudgetStopRule checks a block is not started unless its worst observed cost still fits under the cap.
func TestBudgetStopRule(t *testing.T) {
	d := frozenVersionDesignFixture()
	for _, c := range []struct {
		spent, worst float64
		want         bool
	}{
		{5, 2, true},
		{16, 2, true},
		{16.01, 2, false},
		{0, 0, false},
		{0, -1, false},
	} {
		if got := d.MayStartBlock(c.spent, c.worst); got != c.want {
			t.Errorf("spent %.2f worst block %.2f: may start %v, want %v", c.spent, c.worst, got, c.want)
		}
	}
}

// pinnedArmOrder20261115 is ArmOrder's output for seed 20261115, blocks 1 to 3, recorded when the generator was written.
var pinnedArmOrder20261115 = [][]string{
	{TreatmentB, TreatmentA, TreatmentC},
	{TreatmentB, TreatmentC, TreatmentA},
	{TreatmentC, TreatmentB, TreatmentA},
}

// frozenVersionDesignFixture is the registered design with every owner decision filled by placeholder values.
//
// The values are test inputs, not proposals; the spec carries the proposals.
func frozenVersionDesignFixture() VersionStudyDesign {
	d := versionAsyncDesign()
	for _, tr := range []string{TreatmentB, TreatmentC} {
		e := d.Engines[tr]
		e.VLLMVersion = "v9.9.9"
		e.Image = "vllm/vllm-openai@sha256:" + strings.Repeat("b", 64)
		d.Engines[tr] = e
	}
	d.SLO = SLO{TTFTMs: 1000, TPOTMs: 60}
	d.Margins = map[Endpoint]float64{
		EndpointTTFTP99: 0.10, EndpointTPOTP99: 0.10, EndpointE2EP99: 0.10, EndpointGoodput: 0.02,
	}
	return d
}
