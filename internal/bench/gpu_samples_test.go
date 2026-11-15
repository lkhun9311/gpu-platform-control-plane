package bench

import (
	"math"
	"slices"
	"strings"
	"testing"
	"time"
)

const gpuCSV = `2026/11/20 03:00:00.000, 41, 1710, 6250, 62.50
2026/11/20 03:00:05.000, 44, 1695, 6250, 140.12
2026/11/20 03:00:10.001, 47, 1410, 6250, [N/A]
`

// TestGPUSamplesAreReadFromTheRegisteredQuery: every field of every row, [N/A] power kept as missing rather than zero.
func TestGPUSamplesAreReadFromTheRegisteredQuery(t *testing.T) {
	s, err := ParseGPUSamples(strings.NewReader(gpuCSV))
	if err != nil {
		t.Fatal(err)
	}
	if len(s) != 3 || s[1].TemperatureC != 44 || s[1].SMClockMHz != 1695 || s[1].MemClockMHz != 6250 || s[1].PowerW != 140.12 {
		t.Fatalf("samples %+v", s)
	}
	if !math.IsNaN(s[2].PowerW) {
		t.Fatalf("power [N/A] read as %v", s[2].PowerW)
	}
	if !s[0].At.Equal(time.Date(2026, 11, 20, 3, 0, 0, 0, time.UTC)) {
		t.Fatalf("timestamp %s", s[0].At)
	}
	if !slices.Contains(GPUSampleArgs, "--loop-ms=5000") {
		t.Fatalf("the registered query %v does not sample every 5 s", GPUSampleArgs)
	}
}

// TestGPUSamplesRefuseWhatTheyCannotRead: a skipped row would look like a quiet card.
func TestGPUSamplesRefuseWhatTheyCannotRead(t *testing.T) {
	for name, body := range map[string]string{
		"missing field":   "2026/11/20 03:00:00.000, 41, 1710, 6250\n",
		"not a number":    "2026/11/20 03:00:00.000, hot, 1710, 6250, 62\n",
		"bad time":        "11/20/2026 03:00:00, 41, 1710, 6250, 62\n",
		"out of order":    "2026/11/20 03:00:05.000, 41, 1710, 6250, 62\n2026/11/20 03:00:00.000, 41, 1710, 6250, 62\n",
		"error text":      "No devices were found\n",
		"temperature n/a": "2026/11/20 03:00:00.000, [N/A], 1710, 6250, 62\n",
	} {
		t.Run(name, func(t *testing.T) {
			if s, err := ParseGPUSamples(strings.NewReader(body)); err == nil {
				t.Fatalf("read %+v", s)
			}
		})
	}
}

// TestAGPUWindowSaysWhetherTheSamplesCoverIt: ranges over the cell's span, and a gap beyond twice the interval is not covered.
func TestAGPUWindowSaysWhetherTheSamplesCoverIt(t *testing.T) {
	s, _ := ParseGPUSamples(strings.NewReader(gpuCSV))
	t0 := time.Date(2026, 11, 20, 3, 0, 0, 0, time.UTC)
	w, err := SummarizeGPUWindow(s, t0, t0.Add(12*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if !w.Covered || w.Samples != 3 || w.MaxTempC != 47 || w.MinSMClockMHz != 1410 || w.MaxSMClockMHz != 1710 {
		t.Fatalf("window %+v", w)
	}
	// The card stopped reporting after 03:00:10, so a span to 03:00:30 has a 20 s hole at its end.
	w, _ = SummarizeGPUWindow(s, t0, t0.Add(30*time.Second))
	if w.Covered || w.LongestGapSeconds < 19.9 {
		t.Fatalf("a 20 s gap at the end was covered: %+v", w)
	}
	// Samples outside the span are not the cell's.
	w, _ = SummarizeGPUWindow(s, t0.Add(4*time.Second), t0.Add(6*time.Second))
	if w.Samples != 1 || w.MaxTempC != 44 {
		t.Fatalf("window around one sample %+v", w)
	}
	if w, _ := SummarizeGPUWindow(nil, t0, t0.Add(time.Second)); w.Covered {
		t.Fatal("no samples covered a window")
	}
	if _, err := SummarizeGPUWindow(s, t0, t0); err == nil {
		t.Fatal("an empty span was summarized")
	}
}
