package bench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCalibrationEvidenceRefusesAnArtifactNoLadderProduced: λ0 is frozen only when the recorded rungs, replayed through
// the registered ladder, give exactly the artifact's outcome (#636).
func TestCalibrationEvidenceRefusesAnArtifactNoLadderProduced(t *testing.T) {
	rule := versionAsyncDesign().Calibration
	genuine := func(t *testing.T) (string, CalibrationArtifact) {
		dir := t.TempDir()
		return dir, ladderEvidence(t, dir, 2.0)
	}
	t.Run("a ladder's own evidence passes", func(t *testing.T) {
		dir, art := genuine(t)
		if err := rule.VerifyCalibrationEvidence(dir, art); err != nil {
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
			err := rule.VerifyCalibrationEvidence(dir, art)
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
