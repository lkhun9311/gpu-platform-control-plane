package bench

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var journalT0 = time.Date(2026, 11, 20, 3, 0, 0, 0, time.UTC)

func openTestJournal(t *testing.T) (string, *AttemptJournal) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "attempts.jsonl")
	j, err := OpenAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = j.Close() })
	return path, j
}

// TestAttemptJournalIsTheLedger: starts and ends written as they happen fold into the ledger AnalysisSet reads.
func TestAttemptJournalIsTheLedger(t *testing.T) {
	path, j := openTestJournal(t)
	for b := 1; b <= 2; b++ {
		at := journalT0.Add(time.Duration(b) * time.Hour)
		if err := j.Start(b, 0, at); err != nil {
			t.Fatal(err)
		}
		if err := j.End(b, AttemptValid, "", at.Add(30*time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	l, pending, err := ReadAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	if pending != nil || l.Closed || l.CampaignID != "camp-1" || len(l.Attempts) != 2 {
		t.Fatalf("ledger %+v pending %+v", l, pending)
	}
	if a := l.Attempts[1]; a.Block != 2 || a.Status != AttemptValid || !a.StartedAt.Equal(journalT0.Add(2*time.Hour)) {
		t.Fatalf("attempt %+v", a)
	}
}

// TestAnInterruptedAttemptIsRecoveredAsStopped: a block cut off after its start reaches the ledger as stopped,
// so its manifests belong to an attempted block, and nothing can run after it.
func TestAnInterruptedAttemptIsRecoveredAsStopped(t *testing.T) {
	path, j := openTestJournal(t)
	if err := j.Start(1, 0, journalT0); err != nil {
		t.Fatal(err)
	}
	_ = j.Close() // the process dies here

	if _, err := OpenAttemptJournal(path, "camp-1"); err == nil || !strings.Contains(err.Error(), "recover") {
		t.Fatalf("a journal with an unfinished attempt was reopened for new attempts: %v", err)
	}
	rec, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if rec.Recovered == nil || rec.Recovered.Block != 1 {
		t.Fatalf("recovery %+v", rec)
	}
	l, pending, err := ReadAttemptJournal(path, "camp-1")
	if err != nil || pending != nil {
		t.Fatalf("after recovery: pending %+v err %v", pending, err)
	}
	a := l.Attempts[0]
	if a.Status != AttemptStopped || !strings.Contains(a.Reason, "interrupted") || !a.EndedAt.Equal(journalT0.Add(time.Hour)) {
		t.Fatalf("recovered attempt %+v", a)
	}
	j2, err := OpenAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = j2.Close() }()
	if err := j2.Start(2, 0, journalT0.Add(2*time.Hour)); err == nil {
		t.Fatal("a block started after a stopped attempt")
	}
	if err := j2.Archive(journalT0.Add(2 * time.Hour)); err != nil {
		t.Fatal(err)
	}
	l, _, _ = ReadAttemptJournal(path, "camp-1")
	if !l.Closed {
		t.Fatal("archive did not close the ledger")
	}
}

// TestRecoveryDropsOnlyAnUnterminatedTail: a write the crash tore was never acknowledged, so it is cut, reported, and nothing else is touched.
func TestRecoveryDropsOnlyAnUnterminatedTail(t *testing.T) {
	path, j := openTestJournal(t)
	if err := j.Start(1, 0, journalT0); err != nil {
		t.Fatal(err)
	}
	_ = j.Close()
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	_, _ = f.WriteString(`{"kind":"end","block":1,"sta`)
	_ = f.Close()

	if _, _, err := ReadAttemptJournal(path, "camp-1"); err == nil || !strings.Contains(err.Error(), "unterminated") {
		t.Fatalf("a torn tail was read as a record: %v", err)
	}
	rec, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if rec.DroppedTail != `{"kind":"end","block":1,"sta` || rec.Recovered == nil {
		t.Fatalf("recovery %+v", rec)
	}
	l, pending, err := ReadAttemptJournal(path, "camp-1")
	if err != nil || pending != nil || l.Attempts[0].Status != AttemptStopped {
		t.Fatalf("ledger %+v pending %+v err %v", l, pending, err)
	}
}

// TestTheJournalRefusesRecordsThatAreNotASequence: every malformed history is an error, never a guessed ledger.
func TestTheJournalRefusesRecordsThatAreNotASequence(t *testing.T) {
	line := func(s string) string { return s + "\n" }
	for name, c := range map[string]struct {
		body string
		want string
	}{
		"end without start":    {line(`{"kind":"end","campaign":"camp-1","block":1,"status":"valid","at":"2026-11-20T03:00:00Z"}`), "no attempt is open"},
		"two open starts":      {line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T03:00:00Z"}`) + line(`{"kind":"start","campaign":"camp-1","block":2,"at":"2026-11-20T04:00:00Z"}`), "still open"},
		"end of another block": {line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T03:00:00Z"}`) + line(`{"kind":"end","campaign":"camp-1","block":2,"status":"valid","at":"2026-11-20T04:00:00Z"}`), "block 1 is open"},
		"other campaign":       {line(`{"kind":"start","campaign":"camp-2","block":1,"at":"2026-11-20T03:00:00Z"}`), "campaign"},
		"unknown kind":         {line(`{"kind":"resume","campaign":"camp-1","block":1,"at":"2026-11-20T03:00:00Z"}`), "kind"},
		"no time":              {line(`{"kind":"start","campaign":"camp-1","block":1}`), "time"},
		"after archive":        {line(`{"kind":"archive","campaign":"camp-1","at":"2026-11-20T03:00:00Z"}`) + line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T04:00:00Z"}`), "archived"},
		"archive while open":   {line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T03:00:00Z"}`) + line(`{"kind":"archive","campaign":"camp-1","at":"2026-11-20T04:00:00Z"}`), "still open"},
		"start after stopped":  {line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T03:00:00Z"}`) + line(`{"kind":"end","campaign":"camp-1","block":1,"status":"stopped","reason":"deadline","at":"2026-11-20T04:00:00Z"}`) + line(`{"kind":"start","campaign":"camp-1","block":2,"at":"2026-11-20T05:00:00Z"}`), "stopped"},
		"block started twice":  {line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T03:00:00Z"}`) + line(`{"kind":"end","campaign":"camp-1","block":1,"status":"invalid","reason":"lag","at":"2026-11-20T04:00:00Z"}`) + line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T05:00:00Z"}`), "twice"},
		"end at its start":     {line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T03:00:00Z"}`) + line(`{"kind":"end","campaign":"camp-1","block":1,"status":"valid","at":"2026-11-20T03:00:00Z"}`), "not after"},
		"start after a fault":  {line(`{"kind":"fault","campaign":"camp-1","reason":"sync failed","at":"2026-11-20T03:00:00Z"}`) + line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T04:00:00Z"}`), "stopped"},
		"unknown field":        {line(`{"kind":"start","campaign":"camp-1","block":1,"at":"2026-11-20T03:00:00Z","note":"x"}`), "unknown field"},
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "attempts.jsonl")
			if err := os.WriteFile(path, []byte(c.body), 0o644); err != nil {
				t.Fatal(err)
			}
			_, _, err := ReadAttemptJournal(path, "camp-1")
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err %v, want it to mention %q", err, c.want)
			}
		})
	}
}

// TestRecoveryNeedsATimeAfterTheStart: an end at or before the start is not a sequence AnalysisSet could accept.
func TestRecoveryNeedsATimeAfterTheStart(t *testing.T) {
	path, j := openTestJournal(t)
	_ = j.Start(1, 0, journalT0)
	_ = j.Close()
	if _, err := RecoverAttemptJournal(path, "camp-1", journalT0); err == nil {
		t.Fatal("recovered with an end equal to the start")
	}
	if _, pending, _ := ReadAttemptJournal(path, "camp-1"); pending == nil {
		t.Fatal("a refused recovery still wrote an end")
	}
}

// TestARecoveredJournalIsALedgerAnalysisSetAccepts: recovery yields an incomplete pilot, not a ledger the analysis refuses.
func TestARecoveredJournalIsALedgerAnalysisSetAccepts(t *testing.T) {
	path, j := openTestJournal(t)
	_ = j.Start(1, 0, journalT0)
	_ = j.End(1, AttemptValid, "", journalT0.Add(time.Hour))
	_ = j.Start(2, 0, journalT0.Add(2*time.Hour))
	_ = j.Close()
	if _, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	j2, err := OpenAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	if err := j2.Archive(journalT0.Add(4 * time.Hour)); err != nil {
		t.Fatal(err)
	}
	_ = j2.Close()
	l, _, err := ReadAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	set, err := versionAsyncDesign().AnalysisSet(l)
	if len(set) != 1 || set[0] != 1 || err == nil || !strings.Contains(err.Error(), "incomplete pilot") {
		t.Fatalf("analysis set %v, err %v; want block 1 and an incomplete pilot", set, err)
	}
}

// TestAFailedWriteLeavesTheJournalStateUnchanged: a record that never reached the file must not count as attempted.
func TestAFailedWriteLeavesTheJournalStateUnchanged(t *testing.T) {
	_, j := openTestJournal(t)
	_ = j.f.Close()
	if err := j.Start(1, 0, journalT0); err == nil {
		t.Fatal("a start was reported written to a closed file")
	}
	if j.state.seen[1] || j.state.pending != nil {
		t.Fatalf("the failed start changed the state: seen %v pending %+v", j.state.seen, j.state.pending)
	}
}

// tornFile writes only part of the first record it is given and fails, as a full disk or a size limit would.
type tornFile struct {
	*os.File
	tore bool
}

func (f *tornFile) Write(p []byte) (int, error) {
	if !f.tore {
		f.tore = true
		n, _ := f.File.Write(p[:len(p)/2])
		return n, errors.New("no space left on device")
	}
	return f.File.Write(p)
}

// TestAJournalThatFailedAWriteTakesNoMoreRecords: a later record would land on the torn bytes and make the history unreadable.
func TestAJournalThatFailedAWriteTakesNoMoreRecords(t *testing.T) {
	path, j := openTestJournal(t)
	if err := j.Start(1, 0, journalT0); err != nil {
		t.Fatal(err)
	}
	j.f = &tornFile{File: j.f.(*os.File)}
	if err := j.End(1, AttemptValid, "", journalT0.Add(time.Hour)); err == nil {
		t.Fatal("a torn end was reported written")
	}
	if err := j.End(1, AttemptStopped, "recorder failure", journalT0.Add(time.Hour)); err == nil || !strings.Contains(err.Error(), "recover") {
		t.Fatalf("a journal with a torn tail took another record: %v", err)
	}
	_ = j.Close()
	rec, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(2*time.Hour))
	if err != nil || rec.DroppedTail == "" || rec.Fault == "" {
		t.Fatalf("recovery %+v err %v", rec, err)
	}
}

// TestAJournalLineHoldsExactlyOneRecord: trailing bytes after a record are a malformed line, not something to skip.
func TestAJournalLineHoldsExactlyOneRecord(t *testing.T) {
	for name, body := range map[string]string{
		"garbage":       `{"kind":"archive","campaign":"camp-1","at":"2026-11-20T03:00:00Z"} GARBAGE` + "\n",
		"second record": `{"kind":"archive","campaign":"camp-1","at":"2026-11-20T03:00:00Z"}{"kind":"archive"}` + "\n",
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "attempts.jsonl")
			_ = os.WriteFile(path, []byte(body), 0o644)
			if l, _, err := ReadAttemptJournal(path, "camp-1"); err == nil {
				t.Fatalf("read %+v from a line with trailing bytes", l)
			}
		})
	}
}

