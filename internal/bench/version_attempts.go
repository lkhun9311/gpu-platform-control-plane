package bench

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"time"
)

// The attempt journal is the ledger written as it happens.
//
// The ledger used to be written when an attempt ended, so a block cut off after its manifests were written never reached
// it, and CheckVersionCampaign then refused those manifests as cells of a block the ledger never attempted (#612).
// Each attempt's start is now durable before its first cell runs, and a recovery closes an attempt whose end never came.

// Journal record kinds.
const (
	journalStart   = "start"
	journalEnd     = "end"
	journalArchive = "archive"
	// journalFault records that a write or sync of the journal failed.
	// Rule 5 makes any durability error invalidate its block and the stop rules end the campaign, so the fault closes the
	// attempt it touched as stopped: it is not analysed, not replaced, and nothing starts after it.
	journalFault = "fault"
)

// journalRecord is one line of the attempt journal.
type journalRecord struct {
	Kind     string        `json:"kind"`
	Campaign string        `json:"campaign"`
	Block    int           `json:"block,omitempty"`
	Replaces int           `json:"replaces,omitempty"`
	Status   AttemptStatus `json:"status,omitempty"`
	Reason   string        `json:"reason,omitempty"`
	At       time.Time     `json:"at"`
}

// PendingAttempt is an attempt whose start is recorded and whose end is not.
type PendingAttempt struct {
	Block     int
	Replaces  int
	StartedAt time.Time
}

// journalState folds records into the ledger, refusing any history that is not a sequence of whole attempts.
type journalState struct {
	ledger  AttemptLedger
	pending *PendingAttempt
	seen    map[int]bool
	stopped bool
	// last is the last record applied, so recovery can tell a fault it already appended.
	last journalRecord
}

func newJournalState(campaign string) *journalState {
	return &journalState{ledger: AttemptLedger{CampaignID: campaign}, seen: map[int]bool{}}
}

func (s *journalState) apply(r journalRecord) error {
	switch {
	case r.Campaign != s.ledger.CampaignID:
		return fmt.Errorf("record is for campaign %q, the journal for %q", r.Campaign, s.ledger.CampaignID)
	case r.At.IsZero():
		return fmt.Errorf("%s record has no time", r.Kind)
	case s.ledger.Closed && r.Kind != journalFault:
		return fmt.Errorf("%s record after the ledger was archived", r.Kind)
	}
	switch r.Kind {
	case journalStart:
		switch {
		case s.pending != nil:
			return fmt.Errorf("block %d starts while block %d is still open", r.Block, s.pending.Block)
		case s.stopped:
			return fmt.Errorf("block %d starts after the campaign stopped", r.Block)
		case r.Block < 1:
			return fmt.Errorf("start record names block %d", r.Block)
		case s.seen[r.Block]:
			return fmt.Errorf("block %d is started twice; a block is replaced under a new number, never rerun", r.Block)
		}
		s.seen[r.Block] = true
		s.pending = &PendingAttempt{Block: r.Block, Replaces: r.Replaces, StartedAt: r.At}
	case journalEnd:
		switch {
		case s.pending == nil:
			return fmt.Errorf("end of block %d, but no attempt is open", r.Block)
		case r.Block != s.pending.Block:
			return fmt.Errorf("end of block %d, but block %d is open", r.Block, s.pending.Block)
		case r.Status != AttemptValid && r.Status != AttemptInvalid && r.Status != AttemptStopped:
			return fmt.Errorf("end of block %d has status %q", r.Block, r.Status)
		case r.Status != AttemptValid && r.Reason == "":
			return fmt.Errorf("block %d ends %s with no reason", r.Block, r.Status)
		case !r.At.After(s.pending.StartedAt):
			return fmt.Errorf("block %d ends at %s, not after it started at %s", r.Block, r.At.Format(time.RFC3339Nano), s.pending.StartedAt.Format(time.RFC3339Nano))
		}
		s.ledger.Attempts = append(s.ledger.Attempts, BlockAttempt{
			Block: r.Block, Status: r.Status, Reason: r.Reason,
			StartedAt: s.pending.StartedAt, EndedAt: r.At, Replaces: s.pending.Replaces,
		})
		s.pending = nil
		s.stopped = s.stopped || r.Status == AttemptStopped
	case journalArchive:
		if s.pending != nil {
			return fmt.Errorf("archive while block %d is still open; recover it first", s.pending.Block)
		}
		s.ledger.Closed = true
	case journalFault:
		if err := s.applyFault(r); err != nil {
			return err
		}
	default:
		return fmt.Errorf("record kind %q is not start, end, archive or fault", r.Kind)
	}
	s.last = r
	return nil
}

