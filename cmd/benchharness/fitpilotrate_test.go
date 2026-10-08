package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeFitCell writes a P cell's client rows and gateway record: one premium row, and one contender per arrival
// offset (in ms), each admitted by P when the matching admits entry is true.
func writeFitCell(t *testing.T, dir, name string, offsetsMs []int64, admits []bool) string {
	t.Helper()
	raw := filepath.Join(dir, "raw-"+name+".jsonl")
	rec := filepath.Join(dir, "gateway-record-"+name+".jsonl")
	var rb, gb strings.Builder
	enc := func(b *strings.Builder, v any) {
		j, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(append(j, '\n'))
	}
	enc(&rb, map[string]any{"index": 0, "requestId": name + "-0", "tenant": "premium-1", "promptLenChars": 200, "exactInputTokens": 68})
	enc(&gb, map[string]any{"ev": "done", "requestId": name + "-0", "decision": "admit", "arrivedUnixNanos": 1})
	const origin = int64(1_000_000_000_000)
	for i, off := range offsetsMs {
		id := fmt.Sprintf("%s-%d", name, i+1)
		enc(&rb, map[string]any{"index": i + 1, "requestId": id, "tenant": "standard-noisy", "promptLenChars": 40000, "exactInputTokens": 7695})
		d := "reject"
		if admits[i] {
			d = "admit"
		}
		enc(&gb, map[string]any{"ev": "arrive", "requestId": id, "arrivedUnixNanos": origin + off*1_000_000})
		enc(&gb, map[string]any{"ev": "done", "requestId": id, "decision": d, "arrivedUnixNanos": origin + off*1_000_000})
	}
	if err := os.WriteFile(raw, []byte(rb.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rec, []byte(gb.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	return raw + ":" + rec
}

func fitArgs(cells ...string) []string {
	var a []string
	for _, c := range cells {
		a = append(a, "-cell", c)
	}
	return a
}

// Three contenders at once drain the 30,000 burst; a fourth one second later is admitted only when R >= 10,000.
// P admitted all four (a_P = 1), so S must stay at or below 0.95, which it does at 0.75 below 10,000 and not at
// 1.0 from it: the largest R is 9,999.
//
// Mutation that turns it red: keep the first R that satisfies the rule instead of the largest.
func TestFitPilotRateFindsTheLargestRateOnEveryBlock(t *testing.T) {
	dir := t.TempDir()
	all := []bool{true, true, true, true}
	var cells []string
	for _, n := range []string{"pp-A-prospective-1", "pp-A-prospective-2", "pp-A-prospective-3"} {
		cells = append(cells, writeFitCell(t, dir, n, []int64{0, 0, 0, 1000}, all))
	}
	var out bytes.Buffer
	if err := fitPilotRate(fitArgs(cells...), &out); err != nil {
		t.Fatalf("fit refused: %v\n%s", err, out.String())
	}
	if !strings.Contains(out.String(), "R=9999\n") {
		t.Fatalf("want R=9999, got:\n%s", out.String())
	}
}

// The rule holds on EVERY block: one block whose P admitted less pulls R down with it.
func TestFitPilotRateHoldsOnEveryBlock(t *testing.T) {
	dir := t.TempDir()
	all := []bool{true, true, true, true}
	// After the burst, the fourth at 1 s needs R >= 10,000. The fifth at 3 s needs 3R >= 10,000, since a refused
	// fourth consumed nothing. With P admitting four of five (a_P = 0.8), S must admit at most 0.75, i.e. refuse two.
	low := writeFitCell(t, dir, "pp-A-prospective-3", []int64{0, 0, 0, 1000, 3000}, []bool{true, true, true, true, false})
	var out bytes.Buffer
	err := fitPilotRate(fitArgs(writeFitCell(t, dir, "pp-A-prospective-1", []int64{0, 0, 0, 1000}, all),
		writeFitCell(t, dir, "pp-A-prospective-2", []int64{0, 0, 0, 1000}, all), low), &out)
	if err != nil {
		t.Fatalf("fit refused: %v\n%s", err, out.String())
	}
	// Up to R = 3,333 both are refused (3 * 3,333 = 9,999), so S admits 3/5 = 0.6 <= 0.75; from 3,334 the fifth
	// fits and S admits 4/5 = 0.8 > 0.75. The other blocks alone would allow 9,999.
	if !strings.Contains(out.String(), "R=3333\n") {
		t.Fatalf("want R=3333, got:\n%s", out.String())
	}
}

func TestFitPilotRateRefusesWhenNoRateSatisfiesTheRule(t *testing.T) {
	dir := t.TempDir()
	// Three at once: S admits exactly the burst, 3 of 4 at every R below 10,000... but P admitted only those
	// three, so S would need 0.75 - 0.05 = 0.70, and no R gets S below 0.75.
	p := []bool{true, true, true, false}
	var cells []string
	for _, n := range []string{"pp-A-prospective-1", "pp-A-prospective-2", "pp-A-prospective-3"} {
		cells = append(cells, writeFitCell(t, dir, n, []int64{0, 0, 0, 1000}, p))
	}
	err := fitPilotRate(fitArgs(cells...), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "R unavailable") {
		t.Fatalf("want the R-unavailable outcome, got %v", err)
	}
}

// A contender with no gateway decision makes P's admissions unidentifiable, and the fit refuses.
//
// Mutation that turns it red: skip a contender whose record is missing instead of refusing.
func TestFitPilotRateRefusesAnUnidentifiableBlock(t *testing.T) {
	dir := t.TempDir()
	all := []bool{true, true, true, true}
	c := writeFitCell(t, dir, "pp-A-prospective-1", []int64{0, 0, 0, 1000}, all)
	rec := strings.SplitN(c, ":", 2)[1]
	b, _ := os.ReadFile(rec)
	var kept []string
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if !strings.Contains(l, `"pp-A-prospective-1-4"`) || !strings.Contains(l, `"done"`) {
			kept = append(kept, l)
		}
	}
	if err := os.WriteFile(rec, []byte(strings.Join(kept, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := fitPilotRate(fitArgs(c, writeFitCell(t, dir, "pp-A-prospective-2", []int64{0}, []bool{true}),
		writeFitCell(t, dir, "pp-A-prospective-3", []int64{0}, []bool{true})), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "unidentifiable") {
		t.Fatalf("want an unidentifiable refusal, got %v", err)
	}
}

// At the boundary a_S = a_P - 0.05 exactly holds. Three contenders at once drain the burst and 17 more arrive at
// 1..17 s, so S admits 3 + floor(17R/10,000) of 20. P admitted 14 (0.70), so S may admit 13 (0.65): R <= 6,470.
// In floating point 0.70 - 0.05 is just below 0.65, and the fit stopped at 12 admitted, R = 5,882.
//
// Mutation that turns it red: compare the fractions in floating point.
func TestFitPilotRateHoldsAtTheMarginBoundary(t *testing.T) {
	dir := t.TempDir()
	offsets := []int64{0, 0, 0}
	for k := int64(1); k <= 17; k++ {
		offsets = append(offsets, k*1000)
	}
	admits := make([]bool, 20)
	for i := range 14 {
		admits[i] = true
	}
	var cells []string
	for b := 1; b <= 3; b++ {
		cells = append(cells, writeFitCell(t, dir, fmt.Sprintf("pp-A-prospective-%d", b), offsets, admits))
	}
	var out bytes.Buffer
	if err := fitPilotRate(fitArgs(cells...), &out); err != nil {
		t.Fatalf("fit refused: %v\n%s", err, out.String())
	}
	if !strings.Contains(out.String(), "R=6470\n") {
		t.Fatalf("want R=6470, got:\n%s", out.String())
	}
}

// The same block given twice, or a block from another arm, is refused before any fit.
//
// Mutation that turns it red: count the -cell arguments instead of the distinct registered blocks.
func TestFitPilotRateRequiresEachRegisteredBlockOnce(t *testing.T) {
	dir := t.TempDir()
	one := writeFitCell(t, dir, "pp-A-prospective-1", []int64{0}, []bool{true})
	two := writeFitCell(t, dir, "pp-A-prospective-2", []int64{0}, []bool{true})
	if err := fitPilotRate(fitArgs(one, two, one), &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "again") {
		t.Fatalf("a repeated block was not refused: %v", err)
	}
	off := writeFitCell(t, dir, "pp-A-off-3", []int64{0}, []bool{true})
	if err := fitPilotRate(fitArgs(one, two, off), &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "pp-A-prospective-3") {
		t.Fatalf("another arm's block was not refused: %v", err)
	}
}

func TestFitPilotRateRefusesOtherThanThreeBlocks(t *testing.T) {
	dir := t.TempDir()
	c := writeFitCell(t, dir, "pp-A-prospective-1", []int64{0}, []bool{true})
	if err := fitPilotRate(fitArgs(c, c), &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "3 P blocks") {
		t.Fatalf("two blocks were not refused: %v", err)
	}
}

// A contender ID with no block prefix is refused, not sliced at -1 (review of 27bed2d).
func TestFitPilotRateRefusesAnIDWithoutABlock(t *testing.T) {
	dir := t.TempDir()
	raw := filepath.Join(dir, "raw.jsonl")
	rec := filepath.Join(dir, "rec.jsonl")
	_ = os.WriteFile(raw, []byte(`{"index":1,"requestId":"req1","tenant":"standard-noisy","promptLenChars":40000,"exactInputTokens":7695}`+"\n"), 0o644)
	_ = os.WriteFile(rec, []byte(`{"ev":"done","requestId":"req1","decision":"admit","arrivedUnixNanos":5}`+"\n"), 0o644)
	c := raw + ":" + rec
	if err := fitPilotRate(fitArgs(c, c, c), &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "no block prefix") {
		t.Fatalf("want a refusal, got %v", err)
	}
}