// syncFailFile writes every byte but fails the sync once, so the record is whole on disk and its durability unknown.
type syncFailFile struct {
	*os.File
	failed bool
}

func (f *syncFailFile) Sync() error {
	if !f.failed {
		f.failed = true
		return errors.New("input/output error")
	}
	return f.File.Sync()
}

// TestARecorderFailureSurvivesRecovery: rule 5 makes a block with any durability error invalid and the campaign stops,
// so a whole valid end whose sync failed must not come back from recovery as valid.
func TestARecorderFailureSurvivesRecovery(t *testing.T) {
	for name, wrap := range map[string]func(*os.File) journalFile{
		"sync fails":    func(f *os.File) journalFile { return &syncFailFile{File: f} },
		"write is torn": func(f *os.File) journalFile { return &tornFile{File: f} },
	} {
		t.Run(name, func(t *testing.T) {
			path, j := openTestJournal(t)
			if err := j.Start(1, 0, journalT0); err != nil {
				t.Fatal(err)
			}
			j.f = wrap(j.f.(*os.File))
			if err := j.End(1, AttemptValid, "", journalT0.Add(time.Hour)); err == nil {
				t.Fatal("a failed end was reported written")
			}
			_ = j.Close()
			if _, err := OpenAttemptJournal(path, "camp-1"); err == nil || !strings.Contains(err.Error(), "recover") {
				t.Fatalf("a journal with a recorded fault was reopened: %v", err)
			}
			if _, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(2*time.Hour)); err != nil {
				t.Fatal(err)
			}
			l, pending, err := ReadAttemptJournal(path, "camp-1")
			if err != nil || pending != nil || len(l.Attempts) != 1 {
				t.Fatalf("ledger %+v pending %+v err %v", l, pending, err)
			}
			if a := l.Attempts[0]; a.Status != AttemptStopped || !strings.Contains(a.Reason, "recorder failure") {
				t.Fatalf("attempt after a recorder failure: %+v", a)
			}
			j2, err := OpenAttemptJournal(path, "camp-1")
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = j2.Close() }()
			if err := j2.Start(2, 0, journalT0.Add(3*time.Hour)); err == nil {
				t.Fatal("a block started after a recorder failure")
			}
			// Recovering again changes nothing: the fault is recorded once.
			if _, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(4*time.Hour)); err != nil {
				t.Fatal(err)
			}
			if l2, _, _ := ReadAttemptJournal(path, "camp-1"); len(l2.Attempts) != 1 || l2.Attempts[0] != l.Attempts[0] {
				t.Fatalf("a second recovery changed the ledger: %+v", l2)
			}
		})
	}
}

