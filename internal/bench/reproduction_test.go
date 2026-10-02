package bench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// facts returns a complete, self-consistent target: every field recorded, nothing UNKNOWN.
//
// Written as a helper because the interesting cases are all "this one field differs", and a literal per case
// would let a second difference hide inside a test that claims to be about the first.
func facts(arm string) ReproductionFacts {
	return ReproductionFacts{
		Arm:             arm,
		Study:           StudySharingMatrix,
		Model:           "Qwen/Qwen2.5-3B-Instruct",
		PromptCorpusSHA: "dec1020701584417449f9c7efa5354073682cce69348af3b9fb5244705200a86",
		TraceChecksum:   "499a5e4d3c648ffd987e144c84d762f8b79ee25a14f6e4d0f03f7fe6f2cfb4ab",
		TimeoutMs:       60000,
		Seed:            11,
		LongThreshold:   4096,
		TokenizerRev:    "aa8e72537993ba99e69dfaafa59ed015b17504d1",
		PromptLenChars:  map[string]int{PremiumTenant: 1174, NoisyTenant: 42579},
		GatewaySHA:      "b97d88ebfb97bf1b8cced34ceae5c4b5c4388270",
		ImageDigests:    map[string]string{"engine": "vllm/vllm-openai@sha256:0a51ea5b"},
	}
}

func set(f ...ReproductionFacts) map[string]ReproductionFacts {
	m := map[string]ReproductionFacts{}
	for _, x := range f {
		m[x.Arm] = x
	}
	return m
}

// A fully recorded target that matches passes. Without this the refusals below prove nothing: a function that
// refused everything would satisfy all of them.
func TestReproductionRefusalAcceptsAnIdenticalPlan(t *testing.T) {
	tgt := set(facts(ArmR1), facts(ArmShared), facts(ArmTimeSlicing))
	if err := ReproductionRefusal(tgt, tgt); err != nil {
		t.Fatalf("an identical plan was refused: %v", err)
	}
}

// Each comparable field refused on its own, with its value in the message.
//
// The message matters as much as the refusal: an operator reading "they differ" has to go and find out how,
// and the thing they would find is already in this function.
func TestReproductionRefusalNamesTheFieldAndBothValues(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*ReproductionFacts)
		want   []string
	}{
		{"timeout", func(f *ReproductionFacts) { f.TimeoutMs = 30000 }, []string{"timeoutMs", "60000", "30000", "censors the tail"}},
		{"trace", func(f *ReproductionFacts) {
			f.TraceChecksum = "98efa634891cbd181aa4b251e6d1d730b8fe832887ca2fee33ef9d326a6be39a"
		}, []string{"traceChecksum", "byte-identical"}},
		{"seed", func(f *ReproductionFacts) { f.Seed = 12 }, []string{"seed", "11", "12", "arrival schedule"}},
		{"model", func(f *ReproductionFacts) { f.Model = "Qwen/Qwen2.5-7B-Instruct" }, []string{"model", "7B"}},
		{"corpus", func(f *ReproductionFacts) { f.PromptCorpusSHA = "0000" }, []string{"promptCorpusSHA", "different corpus"}},
		{"study", func(f *ReproductionFacts) { f.Study = StudyThroughputLadder }, []string{"study"}},
		{"threshold", func(f *ReproductionFacts) { f.LongThreshold = 2048 }, []string{"longThreshold", "4096", "2048"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tgt := set(facts(ArmShared))
			p := facts(ArmShared)
			tc.mutate(&p)
			err := ReproductionRefusal(tgt, set(p))
			if err == nil {
				t.Fatalf("a plan differing in %s was accepted as a reproduction", tc.name)
			}
			for _, w := range tc.want {
				if !strings.Contains(err.Error(), w) {
					t.Errorf("the refusal does not say %q: %v", w, err)
				}
			}
		})
	}
}

