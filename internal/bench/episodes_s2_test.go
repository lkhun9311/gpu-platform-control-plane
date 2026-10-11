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
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// heldOutLengths are session 2's serial lengths that no sweep had measured when this was written.
var heldOutLengths = []int{768, 3072, 6144}

// stubHeldOutLengths gives the held-out lengths obviously fake character counts for one test, and removes them afterwards.
// The counts are 900000 plus the token count so that nobody can mistake them for a measurement, and a length the table already carries is left alone.
func stubHeldOutLengths(t *testing.T) {
	t.Helper()
	var added []int
	for _, l := range heldOutLengths {
		if _, ok := resolvedInputLengths[l]; !ok {
			resolvedInputLengths[l] = ResolvedInputLength{Chars: 900000 + l, Matches: 1}
			added = append(added, l)
		}
	}
	t.Cleanup(func() {
		for _, l := range added {
			delete(resolvedInputLengths, l)
		}
	})
}

// Session 1's archive was scored against these exact bytes, so session 2's generator must not move one of them.
// The hashes were taken from gen-trace built at d0e04c2, before session 2 existed, at --duration-ms 900000.
func TestSessionOneTracesAreByteIdentical(t *testing.T) {
	for _, c := range []struct {
		t    EpisodeType
		seed int64
		sha  string
	}{
		{EpisodeSerial, 11, "65fcf64952745514a5655f462e2afc3cdaa051a8cf26852259761fe6d3b361a8"},
		{EpisodeSerial, 21, "ad283b6e6e8bafd9e79c475af41f2f5e3091a08ed5e8a4d7d752035a87ac9775"},
		{EpisodeBurst, 11, "b8e59ce4600d25d53d37c96cb008029942681a600818a2ae4ef8f02f86e45276"},
		{EpisodeBurst, 21, "88fe937a363171fe35342a07d91b82e58c15d57144aa5b0f01e077b1ad85c413"},
		{EpisodeStagger, 11, "d7f6cbca89d2c708cde8c2342f1542a1feea555bbf52b28650eeb9b612ae62ff"},
		{EpisodeStagger, 21, "fb2e8b69909af56ffc2db7cfe7c61aa1a0b3504ca15e76b3078d6b4905bbf699"},
	} {
		rows, err := GenerateEpisodeTrace(EpisodeTraceParams{Study: StudyInstrumentValidation, Seed: c.seed, DurationMs: 900000, Type: c.t})
		if err != nil {
			t.Fatalf("%s seed %d: %v", c.t, c.seed, err)
		}
		var b strings.Builder
		if err := WriteTrace(&b, rows); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256([]byte(b.String()))
		if got := hex.EncodeToString(sum[:]); got != c.sha {
			t.Errorf("session 1 %s trace at seed %d hashes to %s, want %s", c.t, c.seed, got, c.sha)
		}
	}
}

// The registered counts, written out from sections 4 and 5 of the session-2 registration rather than read back from designS2.
func TestSessionTwoCountsPerSetting(t *testing.T) {
	for _, c := range []struct {
		t        EpisodeType
		settings int
		episodes int
	}{
		{EpisodeSerial, 27, 162},
		{EpisodeBurst, 10, 30},
		{EpisodeStagger, 12, 60},
	} {
		want, full, err := designS2.expectedCounts(c.t)
		if err != nil {
			t.Fatal(err)
		}
		if len(full) != c.settings || len(want) != c.settings {
			t.Errorf("%s: %d settings in the cycle and %d counted, want %d", c.t, len(full), len(want), c.settings)
		}
		plan, _, err := designS2.plan(11, c.t)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]int{}
		for _, ep := range splitPlan(plan, c.t) {
			got[ep.signatureAtBase()]++
		}
		total := 0
		for sig, n := range got {
			total += n
			var wantN int
			switch {
			case c.t == EpisodeSerial:
				wantN = 6
			case c.t == EpisodeBurst:
				wantN = 3
			case strings.HasSuffix(sig, " 256/16@base"):
				wantN = 7
			default:
				wantN = 3
			}
			if n != wantN {
				t.Errorf("%s setting [%s] appears %d times, want %d", c.t, sig, n, wantN)
			}
		}
		if total != c.episodes || len(got) != c.settings {
			t.Errorf("%s: %d episodes over %d settings, want %d over %d", c.t, total, len(got), c.episodes, c.settings)
		}
	}
	// The serial grid in tokens, so the held-out lengths are pinned to the registration's three.
	plan, _, _ := designS2.plan(5, EpisodeSerial)
	var lengths []int
	for _, r := range plan {
		if !slices.Contains(lengths, r.tokens) {
			lengths = append(lengths, r.tokens)
		}
	}
	slices.Sort(lengths)
	if !slices.Equal(lengths, []int{256, 512, 768, 1024, 2048, 3072, 4096, 6144, 8192}) {
		t.Errorf("session 2 serial lengths are %v", lengths)
	}
}

