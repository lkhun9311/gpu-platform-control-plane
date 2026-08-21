package queuelab

import "testing"

// held builds a ledger event for a row at an arrival time.
func held(job string, ev EventType, elapsedNs int64) LifecycleEvent {
	return LifecycleEvent{Job: job, Type: ev, ElapsedNs: elapsedNs, ObjectUID: job + "-uid"}
}

// The hold runs from the owner's ADMISSION to the victim's terminal phase, which is the quantity
// held = min(remaining service, grace) is actually about.
//
// Mutation that turns this red: start the interval at the victim's Ready, or end it at the owner's Ready --
// either one turns the hold back into the owner's wait, which is what needed a borrowed platform-cost term
// to test at all.
func TestDeviceHoldRunsFromTheOwnersAdmissionToTheVictimsStop(t *testing.T) {
	ev := []LifecycleEvent{
		held(VictimRow, EventPodReady, 2_000_000_000),
		held(OwnerRow, EventSubmitted, 23_000_000_000),
		held(OwnerRow, EventAdmitted, 24_100_000_000),
		held(VictimRow, EventAttemptStopped, 54_150_000_000),
		held(OwnerRow, EventPodReady, 56_700_000_000),
	}
	got := DeviceHoldNs(ev)
	if got == nil {
		t.Fatal("a ledger carrying both endpoints produced no hold")
	}
	if *got != 30_050_000_000 {
		t.Fatalf("hold = %d ns, want 30.050s (owner admitted 24.100 -> victim stopped 54.150)", *got)
	}
	// The owner's own readiness is 2.6 s later and must not be the endpoint: that interval is the owner's
	// wait, and it contains scheduling and container start that the hold does not.
	if *got == 32_600_000_000 {
		t.Fatal("the hold ran to the owner's readiness")
	}
}

// The delivered dose is not the declared one, and this is what makes the difference visible.
func TestAchievedDoseIsMeasuredRatherThanDeclared(t *testing.T) {
	ev := []LifecycleEvent{
		held(VictimRow, EventPodReady, 2_000_000_000),
		held(OwnerRow, EventSubmitted, 23_286_000_000),
	}
	got := AchievedDoseNs(ev)
	if got == nil {
		t.Fatal("a ledger carrying both endpoints produced no dose")
	}
	if *got != 21_286_000_000 {
		t.Fatalf("dose = %d ns, want 21.286s; the protocol declared 20 and the barrier's poll delivered more",
			*got)
	}
}

// A ledger missing either endpoint says nothing rather than zero. Zero would be the strongest claim the
// interval can make -- an instant release, or a dose delivered the moment the victim was ready.
func TestHoldAndDoseRefuseToInventAnInterval(t *testing.T) {
	onlyAdmit := []LifecycleEvent{held(OwnerRow, EventAdmitted, 24_000_000_000)}
	if h := DeviceHoldNs(onlyAdmit); h != nil {
		t.Fatalf("a ledger with no victim stop reported a hold of %d", *h)
	}
	if d := AchievedDoseNs(onlyAdmit); d != nil {
		t.Fatalf("a ledger with no victim readiness reported a dose of %d", *d)
	}

	// A stop observed before the admission would make the interval a different quantity, not a small one.
	inverted := []LifecycleEvent{
		held(OwnerRow, EventAdmitted, 24_000_000_000),
		held(VictimRow, EventAttemptStopped, 23_000_000_000),
	}
	if h := DeviceHoldNs(inverted); h != nil {
		t.Fatalf("a release observed before the decision reported a hold of %d ns", *h)
	}
}

// A re-executed row delivers its attempts out of order, so the earliest arrival is the endpoint rather than
// the first one folded.
func TestHoldTakesTheEarliestStopOfAReExecutedRow(t *testing.T) {
	ev := []LifecycleEvent{
		held(OwnerRow, EventAdmitted, 24_000_000_000),
		held(VictimRow, EventAttemptStopped, 60_000_000_000),
		held(VictimRow, EventAttemptStopped, 54_000_000_000),
	}
	got := DeviceHoldNs(ev)
	if got == nil || *got != 30_000_000_000 {
		t.Fatalf("hold = %v, want 30s from the EARLIEST stop; the ledger is observation order, not time order", got)
	}
}
