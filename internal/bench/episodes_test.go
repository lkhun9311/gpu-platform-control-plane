/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package bench

import (
	"fmt"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// The spacing bound is pinned on literal values so a change to its constants is a deliberate edit here.
func TestEpisodeSpacingBoundOnLiteralCases(t *testing.T) {
	for _, c := range []struct {
		tokens, outCap int
		want           int64
	}{
		{256, 1, 2000},      // 300 ms estimated, so the two-second floor decides
		{256, 64, 4380},     // one chunk and 64 steps: 2 x (270 + 1920)
		{8192, 16, 3120},    // four chunks: 2 x (1080 + 480)
		{131072, 64, 38400}, // sixteen 8,192-token bursts: 2 x (64 x 270 + 1920)
		{2049, 1, 2000},     // two chunks still under the floor
	} {
		if got := EpisodeSpacingMs(c.tokens, c.outCap); got != c.want {
			t.Errorf("EpisodeSpacingMs(%d, %d) = %d, want %d", c.tokens, c.outCap, got, c.want)
		}
	}
}

// The cycle sizes and spans are the coordinator's hand computation, entered as literals rather than recomputed with the code under test.
func TestEpisodeCycleSizesAndSpans(t *testing.T) {
	for _, c := range []struct {
		t       EpisodeType
		size    int
		cycleMs int64
	}{
		{EpisodeSerial, 18, 53820},
		{EpisodeBurst, 10, 101580},
		{EpisodeStagger, 12, 202320},
	} {
		cycle, err := cycleOf(c.t)
		if err != nil {
			t.Fatal(err)
		}
		if len(cycle) != c.size {
			t.Errorf("%s cycle has %d settings, want %d", c.t, len(cycle), c.size)
		}
		var sum int64
		for _, e := range cycle {
			sum += e.gapMs()
		}
		if sum != c.cycleMs {
			t.Errorf("%s cycle spans %d ms, want %d", c.t, sum, c.cycleMs)
		}
		_, span, err := planEpisodes(11, c.t)
		if err != nil {
			t.Fatal(err)
		}
		// A stagger trace ends after its last prefill's lag, which depends on which setting the permutation put last.
		maxLag := int64(0)
		for _, e := range cycle {
			maxLag = max(maxLag, e.lastAtMs())
		}
		if span < EpisodeCycles*c.cycleMs || span > EpisodeCycles*c.cycleMs+maxLag {
			t.Errorf("%s trace spans %d ms, want between %d and %d", c.t, span, EpisodeCycles*c.cycleMs, EpisodeCycles*c.cycleMs+maxLag)
		}
	}
}

// episodesOf splits a plan into episodes by start, using the cycle order the plan was built in.
func episodesOf(t *testing.T, seed int64, et EpisodeType) [][]plannedRequest {
	t.Helper()
	plan, _, err := planEpisodes(seed, et)
	if err != nil {
		t.Fatal(err)
	}
	var out [][]plannedRequest
	for _, r := range plan {
		n := len(out)
		// A row starts a new episode unless it shares the previous row's offset or is a stagger prefill.
		if n > 0 && (r.offsetMs == out[n-1][0].offsetMs || (et == EpisodeStagger && r.cap == staggerPrefillCap)) {
			out[n-1] = append(out[n-1], r)
			continue
		}
		out = append(out, []plannedRequest{r})
	}
	return out
}

func TestEpisodePlanIsDeterministicPerSeedAndVariesAcrossSeeds(t *testing.T) {
	for _, et := range EpisodeTypes {
		a, _, _ := planEpisodes(7, et)
		b, _, _ := planEpisodes(7, et)
		c, _, _ := planEpisodes(8, et)
		if !reflect.DeepEqual(a, b) {
			t.Errorf("%s: seed 7 produced two different plans", et)
		}
		if reflect.DeepEqual(a, c) {
			t.Errorf("%s: seeds 7 and 8 produced the same plan, so a repetition's seed decides nothing", et)
		}
	}
}

// Every cycle holds every registered setting once, so three cycles hold each exactly three times.
func TestEveryCycleHoldsEverySettingOnce(t *testing.T) {
	for _, et := range EpisodeTypes {
		cycle, _ := cycleOf(et)
		eps := episodesOf(t, 3, et)
		if len(eps) != EpisodeCycles*len(cycle) {
			t.Fatalf("%s: %d episodes, want %d", et, len(eps), EpisodeCycles*len(cycle))
		}
		var orders [][]string
		for k := range EpisodeCycles {
			seen := map[string]int{}
			var order []string
			for _, ep := range eps[k*len(cycle) : (k+1)*len(cycle)] {
				spec := make(episodeSpec, len(ep))
				for i, r := range ep {
					spec[i] = episodeRequest{tokens: r.tokens, cap: r.cap, atMs: r.offsetMs - ep[0].offsetMs}
				}
				seen[spec.signature()]++
				order = append(order, spec.signature())
			}
			for _, e := range cycle {
				if seen[e.signature()] != 1 {
					t.Errorf("%s cycle %d holds [%s] %d times", et, k, e.signature(), seen[e.signature()])
				}
			}
			orders = append(orders, order)
		}
		// Each cycle draws its own permutation; three identical orders would mean the permutation was drawn once.
		if slices.Equal(orders[0], orders[1]) && slices.Equal(orders[1], orders[2]) {
			t.Errorf("%s: all three cycles share one order", et)
		}
	}
}

// The serial grid is checked in tokens because three of its lengths have no measured characters yet.
func TestSerialPlanCoversEveryLengthAndCap(t *testing.T) {
	plan, _, err := planEpisodes(5, EpisodeSerial)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]int{}
	for _, r := range plan {
		got[fmt.Sprintf("%d/%d", r.tokens, r.cap)]++
	}
	for _, l := range []int{256, 512, 1024, 2048, 4096, 8192} {
		for _, c := range []int{1, 16, 64} {
			if n := got[fmt.Sprintf("%d/%d", l, c)]; n != EpisodeCycles {
				t.Errorf("serial (%d tokens, cap %d) appears %d times, want %d", l, c, n, EpisodeCycles)
			}
		}
	}
	if len(got) != 18 {
		t.Errorf("serial plan has %d distinct (length, cap) pairs, want 18", len(got))
	}
}