// s2Episode is one planned episode with the lag it was given.
type s2Episode struct {
	reqs []plannedRequest
	lag  int64
}

// signatureAtBase names the episode with its prefill lag replaced by the word base, so jittered replicates of one setting count together.
func (e s2Episode) signatureAtBase() string {
	parts := make([]string, len(e.reqs))
	for i, r := range e.reqs {
		at := "0"
		if r.offsetMs != e.reqs[0].offsetMs {
			at = "base"
		}
		parts[i] = fmt.Sprintf("%d/%d@%s", r.tokens, r.cap, at)
	}
	return strings.Join(parts, " ")
}

// splitPlan groups a plan into episodes by shared offset, joining a stagger's prefill to the decoders before it.
func splitPlan(plan []plannedRequest, et EpisodeType) []s2Episode {
	var out []s2Episode
	for _, r := range plan {
		n := len(out)
		if n > 0 && r.offsetMs == out[n-1].reqs[0].offsetMs {
			out[n-1].reqs = append(out[n-1].reqs, r)
			continue
		}
		// A warm-up's 2,048/16 request has the prefill's cap, so a group is a stagger only when its first request is a decoder.
		if n > 0 && et == EpisodeStagger && r.cap == staggerPrefillCap && out[n-1].lag == 0 && out[n-1].reqs[0].cap != staggerPrefillCap {
			out[n-1].lag = r.offsetMs - out[n-1].reqs[0].offsetMs
			out[n-1].reqs = append(out[n-1].reqs, r)
			continue
		}
		out = append(out, s2Episode{reqs: []plannedRequest{r}})
	}
	return out
}

// The lag is computed here in floating point from the registration's sentence, independently of the integer form the generator uses.
func registeredLagBase(n, c int) int64 {
	est := math.Ceil(float64(n*c)/2048) * 270
	return int64(math.Round(1.3*est)) + 200
}

func TestSessionTwoStaggerLagIsTheFormulaPlusSeededJitter(t *testing.T) {
	// Two literal anchors, so the formula above is not the only statement of it.
	if registeredLagBase(16, 8192) != 22664 || registeredLagBase(1, 256) != 551 {
		t.Fatalf("the registered lag is %d and %d, want 22664 and 551", registeredLagBase(16, 8192), registeredLagBase(1, 256))
	}
	seen := map[int64]bool{}
	for seed := int64(1); seed <= 40; seed++ {
		plan, _, err := designS2.plan(seed, EpisodeStagger)
		if err != nil {
			t.Fatal(err)
		}
		eps := splitPlan(plan, EpisodeStagger)
		if len(eps) != 60 {
			t.Fatalf("seed %d: %d stagger episodes, want 60", seed, len(eps))
		}
		for _, ep := range eps {
			n := len(ep.reqs) - 1
			dec := ep.reqs[0]
			if dec.cap != 512 || ep.reqs[n].cap != 16 {
				t.Fatalf("seed %d: decoders cap %d and prefill cap %d, want 512 and 16", seed, dec.cap, ep.reqs[n].cap)
			}
			u := ep.lag - registeredLagBase(n, dec.tokens)
			if u < 0 || u > 100 {
				t.Errorf("seed %d: (%d, %d) prefill lags %d ms, %d past the formula, outside 0..100", seed, n, dec.tokens, ep.lag, u)
			}
			seen[u] = true
		}
		again, _, _ := designS2.plan(seed, EpisodeStagger)
		if !reflect.DeepEqual(plan, again) {
			t.Errorf("seed %d gave two different stagger plans", seed)
		}
	}
	// 2,400 draws from 101 values: a jitter that never moved, or never reached its ends, is a jitter that was not drawn as registered.
	if len(seen) < 90 || !seen[0] || !seen[100] {
		t.Errorf("the jitter took %d distinct values (0 seen %v, 100 seen %v) over 2,400 episodes", len(seen), seen[0], seen[100])
	}
}

