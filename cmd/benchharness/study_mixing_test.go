package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// writeRaw writes one repetition's worth of rows and returns the file path.
func writeRaw(t *testing.T, dir, name string, rows []bench.RawRow) string {
	t.Helper()
	var b strings.Builder
	for _, r := range rows {
		enc, err := json.Marshal(r)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		b.Write(enc)
		b.WriteByte('\n')
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

// rowsFor builds a minimal but complete repetition for one arm of one study.
func rowsFor(study, arm string, checksum string) []bench.RawRow {
	const sec = int64(1_000_000_000)
	rows := make([]bench.RawRow, 0, 4)
	for i := range 4 {
		base := sec + int64(i)*sec
		rows = append(rows, bench.RawRow{
			Index: i, Study: study, Arm: arm, Tenant: "premium-1",
			SendUnixNanos: base, FirstTokenUnixNanos: base + 100_000_000, EndUnixNanos: base + sec,
			EstInputTokens: 50, OutputTokens: 5, HTTPStatus: 200,
			TraceChecksum: checksum, LongThreshold: 4096, MatchTolerance: 0.05,
		})
	}
	return rows
}

// TestReportRefusesToPoolTwoStudies is the check that stops a glob from answering a question nobody asked.
//
// The runner writes one raw file per arm per repetition into a run directory, and the report is invoked
// with a glob over them. Nothing prevented that glob from spanning two experiments, and nothing
// downstream would have noticed: arm names are not unique across studies, so rows from a no-gateway
// engine sweep and rows that crossed a gateway hop would have been summarised into the same table.
func TestReportRefusesToPoolTwoStudies(t *testing.T) {
	dir := t.TempDir()
	a := writeRaw(t, dir, "raw-R1-1.jsonl", rowsFor(bench.StudyM5BGateway, "R1", "T"))
	b := writeRaw(t, dir, "raw-mbt-0512-priority-1.jsonl",
		rowsFor(bench.StudyPriceOfProtection, "mbt-0512-priority", "T"))

	_, err := loadArmEvidence([]string{a, b})
	if err == nil {
		t.Fatal("two studies were pooled into one report")
	}
	for _, want := range []string{bench.StudyM5BGateway, bench.StudyPriceOfProtection, "different"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal does not mention %q: %v", want, err)
		}
	}
}

// TestReportNamesTheFileThatDisagrees checks the refusal is actionable rather than merely correct.
//
// An operator at the end of a paid session reads this message and has to know which file to remove. A
// refusal that says only "the studies differ" costs them the walk through a run directory, which is the
// same defect the missing-arm warning was written to fix one level up.
func TestReportNamesTheFileThatDisagrees(t *testing.T) {
	dir := t.TempDir()
	a := writeRaw(t, dir, "raw-off-1.jsonl", rowsFor(bench.StudyM5BGateway, "off", "T"))
	b := writeRaw(t, dir, "raw-default-fcfs-1.jsonl",
		rowsFor(bench.StudyPriceOfProtection, "default-fcfs", "T"))

	_, err := loadArmEvidence([]string{a, b})
	if err == nil {
		t.Fatal("two studies were pooled into one report")
	}
	if !strings.Contains(err.Error(), filepath.Base(a)) || !strings.Contains(err.Error(), filepath.Base(b)) {
		t.Errorf("refusal names neither file: %v", err)
	}
}

// TestUnlabelledEvidenceStillReports keeps the already-paid raw files readable.
//
// Every raw file written before the study field existed carries an empty string. Refusing those would
// make the 2026-09-03 evidence -- four paid repetitions of four arms -- unreadable by the tool that
// produced it, to guard against a mixing that cannot happen among files that are all the same study.
func TestUnlabelledEvidenceStillReports(t *testing.T) {
	dir := t.TempDir()
	a := writeRaw(t, dir, "raw-R1-1.jsonl", rowsFor("", "R1", "T"))
	b := writeRaw(t, dir, "raw-off-1.jsonl", rowsFor("", "off", "T"))

	if _, err := loadArmEvidence([]string{a, b}); err != nil {
		t.Fatalf("unlabelled evidence must still be readable: %v", err)
	}
}

// TestUnlabelledEvidenceCannotBeMixedWithANewStudy closes the hole the previous test opens.
//
// Reading an empty study as M5-b is what keeps old evidence usable. It must not also make old evidence
// poolable with a new experiment's, which is exactly the mistake an operator makes by globbing a
// directory that has both.
func TestUnlabelledEvidenceCannotBeMixedWithANewStudy(t *testing.T) {
	dir := t.TempDir()
	a := writeRaw(t, dir, "raw-R1-1.jsonl", rowsFor("", "R1", "T"))
	b := writeRaw(t, dir, "raw-mbt-0256-fcfs-1.jsonl",
		rowsFor(bench.StudyPriceOfProtection, "mbt-0256-fcfs", "T"))

	_, err := loadArmEvidence([]string{a, b})
	if err == nil {
		t.Fatal("unlabelled evidence was pooled with a different study")
	}
	if !strings.Contains(err.Error(), "predates") {
		t.Errorf("refusal should say the unlabelled side predates the field: %v", err)
	}
}

// TestLegacyAndExplicitM5BEvidencePool keeps a legitimate comparison from being refused.
//
// The four paid repetitions of 2026-09-03 carry no study label. Anything replayed from now on carries
// "m5b-gateway-v1" explicitly. Those are the same experiment, and a run that re-measures one arm must be
// comparable with the arms already paid for -- which is the whole reason unlabelled evidence stays
// readable. The pooling check compared the raw strings and refused the pair in either order.
func TestLegacyAndExplicitM5BEvidencePool(t *testing.T) {
	dir := t.TempDir()
	legacy := writeRaw(t, dir, "raw-R1-1.jsonl", rowsFor("", "R1", "T"))
	explicit := writeRaw(t, dir, "raw-off-1.jsonl", rowsFor(bench.StudyM5BGateway, "off", "T"))

	for _, order := range [][]string{{legacy, explicit}, {explicit, legacy}} {
		if _, err := loadArmEvidence(order); err != nil {
			t.Errorf("unlabelled and explicitly labelled M5-b evidence must pool: %v", err)
		}
	}
}

// TestAFileMixingStudiesIsRefused closes the hole that reading only the first row left open.
//
// loadArmEvidence took rows[0].Study as the file's study. Concatenating a legacy row and a
// price-of-protection row into one file therefore passed, and ReadRawRows sorts by index, so which row
// lands first is not even under the operator's control among ties -- the same two files could be accepted
// or refused depending on an ordering nobody chose.
func TestAFileMixingStudiesIsRefused(t *testing.T) {
	dir := t.TempDir()
	mixed := append(rowsFor(bench.StudyM5BGateway, "R1", "T"),
		rowsFor(bench.StudyPriceOfProtection, "R1", "T")...)
	path := writeRaw(t, dir, "raw-R1-1.jsonl", mixed)

	_, err := loadArmEvidence([]string{path})
	if err == nil {
		t.Fatal("a single file carrying two studies was accepted")
	}
	if !strings.Contains(err.Error(), "mixes studies within one file") {
		t.Errorf("refusal does not name the defect: %v", err)
	}
}

// TestThePriceOfProtectionStudyReportsItsOwnArms is the check that the new study can report at all.
//
// summarize walked a hard-coded list of M5-b's four arm names, so nine of this study's ten arms were
// dropped on the floor -- silently, since a missing arm is not an error there -- and the only survivor was
// R1, the one name the two studies share. The report then complained that static-cap and kv-aware were
// absent and called the run disqualified, which is a verdict about an experiment that was not being run.
func TestThePriceOfProtectionStudyReportsItsOwnArms(t *testing.T) {
	dir := t.TempDir()
	study, _ := bench.LookupStudy(bench.StudyPriceOfProtection)

	var files []string
	for _, arm := range study.Arms {
		files = append(files, writeRaw(t, dir, "raw-"+arm+"-1.jsonl",
			rowsFor(bench.StudyPriceOfProtection, arm, "T")))
	}

	e, err := loadArmEvidence(files)
	if err != nil {
		t.Fatalf("loading the sweep's own arms failed: %v", err)
	}
	summaries, _ := e.summarize()
	if len(summaries) != len(study.Arms) {
		var got []string
		for _, s := range summaries {
			got = append(got, s.Arm)
		}
		t.Fatalf("summarized %d of %d arms: %v", len(summaries), len(study.Arms), got)
	}
	for i, s := range summaries {
		if s.Arm != study.Arms[i] {
			t.Errorf("arm %d is %q, want %q: the report order must be the study's", i, s.Arm, study.Arms[i])
		}
	}
}

// withPriority returns a copy of rows carrying a scheduling priority.
func withPriority(rows []bench.RawRow, p int) []bench.RawRow {
	out := make([]bench.RawRow, len(rows))
	copy(out, rows)
	for i := range out {
		v := p
		out[i].Priority = &v
	}
	return out
}

// TestTreatedAndUntreatedRepetitionsAreNotPooled keeps a comparison from being reported as a repetition.
//
// Replay one manifest twice, once with --priorities and once without, and every field the report used for
// identity was equal: same study, same arm, same trace checksum, same tolerance. The two files pooled as
// repetitions of one condition, and the bootstrap resampled across a treated and an untreated run to
// produce an interval for something that was never measured twice.
func TestTreatedAndUntreatedRepetitionsAreNotPooled(t *testing.T) {
	dir := t.TempDir()
	base := rowsFor(bench.StudyPriceOfProtection, "mbt-0512-priority", "T")
	untreated := writeRaw(t, dir, "raw-mbt-0512-priority-1.jsonl", base)
	treated := writeRaw(t, dir, "raw-mbt-0512-priority-2.jsonl", withPriority(base, 0))

	_, err := loadArmEvidence([]string{untreated, treated})
	if err == nil {
		t.Fatal("a treated and an untreated replay were pooled as repetitions of one arm")
	}
	if !strings.Contains(err.Error(), "different priority treatments") {
		t.Errorf("refusal does not name the defect: %v", err)
	}
}

// TestRepetitionsUnderTheSameTreatmentStillPool keeps the check from rejecting the normal case.
func TestRepetitionsUnderTheSameTreatmentStillPool(t *testing.T) {
	dir := t.TempDir()
	base := rowsFor(bench.StudyPriceOfProtection, "mbt-0512-priority", "T")
	a := writeRaw(t, dir, "raw-mbt-0512-priority-1.jsonl", withPriority(base, 0))
	b := writeRaw(t, dir, "raw-mbt-0512-priority-2.jsonl", withPriority(base, 0))

	if _, err := loadArmEvidence([]string{a, b}); err != nil {
		t.Fatalf("two repetitions under one treatment must pool: %v", err)
	}
}
