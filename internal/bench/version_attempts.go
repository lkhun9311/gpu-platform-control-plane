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
	case s.ledger.Closed:
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
	default:
		return fmt.Errorf("record kind %q is not start, end or archive", r.Kind)
	}
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
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	// The new entry must survive a crash too, or a synced record could sit in a file the directory never names.
	if err := syncDirOf(path); err != nil {
		_ = f.Close()
		return nil, err
	}
	l, pending, err := ReadAttemptJournal(path, campaign)
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	if pending != nil {
		_ = f.Close()
		return nil, fmt.Errorf("block %d started at %s and has no recorded end; recover the journal before starting another attempt",
			pending.Block, pending.StartedAt.Format(time.RFC3339))
	}
	s := newJournalState(campaign)
	s.ledger = l
	for _, a := range l.Attempts {
		s.seen[a.Block] = true
		s.stopped = s.stopped || a.Status == AttemptStopped
	}
	return &AttemptJournal{f: f, state: s}, nil
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
	var rec JournalRecovery
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return JournalRecovery{}, err
	}
	defer func() { _ = f.Close() }()
	if s.pending != nil && !now.After(s.pending.StartedAt) {
		return JournalRecovery{}, fmt.Errorf("recovery time %s is not after block %d's start at %s",
			now.Format(time.RFC3339Nano), s.pending.Block, s.pending.StartedAt.Format(time.RFC3339Nano))
	}
	if len(tail) > 0 {
		if err := f.Truncate(whole); err != nil {
			return JournalRecovery{}, fmt.Errorf("cut the torn tail of %s: %w", path, err)
		}
		if err := f.Sync(); err != nil {
			return JournalRecovery{}, fmt.Errorf("sync %s: %w", path, err)
		}
		rec.DroppedTail = string(tail)
	}
	if s.pending != nil {
		p := *s.pending
		r := journalRecord{
			Kind: journalEnd, Campaign: campaign, Block: p.Block, Status: AttemptStopped, At: now.UTC(),
			Reason: fmt.Sprintf("interrupted: no end was recorded; the attempt was closed by recovery at %s", now.UTC().Format(time.RFC3339)),
		}
		if err := s.apply(r); err != nil {
			return JournalRecovery{}, err
		}
		if err := writeJournalLine(f, r); err != nil {
			return JournalRecovery{}, err
		}
		rec.Recovered = &p
	}
	return rec, nil
}

func syncDirOf(path string) error {
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer func() { _ = d.Close() }()
	return d.Sync()
}
