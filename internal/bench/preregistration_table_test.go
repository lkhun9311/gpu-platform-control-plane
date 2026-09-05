package bench

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// TestThePreRegistrationTableMatchesTheEvidenceItCitesFrom ties the spec's numbers to the report code.
//
// The paid 2026-09-03 raw evidence is 7 MB and deliberately gitignored, so a table typed into a design
// document has, by default, nothing in the repository comparing it to anything. That is the exact shape of
// every overclaim this project has had to withdraw: a value living in two places with no ruler between
// them. The report now emits a machine-readable summary beside its text, that file is committed, and this
// test asserts the document agrees with it digit for digit.
//
// It cannot prove the JSON came from the evidence -- only re-running the report against the raw files does
// that. What it does prove is that nobody can adjust a number in the write-up without the derivation
// disagreeing, which is the failure mode that actually happened.
func TestThePreRegistrationTableMatchesTheEvidenceItCitesFrom(t *testing.T) {
	const (
		specPath = "../../docs/superpowers/specs/2026-09-05-the-price-of-protection.md"
		dataPath = "../../docs/superpowers/specs/data/2026-09-03-arm-summaries.json"
	)
	blob, err := os.ReadFile(dataPath)
	if err != nil {
		t.Fatalf("read summaries: %v", err)
	}
	var summaries []ArmSummary
	if err := json.Unmarshal(blob, &summaries); err != nil {
		t.Fatalf("decode summaries: %v", err)
	}
	byArm := map[string]ArmSummary{}
	for _, s := range summaries {
		byArm[s.Arm] = s
	}

	spec, err := os.ReadFile(specPath)
	if err != nil {
		t.Fatalf("read spec: %v", err)
	}
	// | arm | premium TTFT p99 | output tok/s | premium share | noisy share |
	row := regexp.MustCompile(`(?m)^\| \*{0,2}([A-Za-z0-9-]+)\*{0,2}[^|]*\| *([\d,]+\.\d) ms *\| *(\d+\.\d) *\| *(\d+)% *\| *(\S+) *\|$`)
	matches := row.FindAllStringSubmatch(string(spec), -1)
	if len(matches) != 4 {
		t.Fatalf("found %d evidence rows in %s, want 4 (R1, off, static-cap, kv-aware)", len(matches), specPath)
	}
	for _, m := range matches {
		arm := m[1]
		s, ok := byArm[arm]
		if !ok {
			t.Fatalf("the spec cites arm %q, which is not in %s", arm, dataPath)
		}
		wantP99 := mustFloat(t, strings.ReplaceAll(m[2], ",", ""))
		if fmt.Sprintf("%.1f", s.TTFTMsP99) != fmt.Sprintf("%.1f", wantP99) {
			t.Errorf("%s: spec says p99 %.1f ms, the evidence summary says %.1f", arm, wantP99, s.TTFTMsP99)
		}
		wantRate := mustFloat(t, m[3])
		if fmt.Sprintf("%.1f", s.OutputTokensPerSecond) != fmt.Sprintf("%.1f", wantRate) {
			t.Errorf("%s: spec says %.1f output tok/s, the evidence summary says %.1f",
				arm, wantRate, s.OutputTokensPerSecond)
		}
		if got := sharePct(s, "premium-1"); fmt.Sprintf("%.0f", got) != m[4] {
			t.Errorf("%s: spec says premium share %s%%, the evidence summary says %.0f%%", arm, m[4], got)
		}
		// The noisy column is the one the whole document turns on: an arm that "protected" the tail by
		// deleting the contending tenant reads 0% here, and reading it as an em dash would hide exactly that.
		wantNoisy := m[5]
		gotNoisy := fmt.Sprintf("%.0f%%", sharePct(s, "standard-noisy"))
		if _, served := s.OutputTokensByTenant["standard-noisy"]; !served && wantNoisy == "—" {
			continue
		}
		if gotNoisy != wantNoisy {
			t.Errorf("%s: spec says noisy share %s, the evidence summary says %s", arm, wantNoisy, gotNoisy)
		}
	}
}

func sharePct(s ArmSummary, tenant string) float64 {
	if s.OutputTokens == 0 {
		return 0
	}
	return 100 * float64(s.OutputTokensByTenant[tenant]) / float64(s.OutputTokens)
}

func mustFloat(t *testing.T, s string) float64 {
	t.Helper()
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	return v
}
