package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The paired comparison rests on a premise nothing checked: every arm is offered the SAME premium requests.
//
// The registration's reading 4 divides `shared`'s premium tail by R1's, and the per-repetition ratios are read
// as a paired comparison. That is only legitimate if the two arms received the same premium traffic -- same
// arrival offsets, same prompt lengths, same output caps, in the same order. gen-trace builds R1 by filtering
// the contending tenant out of the SAME trace, so the premise is true by construction, and "by construction"
// is exactly the kind of claim this repository has been wrong about: the construction can change, and a run
// whose arms were offered different premium traffic would still produce a ratio that looks fine.
//
// Measured on the 2026-10-02 archive before this test was written: all three arms, all five repetitions,
// 4,655 premium rows each, one fingerprint across the lot.
func premiumFingerprint(t *testing.T, path string) (string, int) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	h := sha256.New()
	n := 0
	for line := range strings.SplitSeq(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var r TraceRow
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("parse a row of %s: %v", path, err)
		}
		if r.Tenant != PremiumTenant {
			continue
		}
		// Every field that describes what was OFFERED. Tenant is included even though it is constant here,
		// because a trace that renamed the premium tenant would otherwise fingerprint identically.
		// h.Write with fmt.Appendf rather than fmt.Fprintf: hash.Hash never returns an error, and an ignored
		// Fprintf result is a habit worth not having in a file whose whole output is a digest. The bytes are
		// identical either way -- the archives still fingerprint 443db0939d9846de and 52df4f52668151e2.
		h.Write(fmt.Appendf(nil, "%d|%v|%d|%d|%d|%s\n",
			r.Index, r.IsNoisy, r.MaxOutputTokens, r.OffsetMs, r.PromptLenChars, r.Tenant))
		n++
	}
	return hex.EncodeToString(h.Sum(nil))[:16], n
}

// archiveArmReps groups an archive's trace files by arm, so the test says which arm is missing rather than
// failing on a path it built itself.
func archiveArmReps(t *testing.T, dir string) map[string][]string {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(dir, "trace-*.jsonl"))
	if err != nil {
		t.Fatalf("glob %s: %v", dir, err)
	}
	out := map[string][]string{}
	for _, p := range paths {
		base := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(p), "trace-"), ".jsonl")
		i := strings.LastIndex(base, "-")
		if i <= 0 {
			t.Fatalf("%s does not name an arm and a repetition", p)
		}
		out[base[:i]] = append(out[base[:i]], p)
	}
	for arm := range out {
		sort.Strings(out[arm])
	}
	return out
}

// disagreementsAcrossArms walks one archive and returns every cell that was offered different premium
// traffic from the first, as sentences naming both sides.
//
// Extracted so the synthetic violations below exercise THIS comparison rather than a copy of it. The first
// version inlined the walk in the archive test and re-implemented it in the synthetic one, and a mutation
// proved the cost: narrowing the grouping in the archive test changed nothing, because the synthetic test's
// own copy still compared across arms. That is the same defect this repository recorded as "mutate every copy
// of the thing you are testing" -- and writing a second copy inside the test that was supposed to catch it is
// how it recurred.
func disagreementsAcrossArms(t *testing.T, byArm map[string][]string, arms []string) []string {
	t.Helper()
	var out []string
	want, wantN, wantFrom := "", 0, ""
	for _, arm := range arms {
		for _, p := range byArm[arm] {
			got, n := premiumFingerprint(t, p)
			if want == "" {
				want, wantN, wantFrom = got, n, filepath.Base(p)
				continue
			}
			// The count is NOT compared separately, and that is deliberate.
			//
			// premiumFingerprint hashes one line per premium row, so a cell offering a different number of
			// requests cannot produce the same digest -- dropping a row changes it. A separate count
			// comparison would therefore be a branch no fixture can reach: a mutation that deleted it stayed
			// green because every input that would trip it trips the digest first. The count is still
			// REPORTED, because "20 rows against 19" is what an operator needs to see.
			if got != want {
				out = append(out, fmt.Sprintf("%s (%d rows, %s) against %s (%d rows, %s)",
					filepath.Base(p), n, got, wantFrom, wantN, want))
			}
		}
	}
	return out
}

