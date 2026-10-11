package bench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The gateway by content, docs/superpowers/specs/2026-10-07-gateway-identity-for-reproduction.md.

const (
	gwBinary = "79d4784ed8888628aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	gwBase   = "gcr.io/distroless/static@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3"
)

// byContent is a fully recorded target that names its gateway by binary and base.
func byContent(arm string) ReproductionFacts {
	f := facts(arm)
	f.GatewayBinarySHA256, f.GatewayBase = gwBinary, gwBase
	return f
}

// withImages returns f with its own copy of the image map, so a mutation never reaches another fixture.
func withImages(f ReproductionFacts, images map[string]string) ReproductionFacts {
	f.ImageDigests = images
	return f
}

// The case the registration exists for: one binary on one base, built twice, gives two image IDs, and the
// plan -- which runs before the image is built -- has none. Both must pass when the content facts agree.
//
// Mutation that turns this red: keep the gateway's image ID in the comparison when both sides have the facts.
func TestReproductionByContentIgnoresTheRebuiltImageID(t *testing.T) {
	tgt := byContent(ArmShared)
	rebuilt := withImages(byContent(ArmShared), map[string]string{
		"engine": "vllm/vllm-openai@sha256:0a51ea5b", "gateway": "m5c-gateway@sha256:82fc6ed7"})
	if err := ReproductionRefusal(set(tgt), set(rebuilt)); err != nil {
		t.Errorf("a rebuild of the same binary on the same base was refused: %v", err)
	}
	planned := withImages(byContent(ArmShared), map[string]string{"engine": "vllm/vllm-openai@sha256:0a51ea5b"})
	if err := ReproductionRefusal(set(tgt), set(planned)); err != nil {
		t.Errorf("a plan carrying no gateway image ID, as every plan does, was refused: %v", err)
	}
}

// Without the content facts on the target, nothing changes: the image ID is still compared, so a rebuild of a
// legacy run's gateway is refused as before.
//
// Mutation that turns this red: drop the gateway's image ID whenever the PLAN has the facts.
func TestReproductionOfALegacyTargetStillComparesTheImageID(t *testing.T) {
	tgt := facts(ArmShared)
	p := withImages(byContent(ArmShared), map[string]string{
		"engine": "vllm/vllm-openai@sha256:0a51ea5b", "gateway": "m5c-gateway@sha256:82fc6ed7"})
	err := ReproductionRefusal(set(tgt), set(p))
	if err == nil {
		t.Fatal("a rebuilt gateway was accepted against a target that never named its gateway by content")
	}
	for _, w := range []string{"imageDigests", "gateway", "03a1ca8d", "82fc6ed7"} {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("the refusal does not say %q: %v", w, err)
		}
	}
}

// The source commit alone is not the gateway: a different binary or base under the same gatewaySHA is refused.
//
// Mutation that turns this red: drop either comparison from the byContent switch.
func TestReproductionByContentRefusesASubstitutedBinaryOrBase(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*ReproductionFacts)
		want   []string
	}{
		{"binary", func(f *ReproductionFacts) {
			f.GatewayBinarySHA256 = strings.Repeat("b", 64)
		}, []string{"gatewayBinarySHA256", gwBinary, strings.Repeat("b", 64)}},
		{"base", func(f *ReproductionFacts) {
			f.GatewayBase = "gcr.io/distroless/static@sha256:" + strings.Repeat("c", 64)
		}, []string{"gatewayBase", "different base"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := byContent(ArmShared)
			tc.mutate(&p)
			if p.GatewaySHA != facts(ArmShared).GatewaySHA {
				t.Fatal("the fixture changed the source commit, so the case would not be about the binary")
			}
			err := ReproductionRefusal(set(byContent(ArmShared)), set(p))
			if err == nil {
				t.Fatalf("a plan with a different gateway %s under the same commit was accepted", tc.name)
			}
			for _, w := range tc.want {
				if !strings.Contains(err.Error(), w) {
					t.Errorf("the refusal does not say %q: %v", w, err)
				}
			}
		})
	}
}

// The engine and the other content are still compared when the gateway leaves the image comparison.
func TestReproductionByContentStillComparesTheEngine(t *testing.T) {
	p := withImages(byContent(ArmShared), map[string]string{"engine": "vllm/vllm-openai@sha256:deadbeef"})
	err := ReproductionRefusal(set(byContent(ArmShared)), set(p))
	if err == nil || !strings.Contains(err.Error(), "engine") || !strings.Contains(err.Error(), "deadbeef") {
		t.Errorf("a different engine was not refused by name: %v", err)
	}
	p = withImages(byContent(ArmShared), nil)
	err = ReproductionRefusal(set(byContent(ArmShared)), set(p))
	if err == nil || !strings.Contains(err.Error(), "this plan records none") {
		t.Errorf("a plan with no engine image was not refused as recording less than its target: %v", err)
	}
}

