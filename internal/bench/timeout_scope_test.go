package bench

import (
	"os"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// The manifest must say WHICH interval timeoutMs bounds, and an absent scope must stay loadable.
//
// # WHY THESE THREE
//
// The field was added and nothing asserted it: production wrote it in two places, the archive README
// described it, and no test or gate read it back. A field in that state is one a later refactor removes
// silently, which is the shape this session hit three times.
func TestTimeoutScopeIsMarshalledIntoTheManifest(t *testing.T) {
	m := validatableManifest()
	m.TimeoutScope = TimeoutScopeWholeRequest
	data, err := yaml.Marshal(&m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	got := string(data)
	if !strings.Contains(got, "timeoutScope: whole-request-including-stream") {
		t.Errorf("the manifest does not carry the timeout scope; a reader given only timeoutMs cannot tell a whole-request budget from a first-token one. Marshalled:\n%s", got)
	}
	// Beside it, not instead of it: the number alone was never the problem.
	if !strings.Contains(got, "timeoutMs: 30000") {
		t.Errorf("the manifest lost timeoutMs while gaining its scope:\n%s", got)
	}
}

// An empty scope marshals away and still loads, because three archives on disk have no scope at all.
//
// Requiring the field would make every past manifest unloadable to prove a point about future ones, and
// "not recorded" must not read as "no scope". Validate is asserted to accept it.
func TestAManifestWithoutATimeoutScopeStillValidates(t *testing.T) {
	m := validatableManifest()
	data, err := yaml.Marshal(&m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(data), "timeoutScope") {
		t.Errorf("an unset scope was marshalled anyway, so a run that never recorded one would look like it had:\n%s", data)
	}
	if err := m.validateFields(); err != nil {
		t.Errorf("a manifest with no timeout scope failed validation (%v); the fifteen-cell archive carries none, and refusing it would make the past unreadable", err)
	}
}

// validatableManifest is the smallest manifest validateFields accepts, with no timeout scope set.
//
// Every field here is one validateFields requires, and the study and arm come from the registry's own
// constants rather than from strings I typed: the arm has to be one StudySharingMatrix admits, and
// hard-coding "R1" would make this fixture a guess about what ArmR1 contains.
func validatableManifest() RunManifest {
	return RunManifest{
		SchemaVersion:   "v2",
		PromptCorpusSHA: PromptCorpusSHA256,
		Study:           StudySharingMatrix,
		Arm:             ArmR1,
		GatewayURL:      "http://gateway.example:8080",
		TracePath:       "trace.jsonl",
		TraceChecksum:   "sha256:" + strings.Repeat("a", 64),
		Model:           "llama-3-8b",
		TimeoutMs:       30000,
		Seed:            42,
		PrimaryEndpoint: "ttft_p99",
		MatchTolerance:  "0.05",
	}
}

// Both manifest writers take the scope from the constant, so two literals cannot drift apart.
//
// Read as text because the alternative is executing two CLI subcommands from a unit test. The constant's
// own value is asserted above through the marshalled output, so this pins only that nobody re-typed it.
func TestBothManifestWritersUseTheScopeConstant(t *testing.T) {
	if TimeoutScopeWholeRequest != "whole-request-including-stream" {
		t.Fatalf("the scope constant reads %q; the archive README and the published manifests name the other value", TimeoutScopeWholeRequest)
	}
}

// Every place that BUILDS a manifest sets the scope, which the marshalling test above cannot see.
//
// That test constructs its own RunManifest, so deleting the field from gen-trace's literal left it green:
// it establishes that the struct CAN carry the scope, never that the binaries DO. I had checked the real
// output by hand -- ran gen-trace, grepped the YAML, found `timeoutScope: whole-request-including-stream`
// -- and a hand check is not a gate. This reads the writers as text, the way the shell gates read the
// matrix's call sites, because executing two CLI subcommands from a unit test would test the CLI.
//
// Keyed on `RunManifest{` so a THIRD writer added later is counted too, and fails until it sets the field.
func TestEveryManifestWriterSetsTheTimeoutScope(t *testing.T) {
	writers := map[string]string{
		"../../cmd/benchharness/main.go":          "gen-trace",
		"../../cmd/benchharness/preparetraces.go": "prepare-traces",
	}
	for path, name := range writers {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		text := string(src)
		if !strings.Contains(text, "RunManifest{") {
			t.Errorf("%s (%s) no longer builds a RunManifest; this test is keyed on that literal and would stop checking anything", path, name)
			continue
		}
		if !strings.Contains(text, "TimeoutScope:") {
			t.Errorf("%s (%s) builds a manifest without setting TimeoutScope, so its runs would record a timeout budget whose interval is unnamed -- and an empty scope is read as 'this run predates the field', which would be false", path, name)
		}
		if !strings.Contains(text, "bench.TimeoutScopeWholeRequest") {
			t.Errorf("%s (%s) sets the scope from something other than the constant; two hand-typed strings drift and the archive README quotes only one of them", path, name)
		}
	}
}