// disagreementsWithinArms returns every repetition that was offered different premium traffic from its arm's
// first repetition.
//
// Separate from the across-arms walk because the two claims are different: one says the arms are comparable,
// the other says a repetition's spread is the machine's rather than the load's. A single function covering
// both would let one mutation satisfy the other's fixture.
func disagreementsWithinArms(t *testing.T, byArm map[string][]string) []string {
	t.Helper()
	var out []string
	arms := make([]string, 0, len(byArm))
	for a := range byArm {
		arms = append(arms, a)
	}
	sort.Strings(arms)
	for _, arm := range arms {
		paths := byArm[arm]
		if len(paths) < 2 {
			continue
		}
		first, firstN := premiumFingerprint(t, paths[0])
		for _, p := range paths[1:] {
			got, n := premiumFingerprint(t, p)
			// Same reason as the across-arm walk: the digest already covers the row count.
			if got != first {
				out = append(out, fmt.Sprintf("%s: %s (%d rows, %s) against %s (%d rows, %s)",
					arm, filepath.Base(p), n, got, filepath.Base(paths[0]), firstN, first))
			}
		}
	}
	return out
}

// Every arm and repetition of one run offers the same premium requests.
//
// Skipped when the archive is absent: run outputs are gitignored, so a clean checkout has none and a failure
// there would be about the checkout. The archives that ARE present are the ones whose figures this repository
// publishes, which is where the premise has to hold.
func TestEveryArmIsOfferedTheSamePremiumTraffic(t *testing.T) {
	for _, tc := range []struct {
		dir  string
		arms int
		reps int
	}{
		{"../../hack/m5c-20261002-014903/m5c-run", 3, 5},
		{"../../hack/m5c-20260913-011031/m5c-run", 3, 2},
	} {
		t.Run(filepath.Base(filepath.Dir(tc.dir)), func(t *testing.T) {
			if _, err := os.Stat(tc.dir); err != nil {
				t.Skipf("archive %s is not in this checkout (run outputs are not committed)", tc.dir)
			}
			byArm := archiveArmReps(t, tc.dir)
			if len(byArm) != tc.arms {
				t.Fatalf("%s holds %d arms and this archive is recorded as having %d: %v", tc.dir, len(byArm), tc.arms, byArm)
			}

			arms := []string{ArmR1, ArmShared, ArmTimeSlicing}
			for _, arm := range arms {
				paths, ok := byArm[arm]
				if !ok {
					t.Fatalf("%s has no %s arm", tc.dir, arm)
				}
				if len(paths) != tc.reps {
					t.Errorf("%s has %d repetitions of %s and this archive is recorded as having %d", tc.dir, len(paths), arm, tc.reps)
				}
			}

			if d := disagreementsAcrossArms(t, byArm, arms); len(d) > 0 {
				t.Errorf("the arms were NOT offered the same premium traffic, so the per-repetition ratios are not a paired comparison: %s",
					strings.Join(d, "; "))
			}

			fp, n := premiumFingerprint(t, byArm[ArmR1][0])
			if n == 0 {
				t.Fatal("no premium rows were fingerprinted, so this test asserted nothing")
			}
			t.Logf("%d arms x %d repetitions, %d premium requests each, fingerprint %s", tc.arms, tc.reps, n, fp)
		})
	}
}