// applyFault closes the attempt the failed record belonged to as stopped, whichever of its records failed.
//
// A failed start whose line never reached the file names a block the journal has not seen: no cell ran, so only the
// campaign stops. A failed end may be whole on disk with its durability unknown, so the attempt it ended is stopped
// whatever status it gave. A failed archive names block 0 and reopens the ledger, since the archive is not established.
func (s *journalState) applyFault(r journalRecord) error {
	if r.Reason == "" {
		return fmt.Errorf("fault record for block %d has no reason", r.Block)
	}
	reason := "recorder failure: " + r.Reason
	n := len(s.ledger.Attempts)
	switch {
	case r.Block == 0:
		if s.pending != nil {
			return fmt.Errorf("fault names no block while block %d is open", s.pending.Block)
		}
		s.ledger.Closed = false
	case s.pending != nil && s.pending.Block == r.Block:
		if !r.At.After(s.pending.StartedAt) {
			return fmt.Errorf("fault of block %d at %s is not after its start", r.Block, r.At.Format(time.RFC3339Nano))
		}
		s.ledger.Attempts = append(s.ledger.Attempts, BlockAttempt{
			Block: r.Block, Status: AttemptStopped, Reason: reason,
			StartedAt: s.pending.StartedAt, EndedAt: r.At, Replaces: s.pending.Replaces,
		})
		s.pending = nil
	case s.pending != nil:
		return fmt.Errorf("fault names block %d while block %d is open", r.Block, s.pending.Block)
	case n > 0 && s.ledger.Attempts[n-1].Block == r.Block:
		s.ledger.Attempts[n-1].Status = AttemptStopped
		s.ledger.Attempts[n-1].Reason = reason
	case !s.seen[r.Block]:
	default:
		return fmt.Errorf("fault names block %d, which is neither open nor the last attempt", r.Block)
	}
	s.ledger.RecorderFaults = append(s.ledger.RecorderFaults, reason)
	s.stopped = true
	return nil
}

// readJournal folds the journal's complete lines and returns any unterminated tail separately.
//
// Every record is written as one line and synced before the caller goes on, so a line without its newline is a write the
// crash tore before it was acknowledged: no step was taken on it, and only recovery may cut it.
func readJournal(path, campaign string) (*journalState, []byte, int64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, 0, err
	}
	whole := int64(bytes.LastIndexByte(data, '\n') + 1)
	s := newJournalState(campaign)
	sc := bufio.NewScanner(bytes.NewReader(data[:whole]))
	sc.Buffer(make([]byte, 0, 4096), 1<<20)
	for n := 1; sc.Scan(); n++ {
		var r journalRecord
		dec := json.NewDecoder(bytes.NewReader(sc.Bytes()))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&r); err != nil {
			return nil, nil, 0, fmt.Errorf("%s line %d: %w", path, n, err)
		}
		// Decode stops after the first value, so anything after it on the line would otherwise be skipped unread.
		if _, err := dec.Token(); err != io.EOF {
			return nil, nil, 0, fmt.Errorf("%s line %d holds more than one record", path, n)
		}
		if err := s.apply(r); err != nil {
			return nil, nil, 0, fmt.Errorf("%s line %d: %w", path, n, err)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, nil, 0, fmt.Errorf("%s: %w", path, err)
	}
	return s, data[whole:], whole, nil
}

