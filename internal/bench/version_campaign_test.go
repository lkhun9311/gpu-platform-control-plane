package bench

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

// campaignCells builds every cell of blocks 1..n as a campaign would record them, each load's trace named per block.
func campaignCells(t *testing.T, n int) []RunManifest {
	t.Helper()
	d := frozenVersionDesignFixture()
	var out []RunManifest
	for block := 1; block <= n; block++ {
		order := ArmOrder(d.CampaignSeed, block)
		for _, load := range []string{LoadL060, LoadL090} {
			seed, err := WorkloadSeed(d.CampaignSeed, block, load)
			if err != nil {
				t.Fatal(err)
			}
			rate, _ := OfferedRate(load, 4)
			for _, tr := range []string{TreatmentA, TreatmentB, TreatmentC} {
				out = append(out, RunManifest{
					SchemaVersion: ManifestSchemaV3,
					Study:         studyVersionFixture,
					Arm:           VersionStudyArm(tr, load),
					Model:         "qwen2.5-3b-instruct",
					Seed:          seed,
					TraceChecksum: fmt.Sprintf("%064x", block*10+len(load)+int(rate*10)),
					Engine:        new(d.Engines[tr]),
					Cell: &CellIdentity{
						CampaignID:             "s1-20261120",
						Block:                  block,
						Position:               slices.Index(order, tr) + 1,
						OrderSeed:              d.CampaignSeed,
						CapacityRequestsPerSec: 4,
						CapacityArtifactSHA256: strings.Repeat("c", 64),
						OfferedRequestsPerSec:  rate,
					},
				})
			}
		}
	}
	return out
}

// TestCampaignCompleteAtFiveBlocks checks a full campaign passes and names its complete blocks.
func TestCampaignCompleteAtFiveBlocks(t *testing.T) {
	registerFrozenVersionStudy(t)
	complete, err := CheckVersionCampaign(campaignCells(t, 5))
	if err != nil {
		t.Fatalf("a complete campaign was refused: %v", err)
	}
	if !slices.Equal(complete, []int{1, 2, 3, 4, 5}) {
		t.Errorf("complete blocks = %v, want 1..5", complete)
	}
}

// TestCampaignRefusals lists the campaigns analysis must not pair (audit findings 2, 3, 14, 17, 21).
func TestCampaignRefusals(t *testing.T) {
	registerFrozenVersionStudy(t)
	for name, c := range map[string]struct {
		mutate func(cells []RunManifest) []RunManifest
		want   string
	}{
		"four blocks, below the registered floor": {
			func(cells []RunManifest) []RunManifest { return cells[:4*6] }, "not confirmatory",
		},
		"a cell missing from block 3, which leaves four complete blocks": {
			func(cells []RunManifest) []RunManifest { return slices.Delete(cells, 2*6+4, 2*6+5) }, "not confirmatory",
		},
		"B replays different traffic from A in one block and load": {
			func(cells []RunManifest) []RunManifest {
				cells[1].TraceChecksum = strings.Repeat("9", 64)
				return cells
			},
			"trace",
		},
		"two blocks replay one trace": {
			func(cells []RunManifest) []RunManifest {
				for i := 6; i < 9; i++ {
					cells[i].TraceChecksum = cells[0].TraceChecksum
				}
				return cells
			},
			"same trace",
		},
		"a cell from another campaign": {
			func(cells []RunManifest) []RunManifest { cells[7].Cell.CampaignID = "s1-20261121"; return cells }, "campaign",
		},
		"a cell priced against another λ0": {
			func(cells []RunManifest) []RunManifest {
				cells[7].Cell.CapacityRequestsPerSec = 5
				return cells
			},
			"capacity",
		},
		"one cell recorded twice": {
			func(cells []RunManifest) []RunManifest { return append(cells, cells[3]) }, "twice",
		},
		"a cell of another study": {
			func(cells []RunManifest) []RunManifest { cells[2].Study = StudyHoldCapProductTransfer; return cells }, "study",
		},
		"a cell without identity": {
			func(cells []RunManifest) []RunManifest { cells[2].Cell = nil; return cells }, "cell",
		},
		"a cell served by another model": {
			func(cells []RunManifest) []RunManifest { cells[2].Model = "qwen2.5-7b-instruct"; return cells }, "model",
		},
		"no cells": {
			func([]RunManifest) []RunManifest { return nil }, "no cells",
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := CheckVersionCampaign(c.mutate(campaignCells(t, 5)))
			if err == nil {
				t.Fatal("accepted")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("refusal %q does not mention %q", err, c.want)
			}
		})
	}
}

// TestCampaignReplacementBlockCountsOnce checks an invalid block left out and a replacement added still reaches the floor.
func TestCampaignReplacementBlockCountsOnce(t *testing.T) {
	registerFrozenVersionStudy(t)
	cells := campaignCells(t, 6)
	// Block 2 was invalidated, so its six cells are not passed in; block 6 replaces it.
	cells = slices.Delete(cells, 6, 12)
	complete, err := CheckVersionCampaign(cells)
	if err != nil {
		t.Fatalf("refused: %v", err)
	}
	if !slices.Equal(complete, []int{1, 3, 4, 5, 6}) {
		t.Errorf("complete = %v, want [1 3 4 5 6]", complete)
	}
}