// Synthetic violations, because the real archives satisfy the premise and therefore prove nothing about the
// check itself.
//
// Two mutations of the test above came back GREEN: dropping offsetMs from the fingerprint, and narrowing the
// comparison to within one arm. Both are green for the same reason -- every arm and repetition in both
// archives agrees on every field, so any subset of fields and any grouping still reports "all equal". A test
// whose only fixtures satisfy it cannot say which difference it would catch, and this is the third time today
// that shape has appeared.
func writeTrace(t *testing.T, dir, name string, rows []TraceRow) string {
	t.Helper()
	var b strings.Builder
	for _, r := range rows {
		line, err := json.Marshal(r)
		if err != nil {
			t.Fatalf("marshal a row: %v", err)
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(b.String()), 0o600); err != nil {
		t.Fatalf("write %s: %v", p, err)
	}
	return p
}

// premiumOffered builds the premium half of a trace: n requests, one every 100 ms, 1,174-character prompts.
func premiumOffered(n int) []TraceRow {
	out := make([]TraceRow, 0, n)
	for i := range n {
		out = append(out, TraceRow{
			Index: i, OffsetMs: int64(i) * 100, Tenant: PremiumTenant,
			PromptLenChars: 1174, MaxOutputTokens: 64, IsNoisy: false,
		})
	}
	return out
}

func TestThePremiumFingerprintSeesEveryOfferedField(t *testing.T) {
	dir := t.TempDir()
	base := premiumOffered(20)
	want, wantN := premiumFingerprint(t, writeTrace(t, dir, "trace-R1-1.jsonl", base))
	if wantN != 20 {
		t.Fatalf("the baseline fingerprinted %d premium rows, want 20", wantN)
	}

	for _, tc := range []struct {
		name  string
		alter func([]TraceRow) []TraceRow
	}{
		{"one arrival moved by 1 ms", func(r []TraceRow) []TraceRow {
			r[7].OffsetMs++
			return r
		}},
		{"one prompt one character longer", func(r []TraceRow) []TraceRow {
			r[3].PromptLenChars++
			return r
		}},
		{"one output cap raised", func(r []TraceRow) []TraceRow {
			r[11].MaxOutputTokens++
			return r
		}},
		{"two requests swapped in order", func(r []TraceRow) []TraceRow {
			r[4].Index, r[5].Index = r[5].Index, r[4].Index
			return r
		}},
		{"one request dropped", func(r []TraceRow) []TraceRow { return r[:len(r)-1] }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			altered := make([]TraceRow, len(base))
			copy(altered, base)
			altered = tc.alter(altered)
			got, n := premiumFingerprint(t, writeTrace(t, t.TempDir(), "trace-shared-1.jsonl", altered))
			if got == want && n == wantN {
				t.Errorf("%s produced the same fingerprint %s and the same count %d, so the check would call these arms paired",
					tc.name, got, n)
			}
		})
	}
}

// And a violation across arms, driven through the same comparison the archive test uses.
//
// Written as its own archive in a temp directory so the comparison runs end to end rather than against the
// fingerprint helper alone -- the mutation that narrowed the grouping lived in the comparison, not the hash.
func TestTheArchiveComparisonRefusesArmsOfferedDifferentTraffic(t *testing.T) {
	dir := t.TempDir()
	base := premiumOffered(20)
	writeTrace(t, dir, "trace-R1-1.jsonl", base)
	writeTrace(t, dir, "trace-R1-2.jsonl", base)
	writeTrace(t, dir, "trace-shared-1.jsonl", base)
	writeTrace(t, dir, "trace-shared-2.jsonl", base)
	// timeSlicing's repetitions agree with EACH OTHER and differ from the other two arms.
	//
	// The shape matters. The first version made one timeSlicing cell differ from its own sibling, and a
	// mutation that narrowed the comparison to within one arm stayed green -- because that fixture is caught
	// by the within-arm walk and never needs the across-arm one. A violation that only the across-arm
	// comparison can see has to be consistent inside its arm.
	shifted := make([]TraceRow, len(base))
	copy(shifted, base)
	shifted[9].OffsetMs += 5
	writeTrace(t, dir, "trace-timeSlicing-1.jsonl", shifted)
	writeTrace(t, dir, "trace-timeSlicing-2.jsonl", shifted)

	// And the within-arm walk must stay quiet on it, so the two checks are not reading the same signal.
	if d := disagreementsWithinArms(t, archiveArmReps(t, dir)); len(d) > 0 {
		t.Fatalf("the within-arm comparison reported %v; this fixture is meant to be consistent inside every arm so that only the across-arm comparison can see it", d)
	}

	byArm := archiveArmReps(t, dir)
	if len(byArm) != 3 {
		t.Fatalf("the synthetic archive holds %d arms, want 3", len(byArm))
	}

	// THE SAME FUNCTION the archive test calls, not a second copy of its walk.
	disagreements := disagreementsAcrossArms(t, byArm, []string{ArmR1, ArmShared, ArmTimeSlicing})
	if len(disagreements) == 0 {
		t.Fatal("an archive whose timeSlicing arm was offered a 5 ms-shifted schedule reported no disagreement; the comparison does not look across arms")
	}

	// BOTH timeSlicing repetitions are expected, because both carry the shift.
	//
	// The assertion said "timeSlicing-2" while the fixture was being reshaped, and it failed on
	// timeSlicing-1 -- the test was still describing the previous fixture, where one cell differed from its
	// own sibling. Naming the arm rather than one cell is what the current fixture supports.
	if len(disagreements) != 2 {
		t.Errorf("want both timeSlicing repetitions reported, got %d: %s", len(disagreements), strings.Join(disagreements, "; "))
	}
	for _, d := range disagreements {
		if !strings.Contains(d, "trace-timeSlicing-") {
			t.Errorf("a disagreement does not name a timeSlicing cell, so the comparison is pointing at the wrong arm: %s", d)
		}
	}
	// And the two arms that were left alone must not be reported as the differing side.
	joined := strings.Join(disagreements, "; ")
	for _, quiet := range []string{"trace-R1-2.jsonl (", "trace-shared-1.jsonl (", "trace-shared-2.jsonl ("} {
		if strings.Contains(joined, quiet) {
			t.Errorf("%s was offered the same traffic as the baseline and was reported as differing: %s", quiet, joined)
		}
	}
}

