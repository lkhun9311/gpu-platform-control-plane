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

package bench

import (
	"math"
	"testing"
)

// The three interval routines are shared by every study adapter, so each must refuse an input it cannot bound rather than return a valid-looking interval.
// Audit finding 24: zero iterations returned [0,0] marked valid, negative iterations panicked, and absent candidate tails or zero-baseline resamples were tolerated.
// Mutation that turns it red: remove validateBootstrapSettings from any routine, or let PairedRatioCI skip a zero-baseline resample again.
func TestBootstrapRoutinesRefuseInputsTheyCannotBound(t *testing.T) {
	vals := []float64{1, 2, 3}
	for _, tc := range []struct {
		name string
		ci   func() CI
	}{
		{"BootstrapCI zero iterations", func() CI { return BootstrapCI(vals, 0, 1, 0.05) }},
		{"BootstrapCI negative iterations", func() CI { return BootstrapCI(vals, -1, 1, 0.05) }},
		{"BootstrapCI alpha zero", func() CI { return BootstrapCI(vals, 100, 1, 0) }},
		{"BootstrapCI alpha NaN", func() CI { return BootstrapCI(vals, 100, 1, math.NaN()) }},
		{"BootstrapCI NaN value", func() CI { return BootstrapCI([]float64{1, math.NaN(), 3}, 100, 1, 0.05) }},
		{"BootstrapCI Inf value", func() CI { return BootstrapCI([]float64{1, math.Inf(1), 3}, 100, 1, 0.05) }},
		{"PairedRatioCI zero iterations", func() CI { return PairedRatioCI(vals, vals, 0, 1, 0.05) }},
		{"PairedRatioCI negative iterations", func() CI { return PairedRatioCI(vals, vals, -5, 1, 0.05) }},
		{"PairedRatioCI NaN value", func() CI { return PairedRatioCI(vals, []float64{1, math.NaN(), 3}, 100, 1, 0.05) }},
		{"PairedRatioCI zero-baseline resamples", func() CI {
			return PairedRatioCI([]float64{0, 0, 10}, []float64{5, 5, 10}, 2000, 1, 0.05)
		}},
		{"PairedBlockRatioCI zero iterations", func() CI {
			return PairedBlockRatioCI("static-cap", [][]RawRow{block(10, 50, 0), block(10, 60, 0)},
				[][]RawRow{block(10, 70, 0), block(10, 80, 0)}, 0, 1, 0.05)
		}},
		{"PairedBlockRatioCI absent candidate tail", func() CI {
			return PairedBlockRatioCI("static-cap", [][]RawRow{block(10, 50, 0), block(10, 60, 0)},
				[][]RawRow{block(0, 0, 0), block(0, 0, 0)}, 100, 1, 0.05)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var ci CI
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("panicked instead of refusing: %v", r)
					}
				}()
				ci = tc.ci()
			}()
			if ci.Valid {
				t.Fatalf("returned a valid interval [%g, %g] for an input it cannot bound", ci.Lo, ci.Hi)
			}
			if ci.InvalidReason == "" {
				t.Fatal("refused without saying why")
			}
		})
	}
}

// The percentile helper is nearest-rank over observed values, so an empty population has no quantile and must not read as 0.
// Mutation that turns it red: return (0, nil) for an empty slice in percentileOf.
func TestPercentileOfRefusesAnEmptyOrNonFinitePopulation(t *testing.T) {
	if _, err := percentileOf(nil, 0.99); err == nil {
		t.Fatal("an empty population produced a percentile")
	}
	if _, err := percentileOf([]float64{1, math.NaN()}, 0.5); err == nil {
		t.Fatal("a NaN sample produced a percentile")
	}
	if _, err := percentileOf([]float64{1, 2}, math.NaN()); err == nil {
		t.Fatal("a NaN quantile produced a percentile")
	}
	if v, err := percentileOf([]float64{1, 2, 3, 4}, 0.5); err != nil || v != 2 {
		t.Fatalf("percentileOf(1..4, 0.5) = %g, %v; want 2", v, err)
	}
}
