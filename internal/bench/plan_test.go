package bench

import (
	"os"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// TestTheCommittedSampleCannotBeExecuted loads the sample this repository ships and asserts it is refused.
//
// This is the finding, not a placeholder. `config/samples/platform_v1_gpusharingbenchmark.yaml` is the
// protocol the design spec registered, and this harness cannot execute it -- so the CR must not be created
// until an adapter exists, because `spec` is immutable once created and registering it would freeze an
// unexecutable protocol forever.
//
// The sample is loaded from disk rather than restated here. A copy of the spec in this file would let the two
// drift, and the whole point is to judge the thing that ships.
func TestTheCommittedSampleCannotBeExecuted(t *testing.T) {
	blob, err := os.ReadFile("../../config/samples/platform_v1_gpusharingbenchmark.yaml")
	if err != nil {
		t.Fatalf("read the sample: %v", err)
	}
	var cr platformv1.GpuSharingBenchmark
	if err := yaml.UnmarshalStrict(blob, &cr); err != nil {
		t.Fatalf("decode the sample: %v", err)
	}

	_, err = CompilePlan(cr.Spec)
	if err == nil {
		t.Fatal("the committed sample compiled; either an adapter landed and this test should be rewritten, or CompilePlan stopped refusing something it cannot do")
	}

	// Each refusal is asserted by the substring that names ITS OWN cause, never by counting them.
	//
	// A count would pass if two refusals merged or if one was replaced by a different one, and this file
	// exists to say which capabilities are missing. The substrings are the parts an operator would act on.
	wantEach := []string{
		"baseline.tenant is",
		"contender.tenant is",
		"baseline.model is",
		"contender.model is",
		"warmupRequests is",
		"load.generator is",
	}
	msg := err.Error()
	for _, want := range wantEach {
		if !strings.Contains(msg, want) {
			t.Errorf("the refusal does not mention %q; got:\n%s", want, msg)
		}
	}
	// The output caps left this list on 2026-10-01, and their absence is asserted rather than simply
	// removed. A shorter list and a switched-off compiler read the same way otherwise: the sample declares
	// 128 and 256, the generator now takes both as flags, so a refusal naming them would mean the plan had
	// stopped carrying what it can carry.
	for _, gone := range []string{"baseline.outputTokens is", "contender.outputTokens is"} {
		if strings.Contains(msg, gone) {
			t.Errorf("the refusal still mentions %q; the generator takes the cap as a flag now, so a declared "+
				"value is carried into the plan rather than refused:\n%s", gone, msg)
		}
	}

	// And the things the sample DOES satisfy must not be refused, or the compiler is simply refusing
	// everything and the test above would pass for the wrong reason.
	for _, unwanted := range []string{
		// The sample's 256 and 8192 token prompts are RESOLVED, measured against the served tokenizer at
		// 1174 and 42579 characters, so they are no longer among its refusals. They were until 2026-09-30,
		// and this pair of lines is where that change is visible.
		"baseline.inputTokens is",
		"contender.inputTokens is",
		"load.mode is",      // openLoop, which Replay implements
		"load.retries is",   // 0, which the sender honours by never resubmitting
		"load.streaming is", // true, which the SSE reader requires
		"repetitions is",    // 5, which meets the CRD floor
		"sharingMode is",    // sharedInstance, which maps to R1 + shared
		"minRequestsPerRun", // 1000, above the harness floor of 100
	} {
		if strings.Contains(msg, unwanted) {
			t.Errorf("the refusal mentions %q, which the sample satisfies; got:\n%s", unwanted, msg)
		}
	}
}

// TestAPlanCompilesOnceEveryUnsupportedValueIsRemoved proves the compiler can say yes.
//
// A checker that refuses every input is indistinguishable from one that does not work, and this repository
// has shipped that shape before. So the same spec is rebuilt with each unsupported value replaced by the one
// the harness can actually execute, and the compile must succeed and produce the arms the mode declares.
func TestAPlanCompilesOnceEveryUnsupportedValueIsRemoved(t *testing.T) {
	spec := executableSpec()
	p, err := CompilePlan(spec)
	if err != nil {
		t.Fatalf("the executable spec was refused: %v", err)
	}
	if got, want := strings.Join(p.Arms, " "), "R1 shared"; got != want {
		t.Errorf("arms = %q, want %q", got, want)
	}
	if p.Repetitions != 5 {
		t.Errorf("repetitions = %d, want 5", p.Repetitions)
	}
	// The rates stay the decimal strings the CR carried, not floats re-rendered.
	if p.PremiumRate != "2.0" || p.ContenderRate != "6.0" {
		t.Errorf("rates = %q/%q, want 2.0/6.0", p.PremiumRate, p.ContenderRate)
	}
}

// TestEachUnsupportedValueIsRefusedOnItsOwn changes one field at a time away from the executable spec.
//
// Asserting on the sample alone cannot tell a refusal that fires from one that is merely present in a message
// full of others. One field per case, and the case names the substring it expects.
func TestEachUnsupportedValueIsRefusedOnItsOwn(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*platformv1.GpuSharingBenchmarkSpec)
		want   string
	}{
		{"a tenant the generator does not send", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Baseline.Tenant = "tenant-premium"
		}, "baseline.tenant is"},
		{"a model nothing serves", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Contender.Model = "llama3-8b"
		}, "contender.model is"},
		{"an output cap asking the engine for nothing", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Baseline.OutputTokens = 0
		}, "baseline.outputTokens is"},
		{"a warmup the harness has no phase for", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.WarmupRequests = 50
		}, "warmupRequests is"},
		{"a closed-loop arrival model", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Load.Mode = "closedLoop"
		}, "load.mode is"},
		{"a retry the sender never makes", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Load.Retries = 1
		}, "load.retries is"},
		{"a non-streaming response with no first-token time", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Load.Streaming = false
		}, "load.streaming is"},
		{"a generator that did not send the traffic", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Load.Generator = "genai-perf"
		}, "load.generator is"},
		{"a sample floor below the harness floor", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.MinRequestsPerRun = 50
		}, "minRequestsPerRun is"},
		{"a sharing mode the matrix does not deploy", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.SharingMode = "mig"
		}, "sharingMode is"},
		// 3000 rather than a power of two: 256 through 8192 are all in the measured table now and compile, so
		// using one here would assert a refusal that no longer exists. What is still refused is a count nobody
		// has swept.
		{"an input length nobody has swept", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Baseline.InputTokens = 3000
		}, "baseline.inputTokens is"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			spec := executableSpec()
			tc.mutate(&spec)
			_, err := CompilePlan(spec)
			if err == nil {
				t.Fatalf("%s was accepted", tc.name)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("refusal does not mention %q; got: %v", tc.want, err)
			}
		})
	}
}

