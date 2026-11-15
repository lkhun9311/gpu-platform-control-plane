package bench

import (
	"errors"
	"fmt"
	"maps"
	"math"
	"slices"
	"time"
)

// The version study's descriptive outputs, reported beside the verdict and never voting in it.
//
// They are what a reader needs to see why a verdict came out as it did: how much of each arm failed and how, the point
// values behind the intervals, the success-only TPOT the registration keeps out of the vote, and the cost of a good request.

// CellCounts is one cell's reliability, reported for every cell as the registration requires.
type CellCounts struct {
	Block     int
	Offered   int
	Successes int
	Failures  map[RowDisposition]int
}

// Quantity is a reported number, or the reason there is none, so a missing value is never printed as zero.
type Quantity struct {
	Value   float64
	Defined bool
	Reason  string
}

func defined(v float64) Quantity { return Quantity{Value: v, Defined: true} }
func undefined(format string, a ...any) Quantity {
	return Quantity{Reason: fmt.Sprintf(format, a...)}
}

// ArmDescription is one arm at one load, pooled over the analysed blocks.
type ArmDescription struct {
	Treatment, Load string
	Cells           []CellCounts
	Offered         int
	Successes       int
	SuccessFraction float64
	Failures        map[RowDisposition]int
	// TTFTP99Ms and E2EP99Ms are the pooled point values behind the voting intervals; +Inf when the tail is a failure.
	TTFTP99Ms, E2EP99Ms float64
	// TPOTP99Ms is over successful requests that have a TPOT only, which is why it never votes.
	TPOTP99Ms Quantity
	TPOTRows  int
	// GoodputPerSecond is good requests ÷ (W × blocks).
	GoodputPerSecond float64
	// CostPerSLORequestUSD is the session rate × W × blocks ÷ good requests, the price of one good request.
	CostPerSLORequestUSD Quantity
	// UsageTrailerP99Ms and DoneTrailerP99Ms are the completion-through-trailer diagnostic over successes.
	UsageTrailerP99Ms, DoneTrailerP99Ms Quantity
}

// Describe reports every arm at every load over the analysed blocks, at the session rate the bundle froze.
func (d VersionStudyDesign) Describe(windowSeconds int, blocks []int, cells CampaignCells, rateUSDPerHour float64) ([]ArmDescription, error) {
	if !(rateUSDPerHour > 0) || math.IsInf(rateUSDPerHour, 0) {
		return nil, fmt.Errorf("session rate %v USD/h is not a read price", rateUSDPerHour)
	}
	if windowSeconds <= 0 || len(blocks) == 0 {
		return nil, errors.New("no window or no analysed block to describe")
	}
	var out []ArmDescription
	for _, tr := range versionStudyTreatments {
		for _, l := range versionStudyLoads {
			arm, err := cells.armBlocks(tr, l.Name, blocks)
			if err != nil {
				return nil, err
			}
			out = append(out, describeArm(tr, l.Name, blocks, arm, windowSeconds, rateUSDPerHour))
		}
	}
	return out, nil
}

func describeArm(treatment, load string, blocks []int, arm [][]RequestOutcome, windowSeconds int, rateUSDPerHour float64) ArmDescription {
	a := ArmDescription{Treatment: treatment, Load: load, Failures: map[RowDisposition]int{}}
	var ttft, e2e, tpot, usage, done []float64
	good := 0
	for i, cell := range arm {
		cc := CellCounts{Block: blocks[i], Offered: len(cell), Failures: map[RowDisposition]int{}}
		for _, o := range cell {
			ttft = append(ttft, o.TTFTNanos)
			e2e = append(e2e, o.E2ENanos)
			if o.Good {
				good++
			}
			if o.Disposition.IsFailure() {
				cc.Failures[o.Disposition]++
				continue
			}
			cc.Successes++
			for _, x := range []struct {
				v   float64
				dst *[]float64
			}{{o.TPOTNanos, &tpot}, {o.UsageAfterLastNanos, &usage}, {o.DoneAfterLastNanos, &done}} {
				if !math.IsNaN(x.v) {
					*x.dst = append(*x.dst, x.v)
				}
			}
		}
		a.Offered += cc.Offered
		a.Successes += cc.Successes
		for k, v := range cc.Failures {
			a.Failures[k] += v
		}
		a.Cells = append(a.Cells, cc)
	}
	ms := float64(time.Millisecond)
	if a.Offered > 0 {
		a.SuccessFraction = float64(a.Successes) / float64(a.Offered)
	}
	a.TTFTP99Ms = p99Of(ttft) / ms
	a.E2EP99Ms = p99Of(e2e) / ms
	a.TPOTRows = len(tpot)
	a.TPOTP99Ms = p99Quantity(tpot, ms, "no successful request has a TPOT")
	a.UsageTrailerP99Ms = p99Quantity(usage, ms, "no successful request recorded its usage trailer")
	a.DoneTrailerP99Ms = p99Quantity(done, ms, "no successful request recorded [DONE]")
	seconds := float64(windowSeconds) * float64(len(arm))
	a.GoodputPerSecond = float64(good) / seconds
	if good == 0 {
		a.CostPerSLORequestUSD = undefined("no good request, so a good request has no price")
	} else {
		a.CostPerSLORequestUSD = defined(rateUSDPerHour / 3600 * seconds / float64(good))
	}
	return a
}

// p99Of is the nearest-rank p99 of values, which may hold +Inf.
func p99Of(values []float64) float64 {
	s := slices.Clone(values)
	slices.Sort(s)
	return percentile(s, 0.99)
}

func p99Quantity(values []float64, unit float64, none string) Quantity {
	if len(values) == 0 {
		return undefined("%s", none)
	}
	return defined(p99Of(values) / unit)
}

// FailureKinds lists a description's failure dispositions in a fixed order, for a report that prints them.
func (a ArmDescription) FailureKinds() []RowDisposition {
	return slices.Sorted(maps.Keys(a.Failures))
}
