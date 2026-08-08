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

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// A signal landing during the observation window must be seen immediately, not after the wait times out on
// its own; a poll-to-deadline bug here would make Ctrl-C during a long horizon look hung for the remainder
// of the run.
func TestWaitForHorizonCancelledContextReturnsErrorPromptly(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	// Far enough out that only a genuine ctx.Done() short-circuit, not the deadline itself, could return
	// this quickly.
	deadline := time.Now().Add(time.Hour)

	start := time.Now()
	err := waitForHorizon(ctx, deadline)
	elapsed := time.Since(start)

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want an error wrapping context.Canceled, got %v", err)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("waitForHorizon took %v to return on an already-cancelled context; it must not wait for the deadline", elapsed)
	}
}

// The ordinary path — the deadline is reached and nothing cancelled — must still return nil so the caller
// falls through to publication exactly as before this task's change.
func TestWaitForHorizonReturnsNilOnceDeadlinePasses(t *testing.T) {
	deadline := time.Now().Add(50 * time.Millisecond)
	if err := waitForHorizon(context.Background(), deadline); err != nil {
		t.Fatalf("want nil once the deadline has passed, got %v", err)
	}
}

// A deadline already in the past must not block at all, cancelled context or not: there is nothing left to
// observe.
func TestWaitForHorizonPastDeadlineReturnsImmediately(t *testing.T) {
	start := time.Now()
	if err := waitForHorizon(context.Background(), time.Now().Add(-time.Second)); err != nil {
		t.Fatalf("want nil for a deadline already in the past, got %v", err)
	}
	if elapsed := time.Since(start); elapsed > 200*time.Millisecond {
		t.Fatalf("waitForHorizon took %v for an already-past deadline", elapsed)
	}
}

// Gate 0 item 18, and the reason this is a P0 rather than a tidiness point: the horizon the reconstruction
// censors against used to be col.elapsed(), read AFTER the collector had been cancelled and joined. That is
// the observation window plus however long shutdown took — a different boundary on every run, and a wider
// one exactly when the API server is slow, so two runs of the same protocol would be censored at two
// different instants and their numbers would not be comparable.
//
// The test drives reconstructAtHorizon, which is the real call site, twice with a shutdown-shaped delay
// between them. Both the value and its independence from that delay are asserted: a horizon that moved with
// the clock would give the first call a boundary of a few microseconds, which is before every event here.
func TestReconstructHorizonIsTheStampedInstantNotWhateverShutdownTook(t *testing.T) {
	const horizon = 30 * time.Second
	const submittedAt = 2 * time.Second

	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).Build()
	col := newCollector(fc, "ns", "r1", horizon)

	// One offered row that is submitted and then never admitted, because its censored wait is exactly
	// horizon - submitted: the boundary itself, readable straight off the result.
	trace := []queuelab.TrainingTraceRow{
		{Index: 0, Name: "victim", Tenant: "a", GPUCount: 1, DurationSec: 40},
	}
	events := []queuelab.LifecycleEvent{
		{ElapsedNs: int64(submittedAt), Kind: kindMLTrainingJob, Type: queuelab.EventSubmitted, Job: "victim"},
	}

	first, err := reconstructAtHorizon(col, queuelab.ArmNRef, trace, events)
	if err != nil {
		t.Fatalf("reconstruct: %v", err)
	}
	if got, want := first.Outcomes[0].CensoredWaitNs, int64(horizon-submittedAt); got != want {
		t.Fatalf("censored wait = %v, want %v: the horizon is not the stamped instant",
			time.Duration(got), time.Duration(want))
	}

	// Shutdown takes a while — cancelling the watches, joining four goroutines, a slow API server closing
	// them. None of that may move the boundary.
	time.Sleep(150 * time.Millisecond)

	second, err := reconstructAtHorizon(col, queuelab.ArmNRef, trace, events)
	if err != nil {
		t.Fatalf("reconstruct after the shutdown delay: %v", err)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("the reconstruction moved with shutdown duration:\n first %+v\nsecond %+v", first, second)
	}
	if col.horizonNs() != int64(horizon) {
		t.Fatalf("horizonNs = %v, want the configured horizon %v", time.Duration(col.horizonNs()), horizon)
	}
}

