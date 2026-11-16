package bench

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// The calibration evidence a campaign directory holds, written by version-calibrate and read back before λ0 is frozen.
const (
	// CalibrationArtifactFile holds the ladder's outcome and every rung it ran.
	CalibrationArtifactFile = "calibration.json"
	// CalibrationLockFile reserves the directory for one calibration and stays as the record that it ran there.
	CalibrationLockFile = "calibration.lock"
)

// CalibrationRungFile and CalibrationRungRowsFile name one rung's record and its raw rows.
func CalibrationRungFile(ordinal int) string { return fmt.Sprintf("calibration-rung-%d.json", ordinal) }

func CalibrationRungRowsFile(ordinal int) string {
	return fmt.Sprintf("calibration-rung-%d.jsonl", ordinal)
}

// CalibrationRungRecord is one rung's evidence file: its observation, class and any reason it could not measure the engine.
type CalibrationRungRecord struct {
	Ordinal     int             `json:"ordinal"`
	Class       RungClass       `json:"class"`
	Observation RungObservation `json:"observation"`
	Error       string          `json:"error,omitempty"`
}

// VerifyCalibrationEvidence checks that art is what this ladder produces from the rungs recorded in dir (#636, #645).
//
// A resolved flag and a hash say nothing about where λ0 came from: a hand-written artifact passed both.
// So the lock must be there, every rung the artifact lists must have its record and rows with the same ordinal,
// rate and class, every record must be what its rows give under the registered rule, and running the ladder again
// on those classes must reach the same outcome and the same λ0.
func (d VersionStudyDesign) VerifyCalibrationEvidence(dir string, sampling SamplingPolicy, art CalibrationArtifact) error {
	if _, err := os.Stat(filepath.Join(dir, CalibrationLockFile)); err != nil {
		return fmt.Errorf("no calibration ran in %s: %w", dir, err)
	}
	if len(art.Rungs) == 0 {
		return errors.New("the calibration artifact records no rung, so no ladder produced it")
	}
	for i, r := range art.Rungs {
		if r.Ordinal != i+1 {
			return fmt.Errorf("the artifact's rung %d has ordinal %d", i+1, r.Ordinal)
		}
		data, err := os.ReadFile(filepath.Join(dir, CalibrationRungFile(r.Ordinal)))
		if err != nil {
			return fmt.Errorf("rung %d evidence: %w", r.Ordinal, err)
		}
		var rec CalibrationRungRecord
		dec := json.NewDecoder(bytes.NewReader(data))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&rec); err != nil {
			return fmt.Errorf("rung %d evidence: %w", r.Ordinal, err)
		}
		if rec.Ordinal != r.Ordinal || rec.Class != r.Class || rec.Observation.OfferedRate != r.Rate {
			return fmt.Errorf("rung %d evidence records ordinal %d, %s at %v req/s; the artifact says %s at %v req/s",
				r.Ordinal, rec.Ordinal, rec.Class, rec.Observation.OfferedRate, r.Class, r.Rate)
		}
		if err := d.verifyRungRows(dir, sampling, r, rec); err != nil {
			return fmt.Errorf("rung %d rows: %w", r.Ordinal, err)
		}
	}
	mismatch := ""
	replay := d.Calibration.Run(func(rate float64, ordinal int) RungClass {
		if ordinal > len(art.Rungs) || art.Rungs[ordinal-1].Rate != rate {
			if mismatch == "" {
				mismatch = fmt.Sprintf("the ladder runs rung %d at %v req/s, which the artifact does not record", ordinal, rate)
			}
			return RungInvalid
		}
		return art.Rungs[ordinal-1].Class
	})
	switch {
	case mismatch != "":
		return errors.New(mismatch)
	case len(replay.Rungs) != len(art.Rungs):
		return fmt.Errorf("the ladder stops after %d rungs on the recorded classes; the artifact records %d", len(replay.Rungs), len(art.Rungs))
	case replay.Resolved != art.Resolved || replay.Rate != art.StableRateRequestsPerSec:
		return fmt.Errorf("the recorded rungs resolve to %v req/s (resolved %v); the artifact says %v req/s (resolved %v)",
			replay.Rate, replay.Resolved, art.StableRateRequestsPerSec, art.Resolved)
	}
	return nil
}

