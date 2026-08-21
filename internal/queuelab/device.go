package queuelab

import (
	"fmt"
	"sort"
	"time"
)

// The contract a device observation has to satisfy before a run may claim its GPU did work.
//
// It exists because every record this lab has produced reads device-not-observed, and the reason is not
// modesty. The workload is arithmetic that makes no driver call, the cluster advertises nvidia.com/gpu
// through a fake plugin, and a Pod that dropped the resource request entirely would compute the same
// iterations at the same rate. Scheduling those Pods onto real hardware would not change that verdict by
// itself — the iteration counter stays healthy while every operation runs on the CPU — so a session could
// consume scarce GPU time and add no GPU-specific evidence at all.
//
// The one rule everything here follows: THE WORKLOAD IS NOT A WITNESS. A Pod reporting its own device use is
// evidence of nothing, for the same reason a tenant setting a quota-exempt annotation is not evidence of
// exemption — both are claims by the party the check exists to constrain. The observation has to come from
// something the workload cannot write to, and Source is where that is asserted and checked.

// DeviceObserver names what produced an observation. It is a closed set because a record persists one and a
// reader classifies on it, and because an open string would eventually hold "the workload said so".
type DeviceObserver string

const (
	// ObserverDCGM is NVIDIA's DCGM exporter: a DaemonSet scraping the driver directly and labelling each
	// sample with the physical device UUID and the Pod it was serving. The tenant's container cannot write to
	// it, which is the property that matters.
	ObserverDCGM DeviceObserver = "dcgm-exporter"
	// ObserverNvidiaSMI is a node-local nvidia-smi poll. Admissible but weaker: correlating a compute process
	// back to a Pod goes through the PID namespace rather than through a label the driver itself emitted.
	ObserverNvidiaSMI DeviceObserver = "nvidia-smi"
)

// deviceObservers is the set an observation may claim. A value outside it is refused rather than trusted,
// which is what stops "workload-self-report" from ever being one.
var deviceObservers = map[DeviceObserver]bool{ObserverDCGM: true, ObserverNvidiaSMI: true}

// maxObserverGap is how long an observation may see nothing before it stops covering the interval.
//
// Two seconds because the interval this has to cover is the device hold, whose whole subject is a window of
// tens of seconds: a gap of that size can hide an entire preemption. It is deliberately shorter than any
// quantity the lab reports, so a run cannot claim continuous observation of something it blinked through.
const maxObserverGap = 2 * time.Second

// minBusySamples is how many samples must show the device working before "it did work" is a finding rather
// than a spike.
//
// One sample is a reading; two spaced across the interval are a state. This is not a statistical threshold
// and does not pretend to be — it exists so that a single stray non-zero utilisation, of the kind a driver
// reports while another process initialises, cannot carry the claim.
const minBusySamples = 2

// DeviceSample is one observation of one physical device at one instant.
type DeviceSample struct {
	// AtNs is when the OBSERVER took the reading, on its own clock, as an offset from the run's t0.
	AtNs int64
	// DeviceUUID is the physical device. It is required: a sample that cannot say which card it watched
	// cannot establish that the card this Pod held did anything.
	DeviceUUID string
	// PodUID ties the sample to one Pod, and it is the Pod's UID rather than its name because names are
	// reused across attempts. A re-executed row produces two Pods with the same name and different UIDs, and
	// crediting the second attempt's activity to the first would be the exact misattribution this field
	// exists to prevent.
	PodUID string
	// UtilisationPercent is what the observer reported, 0 to 100.
	UtilisationPercent int
}

// DeviceObservation is everything one observer saw over one run.
type DeviceObservation struct {
	Observer DeviceObserver
	// ObserverIdentity is which build of the observer produced this -- an image digest or version string.
	//
	// It is required for the reason the operator image digest is required in the canary key: "DCGM said so"
	// is not provenance if nobody can say which DCGM.
	ObserverIdentity string
	// StartedNs and EndedNs bound what the observer was actually running for. An interval outside them is not
	// covered, whatever the samples happen to contain.
	StartedNs int64
	EndedNs   int64
	Samples   []DeviceSample
}