// dispatchOperatorMode must resolve every one of these without ever reaching the cluster client: if the
// validation-before-client ordering regressed, an operator on a box with no kubeconfig would see a
// "kubeconfig: ..." error instead of the flag-combination message that actually explains their mistake.
// This exercises dispatchOperatorMode itself, not just decideOperatorMode, so it also proves the wiring
// between the two, not only the pure decision in isolation.
//
// The connect function fails the test if it is ever called, which turns "without touching the cluster" from
// something this test relied on incidentally into something it asserts.
func TestDispatchOperatorModeRefusesWithoutTouchingTheCluster(t *testing.T) {
	cases := []struct {
		name      string
		args      operatorModeArgs
		wantFired bool
		wantErr   bool
	}{
		{name: "no mode requested falls through", args: operatorModeArgs{}, wantFired: false, wantErr: false},
		{
			name:      "two modes at once",
			args:      operatorModeArgs{Inspect: true, ReleaseStale: true, TxID: "t"},
			wantFired: true, wantErr: true,
		},
		{
			name:      "mode combined with -arm",
			args:      operatorModeArgs{Arm: "A-honor", Inspect: true},
			wantFired: true, wantErr: true,
		},
		{
			name:      "release-stale missing -confirm-owner-dead",
			args:      operatorModeArgs{ReleaseStale: true, TxID: "tx-1"},
			wantFired: true, wantErr: true,
		},
		{
			name:      "force-release missing -accept-divergence",
			args:      operatorModeArgs{ForceRelease: true, NodeUID: "uid-1"},
			wantFired: true, wantErr: true,
		},
		{
			name:      "clear-quarantine missing -confirm-owner-dead",
			args:      operatorModeArgs{ClearQuarantine: true, QuarantineID: "q1"},
			wantFired: true, wantErr: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			connect := func() (client.WithWatch, error) {
				t.Fatal("a refused invocation must never reach the cluster client")
				return nil, nil
			}
			fired, err := dispatchOperatorMode(connect, tc.args)
			if fired != tc.wantFired {
				t.Fatalf("fired = %v, want %v", fired, tc.wantFired)
			}
			if tc.wantErr && err == nil {
				t.Fatal("want a refusal, got nil")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("want no error, got %v", err)
			}
		})
	}
}

// The bound on the operator modes is only worth anything if the DISPATCH PATH is what applies it, and
// testing operatorModeContext in isolation cannot show that: a regression restoring context.Background() at
// the dispatch site would leave the helper untouched and the suite green.
//
// So this drives the real dispatchOperatorMode against a fake cluster and captures the context the mode
// function is actually handed. It asserts the two properties the design argues for together: the context is
// BOUNDED, so a hung API server cannot hang a recovery indefinitely, and it is LIVE and derived from
// Background rather than from any signal handling, so a Ctrl-C cannot cut a break in half between its Get
// and its Patch.
// Both properties are sampled INSIDE the client call rather than from a captured context afterwards:
// dispatchOperatorMode cancels on the way out, as it must, so a context inspected after it returns is
// always cancelled and would prove the opposite of what this test is for.
func TestDispatchOperatorModeRunsTheModeOnABoundedUncancellableContext(t *testing.T) {
	n := node(nil, nil)
	var (
		called      bool
		deadline    time.Time
		hasDeadline bool
		liveErr     error
	)
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			called = true
			deadline, hasDeadline = ctx.Deadline()
			liveErr = ctx.Err()
			return c.Get(ctx, key, obj, opts...)
		},
	}).Build()

	fired, err := dispatchOperatorMode(
		func() (client.WithWatch, error) { return fc, nil },
		operatorModeArgs{Worker: "platform-worker", Inspect: true},
	)
	if !fired {
		t.Fatal("-inspect-worker must fire")
	}
	if err != nil {
		t.Fatalf("inspecting a free node must succeed, got %v", err)
	}
	if !called {
		t.Fatal("the mode never reached the cluster, so this test proved nothing")
	}

	if !hasDeadline {
		t.Fatal("the dispatch path handed the mode an unbounded context; a hung apiserver would hang recovery")
	}
	if remaining := time.Until(deadline); remaining > operatorModeTimeout {
		t.Fatalf("deadline is %v out, want at most operatorModeTimeout (%v)", remaining, operatorModeTimeout)
	}
	if liveErr != nil {
		t.Fatalf("the mode's context must be live while it runs, got %v", liveErr)
	}
}

