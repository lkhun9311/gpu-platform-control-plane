/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const campaignV2Path = "../../hack/stranded-protocol-v2.yaml"

func loadCampaignV2(t *testing.T) CampaignV2 {
	t.Helper()
	c, err := LoadCampaignV2(campaignV2Path, "../..")
	if err != nil {
		t.Fatalf("the registered campaign does not load: %v", err)
	}
	return c
}

// The registration's own figures, computed by hand there: the test must reproduce them, not approximate them.
func TestFisherOneSidedMatchesTheRegistrationsValues(t *testing.T) {
	for _, tc := range []struct {
		a, n1, b, n2 int
		want         float64
	}{
		{12, 12, 8, 12, 0.0466},
		{12, 12, 9, 12, 0.1087},
		{4, 12, 0, 12, 0.0466},
		{3, 12, 0, 12, 0.1087},
		{0, 12, 0, 12, 1},
	} {
		if got := FisherOneSided(tc.a, tc.n1, tc.b, tc.n2); math.Abs(got-tc.want) > 0.00005 {
			t.Errorf("FisherOneSided(%d/%d against %d/%d) = %.5f, want %.4f", tc.a, tc.n1, tc.b, tc.n2, got, tc.want)
		}
	}
}

func TestTheRegisteredCampaignLoadsWithItsThreeConditions(t *testing.T) {
	c := loadCampaignV2(t)
	got := ""
	for _, cond := range c.Conditions {
		got += fmt.Sprintf("%s:%v:%d ", cond.Name, []int(cond.protocol.Layout()), len(cond.protocol.Submissions))
	}
	if got != "C1:[2 1 1]:6 C2:[3 2]:4 C3:[3 2]:4 " {
		t.Errorf("conditions, layouts and sequence lengths are %q", got)
	}
}

func TestAFirstCampaignFileIsRefusedByItsVersion(t *testing.T) {
	_, err := LoadCampaignV2(protocolPath, "../..")
	if err == nil || !strings.Contains(err.Error(), "version 1") {
		t.Fatalf("a version 1 file was not refused by its version: %v", err)
	}
}

func writeCampaign(t *testing.T, edit func(string) string) string {
	t.Helper()
	data, err := os.ReadFile(campaignV2Path)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "campaign.yaml")
	if err := os.WriteFile(path, []byte(edit(string(data))), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestACampaignTheRegistrationWouldNotRecogniseIsRefused(t *testing.T) {
	for name, tc := range map[string]struct{ from, to, want string }{
		"a block that repeats a cell": {
			"    - [C1/S-gpu-most, C2/S-gpu-most, C1/S-default, C3/S-default, C2/S-default, C3/S-gpu-most]",
			"    - [C1/S-gpu-most, C1/S-gpu-most, C1/S-default, C3/S-default, C2/S-default, C3/S-gpu-most]",
			"not a permutation"},
		"a block too few": {
			"    - [C1/S-gpu-most, C3/S-default, C2/S-gpu-most, C3/S-gpu-most, C1/S-default, C2/S-default]\n", "",
			"11 blocks"},
		"a looser alpha":     {"alpha: 0.05", "alpha: 0.1", "one-sided Fisher"},
		"a correction":       {"correction_across_conditions: none", "correction_across_conditions: holm", "one-sided Fisher"},
		"an unknown predict": {"prediction: gpu-most-strands-in-every", "prediction: gpu-most-strands-sometimes", "predicts"},
		"a condition missing from the order": {
			"list: [C1/S-default, C1/S-gpu-most, C2/S-default, C2/S-gpu-most, C3/S-default, C3/S-gpu-most]",
			"list: [C1/S-default, C1/S-gpu-most, C2/S-default, C2/S-gpu-most, C3/S-default, C4/S-gpu-most]",
			"the order lists"},
	} {
		t.Run(name, func(t *testing.T) {
			path := writeCampaign(t, func(s string) string {
				if !strings.Contains(s, tc.from) {
					t.Fatalf("the perturbation %q does not apply", tc.from)
				}
				return strings.Replace(s, tc.from, tc.to, 1)
			})
			_, err := LoadCampaignV2(path, "../..")
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("refusal %q not produced: %v", tc.want, err)
			}
		})
	}
}

// records builds standing cells for one arm, the first `stranded` of which strand at step idx.
func records(arm Arm, cells, stranded, idx, steps int) []CellRecord {
	out := make([]CellRecord, 0, cells)
	for i := range cells {
		censuses := make([]StrandingReport, steps)
		if i < stranded {
			censuses[idx].StrandedDevices = 2
		}
		out = append(out, CellRecord{Arm: arm, Repetition: i + 1, Attempt: 1, Censuses: censuses})
	}
	return out
}

