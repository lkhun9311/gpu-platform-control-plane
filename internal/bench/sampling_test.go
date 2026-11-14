package bench

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
)

// TestRegisteredSamplingIsGreedyExactLength pins the version study's frozen generation policy (audit finding 12).
func TestRegisteredSamplingIsGreedyExactLength(t *testing.T) {
	st, _ := LookupStudy(StudyVersionAsync)
	want := SamplingPolicy{
		Temperature:       0,
		TopP:              1,
		RepetitionPenalty: 1,
		Seed:              SeedOmitGreedy,
		IgnoreEOS:         true,
		Length:            LengthExactCap,
	}
	if st.Sampling == nil || *st.Sampling != want {
		t.Fatalf("sampling = %+v, want %+v", st.Sampling, want)
	}
}

// TestSamplingValidateRefuses lists the policies a study may not register.
func TestSamplingValidateRefuses(t *testing.T) {
	base := *versionStudySampling()
	for name, mutate := range map[string]func(p *SamplingPolicy){
		"negative temperature":           func(p *SamplingPolicy) { p.Temperature = -0.1 },
		"NaN temperature":                func(p *SamplingPolicy) { p.Temperature = math.NaN() },
		"random sampling without a seed": func(p *SamplingPolicy) { p.Temperature = 0.7 },
		"top_p zero":                     func(p *SamplingPolicy) { p.TopP = 0 },
		"top_p above one":                func(p *SamplingPolicy) { p.TopP = 1.5 },
		"repetition penalty zero":        func(p *SamplingPolicy) { p.RepetitionPenalty = 0 },
		"unknown seed policy":            func(p *SamplingPolicy) { p.Seed = "random" },
		"unknown length policy":          func(p *SamplingPolicy) { p.Length = "natural-ish" },
		"exact cap without ignore_eos":   func(p *SamplingPolicy) { p.IgnoreEOS = false },
		"natural stop with ignore_eos":   func(p *SamplingPolicy) { p.Length = LengthNaturalStop },
	} {
		p := base
		mutate(&p)
		if err := p.Validate(); err == nil {
			t.Errorf("%s: accepted %+v", name, p)
		}
	}
	if err := base.Validate(); err != nil {
		t.Errorf("registered policy refused: %v", err)
	}
	seeded := base
	seeded.Temperature, seeded.Seed = 0.7, SeedRowIndex
	if err := seeded.Validate(); err != nil {
		t.Errorf("seeded random sampling refused: %v", err)
	}
}

// TestSamplingRequestFieldsBody checks the exact JSON a sender adds to a request body.
func TestSamplingRequestFieldsBody(t *testing.T) {
	p := *versionStudySampling()
	f, err := p.RequestFields(TraceRow{Index: 7, MaxOutputTokens: 64})
	if err != nil {
		t.Fatal(err)
	}
	got, _ := json.Marshal(f)
	want := `{"max_tokens":64,"min_tokens":64,"temperature":0,"top_p":1,"repetition_penalty":1,"ignore_eos":true}`
	if string(got) != want {
		t.Fatalf("body = %s, want %s", got, want)
	}

	p.Temperature, p.Seed = 0.7, SeedRowIndex
	f, _ = p.RequestFields(TraceRow{Index: 7, MaxOutputTokens: 64})
	got, _ = json.Marshal(f)
	if !strings.Contains(string(got), `"seed":7`) {
		t.Errorf("row-index seed policy did not send the row's index: %s", got)
	}

	if _, err := p.RequestFields(TraceRow{Index: 1}); err == nil {
		t.Errorf("a row with no output cap was given a body")
	}
	bad := SamplingPolicy{}
	if _, err := bad.RequestFields(TraceRow{MaxOutputTokens: 4}); err == nil {
		t.Errorf("an invalid policy produced a body")
	}
}

// TestSamplingCheckCompletion is the preflight test that the policy took effect on the engine.
func TestSamplingCheckCompletion(t *testing.T) {
	p := *versionStudySampling()
	for _, c := range []struct {
		name   string
		tokens int
		finish string
		ok     bool
	}{
		{"exact cap, stopped on length", 64, "length", true},
		{"short output", 63, "length", false},
		{"stopped on eos", 64, "stop", false},
		{"usage missing", 0, "length", false},
		{"finish reason missing", 64, "", false},
	} {
		err := p.CheckCompletion(64, c.tokens, c.finish)
		if (err == nil) != c.ok {
			t.Errorf("%s: err = %v, want ok=%v", c.name, err, c.ok)
		}
	}
	natural := p
	natural.IgnoreEOS, natural.Length = false, LengthNaturalStop
	if err := natural.CheckCompletion(64, 10, "stop"); err != nil {
		t.Errorf("natural stop refused an early eos: %v", err)
	}
	if err := natural.CheckCompletion(64, 65, "length"); err == nil {
		t.Errorf("natural stop accepted output beyond the cap")
	}
}
