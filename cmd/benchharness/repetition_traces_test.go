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
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// A study whose repetitions are independent traces, and the identity that replaces "one trace per arm".
//
// The 2026-10-04 model-first registration found that every archived repetition replayed one trace, seed 11,
// so five repetitions measured engine noise on one draw of the arrival process and nothing about the draw.
// Its replacement gives each repetition its own seed. That breaks the old identity -- an arm's repetitions
// no longer share a checksum -- and it puts a new one in its place: within ONE repetition, the isolated
// baseline and the contended arm must offer the latency-critical tenant the same schedule, because that
// pairing is what makes the comparison a paired one.

// scheduledRows is rowsFor with the premium schedule and the checksum chosen by the caller.
func scheduledRows(study, arm, checksum string, offsetsMs []int64) []bench.RawRow {
	const sec = int64(1_000_000_000)
	rows := make([]bench.RawRow, 0, len(offsetsMs))
	for i, off := range offsetsMs {
		base := sec + off*1_000_000
		rows = append(rows, bench.RawRow{
			Index: i, Study: study, Arm: arm, Tenant: bench.PremiumTenant,
			ScheduledOffsetMs: off,
			SendUnixNanos:     base, FirstTokenUnixNanos: base + 100_000_000, EndUnixNanos: base + sec,
			EstInputTokens: 50, OutputTokens: 5, HTTPStatus: 200,
			TraceChecksum: checksum, LongThreshold: 4096, MatchTolerance: 0.05,
		})
	}
	return rows
}

// The tail-crossing studies' first BE level, the contended arm these fixtures use.
var level1 = bench.TailCrossingArm(1)

// Two repetitions drawn from two seeds: different premium schedules, and so different checksums.
var (
	scheduleSeedA = []int64{0, 700, 1900, 2600}
	scheduleSeedB = []int64{0, 1100, 1500, 3300, 4100}
)

func TestTheTailCrossingStudiesRegisterAPerRepetitionTrace(t *testing.T) {
	for _, id := range []string{bench.StudyTailCrossingShortLC, bench.StudyTailCrossingLongLC} {
		s, ok := bench.LookupStudy(id)
		if !ok {
			t.Fatalf("%s is not registered", id)
		}
		if !s.TracesVaryByRepetition {
			t.Errorf("%s does not register a trace per repetition; its 2026-10-04 registration replaces one replayed trace with independent ones", id)
		}
	}
	// And the confirmatory matrix keeps its one trace: its published evidence was all replayed from seed 11.
	if s, _ := bench.LookupStudy(bench.StudySharingMatrix); s.TracesVaryByRepetition {
		t.Error("the sharing matrix now claims a trace per repetition, which its archives contradict")
	}
}

func TestAPerRepetitionStudyAcceptsADifferentTraceInEachRepetition(t *testing.T) {
	study := bench.StudyTailCrossingShortLC
	dir := t.TempDir()
	paths := []string{
		writeRaw(t, dir, "raw-R1-1.jsonl", scheduledRows(study, bench.ArmR1, "r1-seedA", scheduleSeedA)),
		writeRaw(t, dir, "raw-R1-2.jsonl", scheduledRows(study, bench.ArmR1, "r1-seedB", scheduleSeedB)),
		writeRaw(t, dir, "raw-be01-shared-1.jsonl", scheduledRows(study, level1, "sh-seedA", scheduleSeedA)),
		writeRaw(t, dir, "raw-be01-shared-2.jsonl", scheduledRows(study, level1, "sh-seedB", scheduleSeedB)),
	}
	e, err := loadArmEvidence(paths)
	if err != nil {
		t.Fatalf("two repetitions from two seeds were refused: %v", err)
	}
	// The row counts differ between the repetitions, and that is the arrival process, not a cut recording.
	if err := e.refuseIfTracesDisagree(); err != nil {
		t.Fatalf("a correctly paired per-repetition run was refused: %v", err)
	}
}

func TestAPerRepetitionStudyRefusesOneTraceReplayedAsTwoRepetitions(t *testing.T) {
	study := bench.StudyTailCrossingShortLC
	dir := t.TempDir()
	rows := scheduledRows(study, level1, "same", scheduleSeedA)
	paths := []string{
		writeRaw(t, dir, "raw-be01-shared-1.jsonl", rows),
		writeRaw(t, dir, "raw-be01-shared-2.jsonl", replayedAgain(rows)),
	}
	_, err := loadArmEvidence(paths)
	if err == nil {
		t.Fatal("one trace replayed twice was accepted as two independent repetitions -- the defect this study exists to stop")
	}
	for _, want := range []string{"same trace", "seed"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q: %v", want, err)
		}
	}
}

