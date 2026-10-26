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
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"sigs.k8s.io/yaml"
)

// CampaignV2 is the second campaign's protocol: several conditions, each with its own first-campaign protocol,
// plus the order every cell runs in and the test that compares the arms.
//
// It is a separate type rather than a version branch inside Protocol, because a condition's cells are judged by
// exactly the first campaign's rules, and keeping that file's schema unchanged is what lets check-cell judge them
// without a second copy of any rule.
type CampaignV2 struct {
	Version    int           `json:"version"`
	Conditions []ConditionV2 `json:"conditions"`
	Order      struct {
		Seed   int64      `json:"seed"`
		List   []string   `json:"list"`
		Blocks [][]string `json:"blocks"`
	} `json:"order"`
	Test struct {
		Kind                       string  `json:"kind"`
		Alpha                      float64 `json:"alpha"`
		CorrectionAcrossConditions string  `json:"correction_across_conditions"`
	} `json:"test"`
}

// ConditionV2 is one layout and sequence, and what the scoring rule says the treatment does on it.
type ConditionV2 struct {
	Name       string     `json:"name"`
	Protocol   string     `json:"protocol"`
	Prediction Prediction `json:"prediction"`
	// protocol is the loaded condition file and protocolSHA256 its hash, both filled by LoadCampaignV2.
	protocol       Protocol
	protocolSHA256 string
}

// Prediction is what S-gpu-most does at a condition's discriminating step, and so which way its test points.
type Prediction string

const (
	// StrandsInNone predicts the treatment never strands, so the test asks whether the reference strands more.
	StrandsInNone Prediction = "gpu-most-strands-in-none"
	// StrandsInEvery predicts the treatment always strands, so the test asks whether it strands more.
	StrandsInEvery Prediction = "gpu-most-strands-in-every"
)

// LoadCampaignV2 reads the campaign file at path and every condition file it names, relative to root.
//
// A first-campaign file passed here is refused by its version, not read as a campaign with no conditions: the
// two schemas share no keys a strict reader would accept, but a refusal that names the version says why.
func LoadCampaignV2(path, root string) (CampaignV2, error) {
	var c CampaignV2
	data, err := os.ReadFile(path)
	if err != nil {
		return CampaignV2{}, fmt.Errorf("could not read the campaign at %s: %w", path, err)
	}
	var probe struct {
		Version int `json:"version"`
	}
	if err := yaml.Unmarshal(data, &probe); err != nil {
		return CampaignV2{}, fmt.Errorf("the campaign at %s does not parse: %w", path, err)
	}
	if probe.Version != 2 {
		return CampaignV2{}, fmt.Errorf("%s is a version %d protocol; check-campaign-v2 judges a version 2 "+
			"campaign, and a first-campaign file has no conditions, order or test to judge it by", path, probe.Version)
	}
	if err := yaml.UnmarshalStrict(data, &c); err != nil {
		return CampaignV2{}, fmt.Errorf("the campaign at %s does not parse: %w", path, err)
	}
	for i := range c.Conditions {
		file := filepath.Join(root, c.Conditions[i].Protocol)
		p, pErr := LoadProtocol(file)
		if pErr != nil {
			return CampaignV2{}, fmt.Errorf("condition %s: %w", c.Conditions[i].Name, pErr)
		}
		raw, rErr := os.ReadFile(file)
		if rErr != nil {
			return CampaignV2{}, fmt.Errorf("condition %s: %w", c.Conditions[i].Name, rErr)
		}
		sum := sha256.Sum256(raw)
		c.Conditions[i].protocol, c.Conditions[i].protocolSHA256 = p, hex.EncodeToString(sum[:])
	}
	if err := c.Validate(); err != nil {
		return CampaignV2{}, fmt.Errorf("the campaign at %s is not self-consistent: %w", path, err)
	}
	return c, nil
}

// noCorrection is the registered correction across conditions: each condition is its own question.
const noCorrection = "none"

