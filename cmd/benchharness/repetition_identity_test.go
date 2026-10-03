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

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// The pairing of two arms is by the repetition identity the runner recorded, and these are its checks.
//
// Nothing pinned this path before. repP99 was read by no test, armEvidence's internals by no test, and the
// refusals' repetition numbers by no test -- so the arrays could be appended in --raw argument order, the
// wrong repetitions compared, and every suite stayed green. The third 2026-09-30 amendment forbids exactly
// that inference: pairing is "recorded rather than inferred from two arrays having equal length".
//
// The identity is read as raw-<arm>-<repetition>.jsonl with the arm taken from the ROWS, because 22 arm
// names in this repository contain hyphens and raw-mbt-1024-priority-1.jsonl cannot otherwise be split.

func TestAFileWithNoRepetitionNumberIsRefused(t *testing.T) {
	dir := t.TempDir()
	// The name the pre-identity runner wrote: one file per arm, no repetition in it.
	// hack/m5b-harness-dryrun.sh produced exactly this shape until the same commit as this test.
	p := writeRepetition(t, dir, "raw-R1.jsonl", "R1", 200, 100, 150, 0)

	err := report([]string{"-out", filepath.Join(dir, "report.txt"), "-raw", p})
	if err == nil {
		t.Fatal("a raw file carrying no repetition identity was accepted; its pairing could only be positional")
	}
	for _, want := range []string{"raw-R1-<repetition>.jsonl", "argument order"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q, so a reader cannot tell what to rename: %v", want, err)
		}
	}
}

// A name whose arm disagrees with the rows is refused, rather than being split on a guess.
//
// This is the case that makes reading the arm from the rows load-bearing: the file says "shared" and every
// row says "R1". Splitting the filename on the last hyphen would have produced arm "raw-shared" or
// repetition "1" for the wrong arm, and either way the block would be paired against the wrong one.
func TestAFileWhoseNameDisagreesWithItsRowsIsRefused(t *testing.T) {
	dir := t.TempDir()
	p := writeRepetition(t, dir, "raw-shared-1.jsonl", "R1", 200, 100, 150, 0)

	err := report([]string{"-out", filepath.Join(dir, "report.txt"), "-raw", p})
	if err == nil {
		t.Fatal("a file named for one arm and carrying another was accepted")
	}
	if !strings.Contains(err.Error(), `carries arm "R1" in every row`) {
		t.Errorf("the refusal does not name the arm the ROWS carry, which is the half that is trusted: %v", err)
	}
}

// The same (arm, repetition) from two directories is refused -- the duplicate check spans the whole input.
//
// replayFrom catches a byte-identical copy by hashing send timestamps. It cannot catch two DIFFERENT
// replays that both call themselves repetition 1, which is what globbing two run directories together
// produces, and that pair would silently discard one of them from the comparison.
func TestTheSameRepetitionIdentityFromTwoDirectoriesIsRefused(t *testing.T) {
	root := t.TempDir()
	a := filepath.Join(root, "run-a")
	b := filepath.Join(root, "run-b")
	for _, d := range []string{a, b} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", d, err)
		}
	}
	// Different contents -- different tails -- both claiming R1 repetition 1.
	//
	// The second is written under another name and then moved, because writeRepetition derives each row's
	// send epoch from the FILE NAME: two files written as raw-R1-1.jsonl would carry identical send
	// timestamps and trip the same-replay refusal first, which is a different defect and would leave this
	// one unproven.
	p1 := writeRepetition(t, a, "raw-R1-1.jsonl", "R1", 200, 100, 150, 0)
	src := writeRepetition(t, b, "raw-R1-9.jsonl", "R1", 200, 400, 150, 0)
	p2 := filepath.Join(b, "raw-R1-1.jsonl")
	blob, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read %s: %v", src, err)
	}
	if err := os.WriteFile(p2, blob, 0o600); err != nil {
		t.Fatalf("write %s: %v", p2, err)
	}
	if err := os.Remove(src); err != nil {
		t.Fatalf("remove %s: %v", src, err)
	}

	rerr := report([]string{"-out", filepath.Join(root, "report.txt"), "-raw", p1, "-raw", p2})
	if rerr == nil {
		t.Fatal("two files both claiming arm R1 repetition 1 were accepted as two repetitions")
	}
	for _, want := range []string{"both record arm R1 repetition 1", "which repetition"} {
		if !strings.Contains(rerr.Error(), want) {
			t.Errorf("the refusal does not say %q: %v", want, rerr)
		}
	}
}

