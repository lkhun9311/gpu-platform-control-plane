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

import "fmt"

// DeltaType is the kind of watch observation the collector feeds the builder.
type DeltaType string

const (
	// DeltaUpsert is an Added or Modified watch event carrying the current object state.
	DeltaUpsert DeltaType = "Upsert"
	// DeltaDelete is a Deleted watch event carrying the object's last-known state.
	DeltaDelete DeltaType = "Delete"
)

// LedgerBuilder turns a stream of classified, job-resolved watch observations into the append-only event
// ledger Reconstruct consumes.
//
// It emits only real state TRANSITIONS: a repeated observation of the same admitted Workload, or a re-sent
// object at a state already recorded, does not produce a duplicate event. It is FAIL-CLOSED, which is the
// precondition Reconstruct's waste lower bound depends on:
//
//   - Any observation classified Invalid (an unexpected eviction, a failed Job) invalidates the run.
//   - A Ready Pod deleted WITHOUT an observed terminal transition invalidates the run, so a missed stop can
//     never be silently treated as "still running to the horizon".
//   - A desync reported by the caller invalidates the run rather than guessing across the gap. The caller
//     decides what counts as one; for the queuelab runner it is any observation stream that ended while the
//     run was still observing, which is unrecoverable because the events in that gap are lost rather than
//     delayed.
//
// MarkVanished below is the one part of this contract with no caller left. It served a relist the runner used
// to perform between two watches; the runner now observes through streams that resume from the last delivered
// resource version, so there is no gap to relist and nothing calls it. It is kept, unused, only because
// removing an exported method is a separable change from the one that orphaned it.
type LedgerBuilder struct {
	lastEvent map[string]EventType // per object UID, the last emitted event (transition dedup)
	ready     map[string]bool      // per Pod UID, currently Ready and not yet observed stopped
	events    []LifecycleEvent
	invalid   string
}

// NewLedgerBuilder returns an empty builder.
func NewLedgerBuilder() *LedgerBuilder {
	return &LedgerBuilder{
		lastEvent: map[string]EventType{},
		ready:     map[string]bool{},
	}
}

// Observe folds one watch delta for an object already resolved to its trace job and classified into st.
//
// kind is the object kind, uid its UID, job the resolved trace job name, and elapsedNs the collector's
// monotonic observation offset. A Delete whose carried state is terminal still emits that terminal event
// before the tombstone check, so a graceful deletion is recorded, not counted as a lost stop.
func (b *LedgerBuilder) Observe(delta DeltaType, kind, uid, job string, st ObservedState, elapsedNs int64) {
	if b.invalid != "" {
		return
	}
	if st.Invalid {
		b.invalid = st.InvalidReason
		return
	}
	if st.Event != "" && b.lastEvent[uid] != st.Event {
		b.events = append(b.events, LifecycleEvent{
			ElapsedNs: elapsedNs,
			Kind:      kind,
			Type:      st.Event,
			Job:       job,
			ObjectUID: uid,
			Reason:    st.Reason,
		})
		b.lastEvent[uid] = st.Event
		switch st.Event {
		case EventPodReady:
			b.ready[uid] = true
		case EventAttemptStopped:
			b.ready[uid] = false
		}
	}
	if delta == DeltaDelete && kind == kindPod && b.ready[uid] {
		b.invalid = fmt.Sprintf("Ready Pod %s was deleted without an observed terminal state", uid)
	}
}

// MarkVanished reports a Pod UID an out-of-band read found gone. If it was Ready and never observed stopping,
// the run is invalid, because its discarded work would otherwise be charged to the horizon on a false premise.
//
// Nothing calls this: see the note on LedgerBuilder for why it is kept and what removed its caller.
func (b *LedgerBuilder) MarkVanished(uid string) {
	if b.invalid != "" {
		return
	}
	if b.ready[uid] {
		b.invalid = fmt.Sprintf("Ready Pod %s vanished on relist without an observed terminal state", uid)
	}
}

// Desync invalidates the run on an unrecoverable watch gap (a 410 Gone whose resume point is past, or an
// observation stream that ended while the run was still observing), because events across the gap cannot be
// trusted and cannot be recovered afterwards.
func (b *LedgerBuilder) Desync(reason string) {
	if b.invalid == "" {
		b.invalid = fmt.Sprintf("watch desync: %s", reason)
	}
}

// Events returns the accumulated ledger in observation order.
func (b *LedgerBuilder) Events() []LifecycleEvent {
	return b.events
}

// Err returns a non-nil error if the run was invalidated, so the caller discards it rather than reporting a
// contaminated number.
func (b *LedgerBuilder) Err() error {
	if b.invalid != "" {
		return fmt.Errorf("run invalid: %s", b.invalid)
	}
	return nil
}