// Validate refuses a campaign whose order, test or conditions the registration would not recognise.
func (c CampaignV2) Validate() error {
	if len(c.Conditions) == 0 {
		return fmt.Errorf("the campaign registers no conditions")
	}
	names := map[string]bool{}
	cells := []string{}
	for _, cond := range c.Conditions {
		if cond.Name == "" || names[cond.Name] {
			return fmt.Errorf("condition name %q is empty or repeated", cond.Name)
		}
		names[cond.Name] = true
		if cond.Prediction != StrandsInNone && cond.Prediction != StrandsInEvery {
			return fmt.Errorf("condition %s predicts %q; the test's direction follows from the prediction, so an "+
				"unknown one leaves the test pointing nowhere", cond.Name, cond.Prediction)
		}
		if discriminatingIndex(cond.protocol) < 0 {
			return fmt.Errorf("condition %s has no discriminating submission", cond.Name)
		}
		for _, a := range cond.protocol.Arms {
			cells = append(cells, cond.Name+"/"+a.Name)
		}
	}
	// The order's list is every condition-arm cell once, and every block is a permutation of it, so every block
	// holds each cell once; whether the blocks are the seed's draw is hack/test/check-stranded-v2-order.sh's.
	if !sameSet(c.Order.List, cells) {
		return fmt.Errorf("the order lists %v and the conditions make %v", c.Order.List, cells)
	}
	for _, cond := range c.Conditions {
		if len(c.Order.Blocks) != cond.protocol.Matrix.RepetitionsPerArm {
			return fmt.Errorf("the order has %d blocks and condition %s registers %d repetitions per arm; each "+
				"block runs one repetition of every cell", len(c.Order.Blocks), cond.Name,
				cond.protocol.Matrix.RepetitionsPerArm)
		}
	}
	for i, b := range c.Order.Blocks {
		if len(b) != len(c.Order.List) || !sameSet(b, c.Order.List) {
			return fmt.Errorf("block %d is %v, not a permutation of %v", i+1, b, c.Order.List)
		}
	}
	if c.Test.Kind != "fisher-exact-one-sided" || c.Test.Alpha != 0.05 || c.Test.CorrectionAcrossConditions != noCorrection {
		return fmt.Errorf("the test is %q at %v with correction %q; the registration fixes a one-sided Fisher exact "+
			"test at 0.05 with no correction, stated so that it is not chosen later",
			c.Test.Kind, c.Test.Alpha, c.Test.CorrectionAcrossConditions)
	}
	return nil
}

func sameSet(a, b []string) bool {
	x, y := slices.Clone(a), slices.Clone(b)
	slices.Sort(x)
	slices.Sort(y)
	return slices.Equal(x, y) && len(slices.Compact(slices.Clone(x))) == len(x)
}

func discriminatingIndex(p Protocol) int {
	for i, s := range p.Submissions {
		if s.Discriminating {
			return i
		}
	}
	return -1
}

// FisherOneSided is P(X >= a) for X hypergeometric: a of the k successes fell in the first group of n1, out of
// n1+n2. It is exact, from big-integer binomials, because twelve per arm is small enough that nothing needs
// approximating and a rounded tail at the 0.05 line would decide a reading.
func FisherOneSided(a, n1, b, n2 int) float64 {
	k := a + b
	total := new(big.Int).Binomial(int64(n1+n2), int64(k))
	tail := new(big.Int)
	for x := a; x <= min(n1, k); x++ {
		term := new(big.Int).Binomial(int64(n1), int64(x))
		term.Mul(term, new(big.Int).Binomial(int64(n2), int64(k-x)))
		tail.Add(tail, term)
	}
	f, _ := new(big.Rat).SetFrac(tail, total).Float64()
	return f
}

// ConditionReading is one condition's counts, its test and the registered reading they license.
type ConditionReading struct {
	Condition       string
	DefaultStranded int
	DefaultCells    int
	GPUMostStranded int
	GPUMostCells    int
	P               float64
	Passes          bool
	Reading         string
}

// strandedAtDiscriminatingStep counts the standing cells whose census at the discriminating step strands.
func strandedAtDiscriminatingStep(p Protocol, records []CellRecord, arm Arm) (stranded, cells int, err error) {
	idx := discriminatingIndex(p)
	for _, r := range records {
		if r.Arm != arm || !r.Valid() {
			continue
		}
		if idx >= len(r.Censuses) {
			return 0, 0, fmt.Errorf("cell %s/%d has %d censuses and the discriminating step is %d",
				r.Arm, r.Repetition, len(r.Censuses), idx+1)
		}
		cells++
		if r.Censuses[idx].StrandedDevices > 0 {
			stranded++
		}
	}
	return stranded, cells, nil
}