// The repetitions are the SAME trace replayed, and that bounds what their spread can mean.
//
// Written because the narrow spread is quoted as a result -- the 2026-10-01 run's five ratios span 0.08 --
// and a reader can take it for evidence about GPUs. It is not: identical offered traffic means the variation
// between repetitions is the machine's, on one card, in one session. This test pins the premise so the
// caveat beside the number stays true.
func TestRepetitionsReplayTheSameTrace(t *testing.T) {
	const dir = "../../hack/m5c-20261002-014903/m5c-run"
	if _, err := os.Stat(dir); err != nil {
		t.Skipf("archive %s is not in this checkout (run outputs are not committed)", dir)
	}
	if d := disagreementsWithinArms(t, archiveArmReps(t, dir)); len(d) > 0 {
		t.Errorf("the repetitions are not the same trace, so their spread is not the machine's alone: %s",
			strings.Join(d, "; "))
	}
}

// And a within-arm violation, so the check above is not green only because every real archive satisfies it.
//
// A mutation that disabled the within-arm comparison entirely came back green: the real repetitions ARE
// identical, so deleting the comparison changes nothing any fixture notices. This is the companion to the
// across-arms case and exists for the same reason.
func TestTheWithinArmComparisonRefusesARepetitionOfferedDifferentTraffic(t *testing.T) {
	dir := t.TempDir()
	base := premiumOffered(20)
	writeTrace(t, dir, "trace-R1-1.jsonl", base)
	writeTrace(t, dir, "trace-R1-2.jsonl", base)
	writeTrace(t, dir, "trace-shared-1.jsonl", base)

	// `shared`'s second repetition carries one arrival 5 ms later than every other cell's.
	moved := make([]TraceRow, len(base))
	copy(moved, base)
	moved[9].OffsetMs += 5
	writeTrace(t, dir, "trace-shared-2.jsonl", moved)

	d := disagreementsWithinArms(t, archiveArmReps(t, dir))
	if len(d) == 0 {
		t.Fatal("a repetition whose arrival schedule moved by 5 ms reported no disagreement; the within-arm comparison does not look at the schedule")
	}
	joined := strings.Join(d, "; ")
	if !strings.Contains(joined, "shared-2") {
		t.Errorf("the disagreement names %s rather than the repetition that was altered", joined)
	}
	if strings.Contains(joined, "R1") {
		t.Errorf("R1's repetitions are identical and were reported as differing: %s", joined)
	}
}
