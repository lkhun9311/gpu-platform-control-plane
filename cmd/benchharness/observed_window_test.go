package main

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// writeClockedRepetition writes one repetition's two rows, each on that repetition's own clock origin.
// A nil window leaves the rows without a clock, as a repetition recorded by an older replay would be.
func writeClockedRepetition(t *testing.T, dir string, rep int, origin int64, window *int64) string {
	t.Helper()
	const sec = int64(1_000_000_000)
	var b strings.Builder
	for i := range 2 {
		base := origin + int64(i)*sec
		r := bench.RawRow{
			Index: i, Arm: "static-cap", Tenant: "premium-1", SendUnixNanos: base,
			FirstTokenUnixNanos: base + 100_000_000, EndUnixNanos: base + sec,
			EstInputTokens: 50, OutputTokens: 5, HTTPStatus: 200,
			TraceChecksum: "T", LongThreshold: 4096, MatchTolerance: 0.05,
		}
		if window != nil {
			send := int64(i) * sec
			terminal := send + *window/2
			r.Clock = &bench.RequestClock{OriginUnixNanos: origin, SendNanos: &send, TerminalNanos: &terminal}
		}
		enc, err := json.Marshal(r)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		b.Write(enc)
		b.WriteByte('\n')
	}
	path := filepath.Join(dir, "raw-static-cap-"+string(rune('1'+rep))+".jsonl")
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	return path
}

// TestObservedWindowSumsTheRepetitionsOwnWindows: pooled rows cross clock origins, so the arm's window is the sum of each repetition's.
func TestObservedWindowSumsTheRepetitionsOwnWindows(t *testing.T) {
	const sec = int64(1_000_000_000)
	dir := t.TempDir()
	four := 4 * sec
	paths := []string{
		writeClockedRepetition(t, dir, 0, 1_000*sec, &four),
		writeClockedRepetition(t, dir, 1, 2_000*sec, &four),
	}
	e, err := loadArmEvidence(paths)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	_, byArm := e.summarize()
	s := byArm["static-cap"]
	// Each repetition spans first send (0 s) to last terminal (1 s + 2 s) = 3 s; two of them are 6 s.
	if !s.ObservedWindowValid || math.Abs(s.ObservedSeconds-6) > 0.001 {
		t.Fatalf("observed window = %.3f valid=%v, want 6 s valid: two repetitions measured on their own clocks", s.ObservedSeconds, s.ObservedWindowValid)
	}
}

// TestObservedWindowIsNotMeasuredWhenARepetitionHasNoClock: a sum missing one repetition would understate the arm.
func TestObservedWindowIsNotMeasuredWhenARepetitionHasNoClock(t *testing.T) {
	const sec = int64(1_000_000_000)
	dir := t.TempDir()
	four := 4 * sec
	paths := []string{
		writeClockedRepetition(t, dir, 0, 1_000*sec, &four),
		writeClockedRepetition(t, dir, 1, 2_000*sec, nil),
	}
	e, err := loadArmEvidence(paths)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	_, byArm := e.summarize()
	s := byArm["static-cap"]
	if s.ObservedWindowValid || s.ObservedSeconds != 0 {
		t.Fatalf("observed window = %.3f valid=%v, want not measured when one repetition carries no clock", s.ObservedSeconds, s.ObservedWindowValid)
	}
}