// Judge runs one condition's test and names its registered reading, from records check-campaign accepted.
func (cond ConditionV2) Judge(records []CellRecord, alpha float64) (ConditionReading, error) {
	r := ConditionReading{Condition: cond.Name}
	var err error
	if r.DefaultStranded, r.DefaultCells, err = strandedAtDiscriminatingStep(cond.protocol, records, ArmUntouched); err != nil {
		return r, err
	}
	if r.GPUMostStranded, r.GPUMostCells, err = strandedAtDiscriminatingStep(cond.protocol, records, ArmConfigured); err != nil {
		return r, err
	}
	switch cond.Prediction {
	case StrandsInNone:
		// The predicted direction: the reference strands more often than the treatment.
		r.P = FisherOneSided(r.DefaultStranded, r.DefaultCells, r.GPUMostStranded, r.GPUMostCells)
		r.Passes = r.P <= alpha
		switch {
		case r.GPUMostStranded > 0:
			r.Reading = "the prediction failed: S-gpu-most stranded, which the scoring rule said it cannot"
		case r.Passes:
			r.Reading = "packing removed stranding on this layout and mix"
		default:
			r.Reading = "not distinguished"
		}
	case StrandsInEvery:
		// The predicted direction: the treatment strands more often than the reference.
		r.P = FisherOneSided(r.GPUMostStranded, r.GPUMostCells, r.DefaultStranded, r.DefaultCells)
		r.Passes = r.P <= alpha
		switch {
		case r.GPUMostStranded < r.GPUMostCells:
			r.Reading = "the prediction failed: S-gpu-most avoided stranding in a cell, which the scoring rule " +
				"said it cannot"
		case r.Passes:
			r.Reading = "packing lost on this mix"
		default:
			r.Reading = "packing stranded every time and the default too often to tell apart"
		}
	default:
		return r, fmt.Errorf("condition %s has no test for prediction %q", cond.Name, cond.Prediction)
	}
	return r, nil
}

// CheckCampaignV2 judges each condition's records by the first campaign's rules, then tests and reads each.
//
// recordsDir holds one directory per condition, named for it, so a record cannot be counted under a condition
// whose layout it did not run on. A condition whose campaign check refuses stops the whole verdict, because the
// registration publishes a comparison only when every registered cell has an attempt that stands.
func (c CampaignV2) CheckCampaignV2(recordsDir string) ([]ConditionReading, error) {
	out := make([]ConditionReading, 0, len(c.Conditions))
	for _, cond := range c.Conditions {
		records, _, err := LoadCellRecords(filepath.Join(recordsDir, cond.Name))
		if err != nil {
			return out, fmt.Errorf("condition %s: %w", cond.Name, err)
		}
		// The directory is a filing convention, not evidence: C2 and C3 share submission names, so each record must
		// name, by hash, the very file it was performed against.
		for i, r := range records {
			if r.ProtocolSHA256 != cond.protocolSHA256 {
				return out, fmt.Errorf("condition %s: record %d (%s/%d attempt %d) was performed against protocol "+
					"%q and this condition's file is %s; it belongs to another condition or another version",
					cond.Name, i+1, r.Arm, r.Repetition, r.Attempt, r.ProtocolSHA256, cond.protocolSHA256)
			}
		}
		if err := cond.protocol.CheckCampaign(records); err != nil {
			return out, fmt.Errorf("condition %s: %w", cond.Name, err)
		}
		reading, err := cond.Judge(records, c.Test.Alpha)
		if err != nil {
			return out, err
		}
		out = append(out, reading)
	}
	return out, nil
}

// SignReversal is the finding Finding 8 said a different mix could produce, reported only when both tests pass.
func SignReversal(readings []ConditionReading) string {
	byName := map[string]ConditionReading{}
	for _, r := range readings {
		byName[r.Condition] = r
	}
	lose, win := byName["C2"], byName["C3"]
	if lose.Passes && win.Passes && strings.HasPrefix(lose.Reading, "packing lost") &&
		strings.HasPrefix(win.Reading, "packing removed") {
		return "a sign reversal between C2 and C3 on the same layout: packing lost on one mix and won on the other"
	}
	return ""
}