// Every request of an episode is sent before the next episode starts, and episodes are at least the bound apart.
func TestEpisodesAreSpacedByTheBound(t *testing.T) {
	for _, et := range EpisodeTypes {
		eps := episodesOf(t, 9, et)
		for i := 0; i+1 < len(eps); i++ {
			spec := make(episodeSpec, len(eps[i]))
			for j, r := range eps[i] {
				spec[j] = episodeRequest{tokens: r.tokens, cap: r.cap}
			}
			gap := eps[i+1][0].offsetMs - eps[i][0].offsetMs
			if gap < spec.gapMs() || gap < spacingMinGapMs {
				t.Errorf("%s episode %d is followed after %d ms, under its bound %d", et, i, gap, spec.gapMs())
			}
			for _, r := range eps[i] {
				if r.offsetMs >= eps[i+1][0].offsetMs {
					t.Errorf("%s episode %d sends at %d, after the next episode starts at %d", et, i, r.offsetMs, eps[i+1][0].offsetMs)
				}
			}
		}
	}
}

// A burst's rows share one offset and one shape, and the stagger's prefill follows its decoders by the registered lag.
func TestBurstRowsShareAnOffsetAndStaggerPrefillsLag(t *testing.T) {
	for _, ep := range episodesOf(t, 4, EpisodeBurst) {
		if !slices.Contains([]int{1, 4, 16, 64}, len(ep)) {
			t.Errorf("burst of %d requests", len(ep))
		}
		for _, r := range ep {
			if r.offsetMs != ep[0].offsetMs || r.tokens != ep[0].tokens || r.cap != burstCap {
				t.Errorf("burst at %d is not homogeneous: %+v against %+v", ep[0].offsetMs, r, ep[0])
			}
		}
		if len(ep) == 64 && ep[0].tokens != 256 {
			t.Errorf("the 64-wide burst is at %d tokens, want 256", ep[0].tokens)
		}
	}
	for _, ep := range episodesOf(t, 4, EpisodeStagger) {
		n := len(ep) - 1
		last := ep[n]
		if last.cap != staggerPrefillCap || !slices.Contains(staggerPrefills, last.tokens) {
			t.Fatalf("stagger episode does not end in a registered prefill: %+v", last)
		}
		c := ep[0].tokens
		wantLag := int64((n*c+2047)/2048*270) + 200
		if last.offsetMs-ep[0].offsetMs != wantLag {
			t.Errorf("prefill after %d decoders at %d tokens lags %d ms, want %d", n, c, last.offsetMs-ep[0].offsetMs, wantLag)
		}
		for _, r := range ep[:n] {
			if r.offsetMs != ep[0].offsetMs || r.tokens != c || r.cap != staggerDecodeCap {
				t.Errorf("stagger decoders are not one homogeneous group: %+v", r)
			}
		}
	}
}