// The first three cycles hold all twelve settings and the last four only the six short ones, each in its own order.
func TestSessionTwoStaggerCyclesAreFullThenShort(t *testing.T) {
	eps := splitPlan(func() []plannedRequest { p, _, _ := designS2.plan(3, EpisodeStagger); return p }(), EpisodeStagger)
	var orders [][]string
	at := 0
	for k, size := range []int{12, 12, 12, 6, 6, 6, 6} {
		seen := map[string]bool{}
		var order []string
		for _, ep := range eps[at : at+size] {
			sig := ep.signatureAtBase()
			if seen[sig] {
				t.Errorf("cycle %d holds [%s] twice", k, sig)
			}
			seen[sig] = true
			order = append(order, sig)
			if size == 6 && ep.reqs[len(ep.reqs)-1].tokens != 256 {
				t.Errorf("short cycle %d holds a %d-token prefill", k, ep.reqs[len(ep.reqs)-1].tokens)
			}
		}
		if len(seen) != size {
			t.Errorf("cycle %d holds %d distinct settings, want %d", k, len(seen), size)
		}
		orders = append(orders, order)
		at += size
	}
	if slices.Equal(orders[3], orders[4]) && slices.Equal(orders[4], orders[5]) && slices.Equal(orders[5], orders[6]) {
		t.Error("the four short cycles share one order, so the permutation was drawn once")
	}
}

// The arm's mode never reaches the generator, and the seed decides the order.
func TestSessionTwoPlanIsDeterministicPerSeed(t *testing.T) {
	for _, et := range EpisodeTypes {
		a, _, _ := designS2.plan(7, et)
		b, _, _ := designS2.plan(7, et)
		c, _, _ := designS2.plan(8, et)
		if !reflect.DeepEqual(a, b) {
			t.Errorf("%s: seed 7 produced two different plans", et)
		}
		if reflect.DeepEqual(a, c) {
			t.Errorf("%s: seeds 7 and 8 produced the same plan", et)
		}
	}
}

// The spans at seed 11 are what the shell's DURATION_MS has to hold, so they are pinned and reported.
// The cycle sums are the coordinator's arithmetic with the spacing bound, entered as literals; the spans add the seeded order's last lag.
func TestSessionTwoSpansAtSeed11(t *testing.T) {
	for _, c := range []struct {
		t       EpisodeType
		cycleMs int64
		span    int64
		warmup  int64
	}{
		{EpisodeSerial, 81200, 487200, 87200},
		{EpisodeBurst, 101580, 304740, 107580},
		// 2,372,400 ms of gaps plus the last episode's lag, a short-prefill setting whose jittered lag the seed decides.
		{EpisodeStagger, 478800, 2378283, 484800},
	} {
		full, _ := designS2.fullCycle(c.t)
		var sum int64
		for _, e := range full {
			sum += e.gapMs()
		}
		if sum != c.cycleMs {
			t.Errorf("%s cycle sums to %d ms, want %d", c.t, sum, c.cycleMs)
		}
		_, span, _ := designS2.plan(11, c.t)
		_, wspan, _ := designS2.warmupPlan(11, c.t)
		t.Logf("%s at seed 11: measured span %d ms, warm-up span %d ms", c.t, span, wspan)
		if span != c.span || wspan != c.warmup {
			t.Errorf("%s at seed 11 spans %d ms and its warm-up %d ms, want %d and %d", c.t, span, wspan, c.span, c.warmup)
		}
	}
}

