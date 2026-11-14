package bench

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gateway"
)

var _ = Describe("a request the gateway had no room to hold", func() {
	// holdRow is an eligible standard request refused 503 with reason, as the sender records it.
	holdRow := func(index int, reason string) RawRow {
		return RawRow{Index: index, SendUnixNanos: 1, HTTPStatus: 503, ErrorKind: "http", AdmissionReason: reason, EstInputTokens: 8000}
	}

	// It is neither admitted nor shed: a 503 used to land in the admitted terms of the fraction because it was not a 429.
	// Mutations that turn this red: drop the early return in tallyEligibleWork, or stop counting HoldRefused.
	It("is counted apart and kept out of both terms of the admitted-work fraction", func() {
		var rows []RawRow
		for i := 1; i <= 100; i++ {
			rows = append(rows, completedRow(i, float64(i), 100))
		}
		rows = append(rows, holdRow(101, gateway.ReasonHoldFull), holdRow(102, gateway.ReasonHoldTenantFull))

		s := Summarize("serial", rows)
		Expect(s.HoldRefused).To(Equal(2))
		Expect(s.Rejected).To(BeZero(), "a hold refusal is not the guard shedding work")
		Expect(s.OfferedInputTokens).To(BeZero())
		Expect(s.AdmittedInputTokens).To(BeZero())
		Expect(s.AdmissionLost).To(BeZero(), "the response arrived, so the verdict is not lost; it is the gateway's")
	})

	// Only the gateway's two reasons on a 503 count; a 503 for anything else is another failure, and the reason alone is not enough.
	// Mutation that turns this red: match on the status alone, or on the reason alone.
	It("needs both the 503 and one of the two reasons", func() {
		other := holdRow(1, "")
		wrongStatus := holdRow(2, gateway.ReasonHoldFull)
		wrongStatus.HTTPStatus = 429
		s := Summarize("serial", []RawRow{other, wrongStatus, holdRow(3, gateway.ReasonHoldFull)})
		Expect(s.HoldRefused).To(Equal(1))
	})

	// A compared arm that met the limit measured the gateway's capacity as well as its policy, so the run cannot certify either.
	// Mutation that turns this red: drop the invalidation in EvaluateChecks.
	It("invalidates a run whose compared arm had any", func() {
		r1 := ArmSummary{Arm: "R1", TTFTMsP99: 100, TailSampleSize: 500}
		staticCap := ArmSummary{Arm: "static-cap", TTFTMsP99: 200, OfferedInputTokens: 1000, AdmittedInputTokens: 500, OfferedExactTokens: 1000, AdmittedExactTokens: 500, TailSampleSize: 500}
		kvAware := ArmSummary{Arm: "kv-aware", TTFTMsP99: 110, OfferedInputTokens: 1000, AdmittedInputTokens: 510, OfferedExactTokens: 1000, AdmittedExactTokens: 510, TailSampleSize: 500}
		ci := CI{Lo: 0.45, Hi: 0.65, Valid: true}
		Expect(EvaluateChecks(r1, staticCap, kvAware, ci, 0.05).Invalid).To(BeFalse(), "the baseline must be valid for the next line to mean anything")

		kvAware.HoldRefused = 1
		c := EvaluateChecks(r1, staticCap, kvAware, ci, 0.05)
		Expect(c.Invalid).To(BeTrue())
		Expect(c.InvalidReason).To(ContainSubstring("could hold no more"))
		Expect(c.OverallPass).To(BeFalse())
	})
})
