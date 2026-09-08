package bench

import (
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// The fixtures are built from the pre-registration's bars rather than from the pilot's numbers, so a reading
// that drifts from the document fails here rather than agreeing with whatever the last run happened to do.
//
// R1: TTFT p99 100 ms, premium TPOT p99 20 ms. Control: TTFT p99 1000 ms (10x, so reading 4 never fires by
// accident), 1000 output tokens of which the noisy tenant has 400, throughput 100 tok/s.
func popR1() ArmSummary {
	return ArmSummary{
		Arm: ArmR1, TTFTMsP99: 100, TailSampleSize: 500,
		TPOTMsP99ByTenant: map[string]float64{PremiumTenant: 20},
	}
}

func popControl() ArmSummary {
	return ArmSummary{
		Arm: ArmDefaultFCFS, TTFTMsP99: 1000, TailSampleSize: 500,
		TPOTMsP99ByTenant:     map[string]float64{PremiumTenant: 200},
		OutputTokens:          1000,
		OutputTokensByTenant:  map[string]int64{PremiumTenant: 600, NoisyTenant: 400},
		OutputTokensPerSecond: 100,
		RepetitionTTFTMsP99:   []float64{980, 1000, 1020},
		RepetitionCount:       3,
	}
}

// popCell builds a cell at the given multiples of the bars. share is the noisy tenant's fraction of the
// control's share, and thru is the fraction of the control's throughput.
func popCell(name string, ttftX, tpotX, share, thru float64) ArmSummary {
	noisy := int64(400 * share)
	return ArmSummary{
		Arm: name, TTFTMsP99: 100 * ttftX, TailSampleSize: 500,
		TPOTMsP99ByTenant:     map[string]float64{PremiumTenant: 20 * tpotX},
		OutputTokens:          1000,
		OutputTokensByTenant:  map[string]int64{PremiumTenant: 1000 - noisy, NoisyTenant: noisy},
		OutputTokensPerSecond: 100 * thru,
		DispositionByTenant:   map[string]Disposition{NoisyTenant: {Offered: 100, Completed: 100}},
	}
}

var _ = Describe("the price-of-protection readings", func() {
	It("fires reading 4 and stops when the load made no contention", func() {
		control := popControl()
		control.TTFTMsP99 = 400 // 4x R1, under the 5x bar
		res := EvaluatePriceOfProtection(popR1(), control,
			[]ArmSummary{popCell("mbt-0512-priority", 1.0, 1.0, 1.0, 1.0)}, PremiumTenant, NoisyTenant)

		Expect(res.Readings[0].ID).To(Equal("4"))
		Expect(res.Readings[0].Fired).To(BeTrue())
		Expect(res.Answer).To(Equal("4"))
		// And nothing below it is scored: an uncontended load makes those comparisons meaningless, not
		// negative, so reporting them as "did not fire" would be four wrong answers.
		Expect(res.Readings).To(HaveLen(1))
	})

	It("fires reading 1 for a cell that holds all four bars", func() {
		res := EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{
			popCell("mbt-0256-fcfs", 5.0, 1.0, 1.0, 1.0),      // tail too slow
			popCell("mbt-0512-priority", 1.5, 1.1, 0.9, 0.98), // all four
		}, PremiumTenant, NoisyTenant)

		Expect(res.Answer).To(Equal("1 (mbt-0512-priority)"))
	})

	It("does not fire reading 1 for a cell that protects the tail by deleting the tenant's work", func() {
		res := EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{
			popCell("mbt-0512-priority", 1.5, 1.1, 0.10, 1.0), // share far below 0.75
		}, PremiumTenant, NoisyTenant)

		Expect(readingByID(res, "1").Fired).To(BeFalse())
	})

	It("fires reading 1b when the only thing a cell misses is throughput", func() {
		res := EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{
			popCell("mbt-0512-priority", 1.5, 1.1, 0.9, 0.80), // 80% of the control's throughput
		}, PremiumTenant, NoisyTenant)

		Expect(readingByID(res, "1").Fired).To(BeFalse())
		Expect(readingByID(res, "1b").Fired).To(BeTrue())
		Expect(readingByID(res, "1b").Detail).To(ContainSubstring("20%"))
	})

	It("fires reading 2 only when the ledger shows the work was refused, not merely late", func() {
		deleted := popCell("mbt-0512-fcfs", 1.5, 1.1, 0.10, 1.0)
		deleted.DispositionByTenant = map[string]Disposition{
			NoisyTenant: {Offered: 100, Completed: 10, Rejected: 90},
		}
		res := EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{deleted}, PremiumTenant, NoisyTenant)
		Expect(readingByID(res, "2").Fired).To(BeTrue())

		// The same small share, reached by timing out instead. That is delay, and the pre-registration is
		// explicit that a share loss alone cannot tell the two apart.
		late := popCell("mbt-0512-fcfs", 1.5, 1.1, 0.10, 1.0)
		late.DispositionByTenant = map[string]Disposition{
			NoisyTenant: {Offered: 100, Completed: 10, TimedOut: 90},
		}
		res = EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{late}, PremiumTenant, NoisyTenant)
		Expect(readingByID(res, "2").Fired).To(BeFalse())
		Expect(readingByID(res, "2").Detail).To(ContainSubstring("delay rather than deletion"))
	})

	It("declines to decide reading 2 when the evidence carries no per-tenant ledger", func() {
		blind := popCell("mbt-0512-fcfs", 1.5, 1.1, 0.10, 1.0)
		blind.DispositionByTenant = nil
		res := EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{blind}, PremiumTenant, NoisyTenant)

		r := readingByID(res, "2")
		Expect(r.NotEvaluable).To(BeTrue())
		Expect(r.Fired).To(BeFalse())
	})

	It("declines to decide reading 3 without at least two repetitions of the control", func() {
		control := popControl()
		control.RepetitionTTFTMsP99 = []float64{1000}
		control.RepetitionCount = 1
		res := EvaluatePriceOfProtection(popR1(), control, []ArmSummary{
			popCell("mbt-0512-fcfs", 5.0, 5.0, 1.0, 1.0),
		}, PremiumTenant, NoisyTenant)

		r := readingByID(res, "3")
		Expect(r.NotEvaluable).To(BeTrue())
		Expect(r.Fired).To(BeFalse())
	})

	It("fires reading 3 when no cell beats the control by more than its own spread", func() {
		// Control spread is 1020-980 = 40 ms. This cell improves it by 10 ms, which is inside the noise.
		res := EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{
			{Arm: "mbt-0512-fcfs", TTFTMsP99: 990, TailSampleSize: 500,
				TPOTMsP99ByTenant: map[string]float64{PremiumTenant: 200}, OutputTokens: 1000,
				OutputTokensByTenant: map[string]int64{NoisyTenant: 400}, OutputTokensPerSecond: 100},
		}, PremiumTenant, NoisyTenant)

		Expect(readingByID(res, "3").Fired).To(BeTrue())
	})

	It("reports no answer rather than a false one when nothing fired", func() {
		// A cell that beats the control well past its spread, but misses every positive bar. None of the five
		// applies, and the honest output is silence rather than the nearest negative.
		res := EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{
			popCell("mbt-0512-priority", 3.0, 5.0, 1.0, 1.0),
		}, PremiumTenant, NoisyTenant)

		Expect(res.Answer).To(BeEmpty())
		Expect(FormatPriceOfProtection(res)).To(ContainSubstring("none of the readings fired"))
	})

	It("prints every reading with the numbers it was decided on", func() {
		res := EvaluatePriceOfProtection(popR1(), popControl(), []ArmSummary{
			popCell("mbt-0512-priority", 1.5, 1.1, 0.9, 0.98),
		}, PremiumTenant, NoisyTenant)
		out := FormatPriceOfProtection(res)

		for _, id := range []string{"1", "1b", "2", "3", "4"} {
			Expect(out).To(MatchRegexp(`(?m)^  ` + id + `\s`))
		}
		Expect(strings.Count(out, "\n")).To(BeNumerically(">", 10))
	})
})

func readingByID(res PoPResult, id string) PoPReading {
	for _, r := range res.Readings {
		if r.ID == id {
			return r
		}
	}
	return PoPReading{ID: "missing:" + id}
}
