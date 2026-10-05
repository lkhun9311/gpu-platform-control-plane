package bench

import (
	"fmt"
	"sort"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("the study registry", func() {
	Describe("the price-of-protection sweep's arms", func() {
		It("names exactly the ten arms the pre-registration designs", func() {
			// Written out rather than regenerated from the same factors the code uses.
			//
			// A test that builds the expected names with the production function proves the function is
			// consistent with itself and nothing else. These strings are what the runner passes on the
			// command line and what a reader sees in the report, so they are pinned literally: changing
			// one has to be a deliberate edit here, not a side effect of touching a format string.
			s, ok := LookupStudy(StudyPriceOfProtection)
			Expect(ok).To(BeTrue())
			Expect(s.Arms).To(Equal([]string{
				"R1",
				"default-fcfs",
				"mbt-0256-fcfs",
				"mbt-0256-priority",
				"mbt-0512-fcfs",
				"mbt-0512-priority",
				"mbt-1024-fcfs",
				"mbt-1024-priority",
				"mbt-2048-fcfs",
				"mbt-2048-priority",
			}))
		})

		It("orders the cells numerically when sorted as strings", func() {
			// The zero padding is the whole reason the names are not b256/b512/b1024.
			//
			// Without it a plain sort gives 1024, 2048, 256, 512 -- a table whose budget column counts
			// down and then up, which a reader corrects for silently and a script does not correct for
			// at all.
			var cells []string
			for _, budget := range priceOfProtectionBudgets {
				cells = append(cells, PriceOfProtectionArm(budget, "fcfs"))
			}
			sorted := append([]string(nil), cells...)
			sort.Strings(sorted)
			Expect(sorted).To(Equal(cells), "lexical order must be numeric order")
		})

		It("refuses to admit an arm from the other study", func() {
			pop, _ := LookupStudy(StudyPriceOfProtection)
			m5b, _ := LookupStudy(StudyM5BGateway)

			// The specific collision the study field exists to prevent. The pre-registration's readings
			// call this study's control "off", and M5-b has an arm by that name which ran through a
			// gateway. Neither study may admit the other's condition.
			Expect(pop.Admits("off")).To(BeFalse())
			Expect(pop.Admits("kv-aware")).To(BeFalse())
			Expect(m5b.Admits("default-fcfs")).To(BeFalse())
			Expect(m5b.Admits("mbt-0512-priority")).To(BeFalse())

			// R1 is the one name both studies legitimately share: an isolated premium baseline means the
			// same thing in each, and both measure it as their ceiling.
			Expect(pop.Admits(ArmR1)).To(BeTrue())
			Expect(m5b.Admits(ArmR1)).To(BeTrue())
		})
	})

	Describe("evidence that predates the study field", func() {
		It("reads an empty study as the gateway experiment", func() {
			// Every raw file this repository has written so far carries no study at all. They are M5-b's,
			// because M5-b is the only experiment that has been run, and a report has to keep reading
			// them.
			s, ok := LookupStudy("")
			Expect(ok).To(BeTrue())
			Expect(s.ID).To(Equal(StudyM5BGateway))
		})

		It("does not invent a study for an identifier nobody registered", func() {
			_, ok := LookupStudy("price-of-protection")
			Expect(ok).To(BeFalse(), "a near-miss on a real study ID must not resolve")
		})
	})

	Describe("the repetition floor each registration fixed", func() {
		It("carries the number each pre-registration states, as a literal", func() {
			// Pinned literally for the reason the arm names above are: a table built from the production
			// values proves the registry is consistent with itself. These numbers decide how many paid cells
			// a study needs, so changing one has to be a deliberate edit here.
			//
			// Zero means "this registration fixed no floor", which is a value and not an omission -- the same
			// distinction a nil Frozen draws. A refusal reading zero declines to judge rather than treating
			// it as a floor of none.
			for _, c := range []struct {
				id       string
				minReps  int
				interval bool
			}{
				{StudyM5BGateway, 5, true},
				{StudySharingMatrix, 5, true},
				{StudyTailCrossingShortLC, 2, false},
				{StudyTailCrossingMidLC, 2, false},
				{StudyTailCrossingLongLC, 2, false},
				{StudyPriceOfProtection, 0, false},
				{StudyThroughputLadder, 0, false},
				{StudyThroughputLadderDown, 0, false},
				{StudyThroughputLadderIndependent, 0, false},
			} {
				s, ok := LookupStudy(c.id)
				Expect(ok).To(BeTrue(), c.id)
				Expect(s.MinRepetitions).To(Equal(c.minReps), fmt.Sprintf("%s's repetition floor", c.id))
				Expect(s.PublishesInterval).To(Equal(c.interval), fmt.Sprintf("%s's interval promise", c.id))
			}
		})

		It("never promises an interval on fewer than three repetitions", func() {
			// The pair has to be read together, and this is the disagreement worth refusing. Measured
			// 2026-10-04 by calling the interval functions with two values: BootstrapCI returned
			// Lo=3998.000 Hi=4001.000 and PairedRatioCI returned Lo=22.8629 Hi=22.9770, both with an EMPTY
			// InvalidReason -- each declines only at n==1. A two-point bootstrap has four distinct
			// resamples, so those bounds ARE the two observations, which this project's own report calls an
			// OBSERVED RANGE rather than an interval.
			//
			// Three rather than five, because what is being excluded is the degenerate case the functions
			// cannot detect. Whether five is required is a question for each registration, and the literal
			// table above is where that answer lives.
			for _, id := range KnownStudyIDs() {
				s, _ := LookupStudy(id)
				if !s.PublishesInterval || s.MinRepetitions == 0 {
					continue
				}
				Expect(s.MinRepetitions).To(BeNumerically(">=", 3),
					fmt.Sprintf("%s publishes an interval on %d repetitions, whose bounds would be the observations themselves", id, s.MinRepetitions))
			}
		})

		It("fixes a floor for every study that froze a load", func() {
			// A study with a frozen tuple is one a paid run can be bought for, and the cell count follows
			// from the floor. Nothing else makes a new entry declare one: the registry's size is pinned
			// nowhere, so an eighth study added with both fields omitted would read as zero -- "no
			// registration said" -- on a study whose registration certainly has to.
			//
			// Tied to Frozen rather than to a list of ids so that the next frozen study inherits the demand
			// instead of being added to a literal somebody has to remember to extend.
			for _, id := range KnownStudyIDs() {
				s, _ := LookupStudy(id)
				if s.Frozen == nil {
					continue
				}
				Expect(s.MinRepetitions).To(BeNumerically(">=", 1),
					fmt.Sprintf("%s freezes a load but fixes no repetition floor, so nothing says how many cells its question costs", id))
			}
		})
	})

	Describe("the report's arm column", func() {
		It("is wide enough for the longest arm any study defines", func() {
			// This was the literal 12, sized for M5-b's four names. "mbt-0512-priority" is 17, so every
			// column to its right would have been pushed out of line in the one table a reader looks at
			// -- and nothing would have failed. Deriving the width means a new study cannot do that.
			widest := 0
			var widestName string
			for _, id := range KnownStudyIDs() {
				s, _ := LookupStudy(id)
				for _, a := range s.Arms {
					if len(a) > widest {
						widest, widestName = len(a), a
					}
				}
			}
			Expect(ArmColumnWidth).To(BeNumerically(">=", widest),
				fmt.Sprintf("arm %q does not fit", widestName))
		})

		It("keeps the columns aligned for the longest name", func() {
			// The property that matters is alignment, so it is checked by formatting rather than by
			// asserting a number equal to the one the production code computed.
			short := fmt.Sprintf("%-*s|", ArmColumnWidth, ArmR1)
			long := fmt.Sprintf("%-*s|", ArmColumnWidth, "mbt-0512-priority")
			Expect(short).To(HaveLen(len(long)))
		})
	})
})