// TestAFailedArchiveReopensTheLedgerAndStopsTheCampaign: the archive is not established, and no block may start after the fault.
func TestAFailedArchiveReopensTheLedgerAndStopsTheCampaign(t *testing.T) {
	path, j := openTestJournal(t)
	_ = j.Start(1, 0, journalT0)
	_ = j.End(1, AttemptValid, "", journalT0.Add(time.Hour))
	j.f = &syncFailFile{File: j.f.(*os.File)}
	if err := j.Archive(journalT0.Add(2 * time.Hour)); err == nil {
		t.Fatal("a failed archive was reported written")
	}
	_ = j.Close()
	if _, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	l, _, err := ReadAttemptJournal(path, "camp-1")
	if err != nil || l.Closed || l.Attempts[0].Status != AttemptValid {
		t.Fatalf("ledger %+v err %v; want block 1 valid and the ledger open", l, err)
	}
	j2, err := OpenAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = j2.Close() }()
	if err := j2.Start(2, 0, journalT0.Add(4*time.Hour)); err == nil {
		t.Fatal("a block started after a recorder failure")
	}
	if err := j2.Archive(journalT0.Add(4 * time.Hour)); err != nil {
		t.Fatal(err)
	}
}

// TestRecoveryRecordsAFaultOnceAcrossACrash: a crash after the fault is appended and before its marker is removed leaves both.
func TestRecoveryRecordsAFaultOnceAcrossACrash(t *testing.T) {
	path, j := openTestJournal(t)
	_ = j.Start(1, 0, journalT0)
	j.f = &syncFailFile{File: j.f.(*os.File)}
	_ = j.End(1, AttemptValid, "", journalT0.Add(time.Hour))
	_ = j.Close()
	marker, err := os.ReadFile(faultMarkerPath(path))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(path)
	_ = os.WriteFile(faultMarkerPath(path), marker, 0o644)
	if _, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if after, _ := os.ReadFile(path); string(after) != string(before) {
		t.Fatalf("the fault was appended twice:\n%s", after)
	}
	if _, err := os.Stat(faultMarkerPath(path)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the marker was left: %v", err)
	}
}