// This is the acceptance condition the whole change rests on, driven end to end rather than asserted on
// amend in isolation: run() must choose one disposition, its deferred emergency release must change that
// choice after the return value has already been picked, and the record the caller persists must carry the
// amended one.
//
// If it failed, the durable record would say the run failed at setup while the operator's terminal said the
// worker was never restored — two accounts of the same run, with the more serious one missing from the only
// account that survives the process.
//
// The failure is staged through the real client: the namespace Create fails, which is what makes run()
// decide setup-failed, and it poisons the Node reads so the deferred release cannot prove restoration.
func TestRunDeferredEmergencyReleaseAmendsThePersistedRecord(t *testing.T) {
	poisoned := false
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: func(ctx context.Context, c client.WithWatch, obj client.Object,
				opts ...client.CreateOption) error {
				if _, ok := obj.(*corev1.Namespace); ok {
					poisoned = true
					return fmt.Errorf("namespace quota exhausted")
				}
				return c.Create(ctx, obj, opts...)
			},
			Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
				opts ...client.GetOption) error {
				if _, ok := obj.(*corev1.Node); ok && poisoned {
					return fmt.Errorf("apiserver unreachable")
				}
				return c.Get(ctx, key, obj, opts...)
			},
		}).Build()

	o, events, res := run(context.Background(), func() (client.WithWatch, error) { return fc, nil },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker", time.Duration(horizonSec)*time.Second)

	if res != nil {
		t.Fatal("a run that never reconstructed anything must hand back no result to render")
	}
	if o.Disposition != dispWorkerNotRestored {
		t.Fatalf("the defer must amend the outcome it found, got %s: %s", o.Disposition, o.Reason)
	}
	if !strings.Contains(o.Reason, "ensuring namespace") {
		t.Fatalf("the amended outcome must keep what run() originally decided as the cause, got %q", o.Reason)
	}

	// The record is what actually survives, so the assertion is made against the bytes on disk rather than
	// against the outcome value the test already holds.
	path := t.TempDir() + "/record.json"
	started := time.Date(2026, 8, 8, 10, 0, 0, 0, time.UTC)
	if err := writeRecord(path, buildRecord(o, events, "r7", string(queuelab.ArmAHonor), false,
		started, started.Add(90*time.Second))); err != nil {
		t.Fatalf("persist: %v", err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	rr, err := decodeRunRecord(b)
	if err != nil {
		t.Fatalf("the persisted record must decode: %v", err)
	}
	if rr.Disposition != string(dispWorkerNotRestored) {
		t.Fatalf("the persisted record must carry the amended disposition, got %s", rr.Disposition)
	}
	if !strings.Contains(rr.Reason, "ensuring namespace") {
		t.Fatalf("the persisted reason must name both the amendment and its cause, got %q", rr.Reason)
	}
	t.Logf("persisted record:\n%s", b)
}

// A record is only worth persisting if every path fills it in, so this walks the outcome-producing paths
// reachable without a cluster and refuses a zero disposition on any of them: a zero disposition would be
// encoded as an empty string, which decodeRunRecord rejects and which claims nothing about the run.
func TestRunSetsADispositionOnEveryPathReachableWithoutACluster(t *testing.T) {
	// A connect failure is the earliest return in run(), before anything is acquired or built.
	o, _, res := run(context.Background(),
		func() (client.WithWatch, error) { return nil, fmt.Errorf("kubeconfig: no such file") },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker", time.Duration(horizonSec)*time.Second)
	if o.Disposition != dispClientFailed {
		t.Fatalf("a failed connect is client-failed, got %q", o.Disposition)
	}
	if res != nil {
		t.Fatal("a run that never connected must hand back no result")
	}

	// An acquisition refusal is the last return before the emergency-release defer is even registered, which
	// is the boundary a future edit is most likely to get wrong.
	held := node(map[string]string{workerLabelKey: "someone-else"}, nil)
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(held).Build()
	o, _, res = run(context.Background(), func() (client.WithWatch, error) { return fc, nil },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker", time.Duration(horizonSec)*time.Second)
	if o.Disposition != dispAcquisitionRefused {
		t.Fatalf("a refused acquisition is acquisition-refused, got %q: %s", o.Disposition, o.Reason)
	}
	if res != nil {
		t.Fatal("a run that never acquired its worker must hand back no result")
	}
	if o.Reason == "" {
		t.Fatal("a refusal with no reason tells the operator nothing the record can act on")
	}
}

// The preview note is the one free-text field in either record, so a future writer could fold run data into
// it and hand a gateless run the reconstructable evidence previewRecord has no field for. It must therefore
// be the same constant whatever the run did.
func TestPreviewRecordNoteIsAConstantNotDerivedFromTheRun(t *testing.T) {
	quiet := buildRecord(outcome{Disposition: dispChecksPassed}, nil, "r1", "A-honor", true,
		time.Now(), time.Now()).(previewRecord)
	busy := buildRecord(outcome{Disposition: dispCancelled, Reason: "observing until the horizon"},
		[]queuelab.LifecycleEvent{{ElapsedNs: 1, Kind: "Pod", Job: "a1"}}, "r2", "N-ref", true,
		time.Now(), time.Now()).(previewRecord)

	if quiet.Note != previewNote || busy.Note != previewNote {
		t.Fatalf("the note must be the fixed constant, got %q and %q", quiet.Note, busy.Note)
	}
	if quiet.Note != busy.Note {
		t.Fatal("the note varied with the run, which is the smuggling path a constant exists to close")
	}
}

// A refusal that fired before -runid was read still has to leave a record a reader can open, and
// decodeRunRecord requires a non-empty run id. The sentinel only works if it can never be confused with a
// run id somebody actually passed, which is a property of runIDPattern rather than of the constant.
func TestRefusalRecordIsReadableEvenWithoutARunID(t *testing.T) {
	if runIDPattern.MatchString(unidentifiedRunID) {
		t.Fatalf("%q is an acceptable run id, so a real run could collide with the sentinel", unidentifiedRunID)
	}

	err := errors.New("-runid is required")
	rec := buildRecord(outcome{Disposition: dispRefusedBeforeCluster, Reason: err.Error(), Err: err},
		nil, recordRunID(""), "", false, time.Now(), time.Now())
	b, encErr := encodeRecord(rec)
	if encErr != nil {
		t.Fatalf("encode: %v", encErr)
	}
	got, decErr := decodeRunRecord(b)
	if decErr != nil {
		t.Fatalf("a refusal's record must decode, or the refusals this record exists to make visible are "+
			"written and then unreadable: %v", decErr)
	}
	if got.Disposition != string(dispRefusedBeforeCluster) {
		t.Fatalf("a refusal is refused-before-cluster, got %q", got.Disposition)
	}
	if got.RunID != unidentifiedRunID {
		t.Fatalf("an unidentified invocation must say so rather than carry an empty id, got %q", got.RunID)
	}
}

// -out names the record now that the bare ledger is gone, and an invocation that names no path must still
// leave one: a record written only when asked for would be absent exactly when an operator is trying to work
// out what a surprising refusal did.
func TestRecordPathFallsBackToADefaultRatherThanBeingSkipped(t *testing.T) {
	if got := recordPathFor(""); got != defaultRecordName {
		t.Fatalf("an unnamed record path must fall back to %q, got %q", defaultRecordName, got)
	}
	if got := recordPathFor("/tmp/rec1.json"); got != "/tmp/rec1.json" {
		t.Fatalf("-out must name the record, got %q", got)
	}
}
