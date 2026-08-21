package queuelab

// The intervals this file derives are the experiment's own timing, read back out of a run's ledger rather
// than taken from the constants the protocol declared. They exist because the two disagree, and because the
// quantity the lab's central claim is ABOUT was never the one it published.
//
// held = min(remaining service, termination grace period) is a statement about how long a preempted borrower
// keeps its device after the platform has decided its owner should have it. What the lab measured instead was
// the owner's admission-to-running wait, which contains that hold and then the scheduling, the image, and the
// container start on top of it — so the model could only be tested by subtracting an estimate of those,
// borrowed from the other arm. That subtraction turned out to be wrong in kind rather than in size: the
// owner's Pod spends the grace window pending against the device, so restoration after release costs about
// 1.6 s LESS in the arm the model predicts than in the arm the estimate came from.
//
// The hold itself needs no such term, and it is three orders of magnitude quieter: across the recorded runs
// its within-cell spread is 8 to 17 milliseconds against an owner-wait floor of one to three seconds. The
// honouring arm becomes a genuine zero-hold control at about 43 ms rather than a source of a subtrahend.

// DeviceHoldNs is how long the borrower kept the device after Kueue admitted its owner, or nil when the run's
// ledger cannot say.
//
// The endpoints are the owner's ADMISSION -- the moment the platform committed the capacity to the owner --
// and the victim's terminal phase, which is when the device is actually released. Deletion is deliberately
// not the endpoint: a deletionTimestamp only starts the grace period, during which the Pod goes on holding
// the device, and that window is the entire subject.
//
// Both endpoints are arrival times from THIS collector rather than component stamps, and the choice is
// deliberate. The two events come from different watches, so a component-stamp reading would carry the offset
// between Kueue's clock and the kubelet's, while the arrival reading carries only the differential delivery
// lag of two streams that the recorded runs show agreeing to within tens of milliseconds. The stamp version
// is available for corroboration; it is quantised to the second, which is coarser than this interval's own
// scatter.
func DeviceHoldNs(events []LifecycleEvent) *int64 {
	admitted := firstElapsed(events, OwnerRow, func(e *LifecycleEvent) bool { return e.Type == EventAdmitted })
	stopped := firstElapsed(events, VictimRow, func(e *LifecycleEvent) bool { return e.Type == EventAttemptStopped })
	if admitted == nil || stopped == nil {
		return nil
	}
	// A negative hold is not legal reordering to be shrugged at: it would say the borrower released the device
	// before the platform decided the owner should have it, which makes the interval a different quantity.
	// The two endpoints come from different watches, so a few milliseconds of reordering is possible, and the
	// caller is told nothing rather than a number whose sign contradicts its own definition.
	if *stopped < *admitted {
		return nil
	}
	v := *stopped - *admitted
	return &v
}

// AchievedDoseNs is the dose the run actually delivered: the victim's readiness to the owner's submission.
//
// It exists because the declared dose is a constant and the delivered one is not. The schedule gates the
// owner on the victim's observed Ready through a barrier satisfied by a two-second poll, so every recorded
// run overran its declared dose by 1.0 to 1.4 seconds, systematically and in the same direction. Nothing in
// the record said so, and the model's prediction is built from the declared value.
//
// On this cluster the margin is ten seconds and the overrun is harmless. On a slower one an overrun large
// enough to carry the victim's remaining service across the grace period would make a run measure the OTHER
// regime while carrying this regime's label -- and the label is what selects the prediction.
func AchievedDoseNs(events []LifecycleEvent) *int64 {
	ready := firstElapsed(events, VictimRow, func(e *LifecycleEvent) bool { return e.Type == EventPodReady })
	submitted := firstElapsed(events, OwnerRow, func(e *LifecycleEvent) bool { return e.Type == EventSubmitted })
	if ready == nil || submitted == nil || *submitted < *ready {
		return nil
	}
	v := *submitted - *ready
	return &v
}

// firstElapsed is the earliest arrival time of a matching event for a row, or nil when there is none.
//
// Earliest rather than first-folded, for the reason the reconstruction takes minima everywhere: the ledger is
// observation-insertion order and a re-executed row can deliver its second attempt before its first.
func firstElapsed(events []LifecycleEvent, job string, match func(*LifecycleEvent) bool) *int64 {
	var out *int64
	for i := range events {
		e := &events[i]
		if e.Job != job || !match(e) {
			continue
		}
		if out == nil || e.ElapsedNs < *out {
			v := e.ElapsedNs
			out = &v
		}
	}
	return out
}

// VictimAttemptUID is the Pod that held the device across the preemption, or "" when the ledger cannot say.
//
// It is the attempt whose terminal phase ENDS the hold, which is not the same as "the victim's Pod": a
// re-executed row has several, and the later ones ran after the owner already had its capacity back. A device
// observation attributed to one of those would be evidence about a Pod that was not holding anything the
// owner was waiting for.
func VictimAttemptUID(events []LifecycleEvent) string {
	var uid string
	var at int64
	for i := range events {
		e := &events[i]
		if e.Job != VictimRow || e.Type != EventAttemptStopped || e.ObjectUID == "" {
			continue
		}
		if uid == "" || e.ElapsedNs < at {
			uid, at = e.ObjectUID, e.ElapsedNs
		}
	}
	return uid
}

// DeviceHoldWindow is the interval a device observation has to cover, as offsets from the run's t0.
//
// It is the hold itself rather than the whole run, because that is the window the claim is about: whether
// the card the borrower was holding did work while its owner waited for it. An observation covering the run
// but not this interval has watched the wrong part.
func DeviceHoldWindow(events []LifecycleEvent) (fromNs, toNs int64, ok bool) {
	admitted := firstElapsed(events, OwnerRow, func(e *LifecycleEvent) bool { return e.Type == EventAdmitted })
	stopped := firstElapsed(events, VictimRow, func(e *LifecycleEvent) bool { return e.Type == EventAttemptStopped })
	if admitted == nil || stopped == nil || *stopped <= *admitted {
		return 0, 0, false
	}
	return *admitted, *stopped, true
}
