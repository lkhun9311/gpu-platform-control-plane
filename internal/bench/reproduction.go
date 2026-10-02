package bench

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"sigs.k8s.io/yaml"
)

// ReproductionFacts is what a run has to match for a later run to be called a reproduction of it.
//
// It exists because a registration said "reproduction" and nothing checked it. On 2026-10-02 a paid run was
// registered as a five-repetition reproduction of the 2026-09-13 pilot and offered a 294-token premium prompt
// against that pilot's 50, with a 60-second timeout against its 30. The pre-purchase plan check passed it in
// full: `MatrixPlanRefusal` asks whether a cell is SCORABLE -- study registered, arm admitted, per-repetition
// tail floor -- and has no notion of "the same load as a named prior run".
//
// The fields here are the ones a frozen manifest records about the offered traffic and the judging contract.
// They are deliberately NOT the whole manifest: GatewayURL and TracePath are where a run happened to put
// things, and comparing them would refuse every reproduction for no reason.
type ReproductionFacts struct {
	Arm             string
	Study           string
	Model           string
	PromptCorpusSHA string
	TraceChecksum   string
	TimeoutMs       int
	Seed            int64
	LongThreshold   int

	// TokenizerRev and PromptLenChars are absent from manifests written before those fields existed.
	//
	// An absent field is NOT a match. See ReproductionRefusal: it is reported as UNKNOWN and refuses, because
	// treating "not recorded" as "the same" is how the defect this file closes would recur.
	TokenizerRev   string
	PromptLenChars map[string]int

	// GatewaySHA and ImageDigests say which build produced the numbers.
	//
	// The 2026-09-13 pilot has neither: the code that fills them landed on 2026-09-16. So a reproduction of
	// that pilot cannot be certified on the environment, only on the offered traffic, and the refusal says so
	// rather than passing quietly.
	GatewaySHA   string
	ImageDigests map[string]string
}

// ReproductionFactsFromArchive reads one run's manifests out of an archive directory, keyed by arm.
//
// It does NOT use LoadManifest, and that is the whole reason this function exists. LoadManifest verifies
// TraceChecksum against the file TracePath names, and every archive this project has records TracePath as
// `/src/m5c-run/trace-<arm>-<rep>.jsonl` -- the path INSIDE the rented instance. That path does not exist in
// a checkout, so LoadManifest fails on every archived manifest. The trace files are in the archive, beside
// the manifests, so the checksum is verified against the copy that is actually there.
//
// Two repetitions of one arm must agree on every field. They replay the same trace by construction, so a
// disagreement means the archive is not one run's and comparing against it would compare against a mixture.
func ReproductionFactsFromArchive(dir string) (map[string]ReproductionFacts, error) {
	paths, err := filepath.Glob(filepath.Join(dir, "manifest-*.yaml"))
	if err != nil {
		return nil, fmt.Errorf("list manifests in %s: %w", dir, err)
	}
	if len(paths) == 0 {
		return nil, fmt.Errorf("no manifest-*.yaml in %s, so there is nothing to reproduce; point --reproduces at a run's m5c-run directory", dir)
	}
	sort.Strings(paths)

	out := map[string]ReproductionFacts{}
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", p, err)
		}
		var m RunManifest
		if err := yaml.Unmarshal(data, &m); err != nil {
			return nil, fmt.Errorf("parse %s: %w", p, err)
		}
		if m.Arm == "" {
			return nil, fmt.Errorf("%s names no arm, so its facts cannot be matched to a planned cell", p)
		}

		// The checksum is verified against the trace BESIDE the manifest, by base name.
		//
		// Without this the comparison would trust a number in a file it never checked, and an archive whose
		// rows were edited after the fact would read as the run it claims to be.
		trace := filepath.Join(filepath.Dir(p), filepath.Base(m.TracePath))
		sum, err := ChecksumFile(trace)
		if err != nil {
			return nil, fmt.Errorf("read trace %s for %s: %w", trace, filepath.Base(p), err)
		}
		if sum != m.TraceChecksum {
			return nil, fmt.Errorf("%s declares traceChecksum %s and %s hashes to %s, so this archive is not the run its manifests describe",
				filepath.Base(p), m.TraceChecksum, filepath.Base(trace), sum)
		}

		f := ReproductionFacts{
			Arm:             m.Arm,
			Study:           m.Study,
			Model:           m.Model,
			PromptCorpusSHA: m.PromptCorpusSHA,
			TraceChecksum:   m.TraceChecksum,
			TimeoutMs:       m.TimeoutMs,
			Seed:            m.Seed,
			LongThreshold:   m.LongThreshold,
			TokenizerRev:    m.TokenizerRev,
			PromptLenChars:  m.PromptLenChars,
			GatewaySHA:      m.GatewaySHA,
			ImageDigests:    m.ImageDigests,
		}
		if prev, seen := out[m.Arm]; seen {
			if diff := factsDiffer(prev, f); diff != "" {
				return nil, fmt.Errorf("two manifests for arm %s in %s disagree on %s; an archive whose repetitions differ is not one run's evidence",
					m.Arm, dir, diff)
			}
			continue
		}
		out[m.Arm] = f
	}
	return out, nil
}

