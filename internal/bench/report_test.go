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
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// completedRow builds a raw row for a request that finished with the given TTFT in ms.
func completedRow(index int, ttftMs float64, estInput int) RawRow {
	base := int64(1_000_000_000)
	return RawRow{
		Index:               index,
		SendUnixNanos:       base,
		FirstTokenUnixNanos: base + int64(ttftMs*1e6),
		EndUnixNanos:        base + int64((ttftMs+1)*1e6),
		EstInputTokens:      estInput,
		OutputTokens:        8,
		HTTPStatus:          200,
	}
}

var _ = Describe("percentile", func() {
	It("uses nearest-rank on an observed value", func() {
		s := []float64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
		Expect(percentile(s, 0.50)).To(Equal(float64(5)))
		Expect(percentile(s, 0.99)).To(Equal(float64(10)))
		Expect(percentile(s, 0.90)).To(Equal(float64(9)))
	})
})

var _ = Describe("Summarize", func() {
	It("counts outcomes and computes the tail over completed requests", func() {
		var rows []RawRow
		// 100 completed requests with TTFT 1..100 ms.
		for i := 1; i <= 100; i++ {
			rows = append(rows, completedRow(i, float64(i), 100))
		}
		// One rejection and one timeout.
		rows = append(rows, RawRow{Index: 101, SendUnixNanos: 1, HTTPStatus: 429, EstInputTokens: 8000})
		rows = append(rows, RawRow{Index: 102, SendUnixNanos: 1, ErrorKind: "timeout", EstInputTokens: 8000})

		s := Summarize("off", rows)
		Expect(s.Total).To(Equal(102))
		Expect(s.Completed).To(Equal(100))
		Expect(s.Rejected).To(Equal(1))
		Expect(s.TimedOut).To(Equal(1))
		Expect(s.TTFTMsP50).To(Equal(float64(50)))
		Expect(s.TTFTMsP99).To(Equal(float64(99)))
		// Admitted-work over the eligible (>=4096-token) population: one offered (rejected) + one offered (timed out, not a 429 so counts as admitted work).
		Expect(s.OfferedInputTokens).To(Equal(int64(16000)))
		Expect(s.AdmittedInputTokens).To(Equal(int64(8000))) // the timeout row was admitted (not 429); the 429 was not
	})

	It("flags the tail as censored when more than 1% of requests time out", func() {
		var rows []RawRow
		for i := 1; i <= 98; i++ {
			rows = append(rows, completedRow(i, float64(i), 100))
		}
		rows = append(rows, RawRow{Index: 99, SendUnixNanos: 1, ErrorKind: "timeout"})
		rows = append(rows, RawRow{Index: 100, SendUnixNanos: 1, ErrorKind: "timeout"})
		s := Summarize("off", rows)
		Expect(s.TimedOut).To(Equal(2))
		Expect(s.Censored).To(BeTrue()) // 2/100 = 2% > 1%
	})
})

var _ = Describe("BootstrapCI", func() {
	It("degenerates to the point estimate for a single repetition", func() {
		ci := BootstrapCI([]float64{42}, 1000, 7, 0.05)
		Expect(ci.Lo).To(Equal(float64(42)))
		Expect(ci.Hi).To(Equal(float64(42)))
	})

	It("brackets the mean and is reproducible for a fixed seed", func() {
		vals := []float64{10, 11, 12, 13, 14, 15, 16, 17, 18, 19} // mean 14.5
		a := BootstrapCI(vals, 2000, 99, 0.05)
		b := BootstrapCI(vals, 2000, 99, 0.05)
		Expect(a).To(Equal(b)) // deterministic
		Expect(a.Lo).To(BeNumerically("<", 14.5))
		Expect(a.Hi).To(BeNumerically(">", 14.5))
	})
})

var _ = Describe("EvaluateChecks", func() {
	It("passes when C beats R1 absolutely and B incrementally with a matched admission fraction", func() {
		r1 := ArmSummary{Arm: "R1", TTFTMsP99: 100}
		// static-cap and kv-aware admit the same work (matched), but kv-aware protects the tail better.
		staticCap := ArmSummary{Arm: "static-cap", TTFTMsP99: 200, OfferedInputTokens: 1000, AdmittedInputTokens: 500}
		kvAware := ArmSummary{Arm: "kv-aware", TTFTMsP99: 110, OfferedInputTokens: 1000, AdmittedInputTokens: 510}
		ci := CI{Lo: 0.45, Hi: 0.65} // C/B ratio CI, upper bound < 1.0
		c := EvaluateChecks(r1, staticCap, kvAware, ci, 0.05)
		Expect(c.AbsoluteProtectionPass).To(BeTrue()) // 110/100 = 1.10 <= 1.25
		Expect(c.IncrementalValuePass).To(BeTrue())   // 110/200 = 0.55 <= 0.90, CI hi 0.65 < 1.0
		Expect(c.AdmissionMatchPass).To(BeTrue())     // |0.5-0.51|/0.51 ~ 0.02 <= 0.05
		Expect(c.OverallPass).To(BeTrue())
	})

	It("fails incremental value when C does not beat the admission-matched B (just load shedding)", func() {
		r1 := ArmSummary{Arm: "R1", TTFTMsP99: 100}
		staticCap := ArmSummary{Arm: "static-cap", TTFTMsP99: 115, OfferedInputTokens: 1000, AdmittedInputTokens: 500}
		kvAware := ArmSummary{Arm: "kv-aware", TTFTMsP99: 112, OfferedInputTokens: 1000, AdmittedInputTokens: 505}
		ci := CI{Lo: 0.90, Hi: 1.05} // ratio ~0.97, CI crosses 1.0
		c := EvaluateChecks(r1, staticCap, kvAware, ci, 0.05)
		Expect(c.AbsoluteProtectionPass).To(BeTrue()) // 112/100 = 1.12 <= 1.25
		Expect(c.IncrementalValuePass).To(BeFalse())  // ratio 0.97 > 0.90 and CI hi >= 1.0
		Expect(c.OverallPass).To(BeFalse())
	})

	It("fails admission match when B and C admit different work fractions", func() {
		r1 := ArmSummary{Arm: "R1", TTFTMsP99: 100}
		staticCap := ArmSummary{Arm: "static-cap", TTFTMsP99: 200, OfferedInputTokens: 1000, AdmittedInputTokens: 300}
		kvAware := ArmSummary{Arm: "kv-aware", TTFTMsP99: 110, OfferedInputTokens: 1000, AdmittedInputTokens: 600}
		ci := CI{Lo: 0.45, Hi: 0.65}
		c := EvaluateChecks(r1, staticCap, kvAware, ci, 0.05)
		Expect(c.AdmissionMatchPass).To(BeFalse()) // 0.3 vs 0.6 is a 50% gap
		Expect(c.OverallPass).To(BeFalse())
	})
})