// The warm-up is one drained 2,048/16 request, one regular cycle, then two drained 2,048/16 verification requests.
func TestSessionTwoWarmupShape(t *testing.T) {
	stubHeldOutLengths(t)
	for _, et := range EpisodeTypes {
		plan, span, err := designS2.warmupPlan(11, et)
		if err != nil {
			t.Fatal(err)
		}
		eps := splitPlan(plan, et)
		full, _ := designS2.fullCycle(et)
		if len(eps) != len(full)+3 {
			t.Fatalf("%s warm-up has %d episodes, want %d", et, len(eps), len(full)+3)
		}
		for _, i := range []int{0, len(eps) - 2, len(eps) - 1} {
			if r := eps[i].reqs; len(r) != 1 || r[0].tokens != 2048 || r[0].cap != 16 {
				t.Errorf("%s warm-up episode %d is %+v, want one 2048/16 request", et, i, r)
			}
		}
		if eps[0].reqs[0].offsetMs != 0 {
			t.Errorf("%s warm-up starts at %d", et, eps[0].reqs[0].offsetMs)
		}
		seen := map[string]int{}
		for _, ep := range eps[1 : len(eps)-2] {
			seen[ep.signatureAtBase()]++
		}
		if len(seen) != len(full) {
			t.Errorf("%s warm-up cycle holds %d distinct settings, want %d", et, len(seen), len(full))
		}
		for sig, n := range seen {
			if n != 1 {
				t.Errorf("%s warm-up cycle holds [%s] %d times", et, sig, n)
			}
		}
		// Spaced by the same bound as the measured trace, and every row inside the span the duration must hold.
		for i := 0; i+1 < len(eps); i++ {
			spec := make(episodeSpec, len(eps[i].reqs))
			for j, r := range eps[i].reqs {
				spec[j] = episodeRequest{tokens: r.tokens, cap: r.cap}
			}
			if gap := eps[i+1].reqs[0].offsetMs - eps[i].reqs[0].offsetMs; gap != spec.gapMs() {
				t.Errorf("%s warm-up episode %d is followed after %d ms, want its bound %d", et, i, gap, spec.gapMs())
			}
		}
		rows, err := GenerateEpisodeWarmupTrace(EpisodeTraceParams{Study: StudyInstrumentValidationS2, Seed: 11, DurationMs: span, Type: et})
		if err != nil {
			t.Fatalf("%s warm-up at exactly its span: %v", et, err)
		}
		for _, r := range rows {
			if r.Tenant != PremiumTenant || r.IsNoisy || r.OffsetMs >= span {
				t.Errorf("%s warm-up row %+v", et, r)
			}
		}
		if _, err := GenerateEpisodeWarmupTrace(EpisodeTraceParams{Study: StudyInstrumentValidationS2, Seed: 11, DurationMs: span - 1, Type: et}); err == nil {
			t.Errorf("%s warm-up one ms short of its span was not refused", et)
		}
		// The warm-up is not a measured trace, and the plan check says so rather than scoring it.
		if err := EpisodeTraceRefusal(StudyInstrumentValidationS2, et, rows); err == nil {
			t.Errorf("%s warm-up passed the measured trace's plan check", et)
		}
	}
	if _, err := GenerateEpisodeWarmupTrace(EpisodeTraceParams{Study: StudyInstrumentValidation, Seed: 11, DurationMs: 1 << 30, Type: EpisodeBurst}); err == nil || !strings.Contains(err.Error(), "registers no warm-up") {
		t.Errorf("session 1 was given a warm-up: %v", err)
	}
}