func TestAPerRepetitionStudyRefusesABaselinePairedWithAnotherSeed(t *testing.T) {
	study := bench.StudyTailCrossingLongLC
	dir := t.TempDir()
	// Repetition 2's baseline was generated from seed A again, so it is not the shared cell's partner.
	paths := []string{
		writeRaw(t, dir, "raw-R1-1.jsonl", scheduledRows(study, bench.ArmR1, "r1-seedA", scheduleSeedA)),
		writeRaw(t, dir, "raw-R1-2.jsonl", replayedAgain(scheduledRows(study, bench.ArmR1, "r1-seedA2", scheduleSeedA))),
		writeRaw(t, dir, "raw-be01-shared-1.jsonl", scheduledRows(study, level1, "sh-seedA", scheduleSeedA)),
		writeRaw(t, dir, "raw-be01-shared-2.jsonl", scheduledRows(study, level1, "sh-seedB", scheduleSeedB)),
	}
	e, err := loadArmEvidence(paths)
	if err != nil {
		t.Fatalf("the fixture was refused before the pairing check could run: %v", err)
	}
	err = e.refuseIfTracesDisagree()
	if err == nil {
		t.Fatal("a baseline and a contended arm with different latency-critical schedules were paired as one repetition")
	}
	for _, want := range []string{"repetition 2", "schedule", bench.ArmR1, level1} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not name %q: %v", want, err)
		}
	}
}

// The control: a study that registered one trace still refuses two, exactly as before.
func TestAOneTraceStudyStillRefusesTwoTraces(t *testing.T) {
	study := bench.StudySharingMatrix
	dir := t.TempDir()
	paths := []string{
		writeRaw(t, dir, "raw-shared-1.jsonl", scheduledRows(study, bench.ArmShared, "seedA", scheduleSeedA)),
		writeRaw(t, dir, "raw-shared-2.jsonl", scheduledRows(study, bench.ArmShared, "seedB", scheduleSeedB)),
	}
	_, err := loadArmEvidence(paths)
	if err == nil || !strings.Contains(err.Error(), "different traces") {
		t.Fatalf("the sharing matrix accepted two traces under one arm: %v", err)
	}
}

// And the per-repetition rule cannot be satisfied by a study that would need it and lacks the flag: the
// identity check above is what a five-repetition, one-seed run of the tail-crossing studies now meets.
func TestEveryRepetitionOfAPerRepetitionArmIsChecked(t *testing.T) {
	study := bench.StudyTailCrossingShortLC
	dir := t.TempDir()
	var paths []string
	// Three repetitions; the third repeats the first's trace. A check that compared only adjacent
	// repetitions, or only against the first, would see one of the two and miss the other shape.
	sums := []string{"a", "b", "a"}
	scheds := [][]int64{scheduleSeedA, scheduleSeedB, scheduleSeedA}
	for i := range sums {
		rows := scheduledRows(study, level1, sums[i], scheds[i])
		for range i {
			rows = replayedAgain(rows)
		}
		paths = append(paths, writeRaw(t, dir, "raw-be01-shared-"+strconv.Itoa(i+1)+".jsonl", rows))
	}
	if _, err := loadArmEvidence(paths); err == nil {
		t.Fatal("repetition 3 replayed repetition 1's trace and was accepted")
	}
}

// A recording cut short is caught by the same pairing, because it drops latency-critical rows.
//
// The per-arm path catches truncation by comparing row counts between contended arms that share a trace.
// These studies hold one contended arm per comparison group, so that comparison has nothing to compare, and
// the late rows a cut recording loses are the ones contention makes slow.
func TestAPerRepetitionStudyRefusesARecordingCutShort(t *testing.T) {
	study := bench.StudyTailCrossingShortLC
	dir := t.TempDir()
	full := scheduledRows(study, level1, "sh-seedB", scheduleSeedB)
	paths := []string{
		writeRaw(t, dir, "raw-R1-1.jsonl", scheduledRows(study, bench.ArmR1, "r1-seedB", scheduleSeedB)),
		writeRaw(t, dir, "raw-be01-shared-1.jsonl", full[:len(full)-2]),
	}
	e, err := loadArmEvidence(paths)
	if err != nil {
		t.Fatalf("the fixture was refused before the pairing check could run: %v", err)
	}
	if err := e.refuseIfTracesDisagree(); err == nil || !strings.Contains(err.Error(), "stopped early") {
		t.Fatalf("a contended repetition missing its last two latency-critical rows was accepted: %v", err)
	}
}

// The runner reads the policy through this subcommand, so what it prints is the contract the shell parses.
func TestStudyTracesPrintsTheRegisteredPolicy(t *testing.T) {
	for study, want := range map[string]string{
		bench.StudyTailCrossingShortLC: "per-repetition",
		bench.StudyTailCrossingLongLC:  "per-repetition",
		bench.StudySharingMatrix:       "one",
	} {
		out, err := captureStdout(t, func() error { return studyTraces([]string{"--study", study}) })
		if err != nil {
			t.Fatalf("study-traces --study %s: %v", study, err)
		}
		if strings.TrimSpace(out) != want {
			t.Errorf("study-traces --study %s printed %q; want %q", study, out, want)
		}
	}
	if err := studyTraces([]string{"--study", "no-such-study"}); err == nil {
		t.Error("an unregistered study was given a trace policy")
	}
}

