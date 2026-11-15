package bench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// campaignDir is a new directory holding a calibration artifact, and the inputs a session would have read by then.
func campaignDir(t *testing.T, art CalibrationArtifact) (string, CampaignInputs) {
	t.Helper()
	dir := t.TempDir()
	data, _ := json.Marshal(art)
	if err := os.WriteFile(filepath.Join(dir, "calibration.json"), data, 0o600); err != nil {
		t.Fatal(err)
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
// It runs on a fixture copy of the study with a 300 s warm-up.
// Under the registered 60 s warm-up, a λ0 low enough to lengthen the window leaves some block's warm-up short of a class (next test).
func TestWriteCampaignBundleLengthensTheWindowFromTheTraces(t *testing.T) {
	st, _ := LookupStudy(StudyVersionAsync)
	d := versionAsyncDesign()
	d.WarmupSeconds = 300
	st.ID, st.Version = studyVersionFixture+"-long-warmup", &d
	studies[st.ID] = st
	t.Cleanup(func() { delete(studies, st.ID) })
	dir, in := campaignDir(t, CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 0.5})
	b, _, err := WriteCampaignBundle(dir, st.ID, in)
	if err != nil {
		t.Fatal(err)
	}
	// 0.6 x 0.5 = 0.3 req/s; 1,000 / (6 x 0.3) is about 556 s, so the window lands near 540-600 s, never at the 300 s minimum.
	if b.WindowSeconds < 480 || b.WindowSeconds > 660 {
		t.Fatalf("window %d s, want about 560 s", b.WindowSeconds)
	}
}

// TestWriteCampaignBundleStopsOnAnUnqualifiedWarmup: under the registered design a low λ0 stops the session before anything is frozen.
func TestWriteCampaignBundleStopsOnAnUnqualifiedWarmup(t *testing.T) {
	dir, in := campaignDir(t, CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 0.5})
	_, _, err := WriteCampaignBundle(dir, StudyVersionAsync, in)
	if err == nil || !strings.Contains(err.Error(), "warm-up") {
		t.Fatalf("err %v, want the warm-up refusal", err)
	}
	if _, statErr := os.Stat(filepath.Join(dir, CampaignBundleFile)); !os.IsNotExist(statErr) {
		t.Fatalf("a bundle was written despite the refusal: %v", statErr)
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
	} {
		t.Run(name, func(t *testing.T) {
			dir, in := campaignDir(t, c.art)
			if c.edit != nil {
				c.edit(&in)
			}
			_, _, err := WriteCampaignBundle(dir, StudyVersionAsync, in)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("err %v, want a refusal mentioning %q", err, c.want)
			}
			// Refused before anything is written, so a later corrected run starts from an empty campaign directory.
			if entries, _ := os.ReadDir(dir); len(entries) != 1 {
				t.Fatalf("the refusal left %d files, want only the calibration artifact", len(entries))
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