// ReadAttemptJournal returns the ledger the journal records and the attempt still open, if any.
//
// An unterminated last line is refused: it is a torn write, and reading past it would decide what the crash left undecided.
func ReadAttemptJournal(path, campaign string) (AttemptLedger, *PendingAttempt, error) {
	// A recorded failure the journal does not yet hold could reverse what it says, such as an archive whose sync failed.
	if _, err := os.Stat(faultMarkerPath(path)); err == nil {
		return AttemptLedger{}, nil, fmt.Errorf("%s records a failed journal write; recover the journal before reading it", faultMarkerPath(path))
	} else if !errors.Is(err, os.ErrNotExist) {
		return AttemptLedger{}, nil, err
	}
	s, tail, _, err := readJournal(path, campaign)
	if err != nil {
		return AttemptLedger{}, nil, err
	}
	if len(tail) > 0 {
		return AttemptLedger{}, nil, fmt.Errorf("%s ends in an unterminated record (%d bytes); run recovery", path, len(tail))
	}
	return s.ledger, s.pending, nil
}

// journalFile is the journal's open file; tests replace it to fail a write partway.
type journalFile interface {
	Write(p []byte) (int, error)
	Sync() error
	Close() error
	Name() string
}

// AttemptJournal appends attempt records, each synced before the call returns.
type AttemptJournal struct {
	f     journalFile
	path  string
	state *journalState
	// failed is the first write or sync error; after it the file may end in torn bytes a later record would be appended onto.
	failed error
}