// Until the held-out lengths are measured the serial trace is refused, and the refusal names exactly the missing ones.
func TestSessionTwoSerialRefusesUnmeasuredLengths(t *testing.T) {
	var missing []int
	for _, l := range heldOutLengths {
		if _, ok := ResolveInputTokens(l); !ok {
			missing = append(missing, l)
		}
	}
	for _, gen := range []func(EpisodeTraceParams) ([]TraceRow, error){GenerateEpisodeTrace, GenerateEpisodeWarmupTrace} {
		_, err := gen(EpisodeTraceParams{Study: StudyInstrumentValidationS2, Seed: 1, DurationMs: 1 << 30, Type: EpisodeSerial})
		if len(missing) == 0 {
			if err != nil {
				t.Fatalf("every held-out length resolves and the serial trace was still refused: %v", err)
			}
			continue
		}
		if err == nil || !strings.Contains(err.Error(), "no character count for "+fmt.Sprint(missing)) {
			t.Errorf("held-out lengths %v are unmeasured and the refusal does not name them: %v", missing, err)
		}
	}
	if _, err := GenerateEpisodeTrace(EpisodeTraceParams{Seed: 1, DurationMs: 1 << 30, Type: EpisodeBurst}); err == nil || !strings.Contains(err.Error(), "registers no episodes") {
		t.Errorf("a trace with no study was generated: %v", err)
	}
}