func judge(t *testing.T, c CampaignV2, name string, defaultStranded, gpuMostStranded int) ConditionReading {
	t.Helper()
	for _, cond := range c.Conditions {
		if cond.Name != name {
			continue
		}
		idx, steps := discriminatingIndex(cond.protocol), len(cond.protocol.Submissions)
		rs := append(records(ArmUntouched, 12, defaultStranded, idx, steps), records(ArmConfigured, 12, gpuMostStranded, idx, steps)...)
		r, err := cond.Judge(rs, c.Test.Alpha)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	t.Fatalf("no condition %s", name)
	return ConditionReading{}
}

func TestEachReadingFollowsFromTheCountsAndTheDirection(t *testing.T) {
	c := loadCampaignV2(t)
	for _, tc := range []struct {
		cond               string
		defaultN, gpuMostN int
		wantPrefix         string
		wantPasses         bool
	}{
		{"C2", 8, 12, "packing lost", true},
		{"C2", 9, 12, "packing stranded every time", false},
		{"C2", 0, 11, "the prediction failed", true},
		{"C1", 4, 0, "packing removed stranding", true},
		{"C1", 3, 0, "not distinguished", false},
		{"C3", 12, 1, "the prediction failed", true},
		// Neither arm stranding is evidence for neither, so it is not a pass.
		{"C3", 0, 0, "not distinguished", false},
	} {
		r := judge(t, c, tc.cond, tc.defaultN, tc.gpuMostN)
		if !strings.HasPrefix(r.Reading, tc.wantPrefix) || r.Passes != tc.wantPasses {
			t.Errorf("%s with S-default %d/12 and S-gpu-most %d/12 read %q (p %.4f, passes %t), want %q and passes %t",
				tc.cond, tc.defaultN, tc.gpuMostN, r.Reading, r.P, r.Passes, tc.wantPrefix, tc.wantPasses)
		}
	}
}

func TestAnInvalidAttemptIsNotCounted(t *testing.T) {
	c := loadCampaignV2(t)
	cond := c.Conditions[1]
	idx, steps := discriminatingIndex(cond.protocol), len(cond.protocol.Submissions)
	rs := append(records(ArmUntouched, 12, 8, idx, steps), records(ArmConfigured, 12, 12, idx, steps)...)
	// A discarded attempt that stranded, beside the twelve that stand: it must not become a thirteenth.
	bad := records(ArmUntouched, 1, 1, idx, steps)[0]
	bad.InvalidatedBecause = "unobserved_disposition"
	r, err := cond.Judge(append(rs, bad), c.Test.Alpha)
	if err != nil {
		t.Fatal(err)
	}
	if r.DefaultCells != 12 || r.DefaultStranded != 8 {
		t.Errorf("S-default read %d of %d; the invalid attempt was counted", r.DefaultStranded, r.DefaultCells)
	}
}

func TestASignReversalNeedsBothTestsToPass(t *testing.T) {
	c := loadCampaignV2(t)
	lose, win := judge(t, c, "C2", 8, 12), judge(t, c, "C3", 4, 0)
	if SignReversal([]ConditionReading{lose, win}) == "" {
		t.Error("both tests passed in their directions and no reversal was reported")
	}
	if SignReversal([]ConditionReading{judge(t, c, "C2", 9, 12), win}) != "" {
		t.Error("a reversal was reported with C2's test not passing")
	}
}

func TestARecordFiledUnderTheWrongConditionIsRefused(t *testing.T) {
	c := loadCampaignV2(t)
	dir := t.TempDir()
	// The first condition's directory holds records performed against C3's file; the hash is checked before any
	// other rule, so the refusal names it rather than whatever else these minimal records lack.
	writeRecords(t, filepath.Join(dir, c.Conditions[0].Name), c.Conditions[0], c.Conditions[2].protocolSHA256)
	_, err := c.CheckCampaignV2(dir)
	if err == nil || !strings.Contains(err.Error(), "condition C1") || !strings.Contains(err.Error(), "another condition") {
		t.Fatalf("a C3 record under C1 was not refused by its protocol hash: %v", err)
	}
	// And with the right hash the same records get past it, to the first campaign's rules.
	writeRecords(t, filepath.Join(dir, c.Conditions[0].Name), c.Conditions[0], c.Conditions[0].protocolSHA256)
	if _, err := c.CheckCampaignV2(dir); err == nil || strings.Contains(err.Error(), "another condition") {
		t.Fatalf("records with C1's own hash were refused by the hash: %v", err)
	}
}

// writeRecords writes one standing attempt per registered cell of cond, each naming the protocol hash sum.
func writeRecords(t *testing.T, dir string, cond ConditionV2, sum string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, arm := range []Arm{ArmUntouched, ArmConfigured} {
		for rep := 1; rep <= cond.protocol.Matrix.RepetitionsPerArm; rep++ {
			r := CellRecord{Arm: arm, Repetition: rep, Attempt: 1, ProtocolSHA256: sum}
			data, err := json.Marshal(r)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("%s-rep%02d-try1.json", arm, rep)), data, 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestEachConditionsRecordsMustBeInItsOwnDirectory(t *testing.T) {
	c := loadCampaignV2(t)
	if _, err := c.CheckCampaignV2(t.TempDir()); err == nil || !strings.Contains(err.Error(), "condition C1") {
		t.Fatalf("an empty records directory was not refused by its first condition: %v", err)
	}
}
