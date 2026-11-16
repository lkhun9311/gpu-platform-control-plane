package bench

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ladderEvidence runs the registered ladder against an engine stable up to capacity, and records its rungs, lock and
// artifact in dir as version-calibrate does, so the bundle's provenance check reads what a real ladder writes.
func ladderEvidence(t *testing.T, dir string, capacity float64) CalibrationArtifact {
	t.Helper()
	return ladderEvidenceWith(t, dir, capacity, nil)
}

// ladderEvidenceWith is ladderEvidence with the rungs whose ordinals undrained names failing to start drained, as a
// busy engine makes them.
func ladderEvidenceWith(t *testing.T, dir string, capacity float64, undrained map[int]bool) CalibrationArtifact {
	t.Helper()
	return ladderEvidenceFor(t, dir, versionAsyncDesign(), capacity, undrained)
}

// ladderEvidenceFor is ladderEvidenceWith under design d's own ladder and rung traces.
func ladderEvidenceFor(t *testing.T, dir string, d VersionStudyDesign, capacity float64, undrained map[int]bool) CalibrationArtifact {
	t.Helper()
	write := func(name string, data []byte) {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(CalibrationLockFile, []byte("2026-11-20T00:00:00Z\n"))
	res := d.Calibration.Run(func(rate float64, ordinal int) RungClass {
		// What RungRunner.Probe reports for a rung that never started: no rows, the offered rate and the reason.
		if undrained[ordinal] {
			writeRungEvidence(t, dir, CalibrationRungRecord{Ordinal: ordinal, Class: RungInvalid,
				Observation: RungObservation{OfferedRate: rate}, Error: "the engine did not report an empty queue within the drain bound"}, nil)
			return RungInvalid
		}
		trace, err := d.CalibrationTrace(ordinal, rate)
		if err != nil {
			t.Fatal(err)
		}
		rows := rungRows(trace, ordinal, rate <= capacity)
		o, err := ObserveRung(rows, rate, d.Calibration, true)
		if err != nil {
			t.Fatal(err)
		}
		cls := d.Calibration.ClassifyRung(o)
		if want := map[bool]RungClass{true: RungStable, false: RungUnstable}[rate <= capacity]; cls != want {
			t.Fatalf("rung %d at %v req/s classifies %s, want %s from an engine stable up to %v", ordinal, rate, cls, want, capacity)
		}
		writeRungEvidence(t, dir, CalibrationRungRecord{Ordinal: ordinal, Class: cls, Observation: o}, rows)
		return cls
	})
	art := CalibrationArtifact{Resolved: res.Resolved, StableRateRequestsPerSec: res.Rate, Reason: res.Reason, Rungs: res.Rungs}
	data, _ := json.Marshal(art)
	write(CalibrationArtifactFile, data)
	return art
}

// rungRows is what replaying one rung's trace records from a conforming engine.
//
// A stable engine ends every request 100 ms after its intended arrival.
// An unstable one ends it at twice its intended arrival, so the backlog grows through the window and its last arrivals
// end after the drain deadline.
func rungRows(trace []TraceRow, ordinal int, stable bool) []RawRow {
	rows := make([]RawRow, 0, len(trace))
	for _, tr := range trace {
		in := tr.OffsetMs * int64(time.Millisecond)
		end := in + 100*int64(time.Millisecond)
		if !stable {
			end = 2*in + 100*int64(time.Millisecond)
		}
		row := conformingRow(tr)
		row.Arm, row.Tenant, row.IsNoisy = fmt.Sprintf("calibration-%d", ordinal), tr.Tenant, tr.IsNoisy
		row.ScheduledOffsetMs, row.PromptLenChars, row.ExactInputTokens = tr.OffsetMs, tr.PromptLenChars, tr.ExactInputTokens
		row.RequestID = RequestIDFor(fmt.Sprintf("cal%d", ordinal), tr.Index)
		row.Clock = &RequestClock{IntendedNanos: &in, SendNanos: &in, TerminalNanos: &end}
		rows = append(rows, row)
	}
	return rows
}

// writeRungEvidence writes one rung's record and rows as version-calibrate's OnRung does.
func writeRungEvidence(t *testing.T, dir string, rec CalibrationRungRecord, rows []RawRow) {
	t.Helper()
	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, CalibrationRungFile(rec.Ordinal)), append(data, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := WriteRawRows(&buf, rows); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, CalibrationRungRowsFile(rec.Ordinal)), buf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}

