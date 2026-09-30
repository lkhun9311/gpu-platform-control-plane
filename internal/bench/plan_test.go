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
		"baseline.outputTokens is",
		"contender.outputTokens is",
		"warmupRequests is",
		"baseline.inputTokens is",
		"contender.inputTokens is",
		"load.generator is",
	}
	msg := err.Error()
	for _, want := range wantEach {
		if !strings.Contains(msg, want) {
			t.Errorf("the refusal does not mention %q; got:\n%s", want, msg)
		}
	}

	// And the things the sample DOES satisfy must not be refused, or the compiler is simply refusing
	// everything and the test above would pass for the wrong reason.
	for _, unwanted := range []string{
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
		{"an output length the generator caps", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Baseline.OutputTokens = 128
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
		{"a token-denominated input length", func(s *platformv1.GpuSharingBenchmarkSpec) {
			s.Baseline.InputTokens = 256
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

// executableSpec is the sample's protocol with every unsupported value replaced by one the harness can run.
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