// The prompt length is the field this whole file exists for, so it is asserted separately and by value.
func TestReproductionRefusalCatchesThePromptLength(t *testing.T) {
	tgt := set(facts(ArmShared))
	p := facts(ArmShared)
	p.PromptLenChars = map[string]int{PremiumTenant: 200, NoisyTenant: 42579}
	err := ReproductionRefusal(tgt, set(p))
	if err == nil {
		t.Fatal("a plan sending 200-character premium prompts against a 1,174-character target was accepted")
	}
	for _, w := range []string{"promptLenChars", "1174", "200", PremiumTenant} {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("the refusal does not say %q: %v", w, err)
		}
	}
}

// UNKNOWN is not a match. This is the rule the review insisted on and the one a passing-by-default
// implementation would quietly drop.
func TestReproductionRefusalTreatsAnUnrecordedFieldAsUnknown(t *testing.T) {
	for _, tc := range []struct {
		name  string
		strip func(*ReproductionFacts)
		want  string
	}{
		{"tokenizer", func(f *ReproductionFacts) { f.TokenizerRev = "" }, "tokenizerRev"},
		{"prompt lengths", func(f *ReproductionFacts) { f.PromptLenChars = nil }, "promptLenChars"},
		{"gateway build", func(f *ReproductionFacts) { f.GatewaySHA = "" }, "gatewaySHA"},
		{"images", func(f *ReproductionFacts) { f.ImageDigests = nil }, "imageDigests"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tf := facts(ArmShared)
			tc.strip(&tf)
			err := ReproductionRefusal(set(tf), set(facts(ArmShared)))
			if err == nil {
				t.Fatalf("a target that never recorded %s was accepted as reproducible", tc.want)
			}
			for _, w := range []string{tc.want, "UNKNOWN", "cannot be certified"} {
				if !strings.Contains(err.Error(), w) {
					t.Errorf("the refusal does not say %q: %v", w, err)
				}
			}
		})
	}
}

func TestReproductionRefusalRefusesAnArmTheTargetNeverMeasured(t *testing.T) {
	err := ReproductionRefusal(set(facts(ArmR1), facts(ArmShared)), set(facts(ArmTimeSlicing)))
	if err == nil {
		t.Fatal("a plan buying an arm the target never measured was accepted as a reproduction")
	}
	for _, w := range []string{ArmTimeSlicing, "no such arm", ArmR1, ArmShared} {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("the refusal does not say %q: %v", w, err)
		}
	}
}

func TestReproductionRefusalRefusesEmptySides(t *testing.T) {
	if err := ReproductionRefusal(nil, set(facts(ArmShared))); err == nil {
		t.Error("an empty target was accepted")
	}
	if err := ReproductionRefusal(set(facts(ArmShared)), nil); err == nil {
		t.Error("an empty plan was accepted")
	}
}

// A target whose trace was edited after its manifest was written must be refused, not trusted.
//
// This exists because a mutation found nothing: deleting the checksum comparison in
// ReproductionFactsFromArchive left every test green. Every other fixture here carries a correct checksum, so
// the guard was real and unreached -- and an unreached guard is one whose removal nobody would notice. The
// violation IS constructible, unlike the ladder refusals this project left out for being unreachable, so the
// fixture is the fix rather than deleting the check.
func TestReproductionFactsFromArchiveRefusesATamperedTrace(t *testing.T) {
	dir := t.TempDir()
	trace := filepath.Join(dir, "trace-shared-1.jsonl")
	if err := os.WriteFile(trace, []byte(`{"tenant":"premium-1"}`+"\n"), 0o600); err != nil {
		t.Fatalf("write trace: %v", err)
	}
	sum, err := ChecksumFile(trace)
	if err != nil {
		t.Fatalf("checksum: %v", err)
	}
	manifest := "arm: shared\nstudy: " + StudySharingMatrix + "\ntracePath: /src/m5c-run/trace-shared-1.jsonl\n" +
		"traceChecksum: " + sum + "\ntimeoutMs: 60000\nseed: 11\n"
	if err := os.WriteFile(filepath.Join(dir, "manifest-shared-1.yaml"), []byte(manifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}

	// Honest first: the archive loads while it is intact, so the refusal below is about the tampering.
	if _, err := ReproductionFactsFromArchive(dir); err != nil {
		t.Fatalf("an intact archive was refused: %v", err)
	}

	// One byte appended after the manifest froze its hash.
	if err := os.WriteFile(trace, []byte(`{"tenant":"premium-1"}`+"\n"+`{"tenant":"premium-1"}`+"\n"), 0o600); err != nil {
		t.Fatalf("tamper: %v", err)
	}
	_, err = ReproductionFactsFromArchive(dir)
	if err == nil {
		t.Fatal("an archive whose trace no longer hashes to its manifest was accepted as the run it claims to be")
	}
	for _, w := range []string{"traceChecksum", "not the run its manifests describe"} {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("the refusal does not say %q: %v", w, err)
		}
	}
}