// The generator refuses a duration that cannot hold the trace, and every row of an accepted one is inside it.
func TestEpisodeTraceMustFitTheDuration(t *testing.T) {
	for _, et := range []EpisodeType{EpisodeBurst, EpisodeStagger} {
		_, span, _ := planEpisodes(2, et)
		if _, err := GenerateEpisodeTrace(EpisodeTraceParams{Seed: 2, DurationMs: span - 1, Type: et}); err == nil || !strings.Contains(err.Error(), "complete cycles") {
			t.Errorf("%s: a duration one ms short of the span was not refused: %v", et, err)
		}
		rows, err := GenerateEpisodeTrace(EpisodeTraceParams{Seed: 2, DurationMs: span, Type: et})
		if err != nil {
			t.Fatalf("%s at exactly the span: %v", et, err)
		}
		for _, r := range rows {
			if r.OffsetMs >= span || r.Tenant != PremiumTenant || r.IsNoisy {
				t.Errorf("%s row %+v is outside the duration or not the single tenant", et, r)
			}
		}
		if err := EpisodeTraceRefusal(et, rows); err != nil {
			t.Errorf("%s: the generator's own trace is refused: %v", et, err)
		}
	}
}

// Nothing here may invent a character count, so the serial type refuses while any of its lengths is unresolved.
func TestSerialTraceRefusesUnresolvedLengths(t *testing.T) {
	var missing []int
	for _, l := range serialLengths {
		if _, ok := ResolveInputTokens(l); !ok {
			missing = append(missing, l)
		}
	}
	_, err := GenerateEpisodeTrace(EpisodeTraceParams{Seed: 1, DurationMs: 1 << 30, Type: EpisodeSerial})
	if len(missing) == 0 {
		if err != nil {
			t.Fatalf("every serial length resolves and the trace was still refused: %v", err)
		}
		return
	}
	if err == nil || !strings.Contains(err.Error(), fmt.Sprint(missing)) {
		t.Fatalf("serial lengths %v are unresolved and the refusal does not name them: %v", missing, err)
	}
}

// Each refusal is shown to fire on a trace that differs from an accepted one in exactly the refused respect.
func TestEpisodeTraceRefusals(t *testing.T) {
	burst, err := GenerateEpisodeTrace(EpisodeTraceParams{Seed: 6, DurationMs: 1 << 30, Type: EpisodeBurst})
	if err != nil {
		t.Fatal(err)
	}
	stagger, err := GenerateEpisodeTrace(EpisodeTraceParams{Seed: 6, DurationMs: 1 << 30, Type: EpisodeStagger})
	if err != nil {
		t.Fatal(err)
	}
	edit := func(rows []TraceRow, f func([]TraceRow) []TraceRow) []TraceRow {
		return f(slices.Clone(rows))
	}
	for _, c := range []struct {
		name string
		t    EpisodeType
		rows []TraceRow
		want string
	}{
		{"no rows", EpisodeBurst, nil, "no rows"},
		{"a contender row", EpisodeBurst, edit(burst, func(r []TraceRow) []TraceRow { r[3].Tenant = NoisyTenant; r[3].IsNoisy = true; return r }), "no contender"},
		{"a premium row marked noisy", EpisodeBurst, edit(burst, func(r []TraceRow) []TraceRow { r[3].IsNoisy = true; return r }), "no contender"},
		{"an unregistered length", EpisodeBurst, edit(burst, func(r []TraceRow) []TraceRow { r[0].PromptLenChars = 1175; return r }), "no registered input length"},
		{"an unregistered cap", EpisodeBurst, edit(burst, func(r []TraceRow) []TraceRow { r[0].MaxOutputTokens = 32; return r }), "no episode type registers"},
		{"a burst trace in a stagger cell", EpisodeStagger, burst, "not a stagger setting"},
		{"a stagger trace in a burst cell", EpisodeBurst, stagger, "not a burst setting"},
		{"a stagger trace in a serial cell", EpisodeSerial, stagger, "not a serial setting"},
		{"a burst split across two offsets", EpisodeBurst, edit(burst, func(r []TraceRow) []TraceRow {
			for i := 1; i < len(r); i++ {
				if r[i].OffsetMs == r[i-1].OffsetMs {
					r[i].OffsetMs++
					break
				}
			}
			return r
		}), "not a burst setting"},
		{"a stagger prefill at the wrong lag", EpisodeStagger, edit(stagger, func(r []TraceRow) []TraceRow {
			for i := range r {
				if r[i].MaxOutputTokens == staggerPrefillCap {
					r[i].OffsetMs++
					break
				}
			}
			return r
		}), "not a stagger setting"},
		// Every setting present the right number of times, and the episodes one millisecond apart: the trace a
		// review produced by rewriting offsets, which the contents-only check reported as three complete cycles.
		{"episodes packed inside their spacing", EpisodeBurst, edit(burst, func(r []TraceRow) []TraceRow {
			rank := map[int64]int64{}
			for _, x := range r {
				if _, ok := rank[x.OffsetMs]; !ok {
					rank[x.OffsetMs] = int64(len(rank))
				}
			}
			for i := range r {
				r[i].OffsetMs = rank[r[i].OffsetMs]
			}
			return r
		}), "inside that episode's spacing bound"},
		// The whole first episode is removed or repeated, so the case cannot turn into a split burst.
		{"a missing episode", EpisodeBurst, edit(burst, func(r []TraceRow) []TraceRow {
			return slices.DeleteFunc(r, func(x TraceRow) bool { return x.OffsetMs == burst[0].OffsetMs })
		}), "appears 2 times"},
		{"a fourth cycle", EpisodeBurst, edit(burst, func(r []TraceRow) []TraceRow {
			for _, x := range burst {
				if x.OffsetMs == burst[0].OffsetMs {
					x.OffsetMs = 1 << 40
					r = append(r, x)
				}
			}
			return r
		}), "appears 4 times"},
	} {
		err := EpisodeTraceRefusal(c.t, c.rows)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want a refusal containing %q, got %v", c.name, c.want, err)
		}
	}
}