// ReproductionFactsOf lifts a manifest the CURRENT run wrote into the facts a comparison reads.
//
// Separate from ReproductionFactsFromArchive because the two sides arrive differently: a planned cell's
// manifest is on local disk beside its trace, so LoadManifest can read it and verify its checksum, while an
// archived manifest records a path inside a rented instance and cannot.
//
// The asymmetry in what counts as UNKNOWN is deliberate and lives in ReproductionRefusal, not here: the
// question is whether sameness with the TARGET can be established, so a plan manifest that carries no
// imageDigests says nothing about that. A target that carries none defeats it.
func ReproductionFactsOf(m RunManifest) ReproductionFacts {
	return ReproductionFacts{
		Arm:             m.Arm,
		Study:           m.Study,
		Model:           m.Model,
		PromptCorpusSHA: m.PromptCorpusSHA,
		TraceChecksum:   m.TraceChecksum,
		TimeoutMs:       m.TimeoutMs,
		Seed:            m.Seed,
		LongThreshold:   m.LongThreshold,
		TokenizerRev:    m.TokenizerRev,
		PromptLenChars:  m.PromptLenChars,
		GatewaySHA:      m.GatewaySHA,
		ImageDigests:    m.ImageDigests,
	}
}

// factsDiffer names the first comparable field on which two facts disagree, or "" when they agree.
func factsDiffer(a, b ReproductionFacts) string {
	switch {
	case a.Study != b.Study:
		return "study"
	case a.Model != b.Model:
		return "model"
	case a.PromptCorpusSHA != b.PromptCorpusSHA:
		return "promptCorpusSHA"
	case a.TraceChecksum != b.TraceChecksum:
		return "traceChecksum"
	case a.TimeoutMs != b.TimeoutMs:
		return "timeoutMs"
	case a.Seed != b.Seed:
		return "seed"
	case a.LongThreshold != b.LongThreshold:
		return "longThreshold"
	}
	return ""
}