// TestAFailedStartIsRecoverable: a start whole on disk with a failed sync is closed at the recovery time, after its start.
func TestAFailedStartIsRecoverable(t *testing.T) {
	path, j := openTestJournal(t)
	j.f = &syncFailFile{File: j.f.(*os.File)}
	if err := j.Start(1, 0, journalT0); err == nil {
		t.Fatal("a failed start was reported written")
	}
	_ = j.Close()
	if _, err := RecoverAttemptJournal(path, "camp-1", journalT0.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	l, pending, err := ReadAttemptJournal(path, "camp-1")
	if err != nil || pending != nil {
		t.Fatalf("pending %+v err %v", pending, err)
	}
	if a := l.Attempts[0]; a.Status != AttemptStopped || !a.EndedAt.Equal(journalT0.Add(time.Hour)) || !strings.Contains(a.Reason, "recorder failure") {
		t.Fatalf("attempt %+v", a)
	}
}

// TestAJournalWithAPendingFaultIsNotRead: a whole archive line whose sync failed must not be read as a closed ledger.
func TestAJournalWithAPendingFaultIsNotRead(t *testing.T) {
	path, j := openTestJournal(t)
	_ = j.Start(1, 0, journalT0)
	_ = j.End(1, AttemptValid, "", journalT0.Add(time.Hour))
	j.f = &syncFailFile{File: j.f.(*os.File)}
	_ = j.Archive(journalT0.Add(2 * time.Hour))
	_ = j.Close()
	if l, _, err := ReadAttemptJournal(path, "camp-1"); err == nil || !strings.Contains(err.Error(), "recover") {
		t.Fatalf("read %+v while a fault was pending: %v", l, err)
	}
}

// TestARecorderFailureLeavesNoVerdict: the stop rules make any recorder error an incomplete pilot, even after every block was valid.
func TestARecorderFailureLeavesNoVerdict(t *testing.T) {
	d := versionAsyncDesign()
	path, j := openTestJournal(t)
	at := journalT0
	for b := 1; b <= d.PlannedBlocks; b++ {
		_ = j.Start(b, 0, at)
		at = at.Add(time.Hour)
		_ = j.End(b, AttemptValid, "", at)
		at = at.Add(time.Minute)
	}
	j.f = &syncFailFile{File: j.f.(*os.File)}
	_ = j.Archive(at)
	_ = j.Close()
	if _, err := RecoverAttemptJournal(path, "camp-1", at.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	j2, err := OpenAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	if err := j2.Archive(at.Add(2 * time.Hour)); err != nil {
		t.Fatal(err)
	}
	_ = j2.Close()
	l, _, err := ReadAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	set, err := d.AnalysisSet(l)
	if len(set) != d.PlannedBlocks || err == nil || !strings.Contains(err.Error(), "recorder failure") {
		t.Fatalf("analysis set %v err %v; want every block and no verdict", set, err)
	}
}

// TestAFailedRecoveryIsItselfARecorderFailure: a recovery whose sync fails must leave a fault a retry still stops on.
func TestAFailedRecoveryIsItselfARecorderFailure(t *testing.T) {
	d := versionAsyncDesign()
	path, j := openTestJournal(t)
	at := journalT0
	for b := 1; b <= d.PlannedBlocks; b++ {
		_ = j.Start(b, 0, at)
		at = at.Add(time.Hour)
		_ = j.End(b, AttemptValid, "", at)
		at = at.Add(time.Minute)
	}
	_ = j.Close()
	// The process died while writing the archive, so no marker was left.
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	_, _ = f.WriteString(`{"kind":"archive","campaign":"camp-1"`)
	_ = f.Close()

	open := openForRecovery
	openForRecovery = func(p string) (recoveryFile, error) {
		f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND, 0)
		return &syncFailFile{File: f}, err
	}
	_, err := RecoverAttemptJournal(path, "camp-1", at.Add(time.Hour))
	openForRecovery = open
	if err == nil {
		t.Fatal("a recovery whose sync failed was reported done")
	}
	if _, err := RecoverAttemptJournal(path, "camp-1", at.Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	j2, err := OpenAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	_ = j2.Archive(at.Add(3 * time.Hour))
	_ = j2.Close()
	l, _, err := ReadAttemptJournal(path, "camp-1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.AnalysisSet(l); err == nil || !strings.Contains(err.Error(), "recorder failure") {
		t.Fatalf("analysis after a failed recovery: %v", err)
	}
}
