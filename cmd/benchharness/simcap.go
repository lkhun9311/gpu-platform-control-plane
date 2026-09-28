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
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/url"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gateway"
)

// simCap replays a trace's arrival times through the real static-cap admitter and reports what fraction of
// the eligible offered tokens a given rate and burst would admit.
//
// This is the design spec's Arm B tuning procedure, which asks for the bucket to be simulated against a
// pilot's arrival trace and the values frozen before the confirmatory run. It had never been run. The first
// confirmatory run instead received the trace's REQUEST rate in a flag measured in tokens per second, with
// the burst left at a default below the largest prompt, and arm B refused every eligible request for three
// hours -- reporting cleanly the whole time, because nothing compared the tuning against the traffic.
//
// It drives internal/gateway's own admitter through an injected clock rather than reimplementing the bucket.
// A simulator that agreed with the gateway today would be one more value held in two places, which is the
// shape behind every defect this experiment has produced.
func simCap(args []string) error {
	fs := flag.NewFlagSet("sim-cap", flag.ExitOnError)
	tracePath := fs.String("trace", "", "trace file to simulate against (required)")
	rate := fs.Float64("rate", 0, "bucket refill rate in tokens/sec (required)")
	burst := fs.Int("burst", 0, "bucket capacity in tokens (required)")
	longThreshold := fs.Int("long-threshold", 4096, "minimum estimated input tokens for the eligible population")
	premium := fs.String("premium-tenants", "", "comma-separated tenants the gateway resolves to the premium tier; every other tenant is standard")
	target := fs.Float64("target-admitted-fraction", 0, "when set, exit non-zero unless the simulated fraction lands within -tolerance of it")
	tolerance := fs.Float64("tolerance", 0.05, "RELATIVE tolerance on -target-admitted-fraction, matching the design spec's |B-C|/C contract")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *tracePath == "" || *rate <= 0 || *burst <= 0 {
		return fmt.Errorf("-trace, -rate and -burst are all required")
	}

	var premiumTenants []string
	if *premium != "" {
		premiumTenants = strings.Split(*premium, ",")
	}

	f, err := os.Open(*tracePath)
	if err != nil {
		return fmt.Errorf("open trace: %w", err)
	}
	defer f.Close() //nolint:errcheck // read-only

	// The clock is the trace's own arrival offsets, so a ten-minute replay simulates in milliseconds.
	//
	// These are the SCHEDULED offsets, not the times requests actually reached the gateway: the replay client
	// dispatches open-loop and the recorded sendUnixNanos are not perfectly ordered by index. So this is the
	// intended arrival pattern through the real bucket, not a reconstruction of one run's true spacing.
	origin := time.Unix(0, 0)
	var at time.Time
	admitter := gateway.NewStaticCapAdmitterAtClock(*rate, *burst, *longThreshold, func() time.Time { return at })
	backend := &gateway.BackendRef{Namespace: "sim", Name: "engine", Port: 8000, URL: &url.URL{Scheme: "http", Host: "sim"}}

	var offered, admitted int64
	// The estimate charges the bucket, because that is what the gateway spends and what arm B's tuning is
	// expressed in. The EXACT counts weight the fraction, because that is the unit the design registers the
	// admission-match criterion in. They are two numbers with two jobs and they must not be conflated.
	var offeredExact, admittedExact int64
	var exactMissing int
	var eligible, refused int
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var row bench.TraceRow
		if err := json.Unmarshal(line, &row); err != nil {
			return fmt.Errorf("parse trace row: %w", err)
		}
		tier := "standard"
		if slices.Contains(premiumTenants, row.Tenant) {
			tier = "premium"
		}
		est := bench.EstInputTokensForChars(row.PromptLenChars)
		if tier != "standard" || est < *longThreshold {
			continue
		}
		at = origin.Add(time.Duration(row.OffsetMs) * time.Millisecond)
		eligible++
		offered += int64(est)
		if row.ExactInputTokens > 0 {
			offeredExact += int64(row.ExactInputTokens)
		} else {
			exactMissing++
		}
		ok, _ := admitter.Admit(context.Background(), gateway.RequestMeta{Model: "sim", EstInputTokens: est}, backend, row.Tenant, tier)
		if ok {
			admitted += int64(est)
			if row.ExactInputTokens > 0 {
				admittedExact += int64(row.ExactInputTokens)
			}
		} else {
			refused++
		}
	}
	if err := sc.Err(); err != nil {
		return fmt.Errorf("read trace: %w", err)
	}
	if offered == 0 {
		return fmt.Errorf("no eligible requests in %s at a threshold of %d tokens; the simulation has nothing to say about a bucket that would never be consulted", *tracePath, *longThreshold)
	}

	fraction := float64(admitted) / float64(offered)
	exactFraction := 0.0
	if offeredExact > 0 {
		exactFraction = float64(admittedExact) / float64(offeredExact)
	}
	fmt.Printf("eligible=%d refused=%d offered=%d admitted=%d fraction=%.4f (estimate-weighted)\n",
		eligible, refused, offered, admitted, fraction)
	if exactMissing > 0 {
		fmt.Printf("exact tokens: %d of %d eligible rows carry no measured count, so this trace cannot express the registered unit\n", exactMissing, eligible)
	} else {
		fmt.Printf("exact tokens: offeredExact=%d admittedExact=%d fraction=%.4f (the registered unit)\n", offeredExact, admittedExact, exactFraction)
	}
	// A -target check is a claim about the REGISTERED criterion, and the criterion is defined over the served
	// tokenizer's own counts. A trace whose rows carry none cannot answer it.
	//
	// Passing here on the estimate is how a bucket gets frozen against a number nobody measured: this command
	// does not freeze anything itself, but its exit status is what the runner reads before committing to a
	// paid confirmatory run. Refusing is the repository's rule for measurement code -- an error beats a figure
	// the evidence does not support -- and the estimate-weighted fraction is still printed above for diagnosis.
	if *target > 0 && exactMissing > 0 {
		return fmt.Errorf("-target-admitted-fraction asks whether this bucket matches the pilot's admitted-work fraction, which the design defines over EXACT target-tokenizer input tokens, and %d of %d eligible rows in %s carry no measured count. Stamp the trace first (benchharness stamp-exact-tokens) or drop -target-admitted-fraction and read the estimate-weighted fraction above as a diagnostic",
			exactMissing, eligible, *tracePath)
	}
	if *target > 0 {
		// Relative, because the pre-registered admission-match check is |B-C|/C and an absolute band of the
		// same width is a different, looser contract: at a target of 0.8456 an absolute 0.05 admits 0.796,
		// which is 5.9 percent off relative and would fail the check this is meant to pre-empt.
		rel := (exactFraction - *target) / *target
		if rel > *tolerance || rel < -*tolerance {
			return fmt.Errorf("rate %.0f tok/s with burst %d admits %.4f of the eligible offered EXACT tokens against a frozen target of %.4f, which is %.1f percent off relative and outside the %.1f percent allowed. The tuning and the traffic disagree, so arm B would not be admission-matched to C and the incremental-value comparison would measure the mismatch instead of the guard", *rate, *burst, exactFraction, *target, rel*100, *tolerance*100)
		}
	}
	return nil
}
