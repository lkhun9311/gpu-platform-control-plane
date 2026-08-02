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

package queuelab

import (
	"fmt"
	"strings"
	"time"
)

// RenderResult renders one arm's reconstruction as text.
//
// It lives in the pure package rather than the runner so the rule that matters can be enforced by a test:
// every admission is printed next to the execution start it does NOT imply. The published result reported
// "owner admitted in ~120 ms" while the owner did not begin executing for another 9.4 seconds, and nothing
// in the code prevented that framing.
func RenderResult(res LabResult) string {
	var b strings.Builder
	fmt.Fprintf(&b, "===== RESULT (arm %s) =====\n", res.Arm)
	fmt.Fprintf(&b, "offered=%d admitted=%d executed=%d completed=%d unfinishedAtHorizon=%d\n",
		res.Offered, res.Admitted, countExecuted(res), res.Completed, res.UnfinishedAtHorizon)
	fmt.Fprintf(&b, "wastedGPUSeconds(attributable)=%.1f lowerBound=%.1f censored=%v\n",
		res.TotalWastedGPUSeconds, res.TotalWasteLowerBoundGPUSeconds, res.AnyWasteCensored)
	fmt.Fprintf(&b, "unattributedOccupancyGPUSeconds=%.1f\n", res.TotalUnattributedOccupancyGPUSeconds)
	if res.AnyPreemptionIneffective {
		// Stated loudly because it invalidates the natural reading of the waste number: the platform decided
		// to reclaim and the workload did not comply.
		fmt.Fprintf(&b, "PREEMPTION INEFFECTIVE: a preemption was decided but its target completed successfully\n")
	}
	fmt.Fprintf(&b, "admittedWaitP95=%s fullyObserved=%v\n",
		time.Duration(res.AdmittedWaitP95Ns), res.WaitP95FullyObserved)
	for _, o := range res.Outcomes {
		fmt.Fprintf(&b,
			"  %-10s admitted=%v executed=%v completed=%v attempts=%d reExecuted=%v preemptions=%d\n",
			o.Job, o.Admitted, o.Executed, o.Completed, o.Attempts, o.ReExecuted, o.Preemptions)
		fmt.Fprintf(&b,
			"             admitLatency=%s readyLatency=%s admitToReady=%s\n",
			time.Duration(o.AdmitLatencyNs), time.Duration(o.ReadyLatencyNs), time.Duration(o.AdmitToReadyNs))
		fmt.Fprintf(&b,
			"             waste=%.1f(lb %.1f%s) unattributedOccupancy=%.1f totalOccupancy=%.1f\n",
			o.WastedGPUSeconds, o.WasteLowerBoundGPUSeconds, censoredMark(o.WasteCensored),
			o.UnattributedOccupancyGPUSeconds, o.TotalOccupancyGPUSeconds)
	}
	return b.String()
}

// countExecuted counts rows that reached the execution-start proxy, which is deliberately reported next to
// the admitted count so the two are never conflated.
func countExecuted(res LabResult) int {
	n := 0
	for _, o := range res.Outcomes {
		if o.Executed {
			n++
		}
	}
	return n
}

// censoredMark tags a waste figure whose exact value is a lower bound.
func censoredMark(c bool) string {
	if c {
		return " censored"
	}
	return ""
}