// writeMatrixRepetition writes one M5-c repetition: the sharing matrix's study, its arms, one contender.
//
// writeRepetition cannot serve these tests. It leaves Study empty, which CanonicalStudyID reads as the
// M5-b gateway experiment -- whose registry admits R1, off, static-cap and kv-aware and refuses `shared`
// before any pairing is reached. The registered estimand is M5-c's object, so its tests need M5-c rows.
func writeMatrixRepetition(t *testing.T, dir, arm string, rep int, ttftMs float64) string {
	t.Helper()
	path := filepath.Join(dir, fmt.Sprintf("raw-%s-%d.jsonl", arm, rep))
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()

	enc := json.NewEncoder(f)
	// Each repetition gets its own send epoch, so two of them are never the same replay.
	base := int64(1_000_000_000) + int64(rep)*1_000_000_000_000
	write := func(r bench.RawRow) {
		if err := enc.Encode(r); err != nil {
			t.Fatalf("encode: %v", err)
		}
	}
	for i := range bench.MinTailSamples + 40 {
		send := base + int64(i)*2_000_000
		first := send + int64(ttftMs*1e6)
		write(bench.RawRow{
			Index: i, Arm: arm, Tenant: bench.PremiumTenant, HTTPStatus: 200,
			SendUnixNanos: send, FirstTokenUnixNanos: first, EndUnixNanos: first + 20_000_000,
			// EngineInputTokens is what reading 4e holds against the frozen premium count of 256. These rows
			// mean to be a run that carried the declared load, so they say what the engine reported; a zero
			// here describes a run with no usage accounting, which the gate refuses to call verified.
			EstInputTokens: 294, ExactInputTokens: 256, EngineInputTokens: 256, OutputTokens: 16,
			Study: bench.StudySharingMatrix, TraceChecksum: "t", LongThreshold: 4096, MatchTolerance: 0.05,
		})
	}
	// R1 is the isolated baseline and carries no contender traffic at all; every other arm does.
	if arm != bench.ArmR1 {
		for i := range 140 {
			send := base + int64(10_000+i)*2_000_000
			first := send + 900_000_000
			write(bench.RawRow{
				Index: 10_000 + i, Arm: arm, Tenant: bench.NoisyTenant, IsNoisy: true, HTTPStatus: 200,
				SendUnixNanos: send, FirstTokenUnixNanos: first, EndUnixNanos: first + 60_000_000*39,
				// The frozen contender count, for the same reason as the premium rows above.
				EstInputTokens: 8500, ExactInputTokens: 8192, EngineInputTokens: 8192, OutputTokens: 40,
				Study: bench.StudySharingMatrix, TraceChecksum: "t", LongThreshold: 4096, MatchTolerance: 0.05,
			})
		}
	}
	return path
}

// Equally many repetitions is not the same as the same repetitions: {1,2} against {1,3} is refused.
//
// This is the case the amendment singles out. Both arms carry two blocks, so every length check passes,
// and zipping them compares R1's repetition 2 against shared's repetition 3.
func TestTwoArmsWithDifferentIdentitySetsAreRefused(t *testing.T) {
	dir := t.TempDir()
	paths := []string{
		writeMatrixRepetition(t, dir, bench.ArmR1, 1, 70),
		writeMatrixRepetition(t, dir, bench.ArmR1, 2, 72),
		writeMatrixRepetition(t, dir, bench.ArmShared, 1, 1900),
		writeMatrixRepetition(t, dir, bench.ArmShared, 3, 1910),
	}
	args := []string{"-out", filepath.Join(dir, "report.txt")}
	for _, p := range paths {
		args = append(args, "-raw", p)
	}

	err := report(args)
	if err == nil {
		t.Fatal("arms recording repetitions {1,2} and {1,3} were paired; they have no shared blocks")
	}
	for _, want := range []string{"repetitions 1,2", "recorded 1,3", "equally many"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q, so a reader cannot see that the SETS differ rather than"+
				" the counts: %v", want, err)
		}
	}
}