// EstablishesDeviceWork reports whether an observation supports the claim that the named Pod's device did
// work across the whole of an interval, and why not when it does not.
//
// The reason string is the product. A run that fails this check has to be able to tell an operator which of
// the five things went wrong -- no observer, wrong observer, the interval not covered, a gap in the middle,
// or the device idle throughout -- because those send someone to five different places, and because a run
// that comes back "not established" without saying why is indistinguishable from one nobody looked at.
func EstablishesDeviceWork(obs *DeviceObservation, podUID string, fromNs, toNs int64) (bool, string) {
	if obs == nil {
		return false, "no device observer ran: nothing outside the workload watched the card, so this run " +
			"establishes that a device was RESERVED and nothing about whether it was used"
	}
	if !deviceObservers[obs.Observer] {
		return false, fmt.Sprintf("observer %q is not one this build accepts (%q, %q). The workload is not a "+
			"witness: a Pod reporting its own device use is a claim by the party the check exists to constrain",
			obs.Observer, ObserverDCGM, ObserverNvidiaSMI)
	}
	if obs.ObserverIdentity == "" {
		return false, fmt.Sprintf("observer %q did not say which build of it produced these readings; "+
			"\"%s said so\" is not provenance if nobody can say which %s", obs.Observer, obs.Observer, obs.Observer)
	}
	if podUID == "" {
		return false, "the interval names no Pod UID, so no sample can be attributed to the attempt that " +
			"held the device rather than to another attempt of the same row"
	}
	if fromNs >= toNs {
		return false, fmt.Sprintf("the interval to cover is empty (%d..%d ns)", fromNs, toNs)
	}
	if obs.StartedNs > fromNs || obs.EndedNs < toNs {
		return false, fmt.Sprintf("the observer ran %d..%d ns and the interval to cover is %d..%d ns, so part "+
			"of it was never watched", obs.StartedNs, obs.EndedNs, fromNs, toNs)
	}

	mine := make([]DeviceSample, 0, len(obs.Samples))
	devices := map[string]bool{}
	for _, s := range obs.Samples {
		if s.PodUID != podUID || s.AtNs < fromNs || s.AtNs > toNs {
			continue
		}
		if s.DeviceUUID == "" {
			return false, fmt.Sprintf("a sample at %d ns names no device: an observation that cannot say which "+
				"card it watched cannot establish that the card this Pod held did anything", s.AtNs)
		}
		mine = append(mine, s)
		devices[s.DeviceUUID] = true
	}
	if len(mine) == 0 {
		return false, fmt.Sprintf("the observer ran across the interval and produced no sample for Pod %s; a "+
			"device held by a Pod nothing sampled is a reservation", podUID)
	}
	sort.Slice(mine, func(i, j int) bool { return mine[i].AtNs < mine[j].AtNs })

	// Gaps are measured against the interval's own ends as well as between samples, so an observation that
	// starts late or stops early inside a window it nominally covers is caught.
	prev := fromNs
	for _, s := range mine {
		if s.AtNs-prev > int64(maxObserverGap) {
			return false, fmt.Sprintf("the observer saw nothing for %s between %d and %d ns, which is longer "+
				"than the %s a run may blink through; a gap that size can hide an entire preemption",
				time.Duration(s.AtNs-prev), prev, s.AtNs, maxObserverGap)
		}
		prev = s.AtNs
	}
	if toNs-prev > int64(maxObserverGap) {
		return false, fmt.Sprintf("the observer's last sample for Pod %s is %s before the interval ends",
			podUID, time.Duration(toNs-prev))
	}

	busy := 0
	for _, s := range mine {
		if s.UtilisationPercent > 0 {
			busy++
		}
	}
	if busy < minBusySamples {
		return false, fmt.Sprintf("the device held by Pod %s was observed working in %d of %d samples; a card "+
			"that is allocated and idle is the state this whole axis exists to distinguish from one that is "+
			"computing", podUID, busy, len(mine))
	}
	if len(devices) > 1 {
		return false, fmt.Sprintf("samples for Pod %s name %d different devices; the run cannot say which card "+
			"the hold was about", podUID, len(devices))
	}
	return true, ""
}
