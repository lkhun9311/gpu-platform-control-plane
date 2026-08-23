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
	"strings"
)

// httpStatusTooManyRequests is the status the gateway returns when an admission control rejects a request.
const httpStatusTooManyRequests = 429

// errKindTimeout is the RawRow.ErrorKind the replay client records when a request exceeds its deadline.
const errKindTimeout = "timeout"

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
	// Censored is true when more than 1% of the premium requests timed out, so the tail is a lower bound rather than an exact p99 (design spec: report it as at least the timeout, never drop it).
	Censored bool
	// TailSampleSize is the number of completed premium requests the tail percentiles were computed over.
	//
	// The pre-registered checks refuse a run whose compared arms have a zero-size tail, so a run that completed nothing cannot be certified as protection.
	TailSampleSize int
}

// eligibleLongThreshold mirrors the guard's standard-long threshold, so admitted-work is measured over the same population the guard and static cap actually gate.
const eligibleLongThreshold = 4096

// Summarize computes one arm's summary from its raw rows.
//
// The tail percentiles are the DESIGN'S PRIMARY ENDPOINT: premium (victim) TTFT p99, so they are computed only over the premium tenant's completed requests, never over the noisy contender whose long prefills would otherwise dominate the tail and let a guard flatter its number by shedding contender load.
//
// The overall completed/rejected/timed-out/failed counts still account for every offered request, so shedding load always shows up as a rejection count.
//
// The admitted-work fractions are measured over the eligible (standard-long) population, which is the contender the controls actually gate.
func Summarize(arm string, rows []RawRow) ArmSummary {
	s := ArmSummary{Arm: arm, Total: len(rows)}

	// The eligible-population threshold comes from the manifest provenance stamped into the rows, so admitted-work is scored over the same population the guard gated even if the paid run tuned it.
	threshold := eligibleLongThreshold
	if len(rows) > 0 && rows[0].LongThreshold > 0 {
		threshold = rows[0].LongThreshold
	}

	var ttft, e2e []float64
	var premiumTotal, premiumTimedOut int
	for _, r := range rows {
		// Admitted-work accounting covers the eligible population (the long requests the controls gate), for the admission-match check.
		if r.EstInputTokens >= threshold {
			s.OfferedInputTokens += int64(r.EstInputTokens)
			if r.HTTPStatus != httpStatusTooManyRequests {
				s.AdmittedInputTokens += int64(r.EstInputTokens)
			}
		}

		// Overall outcome counts cover every offered request, so load shedding is always visible as a rejection.
		switch {
		case r.ErrorKind == errKindTimeout:
			s.TimedOut++
		case r.HTTPStatus == httpStatusTooManyRequests:
			s.Rejected++
		case r.ErrorKind != "":
			s.Failed++
		default:
			if _, ok := r.TTFTNanos(); ok {
				s.Completed++
			} else {
				s.Failed++
			}
		}

		// The tail is premium-only; the contender's requests never enter the protected metric.
		if r.IsNoisy {
			continue
		}
		premiumTotal++
		if r.ErrorKind == errKindTimeout {
			premiumTimedOut++
			continue
		}
		if r.HTTPStatus == httpStatusTooManyRequests || r.ErrorKind != "" {
			continue
		}
		t, okT := r.TTFTNanos()
		e, okE := r.E2ENanos()
		if !okT || !okE {
			continue
		}
		ttft = append(ttft, nanosToMs(t))
		e2e = append(e2e, nanosToMs(e))
	}

	sort.Float64s(ttft)
	sort.Float64s(e2e)
	s.TailSampleSize = len(ttft)
	s.TTFTMsP50 = percentile(ttft, 0.50)
	s.TTFTMsP95 = percentile(ttft, 0.95)
	s.TTFTMsP99 = percentile(ttft, 0.99)
	s.E2EMsP99 = percentile(e2e, 0.99)

	// The tail is censored when more than 1% of the PREMIUM requests timed out, since those missing slow requests are exactly the ones a p99 should capture.
	if premiumTotal > 0 && float64(premiumTimedOut)/float64(premiumTotal) > 0.01 {
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
	rank = max(rank, 0)
	rank = min(rank, len(sorted)-1)
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
	for i := range iterations {
		var sum float64
		for range n {
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
	// Invalid marks a run whose evidence disqualifies the comparison before any check is read, so a degenerate run can never be certified as protection.
	//
	// InvalidReason names why, for the report.
	Invalid       bool
	InvalidReason string
	// OverallPass is true only when the run is valid and every check passed, which is the condition for using the word "protects".
	OverallPass bool
}

// MinTailSamples is the smallest premium-completion count at which the reported p99 is not simply the
// largest observation.
//
// It is derived, not chosen. The percentile is nearest-rank: index ceil(0.99*n)-1, clamped to n-1. Solve
// ceil(0.99*n)-1 < n-1 and the smallest integer that satisfies it is 100 -- at n=99 the index lands on 98
// of 0..98, the maximum, and every value below 99 does the same. So a run with fewer than 100 premium
// completions reports its slowest request and calls it a tail.
//
// This mattered because nothing read TailSampleSize. It was computed, stored, asserted on in unit tests,
// and never consulted by any production path: not printed, not gating validity. A sixty-second run at a
// rate the engine cannot serve yields a few dozen completions, and the report would have presented that
// maximum with exactly the authority of a p99 over five thousand.
const MinTailSamples = 100

// EvaluateChecks computes the design's pre-registered checks from the four arms' aggregated p99 values and admission-work fractions.
//
// r1P99, offP99 are provenance context; the checks compare C against R1 (absolute) and against B (incremental). incrementalCI is the bootstrap CI of the C/B ratio, produced by the caller from per-repetition ratios.
func EvaluateChecks(r1, staticCap, kvAware ArmSummary, incrementalCI CI, matchTolerance float64) Checks {
	var c Checks

	// A comparison is disqualified before any check is read if a compared arm completed no premium requests or has a censored tail, since its p99 is then not a real tail.
	for _, s := range []ArmSummary{r1, staticCap, kvAware} {
		if s.TailSampleSize == 0 {
			c.Invalid = true
			c.InvalidReason = fmt.Sprintf("arm %s completed no premium requests, so its tail is undefined", s.Arm)
		}
		if s.TailSampleSize > 0 && s.TailSampleSize < MinTailSamples {
			c.Invalid = true
			c.InvalidReason = fmt.Sprintf("arm %s has %d premium completions, below the %d a nearest-rank p99 needs to be anything other than the maximum",
				s.Arm, s.TailSampleSize, MinTailSamples)
		}
		if s.Censored {
			c.Invalid = true
			c.InvalidReason = fmt.Sprintf("arm %s tail is censored (>1%% premium timeouts), so its p99 is only a lower bound", s.Arm)
		}
	}

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

	c.OverallPass = !c.Invalid && c.AbsoluteProtectionPass && c.IncrementalValuePass && c.AdmissionMatchPass
	return c
}

// FormatReport renders the summaries and checks as a plain-text report.
//
// It states explicitly when the comparison is invalid (admission match missed) or the tail is censored, so a reader is never handed a clean-looking number that the methodology already disqualified.
func FormatReport(summaries []ArmSummary, checks Checks, matchTolerance float64) string {
	var b strings.Builder
	b.WriteString("M5-b benchmark report\n\n")
	fmt.Fprintf(&b, "%-12s %8s %8s %8s %8s %8s %8s %8s %8s\n", "arm", "total", "done", "429", "timeout", "ttftP50", "ttftP95", "ttftP99", "tailN")
	for _, s := range summaries {
		censored := ""
		if s.Censored {
			censored = " (p99 censored: >1% timeouts, lower bound)"
		}
		// tailN is printed because the p99 beside it is meaningless without it, and because a reader who
		// cannot see the sample count has no way to tell a tail from a maximum.
		thin := ""
		if s.TailSampleSize > 0 && s.TailSampleSize < MinTailSamples {
			thin = fmt.Sprintf(" (p99 is the maximum: %d < %d premium completions)", s.TailSampleSize, MinTailSamples)
		}
		fmt.Fprintf(&b, "%-12s %8d %8d %8d %8d %8.1f %8.1f %8.1f %8d%s%s\n",
			s.Arm, s.Total, s.Completed, s.Rejected, s.TimedOut, s.TTFTMsP50, s.TTFTMsP95, s.TTFTMsP99, s.TailSampleSize, censored, thin)
	}
	b.WriteString("\nPre-registered checks (primary endpoint: TTFT p99)\n")
	fmt.Fprintf(&b, "  absolute protection  C/R1 = %.3f  (<= 1.25)  %s\n", checks.AbsoluteProtectionRatio, pass(checks.AbsoluteProtectionPass))
	fmt.Fprintf(&b, "  incremental value    C/B  = %.3f  CI[%.3f, %.3f]  (<= 0.90, CI hi < 1.0)  %s\n",
		checks.IncrementalRatio, checks.IncrementalRatioCI.Lo, checks.IncrementalRatioCI.Hi, pass(checks.IncrementalValuePass))
	fmt.Fprintf(&b, "  admission match      |B-C|/C = %.3f  (<= %.3f)  %s\n", checks.AdmissionMatchDelta, matchTolerance, pass(checks.AdmissionMatchPass))
	if checks.Invalid {
		fmt.Fprintf(&b, "  RUN INVALID: %s\n", checks.InvalidReason)
	}
	b.WriteString("\n")
	switch {
	case checks.Invalid:
		b.WriteString("VERDICT: run invalid; no protection claim is made from this evidence.\n")
	case checks.OverallPass:
		b.WriteString("VERDICT: all checks passed; the guard protects the premium tenant's tail beyond load shedding.\n")
	default:
		b.WriteString("VERDICT: not all checks passed; the word \"protects\" is not used for this run.\n")
	}
	return b.String()
}

// pass renders a boolean as a short marker for the report.
func pass(ok bool) string {
	if ok {
		return "PASS"
	}
	return "FAIL"
}
