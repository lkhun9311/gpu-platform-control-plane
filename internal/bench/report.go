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
	"math"
	"math/rand/v2"
	"sort"
)

// httpStatusTooManyRequests is the status the gateway returns when an admission control rejects a request.
const httpStatusTooManyRequests = 429

// ArmSummary is the analysis of one arm's raw evidence for one repetition.
//
// Latency percentiles are in milliseconds, computed from the client-side raw timestamps.
type ArmSummary struct {
	// Arm names the condition.
	Arm string
	// Total is every request the trace offered for this arm.
	Total int
	// Completed counts requests that produced a full response (a first token and an end).
	Completed int
	// Rejected counts admission rejections (HTTP 429), the load the guard or static cap shed.
	Rejected int
	// TimedOut counts requests recorded with a timeout error kind.
	TimedOut int
	// Failed counts other non-completing requests (transport or stream errors).
	Failed int
	// TTFTMsP50/P95/P99 are the time-to-first-token percentiles over COMPLETED requests, in ms.
	TTFTMsP50 float64
	TTFTMsP95 float64
	TTFTMsP99 float64
	// E2EMsP99 is the end-to-end p99 over completed requests, in ms.
	E2EMsP99 float64
	// OfferedInputTokens is the estimated input tokens of every eligible request the trace offered.
	//
	// AdmittedInputTokens is the estimated input tokens of the eligible requests that were NOT rejected.
	//
	// Their ratio is the admitted-work fraction the design uses to check that arm B is admission-matched to arm C.
	OfferedInputTokens  int64
	AdmittedInputTokens int64
	// Censored is true when more than 1% of requests timed out, so the p99 is a lower bound rather than an exact tail (design spec: report it as at least the timeout, never drop it).
	Censored bool
}

// eligibleLongThreshold mirrors the guard's standard-long threshold, so admitted-work is measured over the same population the guard and static cap actually gate.
const eligibleLongThreshold = 4096

// Summarize computes one arm's summary from its raw rows.
//
// Percentiles are taken over completed requests only, but the completed/rejected/timed-out/failed counts account for every offered request, so shedding load can never flatter the tail without also showing up as a rejection count.
func Summarize(arm string, rows []RawRow) ArmSummary {
	s := ArmSummary{Arm: arm, Total: len(rows)}

	var ttft, e2e []float64
	for _, r := range rows {
		// Admitted-work accounting covers the eligible population (the long requests the controls gate), for the admission-match check.
		if r.EstInputTokens >= eligibleLongThreshold {
			s.OfferedInputTokens += int64(r.EstInputTokens)
			if r.HTTPStatus != httpStatusTooManyRequests {
				s.AdmittedInputTokens += int64(r.EstInputTokens)
			}
		}

		switch {
		case r.ErrorKind == "timeout":
			s.TimedOut++
			continue
		case r.HTTPStatus == httpStatusTooManyRequests:
			s.Rejected++
			continue
		case r.ErrorKind != "":
			s.Failed++
			continue
		}

		t, okT := r.TTFTNanos()
		e, okE := r.E2ENanos()
		if !okT || !okE {
			s.Failed++
			continue
		}
		s.Completed++
		ttft = append(ttft, nanosToMs(t))
		e2e = append(e2e, nanosToMs(e))
	}

	sort.Float64s(ttft)
	sort.Float64s(e2e)
	s.TTFTMsP50 = percentile(ttft, 0.50)
	s.TTFTMsP95 = percentile(ttft, 0.95)
	s.TTFTMsP99 = percentile(ttft, 0.99)
	s.E2EMsP99 = percentile(e2e, 0.99)

	if s.Total > 0 && float64(s.TimedOut)/float64(s.Total) > 0.01 {
		s.Censored = true
	}
	return s
}

// nanosToMs converts a nanosecond duration to fractional milliseconds.
func nanosToMs(n int64) float64 { return float64(n) / 1e6 }

// percentile returns the q-quantile of a sorted slice using nearest-rank, or 0 for an empty slice.
//
// Nearest-rank (rather than interpolation) is used because a tail claim should land on an actually observed latency, not a value that never occurred.
func percentile(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if q <= 0 {
		return sorted[0]
	}
	if q >= 1 {
		return sorted[len(sorted)-1]
	}
	// Nearest-rank: the smallest index whose cumulative share reaches q.
	rank := int(math.Ceil(q*float64(len(sorted)))) - 1
	if rank < 0 {
		rank = 0
	}
	if rank >= len(sorted) {
		rank = len(sorted) - 1
	}
	return sorted[rank]
}

// CI is a two-sided confidence interval.
type CI struct {
	Lo float64
	Hi float64
}

// BootstrapCI returns a percentile-bootstrap confidence interval for the mean of values.
//
// The design requires a repetition/block-aware bootstrap rather than a naive bootstrap over pooled requests, so values here are the PER-REPETITION statistics (e.g. each repetition's TTFT p99), and this resamples whole repetitions with replacement.
//
// alpha is the two-sided error, so 0.05 yields a 95% interval; iterations sets the resample count; seed makes it reproducible.
func BootstrapCI(values []float64, iterations int, seed int64, alpha float64) CI {
	if len(values) == 0 {
		return CI{}
	}
	if len(values) == 1 {
		// A single repetition cannot bound its own variance, so the interval degenerates to the point estimate.
		return CI{Lo: values[0], Hi: values[0]}
	}

	src := rand.NewPCG(uint64(seed), uint64(seed)^0x9e3779b97f4a7c15)
	rng := rand.New(src)

	means := make([]float64, iterations)
	n := len(values)
	for i := 0; i < iterations; i++ {
		var sum float64
		for j := 0; j < n; j++ {
			sum += values[rng.IntN(n)]
		}
		means[i] = sum / float64(n)
	}
	sort.Float64s(means)
	return CI{
		Lo: percentile(means, alpha/2),
		Hi: percentile(means, 1-alpha/2),
	}
}

