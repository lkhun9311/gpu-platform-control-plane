package bench

import "testing"

// The confirmation's design is the step-boundary design with new settings, and nothing else changed.
//
// Mutation that turns this red: drop a setting from designStepConfirm, or change its decoders' cap.
func TestStepConfirmDesignHoldsItsSettings(t *testing.T) {
	d, ok := designFor(StudyStepConfirm)
	if !ok {
		t.Fatal("the confirmation study has no episode design")
	}
	for et, want := range map[EpisodeType]int{EpisodeSerial: 16 * 3, EpisodeBurst: 9, EpisodeStagger: 12} {
		full, err := d.fullCycle(et)
		if err != nil {
			t.Fatalf("%s: %v", et, err)
		}
		if len(full) != want {
			t.Errorf("%s holds %d settings a cycle, want %d", et, len(full), want)
		}
		for _, e := range full {
			for _, r := range e {
				if _, ok := ResolveInputTokens(r.tokens); !ok {
					t.Errorf("%s: %d tokens is not in the measured table, so its prompt cannot be built", et, r.tokens)
				}
			}
		}
	}
	base := designStepBoundary
	if d.staggerDecodeCap != base.staggerDecodeCap || d.staggerDecodeMin != base.staggerDecodeMin ||
		d.staggerLagTenths != base.staggerLagTenths || d.staggerJitterMs != base.staggerJitterMs ||
		d.warmupConditioning != base.warmupConditioning || !d.warmup {
		t.Error("the confirmation changed something of the step-boundary design besides its settings and cycles")
	}
	if d.serialCycles != 6 || d.burstCycles != 4 || d.staggerCycles != 7 || d.staggerShortCycles != 0 {
		t.Errorf("cycles are %d/%d/%d (+%d short), want 6/4/7 (+0)", d.serialCycles, d.burstCycles, d.staggerCycles, d.staggerShortCycles)
	}
	s, ok := LookupStudy(StudyStepConfirm)
	if !ok || len(s.Arms) != 3 {
		t.Fatalf("the confirmation study is not registered with its three arms: %+v", s)
	}
}
