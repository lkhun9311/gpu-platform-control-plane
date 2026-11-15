package bench

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestVersionCellManifestsLoadAndPairThroughTheCampaignCheck: written manifests load one by one and pair as a campaign.
func TestVersionCellManifestsLoadAndPairThroughTheCampaignCheck(t *testing.T) {
	dir, in := campaignDir(t, CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2.0})
	b, sum, err := WriteCampaignBundle(dir, StudyVersionAsync, in)
	if err != nil {
		t.Fatal(err)
	}
	d := versionAsyncDesign()
	var cells []RunManifest
	for block := 1; block <= d.PlannedBlocks; block++ {
		for _, treatment := range versionStudyTreatments {
			for _, load := range []string{LoadL060, LoadL090} {
				m, err := VersionCellManifest(b, sum, dir, block, treatment, load, "http://127.0.0.1:8000")
				if err != nil {
					t.Fatal(err)
				}
				path := filepath.Join(dir, fmt.Sprintf("manifest-b%d-%s.yaml", block, m.Arm))
				if err := WriteManifestFile(path, m); err != nil {
					t.Fatal(err)
				}
				loaded, err := LoadManifest(path)
				if err != nil {
					t.Fatalf("block %d %s: %v", block, m.Arm, err)
				}
				cells = append(cells, *loaded)
			}
		}
	}
	set, err := CheckVersionCampaign(b, sum, plannedLedgerFor(b.CampaignID), cells)
	if err != nil || len(set) != d.PlannedBlocks {
		t.Fatalf("campaign check: set %v err %v", set, err)
	}
}

// plannedLedgerFor is six valid blocks of a campaign, closed.
func plannedLedgerFor(id string) AttemptLedger {
	l := plannedLedger()
	l.CampaignID = id
	return l
}

// TestVersionCellManifestRefuses lists cells no manifest may be written for.
func TestVersionCellManifestRefuses(t *testing.T) {
	dir, in := campaignDir(t, CalibrationArtifact{Resolved: true, StableRateRequestsPerSec: 2.0})
	b, sum, err := WriteCampaignBundle(dir, StudyVersionAsync, in)
	if err != nil {
		t.Fatal(err)
	}
	d := versionAsyncDesign()
	for name, c := range map[string]struct {
		block             int
		treatment, load   string
		sha, engine, want string
	}{
		"block 0":             {0, TreatmentA, LoadL060, sum, "http://e", "block"},
		"block past the plan": {d.PlannedBlocks + d.MaxReplacementBlocks + 1, TreatmentA, LoadL060, sum, "http://e", "block"},
		"unknown treatment":   {1, "D", LoadL060, sum, "http://e", "treatment"},
		"unknown load":        {1, TreatmentA, "l120", sum, "http://e", "load"},
		"no bundle sha":       {1, TreatmentA, LoadL060, "", "http://e", "sha"},
		"no engine url":       {1, TreatmentA, LoadL060, sum, "", "engine"},
	} {
		if _, err := VersionCellManifest(b, c.sha, dir, c.block, c.treatment, c.load, c.engine); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err %v, want a refusal mentioning %q", name, err, c.want)
		}
	}
	m, _ := VersionCellManifest(b, sum, dir, 1, TreatmentA, LoadL060, "http://e")
	path := filepath.Join(dir, "m.yaml")
	if err := WriteManifestFile(path, m); err != nil {
		t.Fatal(err)
	}
	if err := WriteManifestFile(path, m); err == nil || !strings.Contains(err.Error(), "exists") {
		t.Fatalf("second write: %v, want a refusal because the manifest exists", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
}