// executableSpec is the sample's protocol with every unsupported value replaced by one the harness can run,
// and it is DELIBERATELY NOT A VALID API OBJECT.
//
// inputTokens is ZERO here, and that is not a placeholder: CompilePlan refuses ANY token-denominated input
// length, because the character-to-token conversion is not invertible. Zero is the only value that does not
// assert a token count the served tokenizer would disagree with, and it means "the plan carries no token
// length" rather than "a prompt of no tokens". An adapter that closes this gap has to change both this
// function and the refusal it satisfies.
func executableSpec() platformv1.GpuSharingBenchmarkSpec {
	return platformv1.GpuSharingBenchmarkSpec{
		GPUClass:    "a10g",
		SharingMode: "sharedInstance",
		Baseline: platformv1.BenchmarkWorkload{
			Tenant: PremiumTenant, Model: ServedModel, QPS: "2.0",
			InputTokens: 0, OutputTokens: FixedPremiumMaxOutputTokens,
		},
		Contender: platformv1.BenchmarkWorkload{
			Tenant: NoisyTenant, Model: ServedModel, QPS: "6.0",
			InputTokens: 0, OutputTokens: FixedNoisyMaxOutputTokens,
		},
		Repetitions:       5,
		WarmupRequests:    0,
		MinRequestsPerRun: 1000,
		Load: platformv1.LoadSpec{
			Mode: "openLoop", Generator: HarnessGenerator,
			Streaming: true, TimeoutMs: 60000, Retries: 0,
		},
	}
}

