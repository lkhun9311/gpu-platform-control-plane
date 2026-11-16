package bench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestCalibrationEvidenceRefusesAnArtifactNoLadderProduced: λ0 is frozen only when the recorded rungs, replayed through
// the registered ladder, give exactly the artifact's outcome (#636).
func TestCalibrationEvidenceRefusesAnArtifactNoLadderProduced(t *testing.T) {
	d := versionAsyncDesign()
	verify := func(dir string, art CalibrationArtifact) error {
		return d.VerifyCalibrationEvidence(dir, *versionStudySampling(), art)
	}
	genuine := func(t *testing.T) (string, CalibrationArtifact) {
		dir := t.TempDir()
		return dir, ladderEvidence(t, dir, 2.0)
	}
	t.Run("a ladder's own evidence passes", func(t *testing.T) {
		dir, art := genuine(t)
		if err := verify(dir, art); err != nil {
			t.Fatal(err)
		}
	})
	for name, c := range map[string]struct {
		tamper func(t *testing.T, dir string, art *CalibrationArtifact)
		want   string
	}{
		"hand-written, no rungs": {func(_ *testing.T, _ string, art *CalibrationArtifact) { art.Rungs = nil }, "records no rung"},
		"no lock": {func(t *testing.T, dir string, _ *CalibrationArtifact) {
			if err := os.Remove(filepath.Join(dir, CalibrationLockFile)); err != nil {
				t.Fatal(err)
			}
		}, "no calibration ran"},
		"a rung record missing": {func(t *testing.T, dir string, _ *CalibrationArtifact) {
			if err := os.Remove(filepath.Join(dir, CalibrationRungFile(2))); err != nil {
				t.Fatal(err)
			}
		}, "rung 2 evidence"},
		"a rung's rows missing": {func(t *testing.T, dir string, _ *CalibrationArtifact) {
			if err := os.Remove(filepath.Join(dir, CalibrationRungRowsFile(1))); err != nil {
				t.Fatal(err)
			}
		}, "rung 1 rows"},
		"λ0 edited": {func(_ *testing.T, _ string, art *CalibrationArtifact) { art.StableRateRequestsPerSec *= 1.2 }, "resolve to"},
		"a rung's class edited": {func(_ *testing.T, _ string, art *CalibrationArtifact) {
			art.Rungs[len(art.Rungs)-1].Class = RungUnstable
		}, "the artifact says"},
		"rungs dropped":        {func(_ *testing.T, _ string, art *CalibrationArtifact) { art.Rungs = art.Rungs[:len(art.Rungs)-1] }, "does not record"},
		"a rung's rate edited": {func(_ *testing.T, _ string, art *CalibrationArtifact) { art.Rungs[0].Rate = 0.4 }, "the artifact says"},
	} {
		t.Run(name, func(t *testing.T) {
			dir, art := genuine(t)
			c.tamper(t, dir, &art)
			err := verify(dir, art)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err %v, want a refusal mentioning %q", err, c.want)
			}
		})
	}
}

// readRungEvidence reads back one rung's record and rows as the fixture wrote them.
func readRungEvidence(t *testing.T, dir string, ordinal int) (CalibrationRungRecord, []RawRow) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, CalibrationRungFile(ordinal)))
	if err != nil {
		t.Fatal(err)
	}
	var rec CalibrationRungRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(filepath.Join(dir, CalibrationRungRowsFile(ordinal)))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	rows, err := ReadRawRows(f)
	if err != nil {
		t.Fatal(err)
	}
	return rec, rows
}

// observed is the record a rung's rows would have given at its rate, so a tamper that keeps record and rows consistent
// reaches the check behind the observation's.
func observed(t *testing.T, rec CalibrationRungRecord, rows []RawRow) CalibrationRungRecord {
	t.Helper()
	o, err := ObserveRung(rows, rec.Observation.OfferedRate, versionAsyncDesign().Calibration, rec.Observation.StartedDrained)
	if err != nil {
		t.Fatal(err)
	}
	rec.Observation = o
	return rec
}