// Every BE level of a repetition is paired with that repetition's baseline, not only the first.
//
// Independent arrivals give one repetition the same latency-critical schedule at every BE level, so the
// baseline is every level's partner; a check that compared it with one level would let another level's
// recording, cut short or drawn from another seed, through.
func TestEveryBELevelIsPairedWithTheRepetitionsBaseline(t *testing.T) {
	study := bench.StudyTailCrossingShortLC
	dir := t.TempDir()
	level3 := bench.TailCrossingArm(3)
	paths := []string{
		writeRaw(t, dir, "raw-R1-1.jsonl", scheduledRows(study, bench.ArmR1, "r1", scheduleSeedA)),
		writeRaw(t, dir, "raw-be01-shared-1.jsonl", scheduledRows(study, level1, "l1", scheduleSeedA)),
		writeRaw(t, dir, "raw-be03-shared-1.jsonl", scheduledRows(study, level3, "l3", scheduleSeedA)),
	}
	e, err := loadArmEvidence(paths)
	if err != nil {
		t.Fatalf("a baseline and two levels of one repetition were refused: %v", err)
	}
	if err := e.refuseIfTracesDisagree(); err != nil {
		t.Fatalf("two levels sharing the baseline's schedule were refused: %v", err)
	}
	// The third level's recording stopped two requests early.
	cut := scheduledRows(study, level3, "l3", scheduleSeedA)
	paths[2] = writeRaw(t, dir, "raw-be03-shared-1.jsonl", cut[:len(cut)-2])
	e, err = loadArmEvidence(paths)
	if err != nil {
		t.Fatalf("the cut fixture was refused before the pairing check: %v", err)
	}
	if err := e.refuseIfTracesDisagree(); err == nil || !strings.Contains(err.Error(), level3) {
		t.Errorf("a cut recording at the third level passed because only the first level was compared: %v", err)
	}
}

// The report reads a sweep's evidence through to the readings block, end to end through the real command.
func TestTheReportPrintsTheTailCrossingReadingsForASweep(t *testing.T) {
	study := bench.StudyTailCrossingShortLC
	dir := t.TempDir()
	// 120 latency-critical requests per trace, so every trace clears the per-trace tail floor.
	sched := func(seed int64) []int64 {
		out := make([]int64, 120)
		for i := range out {
			out[i] = int64(i)*500 + seed
		}
		return out
	}
	paths := []string{
		writeRaw(t, dir, "raw-R1-1.jsonl", scheduledRows(study, bench.ArmR1, "r1a", sched(1))),
		writeRaw(t, dir, "raw-R1-2.jsonl", scheduledRows(study, bench.ArmR1, "r1b", sched(2))),
		writeRaw(t, dir, "raw-be01-shared-1.jsonl", scheduledRows(study, level1, "l1a", sched(1))),
		writeRaw(t, dir, "raw-be01-shared-2.jsonl", scheduledRows(study, level1, "l1b", sched(2))),
	}
	outPath := filepath.Join(dir, "report.txt")
	args := []string{"-out", outPath}
	for _, p := range paths {
		args = append(args, "-raw", p)
	}
	if err := report(args); err != nil {
		t.Fatalf("the report refused a paired two-trace sweep: %v", err)
	}
	body, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"TAIL-CROSSING READINGS (" + study + ")", level1, "pooled"} {
		if !strings.Contains(string(body), want) {
			t.Errorf("the report does not contain %q:\n%s", want, body)
		}
	}
}

// The same through the real command: the identities are only known to the loader, so this is what proves
// they reach the reading.
func TestTheReportRefusesALevelWhoseRepetitionsAreNotTheBaselines(t *testing.T) {
	study := bench.StudyTailCrossingShortLC
	dir := t.TempDir()
	sched := func(seed int64) []int64 {
		out := make([]int64, 120)
		for i := range out {
			out[i] = int64(i)*500 + seed
		}
		return out
	}
	paths := []string{
		writeRaw(t, dir, "raw-R1-1.jsonl", scheduledRows(study, bench.ArmR1, "r1a", sched(1))),
		writeRaw(t, dir, "raw-R1-2.jsonl", scheduledRows(study, bench.ArmR1, "r1b", sched(2))),
		writeRaw(t, dir, "raw-be01-shared-1.jsonl", scheduledRows(study, level1, "l1a", sched(1))),
		writeRaw(t, dir, "raw-be01-shared-3.jsonl", scheduledRows(study, level1, "l1c", sched(3))),
	}
	outPath := filepath.Join(dir, "report.txt")
	args := []string{"-out", outPath}
	for _, p := range paths {
		args = append(args, "-raw", p)
	}
	_ = report(args)
	body, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("the report wrote nothing: %v", err)
	}
	if !strings.Contains(string(body), "NOT READ: "+level1+" pooled repetitions [1 3]") {
		t.Errorf("a level holding repetitions 1 and 3 was read against a baseline holding 1 and 2:\n%s", body)
	}
}