// A target that names its gateway by content and a plan that does not: this run is failing to record it.
func TestReproductionByContentRefusesAPlanWithoutTheFacts(t *testing.T) {
	err := ReproductionRefusal(set(byContent(ArmShared)), set(facts(ArmShared)))
	if err == nil {
		t.Fatal("a plan recording neither fact was accepted against a target that records both")
	}
	if !strings.Contains(err.Error(), "this plan records neither") {
		t.Errorf("the refusal does not say the plan is the one missing them: %v", err)
	}
}

// Half an identity, on either side, is refused rather than read as none.
//
// Mutation that turns this red: return nil from GatewayIdentityRefusal when only one fact is present.
func TestReproductionRefusesHalfAGatewayIdentity(t *testing.T) {
	half := facts(ArmShared)
	half.GatewayBinarySHA256 = gwBinary
	for name, pair := range map[string][2]ReproductionFacts{
		"target": {half, byContent(ArmShared)},
		"plan":   {byContent(ArmShared), half},
	} {
		err := ReproductionRefusal(set(pair[0]), set(pair[1]))
		if err == nil || !strings.Contains(err.Error(), "both or neither") {
			t.Errorf("half an identity on the %s was not refused as such: %v", name, err)
		}
	}
}

func TestGatewayIdentityRefusal(t *testing.T) {
	for _, tc := range []struct {
		name, binary, base, want string
	}{
		{"neither", "", "", ""},
		{"both", gwBinary, gwBase, ""},
		{"binary only", gwBinary, "", "both or neither"},
		{"base only", "", gwBase, "both or neither"},
		{"short binary", gwBinary[:63], gwBase, "64 lowercase hex"},
		{"upper-case binary", strings.ToUpper(gwBinary), gwBase, "64 lowercase hex"},
		{"tagged base", gwBinary, "gcr.io/distroless/static:nonroot", "not pinned by digest"},
	} {
		err := GatewayIdentityRefusal(tc.binary, tc.base)
		switch {
		case tc.want == "" && err != nil:
			t.Errorf("%s: refused: %v", tc.name, err)
		case tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)):
			t.Errorf("%s: want a refusal saying %q, got %v", tc.name, tc.want, err)
		}
	}
}

// Each provenance role is its own fact: a target naming only its engine is UNKNOWN for its gateway.
//
// Mutation that turns this red: go back to counting any non-empty image map as recorded.
func TestReproductionReportsEachUnrecordedImageRole(t *testing.T) {
	for _, role := range ProvenanceRoles {
		tf := facts(ArmShared)
		tf.ImageDigests = withoutRole(tf.ImageDigests, role)
		err := ReproductionRefusal(set(tf), set(tf))
		if err == nil {
			t.Fatalf("a target with no %s image was accepted as reproducible", role)
		}
		for _, w := range []string{"imageDigests." + role, "UNKNOWN"} {
			if !strings.Contains(err.Error(), w) {
				t.Errorf("the refusal does not say %q: %v", w, err)
			}
		}
	}
}

// An archive is read through the same both-or-neither rule, and the facts reach factsDiffer.
func TestReproductionFactsFromArchiveReadsTheGatewayIdentity(t *testing.T) {
	write := func(dir, rep, extra string) {
		trace := filepath.Join(dir, "trace-shared-"+rep+".jsonl")
		if err := os.WriteFile(trace, []byte(`{"tenant":"premium-1"}`+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		sum, err := ChecksumFile(trace)
		if err != nil {
			t.Fatal(err)
		}
		m := "arm: shared\nstudy: " + StudySharingMatrix + "\ntracePath: /src/m5c-run/trace-shared-" + rep + ".jsonl\n" +
			"traceChecksum: " + sum + "\ntimeoutMs: 60000\nseed: 11\n" + extra
		if err := os.WriteFile(filepath.Join(dir, "manifest-shared-"+rep+".yaml"), []byte(m), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	whole := "gatewayBinarySHA256: " + gwBinary + "\ngatewayBase: " + gwBase + "\n"

	dir := t.TempDir()
	write(dir, "1", whole)
	got, err := ReproductionFactsFromArchive(dir)
	if err != nil {
		t.Fatalf("an archive with a whole identity was refused: %v", err)
	}
	if got[ArmShared].GatewayBinarySHA256 != gwBinary || got[ArmShared].GatewayBase != gwBase {
		t.Errorf("the archive's identity was not read: %+v", got[ArmShared])
	}

	dir = t.TempDir()
	write(dir, "1", "gatewayBinarySHA256: "+gwBinary+"\n")
	if _, err := ReproductionFactsFromArchive(dir); err == nil || !strings.Contains(err.Error(), "both or neither") {
		t.Errorf("an archive with half an identity was not refused: %v", err)
	}

	dir = t.TempDir()
	write(dir, "1", whole)
	write(dir, "2", "gatewayBinarySHA256: "+strings.Repeat("d", 64)+"\ngatewayBase: "+gwBase+"\n")
	if _, err := ReproductionFactsFromArchive(dir); err == nil || !strings.Contains(err.Error(), "gatewayBinarySHA256") {
		t.Errorf("two repetitions on two gateway binaries read as one run: %v", err)
	}
}
