package queuelab

import (
	"strings"
	"testing"
	"time"
)

// goodObservation is an observer that watched one Pod's card across an interval and saw it working.
func goodObservation() *DeviceObservation {
	o := &DeviceObservation{
		Observer:         ObserverDCGM,
		ObserverIdentity: "nvcr.io/nvidia/k8s/dcgm-exporter@sha256:abc",
		StartedNs:        0,
		EndedNs:          40_000_000_000,
	}
	for at := int64(0); at <= 40_000_000_000; at += int64(time.Second) {
		o.Samples = append(o.Samples, DeviceSample{
			AtNs: at, DeviceUUID: "GPU-1234", PodUID: "victim-uid", UtilisationPercent: 97,
		})
	}
	return o
}

// The ordinary case, so every refusal below is a refusal of something and not of everything.
func TestAWatchedBusyDeviceEstablishesWork(t *testing.T) {
	ok, why := EstablishesDeviceWork(goodObservation(), "victim-uid", 10_000_000_000, 30_000_000_000)
	if !ok {
		t.Fatalf("a card sampled every second at 97%% across the interval did not establish work: %s", why)
	}
	if why != "" {
		t.Fatalf("an established claim carried a reason: %s", why)
	}
}

// The rule the whole file follows: the workload is not a witness.
func TestTheWorkloadIsNotAWitness(t *testing.T) {
	o := goodObservation()
	o.Observer = "workload-self-report"
	ok, why := EstablishesDeviceWork(o, "victim-uid", 10_000_000_000, 30_000_000_000)
	if ok {
		t.Fatal("a Pod's own report of its device use established that the device was used")
	}
	if !strings.Contains(why, "not a witness") {
		t.Fatalf("the refusal does not say why the source is inadmissible: %s", why)
	}
}

// No observer at all is the state every record this lab has produced is in, and it must say so rather than
// come back with a bare false.
func TestNoObserverSaysWhatTheRunDoesEstablish(t *testing.T) {
	ok, why := EstablishesDeviceWork(nil, "victim-uid", 0, 10)
	if ok {
		t.Fatal("a run with no observer established device work")
	}
	if !strings.Contains(why, "RESERVED") {
		t.Fatalf("the refusal does not say what the run DOES establish: %s", why)
	}
}

// An allocated card sitting idle is the exact state this axis exists to distinguish from a working one, and
// the one a GPU session would produce if the workload never made a driver call.
func TestAnIdleCardDoesNotEstablishWork(t *testing.T) {
	o := goodObservation()
	for i := range o.Samples {
		o.Samples[i].UtilisationPercent = 0
	}
	ok, why := EstablishesDeviceWork(o, "victim-uid", 10_000_000_000, 30_000_000_000)
	if ok {
		t.Fatal("a card that was allocated and idle established that it did work")
	}
	if !strings.Contains(why, "allocated and idle") {
		t.Fatalf("the refusal does not name the state: %s", why)
	}

	// One busy sample is a reading, not a state: a driver reports non-zero utilisation while another process
	// initialises, and that must not carry the claim.
	// Index 20 is t=20 s, INSIDE the 10..30 s interval. An earlier version of this test made a sample at
	// t=5 s busy, outside the window, so it was filtered before the count and the mutation that accepted a
	// single busy sample survived.
	o.Samples[20].UtilisationPercent = 60
	if ok, _ := EstablishesDeviceWork(o, "victim-uid", 10_000_000_000, 30_000_000_000); ok {
		t.Fatal("a single non-zero sample established that the device did work")
	}
	// And two inside the window do carry it, or the threshold would be a refusal of everything.
	o.Samples[21].UtilisationPercent = 60
	if ok, why := EstablishesDeviceWork(o, "victim-uid", 10_000_000_000, 30_000_000_000); !ok {
		t.Fatalf("two busy samples across the interval did not establish work: %s", why)
	}
}

// A gap long enough to hide a preemption is not continuous observation, however good the samples around it.
func TestAGapLongEnoughToHideAPreemptionRefuses(t *testing.T) {
	o := goodObservation()
	kept := o.Samples[:0]
	for _, s := range o.Samples {
		// Drop five seconds out of the middle of the interval.
		if s.AtNs >= 18_000_000_000 && s.AtNs <= 23_000_000_000 {
			continue
		}
		kept = append(kept, s)
	}
	o.Samples = kept
	ok, why := EstablishesDeviceWork(o, "victim-uid", 10_000_000_000, 30_000_000_000)
	if ok {
		t.Fatal("an observation blind for five seconds in the middle established continuous work")
	}
	if !strings.Contains(why, "hide an entire preemption") {
		t.Fatalf("the refusal does not say what the gap costs: %s", why)
	}
}

// An observer that was not running for the whole interval has not covered it, whatever it saw while it was.
func TestAnObserverThatStartedLateHasNotCoveredTheInterval(t *testing.T) {
	o := goodObservation()
	o.StartedNs = 15_000_000_000
	ok, why := EstablishesDeviceWork(o, "victim-uid", 10_000_000_000, 30_000_000_000)
	if ok {
		t.Fatal("an observer that started inside the interval covered it")
	}
	if !strings.Contains(why, "never watched") {
		t.Fatalf("the refusal does not name the uncovered part: %s", why)
	}
}

// Attribution is to the Pod UID, not the name, because the UID is what the API guarantees unique across time:
// a name is free for reuse the moment its Pod is deleted, and an observer labelling by name is read against
// whatever holds that name when the mapping is resolved.
func TestSamplesForAnotherPodDoNotCount(t *testing.T) {
	o := goodObservation()
	for i := range o.Samples {
		o.Samples[i].PodUID = "some-other-attempt-uid"
	}
	ok, why := EstablishesDeviceWork(o, "victim-uid", 10_000_000_000, 30_000_000_000)
	if ok {
		t.Fatal("another attempt's device activity established this one's")
	}
	if !strings.Contains(why, "reservation") {
		t.Fatalf("the refusal does not say what an unsampled hold is: %s", why)
	}
}

// "DCGM said so" is not provenance if nobody can say which DCGM, for the same reason the canary key carries
// the operator's image digest.
func TestAnObserverMustSayWhichBuildItWas(t *testing.T) {
	o := goodObservation()
	o.ObserverIdentity = ""
	if ok, why := EstablishesDeviceWork(o, "victim-uid", 10_000_000_000, 30_000_000_000); ok {
		t.Fatalf("an anonymous observer established device work (%s)", why)
	}
}

// A sample that cannot name its card, or samples naming several, cannot say the card this Pod held did
// anything.
func TestTheDeviceMustBeIdentifiedAndSingular(t *testing.T) {
	anon := goodObservation()
	anon.Samples[3].DeviceUUID = ""
	if ok, why := EstablishesDeviceWork(anon, "victim-uid", 0, 30_000_000_000); ok {
		t.Fatalf("a sample naming no device established work (%s)", why)
	}

	two := goodObservation()
	for i := range two.Samples {
		if i%2 == 0 {
			two.Samples[i].DeviceUUID = "GPU-5678"
		}
	}
	ok, why := EstablishesDeviceWork(two, "victim-uid", 10_000_000_000, 30_000_000_000)
	if ok {
		t.Fatal("samples naming two different cards established which one the hold was about")
	}
	if !strings.Contains(why, "which card") {
		t.Fatalf("the refusal does not name the ambiguity: %s", why)
	}
}
