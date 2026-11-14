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
	"strings"
	"testing"
)

// A NaN or infinite rate or weight is refused before a single arrival is drawn.
// Audit finding 28: a NaN rate passed `<= 0` and ran to the million-row guard, and a NaN or infinite weight skewed tenant selection without an error.
// Mutation that turns it red: drop the call to validateTraceNumbers in GenerateTrace.
func TestGenerateTraceRefusesNonFiniteNumbers(t *testing.T) {
	tenant := func(w, r float64) TenantSpec {
		return TenantSpec{Tenant: "premium-1", Weight: w, PromptLenChars: 40, MaxOutputTokens: 4, RatePerSec: r}
	}
	for _, tc := range []struct {
		name   string
		params TraceParams
	}{
		{"NaN total rate", TraceParams{Seed: 1, DurationMs: 1000, RatePerSec: math.NaN(), Tenants: []TenantSpec{tenant(1, 0)}}},
		{"NaN weight", TraceParams{Seed: 1, DurationMs: 1000, RatePerSec: 5, Tenants: []TenantSpec{tenant(1, 0), {Tenant: "noisy", Weight: math.NaN(), PromptLenChars: 40, MaxOutputTokens: 4}}}},
		{"infinite weight", TraceParams{Seed: 1, DurationMs: 1000, RatePerSec: 5, Tenants: []TenantSpec{tenant(1, 0), {Tenant: "noisy", Weight: math.Inf(1), PromptLenChars: 40, MaxOutputTokens: 4}}}},
		{"NaN tenant rate", TraceParams{Seed: 1, DurationMs: 1000, Tenants: []TenantSpec{tenant(0, 5), {Tenant: "noisy", RatePerSec: math.NaN(), PromptLenChars: 40, MaxOutputTokens: 4}}}},
		{"negative tenant rate", TraceParams{Seed: 1, DurationMs: 1000, Tenants: []TenantSpec{tenant(0, 5), {Tenant: "noisy", RatePerSec: -1, PromptLenChars: 40, MaxOutputTokens: 4}}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rows, err := GenerateTrace(tc.params)
			if err == nil {
				t.Fatalf("generated %d rows from a non-finite or negative parameter", len(rows))
			}
			if strings.Contains(err.Error(), "rows before reaching durationMs") {
				t.Fatalf("refused only at the row guard, after generating: %v", err)
			}
		})
	}
}

// The admission-match tolerance is stamped on every row and read back by the report, so a non-finite one must stop the run before dispatch.
// Mutation that turns it red: make ValidateMatchTolerance accept NaN.
func TestValidateMatchToleranceRefusesNonFiniteOrOutOfRange(t *testing.T) {
	for _, bad := range []float64{math.NaN(), math.Inf(1), math.Inf(-1), -0.01, 1.5} {
		if err := ValidateMatchTolerance(bad); err == nil {
			t.Fatalf("tolerance %g accepted", bad)
		}
	}
	for _, good := range []float64{0, 0.05, 1} {
		if err := ValidateMatchTolerance(good); err != nil {
			t.Fatalf("tolerance %g refused: %v", good, err)
		}
	}
}