// TestAnAPIValidSpecCompilesAndCarriesTheResolvedLengths replaces a test that asserted a gap now closed.
//
// It used to say "the input length is the only remaining gap" and assert that an API-valid spec was refused
// for nothing else. That was true until the resolution table landed; asserting it now would pin the absence
// of a capability that exists. What is worth pinning instead is the other half of the same claim: the plan
// carries the MEASURED character lengths, so a caller has the value the generator needs and never a
// computed one.
//
// The numbers are the measurement, not a convention. 256 tokens resolved to 1174 characters and 8192 to
// 42579, each the smallest of several lengths that give the declared count, swept inside the serving image.
// If the tokenizer moves they change, and the constants below will disagree with the table -- which is what
// TestInputLengthTableMatchesTheMeasurement is for.
func TestAnAPIValidSpecCompilesAndCarriesTheResolvedLengths(t *testing.T) {
	spec := apiValidSpec()
	p, err := CompilePlan(spec)
	if err != nil {
		t.Fatalf("an API-valid spec was refused: %v", err)
	}
	if p.BaselinePromptChars != 1174 {
		t.Errorf("baseline prompt chars = %d, want the measured 1174", p.BaselinePromptChars)
	}
	if p.ContenderPromptChars != 42579 {
		t.Errorf("contender prompt chars = %d, want the measured 42579", p.ContenderPromptChars)
	}
	if p.TokenizerRevision != InputLengthTokenizerRevision {
		t.Errorf("tokenizer revision = %q, want %q", p.TokenizerRevision, InputLengthTokenizerRevision)
	}
	// The output caps are CARRIED from 2026-10-01, and the values here are deliberately NOT 64 and 16.
	//
	// The executable sample declares exactly the generator's old literals, so compiling it proves nothing
	// about whether the plan carries the CR's value or re-states a constant. Asserting against 64/16 would
	// pass just as well with the field deleted -- which a mutation showed: removing both assignments from
	// CompilePlan left every test in this package green, because nothing read them.
	caps := apiValidSpec()
	caps.Baseline.OutputTokens = 96
	caps.Contender.OutputTokens = 24
	pc, err := CompilePlan(caps)
	if err != nil {
		t.Fatalf("a spec declaring caps the generator can now take was refused: %v", err)
	}
	if pc.BaselineOutputTokens != 96 || pc.ContenderOutputTokens != 24 {
		t.Errorf("the plan carries caps %d and %d, want the declared 96 and 24; the generator takes them as "+
			"flags now, so a plan that drops them sends the old literals to the card",
			pc.BaselineOutputTokens, pc.ContenderOutputTokens)
	}
	// And the plan must not quietly carry a length for a side that declared no token count: zero means the
	// side asserted nothing, and turning that into a character length would invent traffic.
	zero := apiValidSpec()
	zero.Contender.InputTokens = 0
	pz, err := CompilePlan(zero)
	if err != nil {
		t.Fatalf("a spec with no contender token count was refused: %v", err)
	}
	if pz.ContenderPromptChars != 0 {
		t.Errorf("contender prompt chars = %d for a side that declared no tokens, want 0", pz.ContenderPromptChars)
	}
}

// apiValidSpec is executableSpec with input lengths the API accepts.
//
// 256 and 8192 are the sample's own declared lengths, kept so the refusal is about the registered protocol
// rather than about numbers invented for a test.
func apiValidSpec() platformv1.GpuSharingBenchmarkSpec {
	s := executableSpec()
	s.Baseline.InputTokens = 256
	s.Contender.InputTokens = 8192
	return s
}