// THE REAL ARCHIVES, which is the case that was missed for real money.
//
// Both runs are in this repository. The ninth pilot is the target the 2026-10-02 run was registered as
// reproducing, and the refusal has to fire on the facts that actually differed -- the timeout and the trace --
// before it ever gets to the fields the pilot never recorded.
//
// Skipped rather than failed when the archives are absent: they are gitignored run outputs, so a clean
// checkout has neither, and a test that failed there would be failing about the checkout.
func TestReproductionRefusalOnTheTwoRealArchives(t *testing.T) {
	const ninth = "../../hack/m5c-20260913-011031/m5c-run"
	const later = "../../hack/m5c-20261002-014903/m5c-run"
	for _, d := range []string{ninth, later} {
		if _, err := os.Stat(filepath.Join(d, "README.txt")); err != nil {
			t.Skipf("archive %s is not in this checkout (run outputs are not committed)", d)
		}
	}

	tgt, err := ReproductionFactsFromArchive(ninth)
	if err != nil {
		t.Fatalf("could not read the ninth pilot's facts: %v", err)
	}
	got, err := ReproductionFactsFromArchive(later)
	if err != nil {
		t.Fatalf("could not read the 2026-10-02 run's facts: %v", err)
	}

	// The arms line up, so the refusal below is about the load and not about a missing arm.
	for _, arm := range []string{ArmR1, ArmShared, ArmTimeSlicing} {
		if _, ok := tgt[arm]; !ok {
			t.Fatalf("the ninth pilot's archive has no %s arm", arm)
		}
		if _, ok := got[arm]; !ok {
			t.Fatalf("the 2026-10-02 archive has no %s arm", arm)
		}
	}

	// The two facts that were measured to differ, asserted by value.
	if tgt[ArmShared].TimeoutMs != 30000 || got[ArmShared].TimeoutMs != 60000 {
		t.Errorf("timeouts are %d and %d; the measured values were 30000 and 60000",
			tgt[ArmShared].TimeoutMs, got[ArmShared].TimeoutMs)
	}
	if tgt[ArmShared].TraceChecksum == got[ArmShared].TraceChecksum {
		t.Error("the two archives' traceChecksums are equal; they were measured to differ")
	}
	// And the pilot's recording gap, which is why this can never be certified either way.
	if unknown := unrecordedFields(tgt[ArmShared]); len(unknown) == 0 {
		t.Error("the ninth pilot's facts report nothing unrecorded; promptLenChars and imageDigests postdate it")
	}

	err = ReproductionRefusal(tgt, got)
	if err == nil {
		t.Fatal("the 2026-10-02 run was accepted as a reproduction of the ninth pilot; that is the defect this file closes")
	}
	if !strings.Contains(err.Error(), "timeoutMs") && !strings.Contains(err.Error(), "traceChecksum") {
		t.Errorf("the refusal names neither the timeout nor the trace: %v", err)
	}
}