// verifyRungRows reads one rung's rows and checks that RungRunner.Probe, given them, writes exactly rec.
//
// The class is recomputed from the rows, never read from the record, because a record is only a claim about its rows.
// Whether the engine started drained is the one input the rows cannot show, so it is taken from the record, but only
// one way: Probe sends nothing to an engine that did not drain, so rows that exist were sent to a drained one.
// An undrained flag over real rows would turn a measured verdict into an invalid rung, which the ladder retries at the
// same rate on a fresh trace.
func (d VersionStudyDesign) verifyRungRows(dir string, sampling SamplingPolicy, r CalibrationRung, rec CalibrationRungRecord) error {
	f, err := os.Open(filepath.Join(dir, CalibrationRungRowsFile(r.Ordinal)))
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	rows, err := ReadRawRows(f)
	if err != nil {
		return err
	}
	// Probe sends nothing when the engine never reported an empty queue or the trace could not be made, and records why.
	// Such a rung is accepted on its stated reason, because no row can show that an engine was busy.
	// An honest drain failure does not decide λ0: the ladder runs the same rate again, and that retry is checked from its own rows.
	// A measured rung whose rows were deleted and replaced by such a reason would get the same retry, which could come out
	// stable where the measured rung did not, and no file in this directory tells the two apart.
	if len(rows) == 0 && rec.Error != "" {
		if rec.Class != RungInvalid || rec.Observation != (RungObservation{OfferedRate: r.Rate}) {
			return fmt.Errorf("none were sent (%s), yet the record says %s with %+v", rec.Error, rec.Class, rec.Observation)
		}
		return nil
	}
	trace, err := d.CalibrationTrace(r.Ordinal, r.Rate)
	if err != nil {
		return err
	}
	// The rung's own trace is regenerated from its ordinal and rate, so rows of another rung or another rate are refused
	// even when their record was rewritten to match them.
	if err := ReconcileRecording(trace, rows); err != nil {
		return fmt.Errorf("not the rung's trace: %w", err)
	}
	for _, row := range rows {
		if err := rungRowTimeline(row, rows[0]); err != nil {
			return err
		}
	}
	if !rec.Observation.StartedDrained {
		return errors.New("the record says the rung did not start drained, yet Probe sends a rung's requests only to a drained engine")
	}
	o, err := ObserveRung(rows, r.Rate, d.Calibration, true)
	if err != nil {
		return err
	}
	if o != rec.Observation {
		return fmt.Errorf("the rows give the observation %+v; the record says %+v", o, rec.Observation)
	}
	cls := d.Calibration.ClassifyRung(o)
	runner := &RungRunner{Design: d, Sampling: sampling}
	nonconforming := runner.checkConformance(trace, rows)
	if nonconforming != nil {
		cls = RungInvalid
	}
	switch {
	case rec.Class != cls:
		return fmt.Errorf("the rows classify as %s (nonconforming: %v); the record says %s", cls, nonconforming, rec.Class)
	case nonconforming != nil && rec.Error == "":
		return fmt.Errorf("the rows do not conform (%v), yet the record states no reason", nonconforming)
	case nonconforming == nil && rec.Error != "":
		return fmt.Errorf("the record states %q, yet its rows conform and give no reason", rec.Error)
	}
	return nil
}

// rungRowTimeline refuses a row whose timeline Replay could not have written for a resolved ladder.
//
// ObserveRung places every request by its intended arrival and its terminal, and the reader's clock-order check covers
// neither the intended arrival, the usage trailer, the [DONE] marker nor the replay a row came from.
// A row whose events contradict each other is refused, because a nonconforming or impossible row is what turns a
// measured verdict into an invalid rung.
func rungRowTimeline(row, first RawRow) error {
	switch row.Disposition {
	case DispositionUnsent, errKindCancelled:
		// RunContext makes a ladder unresolved whenever the session ends during a rung, so a resolved one never holds such a row.
		return fmt.Errorf("row %d is %s, so the session ended during the rung", row.Index, row.Disposition)
	}
	c := row.Clock
	due := row.ScheduledOffsetMs * int64(time.Millisecond)
	switch {
	case c == nil || c.IntendedNanos == nil || *c.IntendedNanos != due:
		return fmt.Errorf("row %d's intended arrival is not its trace offset %d ms", row.Index, row.ScheduledOffsetMs)
	case c.OriginUnixNanos != first.Clock.OriginUnixNanos:
		return fmt.Errorf("row %d is timed from another replay than row %d", row.Index, first.Index)
	case c.SendNanos == nil || c.TerminalNanos == nil:
		// Every row but an unsent one was dispatched, and Replay stamps the dispatch and the return of each.
		return fmt.Errorf("row %d carries no send or no terminal time", row.Index)
	case *c.SendNanos < due:
		// Replay dispatches a request only once its intended arrival has passed.
		return fmt.Errorf("row %d is sent before its intended arrival", row.Index)
	}
	// The terminal is taken when the sender returns, after every event of the response.
	for _, at := range []*int64{c.TransportWriteNanos, c.FirstContentNanos, c.LastContentNanos, c.UsageNanos, c.DoneNanos, c.EndNanos} {
		if at != nil && (*at < *c.SendNanos || *at > *c.TerminalNanos) {
			return fmt.Errorf("row %d records an event outside its send and terminal times", row.Index)
		}
	}
	return nil
}
