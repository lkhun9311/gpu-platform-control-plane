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
	"strings"
)

// TailCrossingLevel is one arm of a tail-crossing sweep, read against the isolated baseline.
//
// The estimand is the POOLED percentile over every completed latency-critical request of every trace, and
// not the median of the per-trace p99s the sharing matrix registered. The 2026-10-04 model-first
// registration made each repetition an independent trace, so the population is the arrival process; the
// median of per-trace p99s would summarise a statistic of each draw instead of the draws together, and at
// about 172 completions a trace's p99 is its second-largest value. The per-trace p99s are carried beside it.
type TailCrossingLevel struct {
	Arm       string
	Traces    int
	Completed int
	P95       float64
	P99       float64
	// PerTraceP99 is each trace's own p99, published beside the pooled one rather than instead of it.
	PerTraceP99 []float64
	// Multiple95/99 and Added95/99Ms are against the baseline at the same percentile, and zero when the
	// level is refused: a refused level carries no number a reader could quote.
	Multiple95, Multiple99 float64
	Added95Ms, Added99Ms   float64
	// InvalidReason is why this level is not read, or "".
	InvalidReason string
}

// TailCrossingResult is a sweep's baseline and every level it bought.
type TailCrossingResult struct {
	Study    string
	Baseline TailCrossingLevel
	Levels   []TailCrossingLevel
	// InvalidReason refuses the whole sweep, which happens only when the baseline cannot be read: every
	// level is a ratio against it.
	InvalidReason string
}

// EvaluateTailCrossing reads each BE level of a tail-crossing sweep against the isolated baseline.
//
// It registers no verdict and no threshold, as the exploratory registration does not; it reports magnitudes
// and the reasons a magnitude is withheld. A level is refused on its own -- a censored or thin level does not
// take the others with it -- while a baseline that cannot be read refuses all of them.
func EvaluateTailCrossing(study string, summaries []ArmSummary) TailCrossingResult {
	r := TailCrossingResult{Study: study}
	var base *ArmSummary
	for i := range summaries {
		if summaries[i].Arm == ArmR1 {
			base = &summaries[i]
		}
	}
	if base == nil {
		r.InvalidReason = fmt.Sprintf("no %s arm, so there is no isolated tail to read any level against", ArmR1)
		return r
	}
	r.Baseline = tailCrossingRow(*base)
	if why := tailCrossingRefusal(*base, nil); why != "" {
		r.InvalidReason = "the isolated baseline cannot be read: " + why
		return r
	}
	for _, s := range summaries {
		if !isTailCrossingArm(s.Arm) {
			continue
		}
		row := tailCrossingRow(s)
		if why := tailCrossingRefusal(s, base); why != "" {
			row.InvalidReason = why
		} else {
			row.Multiple95, row.Added95Ms = s.TTFTMsP95/base.TTFTMsP95, s.TTFTMsP95-base.TTFTMsP95
			row.Multiple99, row.Added99Ms = s.TTFTMsP99/base.TTFTMsP99, s.TTFTMsP99-base.TTFTMsP99
		}
		r.Levels = append(r.Levels, row)
	}
	return r
}

func tailCrossingRow(s ArmSummary) TailCrossingLevel {
	return TailCrossingLevel{
		Arm: s.Arm, Traces: s.RepetitionCount, Completed: s.TailSampleSize,
		P95: s.TTFTMsP95, P99: s.TTFTMsP99, PerTraceP99: s.RepetitionTTFTMsP99,
	}
}

// tailCrossingRefusal is why an arm's pooled tail is not read, or "". base is nil for the baseline itself.
//
// The conditions are RegisteredEstimandFor's, held per trace, plus the one a pooled estimand adds: a level
// pooled over fewer traces than its baseline is a different sample of the arrival process, not a paired one.
func tailCrossingRefusal(s ArmSummary, base *ArmSummary) string {
	switch {
	case censored(s):
		return fmt.Sprintf("%s has a censored tail, so its pooled percentiles are not the registered estimand", s.Arm)
	case s.RepetitionCount > 0 && s.MinRepetitionTail < MinTailSamples:
		return fmt.Sprintf("%s has a repetition with %d latency-critical completions, below the %d a nearest-rank p99 needs per trace",
			s.Arm, s.MinRepetitionTail, MinTailSamples)
	case s.TailSampleSize < MinTailSamples:
		return fmt.Sprintf("%s completed %d latency-critical requests, below the %d a nearest-rank p99 needs", s.Arm, s.TailSampleSize, MinTailSamples)
	case base == nil && (s.TTFTMsP95 <= 0 || s.TTFTMsP99 <= 0):
		return fmt.Sprintf("%s has a non-positive tail, which cannot be divided by", s.Arm)
	case base != nil && s.RepetitionCount != base.RepetitionCount:
		return fmt.Sprintf("%s pooled %d trace(s) against the baseline's %d, so the two are not the same draws of the arrival process",
			s.Arm, s.RepetitionCount, base.RepetitionCount)
	}
	return ""
}

// FormatTailCrossing renders the readings, or nothing for a result that is not a tail-crossing sweep.
func FormatTailCrossing(r TailCrossingResult) string {
	if r.Study == "" {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "\nTAIL-CROSSING READINGS (%s)\n", r.Study)
	b.WriteString("  Latency-critical TTFT, pooled over every trace of an arm; each level against the isolated baseline.\n")
	b.WriteString("  Exploratory: magnitudes only, no verdict and no threshold are registered.\n")
	if r.InvalidReason != "" {
		fmt.Fprintf(&b, "  NOT READ: %s\n", r.InvalidReason)
		return b.String()
	}
	fmt.Fprintf(&b, "  %-12s %6s %6s %9s %9s %18s %18s  %s\n", "arm", "traces", "n", "p95 ms", "p99 ms", "p95 vs R1", "p99 vs R1", "per-trace p99 ms")
	row := func(l TailCrossingLevel, vs95, vs99 string) {
		fmt.Fprintf(&b, "  %-12s %6d %6d %9.1f %9.1f %18s %18s  %s\n", l.Arm, l.Traces, l.Completed, l.P95, l.P99, vs95, vs99, joinMs(l.PerTraceP99))
	}
	row(r.Baseline, "-", "-")
	for _, l := range r.Levels {
		if l.InvalidReason != "" {
			fmt.Fprintf(&b, "  %-12s NOT READ: %s\n", l.Arm, l.InvalidReason)
			continue
		}
		row(l, fmt.Sprintf("%.2fx %+.1f", l.Multiple95, l.Added95Ms), fmt.Sprintf("%.2fx %+.1f", l.Multiple99, l.Added99Ms))
	}
	return b.String()
}

func joinMs(v []float64) string {
	parts := make([]string, len(v))
	for i, x := range v {
		parts[i] = fmt.Sprintf("%.1f", x)
	}
	return strings.Join(parts, " ")
}