// TestCalibrationEvidenceRefusesRowsThatDoNotGiveTheRecord: a rung certifies its class only through the rows it recorded,
// so λ0 is frozen only when every rung's rows, read again under the registered rule, give its record (#645).
func TestCalibrationEvidenceRefusesRowsThatDoNotGiveTheRecord(t *testing.T) {
	d := versionAsyncDesign()
	verify := func(dir string, art CalibrationArtifact) error {
		return d.VerifyCalibrationEvidence(dir, *versionStudySampling(), art)
	}
	t.Run("a rung that never started drained passes with no rows", func(t *testing.T) {
		dir := t.TempDir()
		art := ladderEvidenceWith(t, dir, 2.0, map[int]bool{2: true})
		if art.Rungs[1].Class != RungInvalid || art.Rungs[2].Rate != art.Rungs[1].Rate {
			t.Fatalf("rungs %+v, want rung 2 invalid and rung 3 its retry", art.Rungs)
		}
		if err := verify(dir, art); err != nil {
			t.Fatal(err)
		}
	})
	firstUnstable := func(t *testing.T, art CalibrationArtifact) int {
		for _, r := range art.Rungs {
			if r.Class == RungUnstable {
				return r.Ordinal
			}
		}
		t.Fatal("the ladder ran no unstable rung")
		return 0
	}
	for name, c := range map[string]struct {
		undrained map[int]bool
		tamper    func(t *testing.T, dir string, art *CalibrationArtifact)
		want      string
	}{
		"a rung's rows file empty": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, _ := readRungEvidence(t, dir, 1)
			writeRungEvidence(t, dir, rec, nil)
		}, "rung 1 rows: not the rung's trace"},
		"an undrained rung's reason removed": {map[int]bool{2: true}, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, _ := readRungEvidence(t, dir, 2)
			rec.Error = ""
			writeRungEvidence(t, dir, rec, nil)
		}, "rung 2 rows: not the rung's trace"},
		"an undrained rung's observation filled in": {map[int]bool{2: true}, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, _ := readRungEvidence(t, dir, 2)
			rec.Observation.Arrivals = 90
			writeRungEvidence(t, dir, rec, nil)
		}, "none were sent"},
		"the recorded observation edited": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, rows := readRungEvidence(t, dir, 1)
			rec.Observation.Departures++
			writeRungEvidence(t, dir, rec, rows)
		}, "observation"},
		"rows that give a different observation": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, rows := readRungEvidence(t, dir, 1)
			// A window arrival that timed out is a failure the record does not count.
			for i := range rows {
				if *rows[i].Clock.IntendedNanos >= int64(d.Calibration.WarmupSeconds)*int64(time.Second) {
					rows[i].Disposition, rows[i].ErrorKind, rows[i].HTTPStatus, rows[i].StreamTerminated = "timeout", "timeout", 0, false
					break
				}
			}
			writeRungEvidence(t, dir, rec, rows)
		}, "observation"},
		"a record whose class is not what its rows classify as": {nil, func(t *testing.T, dir string, art *CalibrationArtifact) {
			// Unreliable takes the same ladder branch as unstable, so only the rows can tell the two apart.
			u := firstUnstable(t, *art)
			rec, rows := readRungEvidence(t, dir, u)
			rec.Class = RungUnreliable
			writeRungEvidence(t, dir, rec, rows)
			art.Rungs[u-1].Class = RungUnreliable
		}, "classify"},
		"rows from another rate": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, _ := readRungEvidence(t, dir, 1)
			trace, err := d.CalibrationTrace(1, rec.Observation.OfferedRate*0.9)
			if err != nil {
				t.Fatal(err)
			}
			rows := rungRows(trace, 1, true)
			writeRungEvidence(t, dir, observed(t, rec, rows), rows)
		}, "trace"},
		"rows from another rung's trace": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, _ := readRungEvidence(t, dir, 1)
			trace, err := d.CalibrationTrace(2, rec.Observation.OfferedRate)
			if err != nil {
				t.Fatal(err)
			}
			rows := rungRows(trace, 1, true)
			writeRungEvidence(t, dir, observed(t, rec, rows), rows)
		}, "trace"},
		"intended arrivals moved off the trace's offsets": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, rows := readRungEvidence(t, dir, 1)
			for i := range rows {
				in := *rows[i].Clock.IntendedNanos + int64(time.Second)
				rows[i].Clock.IntendedNanos = &in
			}
			writeRungEvidence(t, dir, observed(t, rec, rows), rows)
		}, "intended"},
		"a measured unstable rung relabeled undrained": {nil, func(t *testing.T, dir string, art *CalibrationArtifact) {
			// An invalid rung is retried at the same rate on a fresh trace, so the relabel would buy a second chance at stability.
			u := firstUnstable(t, *art)
			rec, rows := readRungEvidence(t, dir, u)
			rec.Observation.StartedDrained, rec.Class = false, RungInvalid
			writeRungEvidence(t, dir, rec, rows)
			art.Rungs[u-1].Class = RungInvalid
		}, "drained"},
		"requests ending before they were due": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, rows := readRungEvidence(t, dir, 1)
			for i := range rows {
				end := *rows[i].Clock.IntendedNanos - int64(time.Millisecond)
				rows[i].Clock.SendNanos, rows[i].Clock.TerminalNanos = &end, &end
			}
			writeRungEvidence(t, dir, observed(t, rec, rows), rows)
		}, "before its intended arrival"},
		"rows of two replays": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, rows := readRungEvidence(t, dir, 1)
			rows[len(rows)-1].Clock.OriginUnixNanos++
			writeRungEvidence(t, dir, rec, rows)
		}, "another replay"},
		"a request the session cancelled": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, rows := readRungEvidence(t, dir, 1)
			last := len(rows) - 1
			rows[last].Disposition, rows[last].ErrorKind, rows[last].HTTPStatus, rows[last].StreamTerminated = errKindCancelled, errKindCancelled, 0, false
			writeRungEvidence(t, dir, observed(t, rec, rows), rows)
		}, "session ended"},
		"a reason its rows do not give": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, rows := readRungEvidence(t, dir, 1)
			rec.Error = "row 3 does not conform"
			writeRungEvidence(t, dir, rec, rows)
		}, "rows conform"},
		"a stable record over rows that did not do the registered work": {nil, func(t *testing.T, dir string, _ *CalibrationArtifact) {
			rec, rows := readRungEvidence(t, dir, 1)
			rows[0].EngineOutputTokens--
			writeRungEvidence(t, dir, rec, rows)
		}, "conform"},
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			art := ladderEvidenceWith(t, dir, 2.0, c.undrained)
			if err := verify(dir, art); err != nil {
				t.Fatalf("the untampered ladder was refused: %v", err)
			}
			c.tamper(t, dir, &art)
			err := verify(dir, art)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err %v, want a refusal mentioning %q", err, c.want)
			}
		})
	}
}

// TestWriteCampaignBundleRefusesAHandWrittenCalibration: the rehearsal's finding, end to end through the bundle writer.
func TestWriteCampaignBundleRefusesAHandWrittenCalibration(t *testing.T) {
	dir, in := campaignDir(t, CalibrationArtifact{Resolved: false, Reason: "placeholder"})
	data, _ := json.Marshal(CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 1.0, Reason: "hand-written"})
	if err := os.WriteFile(filepath.Join(dir, CalibrationArtifactFile), data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := WriteCampaignBundle(dir, StudyVersionAsync, in); err == nil || !strings.Contains(err.Error(), "calibration") {
		t.Fatalf("a hand-written calibration artifact gave %v, want a refusal", err)
	}
	if _, err := os.Stat(filepath.Join(dir, CampaignBundleFile)); !os.IsNotExist(err) {
		t.Fatalf("a bundle was written from a hand-written calibration: %v", err)
	}
}
