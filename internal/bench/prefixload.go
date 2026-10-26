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
	"fmt"
	"hash/fnv"
	"math/rand/v2"
)

// PrefixLoad is a shared-prefix load: one tenant's Poisson arrivals, each request one of Groups system prompts
// followed by a suffix of its own.
//
// It is registered on a study rather than taken from flags, as an episode study's load is, because the trace's
// meaning depends on all six values together: the number of prompts against the engine's cache is what decides
// whether routing can matter at all (docs/superpowers/specs/2026-10-27-prefix-aware-routing-design.md, "Load").
type PrefixLoad struct {
	RatePerSec float64
	DurationMs int64
	// PromptChars is every request's whole message; PrefixChars of it is the shared system prompt.
	PromptChars int
	PrefixChars int
	// Groups is how many distinct system prompts the requests draw from, uniformly.
	Groups       int
	OutputTokens int
	TimeoutMs    int
}

// groupHeader opens each system prompt with its own line, so no two prompts share even their first chunk.
func groupHeader(g int) string {
	return fmt.Sprintf("System prompt %d of the prefix-routing study.\n", g)
}

// requestHeader opens each request's own part with its seed and index, so no two requests share a suffix, and in the
// control no two share a first chunk.
func requestHeader(seed int64, index int) string { return fmt.Sprintf("Request %d-%d.\n", seed, index) }

// GeneratePrefixTrace writes the load's trace for one seed.
//
// The arrival times are the independent-arrivals model's for one tenant, so they depend on the seed, the rate and
// the duration alone; the prompt each request draws comes from its own stream keyed by the seed, so it moves
// nothing about the arrivals.
//
// control moves each request's own header to the front, which leaves every length, group and arrival as it was and
// makes every request's first chunk unique: then only the engine's chat template can be shared, and a policy that
// still raises the hit ratio is not raising it by prefix affinity.
func GeneratePrefixTrace(load PrefixLoad, seed int64, control bool) ([]TraceRow, error) {
	if load.Groups < 1 || load.PrefixChars < 1 || load.OutputTokens < 1 || load.RatePerSec <= 0 {
		return nil, fmt.Errorf("a shared-prefix load needs a positive group count, prefix, output and rate: %+v", load)
	}
	longest := len(groupHeader(load.Groups))
	if load.PrefixChars <= longest {
		return nil, fmt.Errorf("prefix of %d characters leaves no room after a %d-character header", load.PrefixChars, longest)
	}
	rows, err := GenerateTrace(TraceParams{Seed: seed, DurationMs: load.DurationMs, Tenants: []TenantSpec{{
		Tenant: PremiumTenant, PromptLenChars: load.PromptChars, MaxOutputTokens: load.OutputTokens,
		RatePerSec: load.RatePerSec,
	}}})
	if err != nil {
		return nil, err
	}
	h := fnv.New64a()
	_, _ = fmt.Fprintf(h, "prefix-group/%d", seed)
	pick := rand.New(rand.NewPCG(h.Sum64(), uint64(seed)))
	for i := range rows {
		if own := load.PromptChars - load.PrefixChars - len(requestHeader(seed, rows[i].Index)); own < 1 {
			return nil, fmt.Errorf("row %d: a %d-character prompt leaves no room for its own part after a %d-character prefix",
				rows[i].Index, load.PromptChars, load.PrefixChars)
		}
		rows[i].PrefixGroup = 1 + pick.IntN(load.Groups)
		rows[i].PrefixChars = load.PrefixChars
		rows[i].PrefixControl = control
		rows[i].PromptSeed = seed
	}
	return rows, nil
}

// PromptForRow is the message a row sends: the corpus at its length for every trace that predates shared prefixes,
// and for a shared-prefix row its system prompt and its own part, in the order its trace says.
//
// It is a pure function of the row, as PromptText is of a length, so every arm replays the same bytes.
func PromptForRow(row TraceRow) string {
	if row.PrefixChars <= 0 {
		return PromptText(row.PromptLenChars)
	}
	gh := groupHeader(row.PrefixGroup)
	system := gh + PromptText(row.PrefixChars-len(gh))
	own := requestHeader(row.PromptSeed, row.Index)
	rest := PromptText(row.PromptLenChars - row.PrefixChars - len(own))
	if row.PrefixControl {
		return own + system + rest
	}
	return system + own + rest
}
