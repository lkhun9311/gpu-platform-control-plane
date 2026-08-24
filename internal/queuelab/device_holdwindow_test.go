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
	"strings"
	"testing"
	"time"
)

// A DEFECT, characterised rather than fixed, and it would have surfaced first on a rented card.
//
// EstablishesDeviceWork is judged over the DEVICE HOLD: owner Admitted to victim AttemptStopped
// (cmd/queuelabrun/record.go passes DeviceHoldWindow's bounds straight into it, and the decode path
// re-runs the gate bound to the same two stamps). Inside that window the victim is being TERMINATED --
// that is what the window is. It requires minBusySamples distinct instants showing the card working.
//
// In the arm that HONOURS SIGTERM the two requirements contradict each other. The recorded holds are 2.171
// to 3.210 s, the observer scrapes every second, so two or three samples land inside; and the victim has
// honoured the signal, so its CUDA loop has already stopped. A card that is allocated and idle is exactly
// what a prompt shutdown looks like, and the gate reads it as the failure it was written to catch.
//
// The asymmetry is the damaging part. The ignoring arm holds for 31 s while still computing and passes
// trivially, so `-require-device` does not fail the run evenly: it refuses the short arm and keeps the long
// one, leaving no contrast to form. Nothing has ever exercised this, because every recorded run used a fake
// device plugin and produced no DCGM observation at all.
//
// Two candidate fixes, neither taken here because both change what the record's device evidence MEANS and
// the decode-time re-check is bound to the hold stamps:
//
//   - judge "this Pod did device work" over the victim's own attempt rather than over the hold, which is
//     the interval the question is actually about;
//   - keep the hold-bound check and make it conditional on the hold being long enough to contain the
//     samples it demands, which turns a silent refusal into a stated limit.
func TestTheBusynessGateRefusesTheHonouringArmsOwnHoldWindow(t *testing.T) {
	// The honouring arm as recorded: a 2.2 s hold, sampled once a second, with the victim already exiting.
	const holdNs = int64(2_177_000_000)
	o := &DeviceObservation{
		Observer:         ObserverDCGM,
		ObserverIdentity: "nvcr.io/nvidia/k8s/dcgm-exporter@sha256:abc",
		Declared:         true,
		StartedNs:        0,
		EndedNs:          60_000_000_000,
	}
	// Before the hold the victim is computing, which is what makes it the victim.
	for at := int64(0); at < 20_000_000_000; at += int64(time.Second) {
		o.Samples = append(o.Samples, DeviceSample{AtNs: at, DeviceUUID: "GPU-1234", PodUID: "victim-uid", UtilisationPercent: 96})
	}
	// Inside the hold it has honoured SIGTERM and stopped. The device is still allocated to it -- that is
	// what the hold IS -- and it reads idle.
	from := int64(20_000_000_000)
	to := from + holdNs
	for at := from; at <= to; at += int64(time.Second) {
		o.Samples = append(o.Samples, DeviceSample{AtNs: at, DeviceUUID: "GPU-1234", PodUID: "victim-uid", UtilisationPercent: 0})
	}

	ok, why := EstablishesDeviceWork(o, "victim-uid", from, to)
	if ok {
		t.Fatal("the gate accepted the honouring arm's hold window; if this now passes the defect has been " +
			"fixed and this characterisation must be replaced by a test of the fix, not deleted")
	}
	if !strings.Contains(why, "allocated and idle") {
		t.Fatalf("refused for an unexpected reason, so this test is no longer characterising what it claims: %v", why)
	}

	// The ignoring arm, same observation shape, a 31 s hold with the victim still computing through it.
	o2 := &DeviceObservation{
		Observer: ObserverDCGM, ObserverIdentity: "nvcr.io/nvidia/k8s/dcgm-exporter@sha256:abc",
		Declared: true, StartedNs: 0, EndedNs: 60_000_000_000,
	}
	from2 := int64(20_000_000_000)
	to2 := from2 + 31_219_000_000
	for at := int64(0); at <= to2; at += int64(time.Second) {
		o2.Samples = append(o2.Samples, DeviceSample{AtNs: at, DeviceUUID: "GPU-1234", PodUID: "victim-uid", UtilisationPercent: 96})
	}
	if ok2, why2 := EstablishesDeviceWork(o2, "victim-uid", from2, to2); !ok2 {
		t.Fatalf("the ignoring arm was also refused (%v); the asymmetry this test documents rests on it passing", why2)
	}
}