// campaignDir is a new directory holding a calibration artifact, and the inputs a session would have read by then.
// A resolved artifact with no rungs stands for a ladder run against an engine stable up to its λ0.
func campaignDir(t *testing.T, art CalibrationArtifact) (string, CampaignInputs) {
	t.Helper()
	dir := t.TempDir()
	if art.Resolved && len(art.Rungs) == 0 {
		ladderEvidence(t, dir, art.StableRateRequestsPerSec)
	} else {
		data, _ := json.Marshal(art)
		if err := os.WriteFile(filepath.Join(dir, CalibrationArtifactFile), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir, CampaignInputs{
		CampaignID: "s1-20261120", CalibrationArtifact: "calibration.json",
		PriceUSDPerHour: 1.237, PriceSource: "aws-pricing-api", PriceReadAt: "2026-11-20T01:00:00Z", OtherChargesUSDPerHour: 0.1,
	}
}

// TestWriteCampaignBundleWritesWhatLoadCampaignBundleAccepts: the writer and the checker share no code path but the files, so the round trip is the test.
func TestWriteCampaignBundleWritesWhatLoadCampaignBundleAccepts(t *testing.T) {
	dir, in := campaignDir(t, CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2.0})
	b, sum, err := WriteCampaignBundle(dir, StudyVersionAsync, in)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, CampaignBundleFile))
	if err != nil {
		t.Fatal(err)
	}
	if sum != Checksum(data) {
		t.Fatalf("returned sha %s, the file hashes to %s", sum, Checksum(data))
	}
	d := versionAsyncDesign()
	if want := (d.PlannedBlocks + d.MaxReplacementBlocks) * len(versionStudyLoads); len(b.Traces) != want {
		t.Fatalf("%d traces, want %d: every planned and replacement block at every load", len(b.Traces), want)
	}
	// At λ0 = 2, the 0.6 load offers 1.2 req/s, so six blocks reach 1,000 measured requests inside the 300 s minimum.
	if b.WindowSeconds != 300 {
		t.Fatalf("window %d s, want 300", b.WindowSeconds)
	}
	if _, again, err := LoadCampaignBundle(filepath.Join(dir, CampaignBundleFile)); err != nil || again != sum {
		t.Fatalf("reload: sha %s err %v", again, err)
	}
}

// TestWriteCampaignBundleLengthensTheWindowFromTheTraces: a low λ0 needs a longer window, and the traces alone decide how long.
//
// Before the stratified warm-up, every λ0 low enough for this stopped on an unqualified warm-up under the registered seed.
func TestWriteCampaignBundleLengthensTheWindowFromTheTraces(t *testing.T) {
	dir, in := campaignDir(t, CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 0.5})
	b, _, err := WriteCampaignBundle(dir, StudyVersionAsync, in)
	if err != nil {
		t.Fatal(err)
	}
	// 0.6 x 0.5 = 0.3 req/s; 1,000 / (6 x 0.3) is about 556 s, so the window lands near 540-600 s, never at the 300 s minimum.
	if b.WindowSeconds < 480 || b.WindowSeconds > 660 {
		t.Fatalf("window %d s, want about 560 s", b.WindowSeconds)
	}
}

// TestWriteCampaignBundleStopsBelowTheDesignsRange: a λ0 too low for the floor stops the session before anything is frozen.
//
// The ladder's lowest resolvable rate is its second fallback, 0.125 req/s, which offers 6 x 0.075 x 1,800 = 810 measured
// requests at the longest window, below the floor of 1,000.
func TestWriteCampaignBundleStopsBelowTheDesignsRange(t *testing.T) {
	dir, in := campaignDir(t, CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 0.126})
	before, _ := os.ReadDir(dir)
	_, _, err := WriteCampaignBundle(dir, StudyVersionAsync, in)
	if err == nil || strings.Contains(err.Error(), "calibration") {
		t.Fatalf("a λ0 below the floor gave %v, want a refusal at the floor", err)
	}
	if after, _ := os.ReadDir(dir); len(after) != len(before) {
		t.Fatalf("the refusal left %d files, want only the calibration evidence's %d", len(after), len(before))
	}
}

// TestWriteCampaignBundleRefuses lists inputs from which no bundle may be written.
func TestWriteCampaignBundleRefuses(t *testing.T) {
	for name, c := range map[string]struct {
		art  CalibrationArtifact
		edit func(in *CampaignInputs)
		want string
	}{
		"unresolved calibration": {CalibrationArtifact{Resolved: false, Reason: "no upper bracket"}, nil, "unresolved"},
		"no campaign id":         {CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2}, func(in *CampaignInputs) { in.CampaignID = "" }, "campaignId"},
		"no price":               {CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2}, func(in *CampaignInputs) { in.PriceUSDPerHour = 0 }, "price"},
		"missing artifact":       {CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2}, func(in *CampaignInputs) { in.CalibrationArtifact = "nope.json" }, "calibration"},
		"no price time":          {CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2}, func(in *CampaignInputs) { in.PriceReadAt = "" }, "priceReadAt"},
		"malformed price time":   {CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2}, func(in *CampaignInputs) { in.PriceReadAt = "yesterday" }, "priceReadAt"},
		"negative other charges": {CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2}, func(in *CampaignInputs) { in.OtherChargesUSDPerHour = -1 }, "otherCharges"},
		"infinite price":         {CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2}, func(in *CampaignInputs) { in.PriceUSDPerHour = math.Inf(1) }, "price"},
	} {
		t.Run(name, func(t *testing.T) {
			dir, in := campaignDir(t, c.art)
			if c.edit != nil {
				c.edit(&in)
			}
			before, _ := os.ReadDir(dir)
			_, _, err := WriteCampaignBundle(dir, StudyVersionAsync, in)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err %v, want a refusal mentioning %q", err, c.want)
			}
			// Refused before anything is written, so a later corrected run starts from the calibration evidence alone.
			if after, _ := os.ReadDir(dir); len(after) != len(before) {
				t.Fatalf("the refusal left %d files, want the calibration evidence's %d", len(after), len(before))
			}
		})
	}
	t.Run("an existing bundle is never overwritten", func(t *testing.T) {
		dir, in := campaignDir(t, CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2})
		if _, _, err := WriteCampaignBundle(dir, StudyVersionAsync, in); err != nil {
			t.Fatal(err)
		}
		if _, _, err := WriteCampaignBundle(dir, StudyVersionAsync, in); err == nil || !strings.Contains(err.Error(), "exists") {
			t.Fatalf("second write: %v, want a refusal because the bundle exists", err)
		}
	})
}