// ReproductionRefusal says whether a planned run may be called a reproduction of a target run.
//
// It refuses for three different reasons and keeps them apart, because they call for different actions:
//
//   - A planned arm the target never measured. The plan is not a repeat of that run.
//   - A comparable field that differs. The plan offers different traffic or judges it differently, and the
//     message names the field with both values so the operator can fix the load or drop the word
//     "reproduction".
//   - A field the TARGET never recorded. Nothing can establish sameness there, so the reproduction cannot be
//     certified -- and saying "no difference found" would be the lie this function exists to stop.
//
// The third case is why a reproduction of the 2026-09-13 pilot can never pass: that archive has no
// tokenizerRev, no promptLenChars, no gatewaySHA and no imageDigests, and neither it nor any later run
// recorded a driver version. The honest outcome is to measure at the load and not call it a reproduction.
func ReproductionRefusal(target, planned map[string]ReproductionFacts) error {
	if len(target) == 0 {
		return fmt.Errorf("the target run has no arms, so there is nothing to reproduce")
	}
	if len(planned) == 0 {
		return fmt.Errorf("the plan has no arms, so it reproduces nothing")
	}

	arms := make([]string, 0, len(planned))
	for a := range planned {
		arms = append(arms, a)
	}
	sort.Strings(arms)

	for _, arm := range arms {
		p := planned[arm]
		t, ok := target[arm]
		if !ok {
			have := make([]string, 0, len(target))
			for a := range target {
				have = append(have, a)
			}
			sort.Strings(have)
			return fmt.Errorf("the plan buys arm %q and the target run has no such arm (it measured %s), so this is not a reproduction of it",
				arm, strings.Join(have, ", "))
		}

		for _, c := range []struct {
			field       string
			tv, pv      string
			consequence string
		}{
			{"study", t.Study, p.Study, "a different study's readings would score it"},
			{"model", t.Model, p.Model, "a different model answers a different question"},
			{"promptCorpusSHA", t.PromptCorpusSHA, p.PromptCorpusSHA, "the prompt text is cut from a different corpus"},
			{"timeoutMs", fmt.Sprint(t.TimeoutMs), fmt.Sprint(p.TimeoutMs), "a different timeout censors the tail differently"},
			{"seed", fmt.Sprint(t.Seed), fmt.Sprint(p.Seed), "a different seed is a different arrival schedule"},
			{"longThreshold", fmt.Sprint(t.LongThreshold), fmt.Sprint(p.LongThreshold), "a different eligible population is gated"},
		} {
			if c.tv != c.pv {
				return fmt.Errorf("arm %s: %s is %s in the target run and %s in this plan -- %s. Fix the load, or stop calling this a reproduction",
					arm, c.field, c.tv, c.pv, c.consequence)
			}
		}

		// The prompt length is compared BEFORE the checksum, and the order is the point.
		//
		// PromptLenCharsByTenant derives this from the trace rows, so for a trace gen-trace actually wrote,
		// a different length always means a different checksum -- measured: 1174, 1175 and 200 characters
		// give three different hashes. Comparing the checksum first would therefore refuse every
		// prompt-length mismatch with "the offered traffic is not byte-identical", which is true and tells
		// the operator nothing about WHAT to change. The 2026-10-02 run differed in exactly this field.
		//
		// The branch is still reachable on its own: a manifest edited by hand keeps its checksum while
		// claiming a different length, and that is a target this function must refuse rather than trust.
		if len(t.PromptLenChars) > 0 && len(p.PromptLenChars) > 0 {
			if d := promptLenDiffer(t.PromptLenChars, p.PromptLenChars); d != "" {
				return fmt.Errorf("arm %s: promptLenChars differ -- %s. The prompt length moves the headline number and the registration does not freeze it",
					arm, d)
			}
		}

		// The checksum is the LAST net, because it cannot say what differs.
		//
		// Everything above names a field and both values. This one fires for any difference the fields above
		// did not catch -- output tokens, arrival jitter, a tenant's weight -- and a reader who gets here
		// knows only that the traffic is not the same bytes. That is worth refusing on and is the least
		// useful message, so it goes after the specific ones.
		if t.TraceChecksum != p.TraceChecksum {
			return fmt.Errorf("arm %s: traceChecksum is %s in the target run and %s in this plan -- the offered traffic is not byte-identical, and the fields compared above all match, so the difference is in something they do not name. Fix the load, or stop calling this a reproduction",
				arm, t.TraceChecksum, p.TraceChecksum)
		}

		if unknown := unrecordedFields(t); len(unknown) > 0 {
			return fmt.Errorf("arm %s: the target run never recorded %s, so sameness there is UNKNOWN rather than established and this plan cannot be certified as reproducing it. Measure at the load and do not call it a reproduction",
				arm, strings.Join(unknown, ", "))
		}
	}
	return nil
}

// unrecordedFields lists the target's fields that carry no value, in a stable order.
//
// Returned as names rather than counted, because the refusal has to say WHICH facts are unavailable: a reader
// deciding whether to rent a card needs to know it is the engine image rather than the timeout.
func unrecordedFields(t ReproductionFacts) []string {
	var out []string
	if t.TokenizerRev == "" {
		out = append(out, "tokenizerRev")
	}
	if len(t.PromptLenChars) == 0 {
		out = append(out, "promptLenChars")
	}
	if t.GatewaySHA == "" {
		out = append(out, "gatewaySHA")
	}
	if len(t.ImageDigests) == 0 {
		out = append(out, "imageDigests")
	}
	return out
}

// promptLenDiffer describes the first tenant whose prompt length differs, or "" when every tenant agrees.
func promptLenDiffer(target, planned map[string]int) string {
	tenants := make([]string, 0, len(target)+len(planned))
	seen := map[string]bool{}
	for t := range target {
		if !seen[t] {
			tenants, seen[t] = append(tenants, t), true
		}
	}
	for t := range planned {
		if !seen[t] {
			tenants, seen[t] = append(tenants, t), true
		}
	}
	sort.Strings(tenants)
	for _, tenant := range tenants {
		tv, tok := target[tenant]
		pv, pok := planned[tenant]
		switch {
		case !tok:
			return fmt.Sprintf("the plan sends %s %d characters and the target run sent it none", tenant, pv)
		case !pok:
			return fmt.Sprintf("the target run sent %s %d characters and the plan sends it none", tenant, tv)
		case tv != pv:
			return fmt.Sprintf("%s was %d characters and is now %d", tenant, tv, pv)
		}
	}
	return ""
}