// admittedWorkFraction is the eligible input tokens admitted over those offered, the design's admission-match quantity.
func admittedWorkFraction(s ArmSummary) float64 {
	if s.OfferedInputTokens == 0 {
		return 0
	}
	return float64(s.AdmittedInputTokens) / float64(s.OfferedInputTokens)
}

// Checks holds the pre-registered success criteria and whether each passed.
type Checks struct {
	// AbsoluteProtection is C premium TTFT p99 <= 1.25 x R1 premium TTFT p99.
	AbsoluteProtectionRatio float64
	AbsoluteProtectionPass  bool
	// IncrementalValue is C/B premium TTFT p99, which must be <= 0.90 with the CI upper bound below 1.0.
	IncrementalRatio     float64
	IncrementalRatioCI   CI
	IncrementalValuePass bool
	// AdmissionMatch is |wB - wC| / wC over admitted-work fractions, which must be within MatchTolerance.
	AdmissionMatchDelta float64
	AdmissionMatchPass  bool
	// OverallPass is true only when every check passed, which is the condition for using the word "protects".
	OverallPass bool
}

// EvaluateChecks computes the design's pre-registered checks from the four arms' aggregated p99 values and admission-work fractions.
//
// r1P99, offP99 are provenance context; the checks compare C against R1 (absolute) and against B (incremental). incrementalCI is the bootstrap CI of the C/B ratio, produced by the caller from per-repetition ratios.
func EvaluateChecks(r1, staticCap, kvAware ArmSummary, incrementalCI CI, matchTolerance float64) Checks {
	var c Checks

	if r1.TTFTMsP99 > 0 {
		c.AbsoluteProtectionRatio = kvAware.TTFTMsP99 / r1.TTFTMsP99
		c.AbsoluteProtectionPass = c.AbsoluteProtectionRatio <= 1.25
	}

	if staticCap.TTFTMsP99 > 0 {
		c.IncrementalRatio = kvAware.TTFTMsP99 / staticCap.TTFTMsP99
	}
	c.IncrementalRatioCI = incrementalCI
	c.IncrementalValuePass = c.IncrementalRatio <= 0.90 && incrementalCI.Hi < 1.0

	wB := admittedWorkFraction(staticCap)
	wC := admittedWorkFraction(kvAware)
	if wC > 0 {
		c.AdmissionMatchDelta = math.Abs(wB-wC) / wC
		c.AdmissionMatchPass = c.AdmissionMatchDelta <= matchTolerance
	}

	c.OverallPass = c.AbsoluteProtectionPass && c.IncrementalValuePass && c.AdmissionMatchPass
	return c
}

// FormatReport renders the summaries and checks as a plain-text report.
//
// It states explicitly when the comparison is invalid (admission match missed) or the tail is censored, so a reader is never handed a clean-looking number that the methodology already disqualified.
func FormatReport(summaries []ArmSummary, checks Checks, matchTolerance float64) string {
	out := "M5-b benchmark report\n\n"
	out += fmt.Sprintf("%-12s %8s %8s %8s %8s %8s %8s %8s\n", "arm", "total", "done", "429", "timeout", "ttftP50", "ttftP95", "ttftP99")
	for _, s := range summaries {
		censored := ""
		if s.Censored {
			censored = " (p99 censored: >1% timeouts, lower bound)"
		}
		out += fmt.Sprintf("%-12s %8d %8d %8d %8d %8.1f %8.1f %8.1f%s\n",
			s.Arm, s.Total, s.Completed, s.Rejected, s.TimedOut, s.TTFTMsP50, s.TTFTMsP95, s.TTFTMsP99, censored)
	}
	out += "\nPre-registered checks (primary endpoint: TTFT p99)\n"
	out += fmt.Sprintf("  absolute protection  C/R1 = %.3f  (<= 1.25)  %s\n", checks.AbsoluteProtectionRatio, pass(checks.AbsoluteProtectionPass))
	out += fmt.Sprintf("  incremental value    C/B  = %.3f  CI[%.3f, %.3f]  (<= 0.90, CI hi < 1.0)  %s\n",
		checks.IncrementalRatio, checks.IncrementalRatioCI.Lo, checks.IncrementalRatioCI.Hi, pass(checks.IncrementalValuePass))
	out += fmt.Sprintf("  admission match      |B-C|/C = %.3f  (<= %.3f)  %s\n", checks.AdmissionMatchDelta, matchTolerance, pass(checks.AdmissionMatchPass))
	out += "\n"
	if checks.OverallPass {
		out += "VERDICT: all checks passed; the guard protects the premium tenant's tail beyond load shedding.\n"
	} else {
		out += "VERDICT: not all checks passed; the word \"protects\" is not used for this run.\n"
	}
	return out
}

// pass renders a boolean as a short marker for the report.
func pass(ok bool) string {
	if ok {
		return "PASS"
	}
	return "FAIL"
}
