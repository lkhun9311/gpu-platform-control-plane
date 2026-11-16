package bench

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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

// VerifyCalibrationEvidence checks that art is what this ladder produces from the rungs recorded in dir (#636).
//
// A resolved flag and a hash say nothing about where λ0 came from: a hand-written artifact passed both. So the lock
// must be there, every rung the artifact lists must have its record and rows with the same ordinal, rate and class,
// and running the registered ladder again on those recorded classes must reach the same outcome and the same λ0.
func (c CalibrationRule) VerifyCalibrationEvidence(dir string, art CalibrationArtifact) error {
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
		if _, err := os.Stat(filepath.Join(dir, CalibrationRungRowsFile(r.Ordinal))); err != nil {
			return fmt.Errorf("rung %d rows: %w", r.Ordinal, err)
		}
	}
	mismatch := ""
	replay := c.Run(func(rate float64, ordinal int) RungClass {
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