// The registration's arms, written out literally, and the type each one replays.
func TestInstrumentValidationArms(t *testing.T) {
	s, ok := LookupStudy("instrument-validation-2026-10-05")
	if !ok {
		t.Fatal("the study is not registered under its dated id")
	}
	want := []string{"serial-log", "serial-nolog", "burst-log", "burst-nolog", "stagger-log", "stagger-nolog", "serial-async", "burst-async", "stagger-async"}
	if !slices.Equal(s.Arms, want) {
		t.Errorf("arms are %v, want %v", s.Arms, want)
	}
	// One trace for every block, as the registration's section 4 says.
	if s.Arrivals != ArrivalsEpisodes || s.TracesVaryByRepetition || s.Frozen != nil {
		t.Errorf("registration fields: arrivals %q, per-repetition %v, frozen %v", s.Arrivals, s.TracesVaryByRepetition, s.Frozen)
	}
	for _, a := range want {
		et, ok := InstrumentValidationEpisode(a)
		if !ok || !strings.HasPrefix(a, string(et)+"-") {
			t.Errorf("%s resolves to %q", a, et)
		}
		// The modes of one type are compared on one trace, and the types on different ones.
		if ArmComparisonGroup(a) != string(et) {
			t.Errorf("%s is in comparison group %q, want %q", a, ArmComparisonGroup(a), et)
		}
	}
	if _, ok := InstrumentValidationEpisode("serial-on"); ok {
		t.Error("an unregistered mode resolved to an episode type")
	}
}

func TestInstrumentValidationArmSetRefusal(t *testing.T) {
	all, _ := LookupStudy(StudyInstrumentValidation)
	if err := MatrixPlanArmSetRefusal(StudyInstrumentValidation, all.Arms); err != nil {
		t.Errorf("the full plan is refused: %v", err)
	}
	for _, c := range []struct {
		arms []string
		want string
	}{
		{[]string{"serial-log"}, "only one of serial-log and serial-nolog"},
		{[]string{"burst-nolog", "serial-log", "serial-nolog"}, "only one of burst-log and burst-nolog"},
		{[]string{"serial-log", "serial-nolog", "R1"}, `arm "R1" is not one of`},
	} {
		if err := MatrixPlanArmSetRefusal(StudyInstrumentValidation, c.arms); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%v: want a refusal containing %q, got %v", c.arms, c.want, err)
		}
	}
	if err := InstrumentValidationPlanRefusal("serial-on", []TraceRow{{Tenant: PremiumTenant}}); err == nil || !strings.Contains(err.Error(), "not one of") {
		t.Errorf("an unregistered arm passed the cell check: %v", err)
	}
}
