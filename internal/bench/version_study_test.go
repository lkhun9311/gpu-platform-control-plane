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
	if st.MinRepetitions != 6 || !st.PublishesInterval || !st.TracesVaryByRepetition {
		t.Errorf("floor %d, interval %v, traces vary %v; want 6, true, true", st.MinRepetitions, st.PublishesInterval,
			st.TracesVaryByRepetition)
	}
	d := st.Version
	if d.SLO != (SLO{TTFTMs: 1000, TPOTMs: 60}) || d.PlannedBlocks != 6 || d.MaxReplacementBlocks != 2 {
		t.Errorf("SLO %+v, planned %d, replacements %d", d.SLO, d.PlannedBlocks, d.MaxReplacementBlocks)
	}
	if d.Engines[TreatmentB].VLLMVersion != "v0.32.0" || d.Engines[TreatmentC].VLLMVersion != "v0.32.0" {
		t.Errorf("B and C versions %q %q, want v0.32.0", d.Engines[TreatmentB].VLLMVersion, d.Engines[TreatmentC].VLLMVersion)
	}
	if d.Engines[TreatmentA].SchedulingPolicy != "priority" {
		t.Errorf("scheduling policy %q, want priority", d.Engines[TreatmentA].SchedulingPolicy)
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
		"treatment B image digest (engine-path track)",
		"treatment B flag review (engine-path track)",
		"treatment C image digest (engine-path track)",
		"treatment C flag review (engine-path track)",
	}
	if got := d.Unfrozen(); !slices.Equal(got, want) {
		t.Fatalf("unfrozen = %v, want %v", got, want)
	}
	if err := d.PreflightRefusal(); err == nil || !strings.Contains(err.Error(), "flag review") {
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
	m := int64(300) * 1000
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
		if got := d.PhaseOf(c.offset, 300); got != c.want {
			t.Errorf("offset %d ms: phase %q, want %q", c.offset, got, c.want)
		}
	}
	if got := d.PhaseOf(w, 0); got != PhaseOutside {
		t.Errorf("a zero window gave phase %q", got)
	}
}

// TestChooseWindowFromTraces is attack item 10: the floor is met by the generated traces, not expected from a rate.
func TestChooseWindowFromTraces(t *testing.T) {
	d := frozenVersionDesignFixture()
	at := func(perBlock map[string]float64) func(int, string, int) (int, error) {
		return func(_ int, load string, w int) (int, error) { return int(perBlock[load] * float64(w)), nil }
	}
	// 6 blocks x 0.2 req/s: 780 s offers 936, 840 s offers 1,008.
	if w, err := d.ChooseWindow(at(map[string]float64{LoadL060: 0.2, LoadL090: 0.3})); err != nil || w != 840 {
		t.Errorf("window %d err %v, want 840", w, err)
	}
	if w, err := d.ChooseWindow(at(map[string]float64{LoadL060: 10, LoadL090: 15})); err != nil || w != 300 {
		t.Errorf("window %d err %v, want the minimum 300", w, err)
	}
	if _, err := d.ChooseWindow(at(map[string]float64{LoadL060: 0.05, LoadL090: 0.075})); err == nil {
		t.Errorf("a window over the maximum was chosen rather than refused")
	}
	// Every load must reach the floor, not their sum.
	if w, _ := d.ChooseWindow(at(map[string]float64{LoadL060: 0.2, LoadL090: 100})); w != 840 {
		t.Errorf("window %d, want 840 set by the lower load", w)
	}
}

// TestLoadOrderIsCounterbalanced is attack item 11: each load runs first in half the planned blocks.
func TestLoadOrderIsCounterbalanced(t *testing.T) {
	first := map[string]int{}
	for b := 1; b <= versionStudyPlannedBlocks; b++ {
		o := LoadOrder(b)
		if len(o) != 2 || o[0] == o[1] {
			t.Fatalf("block %d load order %v", b, o)
		}
		first[o[0]]++
	}
	if first[LoadL060] != 3 || first[LoadL090] != 3 {
		t.Errorf("loads first: %v, want 3 each", first)
	}
	if LoadOrder(0) != nil {
		t.Errorf("block 0 has a load order")
	}
}

// TestSixBlocksBalanceEveryPosition checks the owner's six blocks put each treatment in each position twice.
func TestSixBlocksBalanceEveryPosition(t *testing.T) {
	d := versionAsyncDesign()
	pos := map[string][3]int{}
	for b := 1; b <= d.PlannedBlocks; b++ {
		for i, tr := range ArmOrder(d.CampaignSeed, b) {
			p := pos[tr]
			p[i]++
			pos[tr] = p
		}
	}
	for _, tr := range []string{TreatmentA, TreatmentB, TreatmentC} {
		if pos[tr] != [3]int{2, 2, 2} {
			t.Errorf("treatment %s positions %v, want [2 2 2]", tr, pos[tr])
		}
	}
}

// TestBudgetBounds is attack item 13: every phase is bounded, and a block starts only if every missing valid block still fits.
func TestBudgetBounds(t *testing.T) {
	d := frozenVersionDesignFixture()
	if got := d.BlockBoundSeconds(300); got != 6480 {
		t.Errorf("block bound %d s, want 6480", got)
	}
	if got := d.Calibration.MaxRungs(); got != 30 {
		t.Errorf("calibration rungs bound %d, want 30", got)
	}
	// Setup 2700 + calibration 30 x 360 + preflight 3 x 900 + 6 blocks x 6480 + teardown 600.
	if got := d.SessionBoundSeconds(300); got != 55680 {
		t.Errorf("session bound %d s, want 55680", got)
	}
	const rate = 1.337 // $1.237/h for the instance plus $0.10/h of other charges
	for _, c := range []struct {
		spent float64
		need  int
		want  bool
	}{
		{3.0, 6, true},
		{3.5, 6, false},
		{15.0, 1, true},
		{15.5, 1, false},
		{0, 0, false},
		{-1, 1, false},
	} {
		if got := d.MayStartBlock(c.spent, rate, c.need, 300); got != c.want {
			t.Errorf("spent %.2f, %d blocks needed: may start %v, want %v", c.spent, c.need, got, c.want)
		}
	}
	if d.MayStartBlock(0, 0, 1, 300) || d.MayStartBlock(0, rate, 1, 0) {
		t.Errorf("a zero rate or window let a block start")
	}
	if got := d.TeardownDeadlineSeconds(rate); got != 47866 {
		t.Errorf("teardown deadline %d s after launch, want 47866", got)
	}
}

// pinnedArmOrder20261115 is ArmOrder's output for seed 20261115, blocks 1 to 3, recorded when the generator was written.
var pinnedArmOrder20261115 = [][]string{
	{TreatmentB, TreatmentA, TreatmentC},
	{TreatmentB, TreatmentC, TreatmentA},
	{TreatmentC, TreatmentB, TreatmentA},
}

// frozenVersionDesignFixture is the registered design with the engine-path track's values filled by placeholders.
//
// The digest and review hashes are test inputs, not the v0.32.0 image's.
func frozenVersionDesignFixture() VersionStudyDesign {
	d := versionAsyncDesign()
	for _, tr := range []string{TreatmentB, TreatmentC} {
		e := d.Engines[tr]
		e.Image = "vllm/vllm-openai@sha256:" + strings.Repeat("b", 64)
		d.Engines[tr] = e
		d.EngineFlagReviews[tr] = strings.Repeat(strings.ToLower(tr), 64)
	}
	return d
}