// Shuffling one arm's --raw order must change NOTHING, because the pairing is by identity.
//
// This is the test the closing condition of the defect record originally got backwards: it said shuffling
// must go RED. Under a correct fix shuffling is invisible, and what must go red is restoring the positional
// append -- which the mutation recorded beside this file checks.
//
// Comparing the whole report rather than the ratio alone is deliberate: each arm's median is computed from
// its own values and is order-invariant either way, so a test that read only the point estimate would pass
// on the positional version too.
func TestShufflingOneArmsRawOrderChangesNothing(t *testing.T) {
	dir := t.TempDir()
	// Three repetitions per arm with DIFFERENT tails, so a mis-pairing would move the numbers.
	//
	// All THREE arms, not just the pair being shuffled: with only R1 and `shared` the readings have no
	// candidate, reading 4d refuses the run, and this test would be comparing two refusal messages instead
	// of two sets of paired numbers.
	for _, rep := range []int{1, 2, 3} {
		base := float64(60 + rep*20)
		writeMatrixRepetition(t, dir, bench.ArmR1, rep, base)
		writeMatrixRepetition(t, dir, bench.ArmShared, rep, base*20)
		writeMatrixRepetition(t, dir, bench.ArmTimeSlicing, rep, base*2)
	}
	run := func(order []string) string {
		args := []string{}
		for _, p := range order {
			args = append(args, "-raw", p)
		}
		out, err := captureStdout(t, func() error { return report(args) })
		if err != nil {
			t.Fatalf("report was refused for a valid three-repetition pair: %v\n%s", err, out)
		}
		return out
	}
	// Sorted, then with one arm reversed. The identities are the same set either way.
	sortedOrder := []string{}
	for rep := 1; rep <= 3; rep++ {
		sortedOrder = append(sortedOrder, filepath.Join(dir, fmt.Sprintf("raw-%s-%d.jsonl", bench.ArmR1, rep)))
	}
	for rep := 1; rep <= 3; rep++ {
		sortedOrder = append(sortedOrder, filepath.Join(dir, fmt.Sprintf("raw-%s-%d.jsonl", bench.ArmShared, rep)))
	}
	for rep := 1; rep <= 3; rep++ {
		sortedOrder = append(sortedOrder, filepath.Join(dir, fmt.Sprintf("raw-%s-%d.jsonl", bench.ArmTimeSlicing, rep)))
	}
	// `shared` repetition 1 and 3 swap places. Under positional pairing that moves which R1 block each one
	// is compared with; under identity pairing nothing moves.
	shuffled := append([]string(nil), sortedOrder...)
	shuffled[3], shuffled[5] = shuffled[5], shuffled[3]

	if a, b := run(sortedOrder), run(shuffled); a != b {
		t.Errorf("shuffling one arm's --raw order changed the report, so the pairing is still positional\n"+
			"sorted:\n%s\nshuffled:\n%s", a, b)
	}
}

// The repetition a refusal NAMES is the recorded one, not the position in the argument list.
//
// An operator reads this at the end of a paid session and goes looking for the file. While the number was
// the slice index, "repetition 1" meant "the second file --raw listed for this arm", which is
// raw-R1-3.jsonl whenever the glob was not sorted.
func TestARefusalNamesTheRecordedRepetitionNotThePosition(t *testing.T) {
	dir := t.TempDir()
	// R1's repetition 2 is the short one. Listed LAST, its index would be 1 and its identity 2.
	short := writeRepetition(t, dir, "raw-R1-2.jsonl", "R1", 120, 100, 120, 0)
	long := writeRepetition(t, dir, "raw-R1-1.jsonl", "R1", 200, 100, 200, 0)

	err := report([]string{"-out", filepath.Join(dir, "report.txt"), "-raw", long, "-raw", short})
	if err == nil {
		t.Fatal("a baseline whose repetitions recorded different row counts was accepted")
	}
	// 121 and 201, not 120 and 200: writeRepetition adds one contender row after the premium ones.
	if !strings.Contains(err.Error(), "repetition 2 recorded 121 rows") {
		t.Errorf("the refusal does not name repetition 2 -- the identity -- so it sends the operator to the"+
			" wrong file: %v", err)
	}
	if strings.Contains(err.Error(), "repetition 1 recorded 121") {
		t.Errorf("the refusal named the POSITION of the short repetition rather than its identity: %v", err)
	}
}
