package bench

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestRehearsalDesignDiffersOnlyInDurations: a rehearsal that changed a rule would rehearse a different study.
func TestRehearsalDesignDiffersOnlyInDurations(t *testing.T) {
	r, d := versionAsyncRehearsalDesign(), versionAsyncDesign()
	r.Rehearsal = false
	r.WarmupSeconds, r.MinMeasureSeconds, r.MaxMeasureSeconds = d.WarmupSeconds, d.MinMeasureSeconds, d.MaxMeasureSeconds
	r.MinOfferedPopulation = d.MinOfferedPopulation
	r.Calibration.WarmupSeconds, r.Calibration.WindowSeconds, r.Calibration.DrainSeconds =
		d.Calibration.WarmupSeconds, d.Calibration.WindowSeconds, d.Calibration.DrainSeconds
	r.Bounds = d.Bounds
	if !reflect.DeepEqual(r, d) {
		t.Fatal("the rehearsal design differs from the registered one in more than durations, the floor and the bounds")
	}
	st, ok := LookupStudy(StudyVersionAsyncRehearsal)
	if !ok || st.Version == nil || !reflect.DeepEqual(*st.Version, versionAsyncRehearsalDesign()) {
		t.Fatal("the rehearsal study is not registered with the rehearsal design")
	}
	paid, _ := LookupStudy(StudyVersionAsync)
	st.ID, st.Version = paid.ID, paid.Version
	if !reflect.DeepEqual(st, paid) {
		t.Fatal("the rehearsal study's registration differs from the paid study's beyond its id and design")
	}
}

// TestOnlyTheRehearsalRefusesAPaidRun: the marker is what the purchase gate reads.
func TestOnlyTheRehearsalRefusesAPaidRun(t *testing.T) {
	if err := versionAsyncRehearsalDesign().PaidRunRefusal(); err == nil {
		t.Fatal("the rehearsal design allows a paid run")
	}
	if err := versionAsyncDesign().PaidRunRefusal(); err != nil {
		t.Fatalf("the registered design refuses a paid run: %v", err)
	}
}

// TestRehearsalBundleFitsAStubCampaign: against an engine stable up to 1.2 req/s, the rehearsal's traces qualify their
// warm-up and the window is the rehearsal's 60 s minimum, so a whole campaign runs in minutes.
//
// The registered floor of 1,000 would stretch this window to about 230 s, which is why the rehearsal lowers it.
func TestRehearsalBundleFitsAStubCampaign(t *testing.T) {
	dir := t.TempDir()
	rule := versionAsyncRehearsalDesign().Calibration
	write := func(name string, data []byte) {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(CalibrationLockFile, []byte("2026-11-20T00:00:00Z\n"))
	res := rule.Run(func(rate float64, ordinal int) RungClass {
		cls := RungStable
		if rate > 1.2 {
			cls = RungUnstable
		}
		rec, _ := json.Marshal(CalibrationRungRecord{Ordinal: ordinal, Class: cls, Observation: RungObservation{OfferedRate: rate}})
		write(CalibrationRungFile(ordinal), rec)
		write(CalibrationRungRowsFile(ordinal), nil)
		return cls
	})
	art, _ := json.Marshal(CalibrationArtifact{Resolved: res.Resolved, StableRateRequestsPerSec: res.Rate, Reason: res.Reason, Rungs: res.Rungs})
	write(CalibrationArtifactFile, art)
	b, _, err := WriteCampaignBundle(dir, StudyVersionAsyncRehearsal, CampaignInputs{
		CampaignID: "rehearsal-test", CalibrationArtifact: CalibrationArtifactFile,
		PriceUSDPerHour: 1, PriceSource: "rehearsal, not a read price", PriceReadAt: "2026-11-20T00:00:00Z",
	})
	if err != nil {
		t.Fatal(err)
	}
	if b.WindowSeconds != 60 {
		t.Fatalf("window %d s at λ0 %v, want the rehearsal's 60 s minimum", b.WindowSeconds, res.Rate)
	}
	ladder := len(res.Rungs) * (rule.WarmupSeconds + rule.WindowSeconds + rule.DrainSeconds)
	if ladder > 20*60 {
		t.Fatalf("the rehearsal ladder runs %d rungs for %d s, want under 20 minutes", len(res.Rungs), ladder)
	}
}