// Each session-2 refusal is shown to fire on a trace that differs from an accepted one in the refused respect.
func TestSessionTwoPlanRefusals(t *testing.T) {
	stubHeldOutLengths(t)
	gen := func(et EpisodeType, study string) []TraceRow {
		rows, err := GenerateEpisodeTrace(EpisodeTraceParams{Study: study, Seed: 6, DurationMs: 1 << 30, Type: et})
		if err != nil {
			t.Fatal(err)
		}
		return rows
	}
	serial, burst, stagger := gen(EpisodeSerial, StudyInstrumentValidationS2), gen(EpisodeBurst, StudyInstrumentValidationS2), gen(EpisodeStagger, StudyInstrumentValidationS2)
	for _, c := range []struct {
		et   EpisodeType
		rows []TraceRow
	}{{EpisodeSerial, serial}, {EpisodeBurst, burst}, {EpisodeStagger, stagger}} {
		if err := InstrumentValidationPlanRefusal(StudyInstrumentValidationS2, string(c.et)+"-log", c.rows); err != nil {
			t.Errorf("the generator's own %s trace is refused: %v", c.et, err)
		}
	}
	// The first prefill row, and the offset of the decoders it follows.
	prefill := slices.IndexFunc(stagger, func(r TraceRow) bool { return r.MaxOutputTokens == staggerPrefillCap })
	decoders := stagger[prefill-1]
	n := 0
	for _, r := range stagger {
		if r.OffsetMs == decoders.OffsetMs {
			n++
		}
	}
	base := registeredLagBase(n, map[int]int{1174: 256, 42579: 8192}[decoders.PromptLenChars])
	setLag := func(lag int64) []TraceRow {
		r := slices.Clone(stagger)
		r[prefill].OffsetMs = decoders.OffsetMs + lag
		return r
	}
	// The jitter's ends are accepted, so the refusals below are about the range and not about any departure from the draw.
	for _, lag := range []int64{base, base + 100} {
		if err := EpisodeTraceRefusal(StudyInstrumentValidationS2, EpisodeStagger, setLag(lag)); err != nil {
			t.Errorf("a lag of %d ms, inside %d..%d, was refused: %v", lag, base, base+100, err)
		}
	}
	// Removing one whole stagger episode, decoders and prefill, by its decoders' offset.
	removeStagger := func(rows []TraceRow, prefillTokens int) []TraceRow {
		for i, r := range rows {
			if r.MaxOutputTokens == staggerPrefillCap && r.PromptLenChars == map[int]int{256: 1174, 8192: 42579}[prefillTokens] {
				start := rows[i-1].OffsetMs
				out := slices.DeleteFunc(slices.Clone(rows), func(x TraceRow) bool { return x.OffsetMs == start })
				return slices.DeleteFunc(out, func(x TraceRow) bool { return x.OffsetMs == r.OffsetMs && x.MaxOutputTokens == staggerPrefillCap })
			}
		}
		t.Fatalf("no %d-token prefill", prefillTokens)
		return nil
	}
	// Appending a copy of one stagger episode far after the end, which adds a replicate without crowding the spacing.
	appendStagger := func(rows []TraceRow, prefillTokens int) []TraceRow {
		for i, r := range rows {
			if r.MaxOutputTokens == staggerPrefillCap && r.PromptLenChars == map[int]int{256: 1174, 8192: 42579}[prefillTokens] {
				start := rows[i-1].OffsetMs
				out := slices.Clone(rows)
				for _, x := range rows {
					if x.OffsetMs == start || (x.OffsetMs == r.OffsetMs && x.MaxOutputTokens == staggerPrefillCap) {
						x.OffsetMs += 1 << 40
						out = append(out, x)
					}
				}
				return out
			}
		}
		t.Fatalf("no %d-token prefill", prefillTokens)
		return nil
	}
	for _, c := range []struct {
		name string
		et   EpisodeType
		rows []TraceRow
		want string
	}{
		{"a prefill one ms before the formula", EpisodeStagger, setLag(base - 1), "the registered lag"},
		{"a prefill one ms past the jitter", EpisodeStagger, setLag(base + 101), "the registered lag"},
		{"a session-1 stagger trace", EpisodeStagger, gen(EpisodeStagger, StudyInstrumentValidation), "output cap 128, which no episode type registers"},
		{"a session-1 serial trace", EpisodeSerial, gen(EpisodeSerial, StudyInstrumentValidation), "appears 3 times and study instrument-validation-s2-2026-10-05 places it exactly 6 times"},
		{"a short-prefill stagger missing once", EpisodeStagger, removeStagger(stagger, 256), "appears 6 times and study instrument-validation-s2-2026-10-05 places it exactly 7 times"},
		{"a long-prefill stagger once too many", EpisodeStagger, appendStagger(stagger, 8192), "appears 4 times and study instrument-validation-s2-2026-10-05 places it exactly 3 times"},
		{"a serial setting missing once", EpisodeSerial, slices.DeleteFunc(slices.Clone(serial), func(x TraceRow) bool { return x.OffsetMs == serial[0].OffsetMs }), "appears 5 times"},
		{"a burst trace in a stagger cell", EpisodeStagger, burst, "not a stagger setting"},
		{"episodes packed inside their spacing", EpisodeSerial, func() []TraceRow {
			r := slices.Clone(serial)
			for i := range r {
				r[i].OffsetMs = int64(i)
			}
			return r
		}(), "inside that episode's spacing bound"},
	} {
		err := EpisodeTraceRefusal(StudyInstrumentValidationS2, c.et, c.rows)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want a refusal containing %q, got %v", c.name, c.want, err)
		}
	}
	if err := MatrixPlanArmSetRefusal(StudyInstrumentValidationS2, []string{"stagger-log"}); err == nil || !strings.Contains(err.Error(), "only one of stagger-log and stagger-nolog") {
		t.Errorf("a session-2 logging arm without its pair: %v", err)
	}
	all, _ := LookupStudy(StudyInstrumentValidationS2)
	if err := MatrixPlanArmSetRefusal(StudyInstrumentValidationS2, all.Arms); err != nil {
		t.Errorf("the full session-2 plan is refused: %v", err)
	}
	if err := InstrumentValidationPlanRefusal(StudySharingMatrix, "serial-log", serial); err == nil || !strings.Contains(err.Error(), "not an instrument-validation study") {
		t.Errorf("a tail study reached the episode check: %v", err)
	}
}

// The second session is registered with the first session's arms and trace policy.
func TestSessionTwoRegistration(t *testing.T) {
	s1, _ := LookupStudy(StudyInstrumentValidation)
	s2, ok := LookupStudy("instrument-validation-s2-2026-10-05")
	if !ok {
		t.Fatal("session 2 is not registered under its dated id")
	}
	if !slices.Equal(s1.Arms, s2.Arms) || s2.Arrivals != ArrivalsEpisodes || s2.TracesVaryByRepetition || s2.Frozen != nil {
		t.Errorf("session 2 registration: arms %v, arrivals %q, per-repetition %v, frozen %v", s2.Arms, s2.Arrivals, s2.TracesVaryByRepetition, s2.Frozen)
	}
}