// OpenAttemptJournal opens or creates a campaign's journal for new attempts.
//
// A journal with an open attempt or a torn tail is refused, because appending to it would put a new attempt beside one
// whose outcome was never recorded; RecoverAttemptJournal closes it first.
func OpenAttemptJournal(path, campaign string) (*AttemptJournal, error) {
	if campaign == "" {
		return nil, errors.New("the journal names no campaign")
	}
	if _, err := os.Stat(faultMarkerPath(path)); err == nil {
		return nil, fmt.Errorf("%s records a failed journal write; recover the journal before starting another attempt", faultMarkerPath(path))
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	// The new entry must survive a crash too, or a synced record could sit in a file the directory never names.
	if err := syncDirOf(path); err != nil {
		_ = f.Close()
		return nil, err
	}
	// The journal continues from the reader's own fold, so a new record is checked against exactly what a reader would accept.
	s, tail, _, err := readJournal(path, campaign)
	if err == nil && len(tail) > 0 {
		err = fmt.Errorf("%s ends in an unterminated record (%d bytes); recover the journal before starting another attempt", path, len(tail))
	}
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	if s.pending != nil {
		_ = f.Close()
		return nil, fmt.Errorf("block %d started at %s and has no recorded end; recover the journal before starting another attempt",
			s.pending.Block, s.pending.StartedAt.Format(time.RFC3339))
	}
	return &AttemptJournal{f: f, path: path, state: s}, nil
}

// Start records that a block attempt has begun; it must return before the attempt's first cell runs.
func (j *AttemptJournal) Start(block, replaces int, at time.Time) error {
	return j.append(journalRecord{Kind: journalStart, Block: block, Replaces: replaces, At: at.UTC()})
}

// End records how the open attempt ended.
func (j *AttemptJournal) End(block int, status AttemptStatus, reason string, at time.Time) error {
	return j.append(journalRecord{Kind: journalEnd, Block: block, Status: status, Reason: reason, At: at.UTC()})
}

// Archive closes the ledger; nothing is recorded after it, and only then may anything be computed from it.
func (j *AttemptJournal) Archive(at time.Time) error {
	return j.append(journalRecord{Kind: journalArchive, At: at.UTC()})
}

// Close closes the journal file.
func (j *AttemptJournal) Close() error { return j.f.Close() }

// append checks the record against the history before writing it, so the file never holds a record its reader would refuse.
func (j *AttemptJournal) append(r journalRecord) error {
	if j.failed != nil {
		return fmt.Errorf("the journal failed a write (%v) and takes no more records; close it and recover it", j.failed)
	}
	r.Campaign = j.state.ledger.CampaignID
	next := *j.state
	next.ledger.Attempts = append([]BlockAttempt(nil), j.state.ledger.Attempts...)
	// A write that fails must leave the state as it was, so the map is copied too.
	next.seen = maps.Clone(j.state.seen)
	if err := next.apply(r); err != nil {
		return err
	}
	if err := writeJournalLine(j.f, r); err != nil {
		j.failed = err
		// The marker goes beside the journal, not into it: the journal may now end in torn bytes.
		block := r.Block
		if r.Kind == journalArchive {
			block = 0
		}
		fault := journalRecord{
			Kind: journalFault, Campaign: r.Campaign, Block: block, At: r.At,
			Reason: fmt.Sprintf("the %s record failed: %v", r.Kind, err),
		}
		if merr := writeFaultMarker(j.path, fault); merr != nil {
			return errors.Join(err, fmt.Errorf("the failure itself could not be recorded, so the runner must stop and report it: %w", merr))
		}
		return err
	}
	*j.state = next
	return nil
}

func writeJournalLine(f journalFile, r journalRecord) error {
	line, err := json.Marshal(r)
	if err != nil {
		return err
	}
	// One write per record, so a crash can tear only the last line, which the reader then sees as unterminated.
	if _, err := f.Write(append(line, '\n')); err != nil {
		return fmt.Errorf("write %s: %w", f.Name(), err)
	}
	if err := f.Sync(); err != nil {
		return fmt.Errorf("sync %s: %w", f.Name(), err)
	}
	return nil
}

// JournalRecovery reports what a recovery changed.
type JournalRecovery struct {
	// DroppedTail is the torn last write that was cut, if there was one.
	DroppedTail string
	// Recovered is the open attempt that was closed as stopped, if there was one.
	Recovered *PendingAttempt
	// Fault is the recorded write failure that was moved into the journal, if there was one.
	Fault string
}

// RecoverAttemptJournal makes a journal left by a crash readable again, and records the open attempt as stopped.
//
// Stopped, not invalid: the registration replaces a block only for an established instrumentation, protocol or external
// failure, and an interrupted runner establishes none of them. So the campaign ends there as an incomplete pilot, and the
// interrupted block's manifests are cells of an attempted block that is not analysed.
// The end is stamped at now, the recovery time, because that is the earliest time the attempt is known to have ended by.
func RecoverAttemptJournal(path, campaign string, now time.Time) (JournalRecovery, error) {
	s, tail, whole, err := readJournal(path, campaign)
	if err != nil {
		return JournalRecovery{}, err
	}
	pendingBlock := 0
	if s.pending != nil {
		pendingBlock = s.pending.Block
	}
	rec, refused, ioErr := recoverJournal(path, campaign, now, s, tail, whole)
	if refused != nil {
		return JournalRecovery{}, refused
	}
	if ioErr == nil {
		return rec, nil
	}
	// Recovery's own failed write is a recorder failure too; without a marker a retry would find nothing left to stop on.
	// A marker already present stops the campaign by itself, so it is kept rather than replaced.
	if _, err := os.Stat(faultMarkerPath(path)); errors.Is(err, os.ErrNotExist) {
		fault := journalRecord{
			Kind: journalFault, Campaign: campaign, Block: pendingBlock, At: now.UTC(),
			Reason: fmt.Sprintf("recovery failed: %v", ioErr),
		}
		if merr := writeFaultMarker(path, fault); merr != nil {
			return JournalRecovery{}, errors.Join(ioErr, fmt.Errorf("the failure itself could not be recorded, so the runner must stop and report it: %w", merr))
		}
	}
	return JournalRecovery{}, ioErr
}

// recoveryFile is the journal opened for recovery; tests replace it to fail a sync.
type recoveryFile interface {
	journalFile
	Truncate(size int64) error
}

var openForRecovery = func(path string) (recoveryFile, error) {
	return os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
}

// recoverJournal returns a refusal, which changed nothing, separately from an I/O failure, which may have.
func recoverJournal(path, campaign string, now time.Time, s *journalState, tail []byte, whole int64) (JournalRecovery, error, error) {
	var rec JournalRecovery
	f, err := openForRecovery(path)
	if err != nil {
		return JournalRecovery{}, nil, err
	}
	defer func() { _ = f.Close() }()
	fault, hasFault, err := readFaultMarker(path)
	if err != nil {
		return JournalRecovery{}, err, nil
	}
	if s.pending != nil && !now.After(s.pending.StartedAt) {
		return JournalRecovery{}, fmt.Errorf("recovery time %s is not after block %d's start at %s",
			now.Format(time.RFC3339Nano), s.pending.Block, s.pending.StartedAt.Format(time.RFC3339Nano)), nil
	}
	if len(tail) > 0 {
		if err := f.Truncate(whole); err != nil {
			return JournalRecovery{}, nil, fmt.Errorf("cut the torn tail of %s: %w", path, err)
		}
		if err := f.Sync(); err != nil {
			return JournalRecovery{}, nil, fmt.Errorf("sync %s: %w", path, err)
		}
		rec.DroppedTail = string(tail)
	}
	if hasFault {
		// The record is stamped at the recovery time, like an interrupted attempt's end: a failed start's marker carries the
		// start's own time, which no end can equal, and the failure's own time stays in the reason.
		fault.Reason = fmt.Sprintf("%s (at %s)", fault.Reason, fault.At.UTC().Format(time.RFC3339Nano))
		fault.At = now.UTC()
		// A crash between appending the fault and removing its marker leaves both; the fault is recorded once.
		if !sameFault(s.last, fault) {
			if err := s.apply(fault); err != nil {
				return JournalRecovery{}, fmt.Errorf("apply %s: %w", faultMarkerPath(path), err), nil
			}
			if err := writeJournalLine(f, fault); err != nil {
				return JournalRecovery{}, nil, err
			}
		}
		rec.Fault = fault.Reason
		// The line may be whole but unsynced from a recovery that crashed, and the marker is the only other copy of the fault.
		if err := f.Sync(); err != nil {
			return JournalRecovery{}, nil, fmt.Errorf("sync %s before removing its fault marker: %w", path, err)
		}
		if err := os.Remove(faultMarkerPath(path)); err != nil {
			return JournalRecovery{}, nil, err
		}
		if err := syncDirOf(path); err != nil {
			return JournalRecovery{}, nil, err
		}
	}
	if s.pending != nil {
		p := *s.pending
		r := journalRecord{
			Kind: journalEnd, Campaign: campaign, Block: p.Block, Status: AttemptStopped, At: now.UTC(),
			Reason: fmt.Sprintf("interrupted: no end was recorded; the attempt was closed by recovery at %s", now.UTC().Format(time.RFC3339)),
		}
		if err := s.apply(r); err != nil {
			return JournalRecovery{}, err, nil
		}
		if err := writeJournalLine(f, r); err != nil {
			return JournalRecovery{}, nil, err
		}
		rec.Recovered = &p
	}
	return rec, nil, nil
}

func syncDirOf(path string) error {
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer func() { _ = d.Close() }()
	return d.Sync()
}

// faultMarkerPath is where a failed journal write is recorded.
func faultMarkerPath(journal string) string { return journal + ".fault" }

// writeFaultMarker records a failed write in a new file, synced with its directory entry.
func writeFaultMarker(journal string, r journalRecord) error {
	line, err := json.Marshal(r)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(faultMarkerPath(journal), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(line, '\n')); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return syncDirOf(journal)
}

// readFaultMarker reads a recorded write failure, refusing a marker it cannot read whole.
func readFaultMarker(journal string) (journalRecord, bool, error) {
	data, err := os.ReadFile(faultMarkerPath(journal))
	if errors.Is(err, os.ErrNotExist) {
		return journalRecord{}, false, nil
	}
	if err != nil {
		return journalRecord{}, false, err
	}
	var r journalRecord
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return journalRecord{}, false, fmt.Errorf("%s: %w", faultMarkerPath(journal), err)
	}
	if _, err := dec.Token(); err != io.EOF || r.Kind != journalFault {
		return journalRecord{}, false, fmt.Errorf("%s does not hold exactly one fault record", faultMarkerPath(journal))
	}
	return r, true, nil
}

// sameFault reports whether the journal's last record is this fault, whatever recovery time stamped it.
func sameFault(a, b journalRecord) bool {
	a.At, b.At = time.Time{}, time.Time{}
	return a == b
}
