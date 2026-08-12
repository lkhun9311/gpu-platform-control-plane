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
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/apiutil"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	kueuev1beta2 "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
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
	fc := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil)).
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

	tdNow, tdSleep := fakeClock(time.Unix(0, 0))
	o, events, res, _ := run(context.Background(), func() (client.WithWatch, error) { return fc, nil },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker", time.Duration(horizonSec)*time.Second,
		tdNow, tdSleep)

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
	if err := writeRecord(path, buildRecord(o, events, nil, "r7", string(queuelab.ArmAHonor), false,
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

// This covers exactly two of run()'s seventeen returns — the connect failure and the acquisition refusal —
// and its name says so. An earlier version claimed to cover every path, which it could not: the other
// fifteen need a live cluster, and a reviewer proved the gap by deleting four `o = ...` assignments and
// watching go vet stay silent and the suite stay green. The totality invariant is enforced in
// buildRecord's classified() instead; see TestBuildRecordRefusesAZeroDisposition.
//
// These two are still worth pinning by hand because they bracket the emergency-release defer: the connect
// failure returns before it is registered, and the acquisition refusal is the last return before it is.
func TestRunSetsADispositionOnTheConnectAndAcquisitionPaths(t *testing.T) {
	// A connect failure is the earliest return in run(), before anything is acquired or built.
	tdNow, tdSleep := fakeClock(time.Unix(0, 0))
	o, _, res, _ := run(context.Background(),
		func() (client.WithWatch, error) { return nil, fmt.Errorf("kubeconfig: no such file") },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker", time.Duration(horizonSec)*time.Second,
		tdNow, tdSleep)
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
	o, _, res, _ = run(context.Background(), func() (client.WithWatch, error) { return fc, nil },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker", time.Duration(horizonSec)*time.Second,
		tdNow, tdSleep)
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
	quiet := buildRecord(outcome{Disposition: dispChecksPassed}, nil, nil, "r1", "A-honor", true,
		time.Now(), time.Now()).(previewRecord)
	busy := buildRecord(outcome{Disposition: dispCancelled, Reason: "observing until the horizon"},
		[]queuelab.LifecycleEvent{{ElapsedNs: 1, Kind: "Pod", Job: "a1"}}, nil, "r2", "N-ref", true,
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
	rec := buildRecord(outcome{Disposition: dispRefusedBeforeCluster, Reason: err.Error()},
		nil, nil, recordRunID(""), "", false, time.Now(), time.Now())
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
//
// The default must also differ per invocation. It used to be one fixed name, which composed into a real
// defect: writeRecord replaces by rename, so a mistyped command in the same working directory destroyed the
// previous run's record — a refusal erasing evidence, inside the change written to stop refusals erasing
// evidence.
func TestRecordPathNamesEveryInvocationSeparately(t *testing.T) {
	if got := recordPathFor("/tmp/rec1.json", time.Now(), 1234); got != "/tmp/rec1.json" {
		t.Fatalf("-out must name the record, got %q", got)
	}

	at := time.Date(2026, 8, 8, 1, 10, 27, 0, time.UTC)
	first := recordPathFor("", at, 1234)
	if first == "" || !strings.HasSuffix(first, ".json") {
		t.Fatalf("an unnamed record path must still name a file, got %q", first)
	}

	// Two invocations in the same second are separated by the pid, and two at the same pid by the clock, so
	// no pair of live invocations can land on one path by construction.
	if sameSecond := recordPathFor("", at, 5678); sameSecond == first {
		t.Fatalf("two invocations in the same second collided on %q", first)
	}
	if samePID := recordPathFor("", at.Add(time.Second), 1234); samePID == first {
		t.Fatalf("two invocations at the same pid collided on %q", first)
	}
}

// A zero disposition is the silent lie this task exists to prevent, and no test can walk the seventeen
// returns that could produce one: fifteen need a live cluster. So the invariant is enforced where every
// record is built rather than audited where only some are reachable — a reviewer deleted four `o = ...`
// assignments and neither go vet nor the suite noticed.
func TestBuildRecordRefusesAZeroDisposition(t *testing.T) {
	rr, ok := buildRecord(outcome{}, nil, nil, "r7", "A-honor", false, time.Now(), time.Now()).(runRecord)
	if !ok {
		t.Fatal("a non-preview invocation must build a runRecord")
	}
	if rr.Disposition != string(dispUnclassified) {
		t.Fatalf("an unset disposition must be named, not written as an empty string, got %q", rr.Disposition)
	}
	if !strings.Contains(rr.Reason, "bug in run()") {
		t.Fatalf("the record must say this is a bug rather than an outcome of the run, got %q", rr.Reason)
	}

	// The preview branch builds a different type, so it needs its own proof rather than inheriting this one.
	pr, ok := buildRecord(outcome{}, nil, nil, "r7", "A-honor", true, time.Now(), time.Now()).(previewRecord)
	if !ok {
		t.Fatal("a preview invocation must build a previewRecord")
	}
	if pr.Disposition != string(dispUnclassified) {
		t.Fatalf("the preview branch must substitute too, got %q", pr.Disposition)
	}

	// The substitution must not touch an outcome that already has one, or it would rewrite real dispositions.
	kept := buildRecord(outcome{Disposition: dispChecksPassed, Reason: "x"}, nil, nil, "r7", "A-honor", false,
		time.Now(), time.Now()).(runRecord)
	if kept.Disposition != string(dispChecksPassed) || kept.Reason != "x" {
		t.Fatalf("a classified outcome must pass through untouched, got %q / %q", kept.Disposition, kept.Reason)
	}
}

// The persist-before-publish ordering is the rule this whole task establishes, and it used to live inline
// in main(), which no test can call. If a persistence failure still rendered, an unrecorded result would
// reach the terminal and a non-zero exit could not retract it.
func TestReportRunPublishesNothingWhenTheRecordCannotBePersisted(t *testing.T) {
	var stdout, stderr bytes.Buffer
	res := queuelab.LabResult{Arm: "A-honor"}
	code := reportRun(&stdout, &stderr, func(string, any) error { return errors.New("disk full") },
		runReport{
			Outcome: outcome{Disposition: dispChecksPassed},
			Events:  []queuelab.LifecycleEvent{{ElapsedNs: 1, Kind: "Pod", Job: "a1"}},
			Result:  &res,
			Record:  runRecord{SchemaVersion: recordSchemaVersion},
			Path:    "/nowhere/run.json",
		})

	if code == 0 {
		t.Fatal("a run whose record was not persisted must exit non-zero")
	}
	if stdout.Len() != 0 {
		t.Fatalf("nothing may be published when the record is not durable, got stdout %q", stdout.String())
	}
	if !strings.Contains(stderr.String(), "not persisted") {
		t.Fatalf("the persistence failure exists only on stderr, so it must be there: %q", stderr.String())
	}
}

// The mirror of the test above: a successful write must publish the RESULT, which is the one thing a
// non-zero exit cannot retract once it is on the terminal.
//
// It asserts on the rendered result rather than on a ledger line for a reason a reviewer proved empirically:
// deleting reportRun's rendering block left the suite green, because an events line is printed by printEvents
// and satisfies any assertion that only looks for one.
func TestReportRunPublishesOnceTheRecordIsDurable(t *testing.T) {
	var stdout, stderr bytes.Buffer
	res := queuelab.LabResult{Arm: "A-honor"}
	wrote := ""
	code := reportRun(&stdout, &stderr, func(path string, _ any) error { wrote = path; return nil },
		runReport{
			Outcome: outcome{Disposition: dispChecksPassed},
			Events:  []queuelab.LifecycleEvent{{ElapsedNs: 1, Kind: "Pod", Job: "a1"}},
			Result:  &res,
			Record:  runRecord{SchemaVersion: recordSchemaVersion},
			Path:    "/tmp/run.json",
		})

	if code != 0 {
		t.Fatalf("a run that passed its checks and persisted its record exits 0, got %d", code)
	}
	if wrote != "/tmp/run.json" {
		t.Fatalf("reportRun must persist to the path it was given, got %q", wrote)
	}
	if !strings.Contains(stdout.String(), queuelab.RenderResult(res)) {
		t.Fatalf("a durable record must be followed by the rendered result, got %q", stdout.String())
	}
	if !strings.Contains(stdout.String(), "job=a1") {
		t.Fatalf("a non-preview run publishes its ledger, got %q", stdout.String())
	}
	if !strings.Contains(stderr.String(), "/tmp/run.json") {
		t.Fatalf("the operator must be told where the record went, got %q", stderr.String())
	}
}

// The other half of the rendering rule: a durable record is necessary to publish a result, not sufficient.
//
// run() hands back a nil Result on every path that failed, so this scenario needs the caller to be wrong
// about that — a Result surviving alongside a failing disposition — and the check that must catch it is the
// disposition gate, not the nil check. Rendering here would put a number on the terminal for a run whose own
// collector desynced, which is exactly the "a run that looked fine was allowed to count" failure this lab
// published once already.
func TestReportRunRendersNoResultUnlessTheChecksPassed(t *testing.T) {
	var stdout, stderr bytes.Buffer
	res := queuelab.LabResult{Arm: "A-honor"}
	code := reportRun(&stdout, &stderr, func(string, any) error { return nil }, runReport{
		Outcome: outcome{Disposition: dispCollectorDesync, Reason: "watch gap"},
		Events:  []queuelab.LifecycleEvent{{ElapsedNs: 1, Kind: "Pod", Job: "a1"}},
		Result:  &res,
		Record:  runRecord{SchemaVersion: recordSchemaVersion},
		Path:    "/tmp/run.json",
	})

	if code == 0 {
		t.Fatal("a run that did not pass its checks must exit non-zero")
	}
	if strings.Contains(stdout.String(), queuelab.RenderResult(res)) {
		t.Fatalf("a result must not be rendered for a disposition other than %s, got %q",
			dispChecksPassed, stdout.String())
	}
	// The ledger still publishes: withholding it would leave the failed run undiagnosable, which is the
	// invisibility this record exists to end — only the countable result is withheld.
	if !strings.Contains(stdout.String(), "job=a1") {
		t.Fatalf("a failed non-preview run still publishes its ledger, got %q", stdout.String())
	}
	if !strings.Contains(stderr.String(), string(dispCollectorDesync)) {
		t.Fatalf("stderr must name the disposition that stopped publication, got %q", stderr.String())
	}
}

// reportRun applies the same substitution buildRecord does, so the terminal and the record cannot give two
// accounts of one run.
//
// Without it a zero disposition — a bug in run(), not an outcome of it — printed as "ERROR: :", the blank
// field dispUnclassified exists precisely to replace, while the record on disk named it correctly.
func TestReportRunNamesAnUnclassifiedOutcomeOnStderrToo(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := reportRun(&stdout, &stderr, func(string, any) error { return nil }, runReport{
		Outcome: outcome{},
		Record:  runRecord{SchemaVersion: recordSchemaVersion},
		Path:    "/tmp/run.json",
	})

	if code == 0 {
		t.Fatal("an unclassified outcome is not a passing run")
	}
	if !strings.Contains(stderr.String(), string(dispUnclassified)) {
		t.Fatalf("stderr must name the unclassified failure rather than print a blank field, got %q",
			stderr.String())
	}
	if !strings.Contains(stderr.String(), "bug in run()") {
		t.Fatalf("stderr must carry the same reason the record does, got %q", stderr.String())
	}
}

// previewRecord carries a count and no events so a gateless run cannot emit anything reconstructable, and
// a printed ledger reconstructs exactly as well as a written one: `queuelabrun -preview ... > ledger.txt`
// would otherwise produce the artifact the record's whole shape exists to deny.
func TestReportRunWithholdsTheLedgerFromAPreview(t *testing.T) {
	var stdout, stderr bytes.Buffer
	events := []queuelab.LifecycleEvent{{ElapsedNs: 1, Kind: "Pod", Type: queuelab.EventPodReady, Job: "a1"}}
	reportRun(&stdout, &stderr, func(string, any) error { return nil }, runReport{
		Outcome: outcome{Disposition: dispChecksPassed},
		Events:  events,
		Record:  previewRecord{SchemaVersion: recordSchemaVersion},
		Path:    "/tmp/run.json",
		Preview: true,
	})

	out := stdout.String()
	if strings.Contains(out, "job=a1") || strings.Contains(out, string(queuelab.EventPodReady)) {
		t.Fatalf("a preview must not print its ledger, got %q", out)
	}
	if !strings.Contains(out, "ledger: 1 events") {
		t.Fatalf("a preview still reports how many events it saw, got %q", out)
	}
	if !strings.Contains(out, previewBanner) {
		t.Fatalf("preview output must stay bracketed by the banner, got %q", out)
	}
}

// fullScheme extends testScheme with the CRDs a full protocol run touches.
//
// Every test that reaches run()'s teardown now needs it, not just the ones that drive the whole protocol:
// teardown enumerates a ClusterQueue and a ResourceFlavor and reads both, and against a scheme without them
// every read fails, every target classifies absenceUnknown, and the run reports residue for a reason that
// has nothing to do with what it is testing. testScheme stays as it is for the tests that never reach a
// cluster at all.
func fullScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := testScheme(t)
	if err := platformv1.AddToScheme(scheme); err != nil {
		t.Fatalf("add platform/v1 to scheme: %v", err)
	}
	if err := kueuev1beta2.AddToScheme(scheme); err != nil {
		t.Fatalf("add kueue v1beta2 to scheme: %v", err)
	}
	return scheme
}

// fakeSchedulerCreate stands in for the Kueue scheduler this fake cluster has none of. It stamps every
// MLTrainingJob straight to Running — the fact the barrier-staged schedule depends on — so an uncontested
// arm falls through to run()'s own explicit release exactly as it would against a real, empty cluster with
// nothing else competing for the worker.
//
// The UID it used to set by hand now comes from stampUIDOnCreate, which does it for every kind rather than
// for MLTrainingJob alone. The collector's UID-keyed cache always needed one; teardown needs one on the
// namespace and the fixtures too, and a fake cluster that assigned UIDs to exactly one kind would report
// residue for every run() test purely as an artefact of the double.
func fakeSchedulerCreate(ctx context.Context, c client.WithWatch, obj client.Object,
	opts ...client.CreateOption) error {
	if mltj, ok := obj.(*platformv1.MLTrainingJob); ok {
		mltj.Status.Phase = phaseRunning
	}
	return stampUIDOnCreate(ctx, c, obj, opts...)
}

// stubWatch never delivers an event; it exists only to close once ctx is cancelled, which the fake client's
// real Watch — a thin wrapper over an in-memory tracker with no notion of context at all — never does on its
// own. collector.watch relies on that closing to unblock and rejoin its goroutines once run() cancels its
// observation context, so without this a full run() driven against a bare fake client hangs forever in
// col.wait() the instant it tries to finish, whatever the rest of the run computed.
//
// It costs nothing in fidelity here: every fact this file's two full-run tests depend on — an MLTrainingJob's
// Submitted event and its Status.Phase for the barrier checks — is written directly rather than observed off
// a watch (see fakeSchedulerCreate and collector.submitObserved), and classify() has no case for
// MLTrainingJob in the first place, so a real relay of watch events would not change what either test sees.
type stubWatch struct{ ch chan watch.Event }

func newStubWatch(ctx context.Context) *stubWatch {
	w := &stubWatch{ch: make(chan watch.Event)}
	go func() {
		<-ctx.Done()
		close(w.ch)
	}()
	return w
}

func (w *stubWatch) Stop()                          {}
func (w *stubWatch) ResultChan() <-chan watch.Event { return w.ch }

// fakeSchedulerWatch pairs with fakeSchedulerCreate to complete the fake-cluster double: see stubWatch.
func fakeSchedulerWatch(ctx context.Context, c client.WithWatch, obj client.ObjectList,
	opts ...client.ListOption) (watch.Interface, error) {
	return newStubWatch(ctx), nil
}

// run()'s own release — at the very end, after reconstruction and cardinality have already passed, not the
// deferred emergency one that covers early returns — is the last thing standing between a computed result
// and calling the worker restored. If it fails, run() must reach classifyReleaseFailure, not the phase
// classifier every earlier failure in this function uses, because this release ran to completion rather than
// being cut short partway through: a failure here means the worker is still held, in full, with nothing left
// to retry, which is what dispWorkerNotRestored says and dispCancelled does not.
//
// Driving this requires run() to actually complete its protocol, so the Node patch this test fails is
// counted rather than the first one intercepted: the first Node patch is acquireWorker's own, and only the
// second is the run's own release.
//
// This test is real time, not simulated: it drives run() through the actual doseSec=40 protocol wait (see
// spine.go), which is a protocol constant the experiment's validity rests on and is deliberately not made
// configurable for tests — a test-only override would be exactly the seam that later gets used in
// production. -short skips it for that reason: `go test -short` does NOT check that an explicit release
// failure is recorded as worker-not-restored with nothing rendered. Only a full `go test` (no -short)
// exercises this acceptance condition.
func TestRunExplicitReleaseFailureRecordsWorkerNotRestored(t *testing.T) {
	if testing.Short() {
		t.Skip("drives run() through the full 40-second protocol dose to reach the explicit-release path; " +
			"this and the cancellation test below are the only two that drive run() past col.start, so -short " +
			"leaves submit, the barriers, the collector and the explicit release entirely unexercised — in " +
			"particular it does not check that an explicit release failure is recorded as worker-not-restored")
	}
	var nodePatches int
	fc := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: fakeSchedulerCreate,
			Watch:  fakeSchedulerWatch,
			Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
				opts ...client.PatchOption) error {
				if _, ok := obj.(*corev1.Node); ok {
					nodePatches++
					// A non-conflict error is not retried, which is what makes it land on the explicit
					// release's own failure path rather than acquisition's conflict-retry loop.
					if nodePatches == 2 {
						return fmt.Errorf("apiserver unreachable")
					}
				}
				return c.Patch(ctx, obj, patch, opts...)
			},
		}).Build()

	tdNow, tdSleep := fakeClock(time.Unix(0, 0))
	o, events, res, _ := run(context.Background(), func() (client.WithWatch, error) { return fc, nil },
		queuelab.ArmNRef, "r8", "queuelab-r8", "platform-worker", 45*time.Second, tdNow, tdSleep)

	if nodePatches != 2 {
		t.Fatalf("want exactly 2 node patches (acquire + the run's own release), got %d — this test proved "+
			"nothing about the explicit release if the run never reached it", nodePatches)
	}
	if res != nil {
		t.Fatal("a run whose own release failed must hand back no result to render, or a caller could " +
			"publish a number computed under a worker that is still held")
	}
	if o.Disposition != dispWorkerNotRestored {
		t.Fatalf("an explicit release failure is worker-not-restored, got %s: %s", o.Disposition, o.Reason)
	}

	// The record is what actually survives, so the assertion is made against the bytes on disk rather than
	// the in-memory outcome the test already holds.
	path := t.TempDir() + "/record.json"
	started := time.Now()
	if err := writeRecord(path, buildRecord(o, events, nil, "r8", string(queuelab.ArmNRef), false,
		started, started.Add(45*time.Second))); err != nil {
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
		t.Fatalf("the persisted record must carry worker-not-restored, got %s", rr.Disposition)
	}
}

// This is the acceptance condition the whole disposition design turns on. run()'s own release executes on
// cleanupContext — a bounded context deliberately derived from context.Background() rather than the
// signal-cancelled run context, exactly so a Ctrl-C landing while restoration is in flight cannot be
// mistaken for the reason restoration failed (see cleanupContext's and classifyReleaseFailure's comments).
//
// This drives that scenario for real: it cancels the run's own context from inside the release-phase Patch,
// the instant restoration is in flight, and checks two things. First, that the context the release actually
// ran on was still live the moment cancellation landed elsewhere — proving cleanupContext is genuinely
// independent rather than only documented as such, since a regression that handed the release the run's own
// context would show Canceled here immediately, before the injected failure below even matters. Second, that
// the disposition which follows names the release failure and never cancellation: the wrong implementation
// this guards against is routing the release failure through the PHASE classifier (classifyPhaseFailure)
// instead of classifyReleaseFailure, which is why the injected failure itself wraps context.Canceled — the
// phase classifier treats that as cancellation outright and would relabel this run cancelled, exactly the
// misreading two accounts of one run — a worker still held, reported as merely interrupted — that this
// design exists to prevent.
//
// This test is real time, not simulated: it drives run() through the actual doseSec=40 protocol wait (see
// spine.go), which is a protocol constant the experiment's validity rests on and is deliberately not made
// configurable for tests — a test-only override would be exactly the seam that later gets used in
// production. -short skips it for that reason: `go test -short` does NOT check the acceptance condition
// above — that a cancellation arriving while restoration is in flight never relabels the run cancelled. Only
// a full `go test` (no -short) exercises it.
func TestRunCancellationWhileRestoringNeverRelabelsAsCancelled(t *testing.T) {
	if testing.Short() {
		t.Skip("drives run() through the full 40-second protocol dose to reach the explicit-release path; " +
			"this and the release-failure test above are the only two that drive run() past col.start, so " +
			"-short leaves submit, the barriers, the collector and the explicit release entirely unexercised " +
			"— in particular it does not check that a cancellation during restoration never relabels the run " +
			"cancelled")
	}
	ctx, cancel := context.WithCancel(context.Background())
	var nodePatches int
	var releaseCtxErr error
	fc := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: fakeSchedulerCreate,
			Watch:  fakeSchedulerWatch,
			Patch: func(pctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
				opts ...client.PatchOption) error {
				if _, ok := obj.(*corev1.Node); ok {
					nodePatches++
					if nodePatches == 2 {
						cancel()
						releaseCtxErr = pctx.Err()
						return fmt.Errorf("release patch: %w", context.Canceled)
					}
				}
				return c.Patch(pctx, obj, patch, opts...)
			},
		}).Build()

	tdNow, tdSleep := fakeClock(time.Unix(0, 0))
	o, events, res, _ := run(ctx, func() (client.WithWatch, error) { return fc, nil },
		queuelab.ArmNRef, "r9", "queuelab-r9", "platform-worker", 45*time.Second, tdNow, tdSleep)

	if nodePatches != 2 {
		t.Fatalf("want exactly 2 node patches (acquire + the run's own release), got %d — this test proved "+
			"nothing about restoration if the run never reached it", nodePatches)
	}
	if releaseCtxErr != nil {
		t.Fatalf("the release ran on a context the run's own cancellation could reach; want an independent "+
			"one derived from cleanupContext, got err %v on it", releaseCtxErr)
	}
	if res != nil {
		t.Fatal("a run whose own release failed must hand back no result to render")
	}
	if o.Disposition != dispWorkerNotRestored {
		t.Fatalf("a cancellation arriving while restoration is in flight must not relabel the run cancelled; "+
			"want worker-not-restored, got %s: %s", o.Disposition, o.Reason)
	}

	path := t.TempDir() + "/record.json"
	started := time.Now()
	if err := writeRecord(path, buildRecord(o, events, nil, "r9", string(queuelab.ArmNRef), false,
		started, started.Add(45*time.Second))); err != nil {
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
		t.Fatalf("the persisted record must not carry cancelled, got %s", rr.Disposition)
	}
}

// runCall is one mutating call run() made against the cluster, in the order it made it.
//
// The property these tests are about — teardown happens before the worker's markers come off — is a
// property of the ORDER of calls, and no final state can show it: the node ends up released and the
// namespace ends up gone whichever order they happened in. This is the same reason Task 1's phase-order
// test had to assert on a call log rather than on what the cluster looked like afterwards.
type runCall struct {
	Op   string // "delete" | "patch"
	Kind string
	Name string
}

// recordRunCalls wraps a client so every delete and patch is captured in order.
//
// It wraps with interceptor.NewClient rather than adding to the builder, because WithInterceptorFuncs is a
// single slot whose last call wins and every test below needs its own Create behaviour as well as the log.
// The mutex is not decorative: run() has four watch goroutines live for most of its body, and a test that
// only happens not to trip -race today would be a poor thing to leave for the next reader.
func recordRunCalls(t *testing.T, inner client.WithWatch) (client.WithWatch, func() []runCall) {
	t.Helper()
	var (
		mu  sync.Mutex
		got []runCall
	)
	kindOf := func(obj client.Object) string {
		gvk, err := apiutil.GVKForObject(obj, inner.Scheme())
		if err != nil {
			t.Fatalf("no GroupVersionKind for %T: %v", obj, err)
		}
		return gvk.Kind
	}
	add := func(c runCall) {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, c)
	}
	c := interceptor.NewClient(inner, interceptor.Funcs{
		Delete: func(ctx context.Context, cl client.WithWatch, obj client.Object,
			opts ...client.DeleteOption) error {
			add(runCall{Op: "delete", Kind: kindOf(obj), Name: obj.GetName()})
			return cl.Delete(ctx, obj, opts...)
		},
		Patch: func(ctx context.Context, cl client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			add(runCall{Op: "patch", Kind: kindOf(obj), Name: obj.GetName()})
			return cl.Patch(ctx, obj, patch, opts...)
		},
	})
	return c, func() []runCall {
		mu.Lock()
		defer mu.Unlock()
		return append([]runCall(nil), got...)
	}
}

// stampUIDOnCreate gives every created object a UID, which a real apiserver does and the fake client does
// not.
//
// Without it these tests would exercise a cluster no teardown can ever meet: recoverTargets learns the UID
// from the object it reads, classifyAbsence returns absenceUnknown for an empty one, and the executor would
// therefore never issue a single Delete — every run() test would "prove" residue for the wrong reason.
func stampUIDOnCreate(ctx context.Context, c client.WithWatch, obj client.Object,
	opts ...client.CreateOption) error {
	if obj.GetUID() == "" {
		obj.SetUID(types.UID("uid-" + obj.GetName()))
	}
	return c.Create(ctx, obj, opts...)
}

// firstIndexOf reports where a call appears in the log, or -1. The tests assert on indices rather than on
// mere presence, because presence is what both the right and the wrong order have in common.
func firstIndexOf(calls []runCall, op, kind string, nth int) int {
	seen := 0
	for i, c := range calls {
		if c.Op == op && c.Kind == kind {
			seen++
			if seen == nth {
				return i
			}
		}
	}
	return -1
}

// releasePatchIndex is where the run's own release of the worker appears. It is the SECOND Node patch:
// the first is acquireWorker installing the markers, and a test that looked for "a Node patch" would be
// satisfied by the acquisition alone and could never fail.
func releasePatchIndex(calls []runCall) int { return firstIndexOf(calls, "patch", "Node", 2) }

// The ordering this whole task exists to establish, on the path that returns early — which is every failure
// between acquiring the worker and reconstructing the result, and therefore the common case.
//
// If the worker's label and NoSchedule taint came off first, the next run would acquire a node whose GPUs
// this run's namespace is still holding, and it would look perfectly free while doing it. The assertion is
// on the index of the namespace delete against the index of the release patch, because both calls happen in
// either order and only their sequence distinguishes the two implementations.
func TestRunTearsDownBeforeTheEmergencyReleaseOnAnEarlyReturn(t *testing.T) {
	inner := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: func(ctx context.Context, c client.WithWatch, obj client.Object,
				opts ...client.CreateOption) error {
				// The flavor is the first fixture applyFixtures creates, so failing it returns the run early
				// with the namespace already on the cluster: the exact state teardown exists for.
				if _, ok := obj.(*kueuev1beta2.ResourceFlavor); ok {
					return fmt.Errorf("resource flavor quota exhausted")
				}
				return stampUIDOnCreate(ctx, c, obj, opts...)
			},
		}).Build()
	c, calls := recordRunCalls(t, inner)
	now, sleep := fakeClock(time.Unix(0, 0))

	o, _, res, left := run(context.Background(), func() (client.WithWatch, error) { return c, nil },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker",
		time.Duration(horizonSec)*time.Second, now, sleep)

	if res != nil {
		t.Fatal("a run that failed setup must hand back no result")
	}
	if o.Disposition != dispSetupFailed {
		t.Fatalf("a clean teardown must leave the original disposition alone, got %s: %s", o.Disposition, o.Reason)
	}
	if len(left) != 0 {
		t.Fatalf("teardown had one namespace to remove and it was removable; residue %+v", left)
	}

	got := calls()
	del := firstIndexOf(got, "delete", "Namespace", 1)
	rel := releasePatchIndex(got)
	if del < 0 {
		t.Fatalf("the namespace this run created was never deleted; calls: %+v", got)
	}
	if rel < 0 {
		t.Fatalf("the worker was never released; calls: %+v", got)
	}
	if del > rel {
		t.Fatalf("the worker was released at call %d, before the namespace was deleted at call %d: the next "+
			"run would acquire a node this run's namespace still holds; calls: %+v", rel, del, got)
	}
}

// The same ordering on the path that returns normally, which a defer cannot get right on its own: an inline
// release always runs before a defer registered later, so the happy path has to call teardown explicitly and
// in the right place. Nothing about the deferred path can show that.
//
// This test is real time, not simulated: it drives run() through the actual doseSec=40 protocol wait, the
// same as the two release tests above and for the same reason — the dose is a protocol constant the
// experiment's validity rests on and is deliberately not configurable. -short therefore does NOT check the
// happy-path half of this ordering.
func TestRunTearsDownBeforeItsOwnReleaseOnTheHappyPath(t *testing.T) {
	if testing.Short() {
		t.Skip("drives run() through the full 40-second protocol dose to reach the happy path; -short leaves " +
			"the inline teardown-before-release ordering unexercised, and only the deferred path is checked")
	}
	inner := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: fakeSchedulerCreate,
			Watch:  fakeSchedulerWatch,
		}).Build()
	c, calls := recordRunCalls(t, inner)
	now, sleep := fakeClock(time.Unix(0, 0))

	o, _, res, left := run(context.Background(), func() (client.WithWatch, error) { return c, nil },
		queuelab.ArmNRef, "r8", "queuelab-r8", "platform-worker", 45*time.Second, now, sleep)

	if o.Disposition != dispChecksPassed {
		t.Fatalf("an uncontested N-ref run against a clean cluster must pass, got %s: %s", o.Disposition, o.Reason)
	}
	if res == nil {
		t.Fatal("a passing run must hand back a result, or this test never reached the happy path at all")
	}
	if len(left) != 0 {
		t.Fatalf("teardown left residue on a cluster that deletes on request: %+v", left)
	}

	got := calls()
	del := firstIndexOf(got, "delete", "Namespace", 1)
	rel := releasePatchIndex(got)
	if del < 0 {
		t.Fatalf("the namespace this run created was never deleted; calls: %+v", got)
	}
	if rel < 0 {
		t.Fatalf("the run never released its worker; calls: %+v", got)
	}
	if del > rel {
		t.Fatalf("the happy path released the worker at call %d before deleting the namespace at call %d; a "+
			"defer registered after the release cannot fix this, the call has to be inline and earlier; "+
			"calls: %+v", rel, del, got)
	}
	// The fixtures are cluster-scoped and outlive the namespace, so a teardown that stopped at the namespace
	// would leave the next run under this id colliding with a ResourceFlavor built for a different arm.
	if firstIndexOf(got, "delete", "ResourceFlavor", 1) < 0 {
		t.Fatalf("the run's ResourceFlavor was never deleted; calls: %+v", got)
	}
}

// The rerun a used run id actually produces: a cluster-scoped ResourceFlavor from a previous attempt is still
// there (only the namespace is ever cleaned up by hand), so applyFixtures refuses and the run returns early
// with its own namespace already created.
//
// Everything this test asserts used to be the other way round. Recovery refused the whole batch on the first
// foreign target, so teardown issued no Delete at all, the run's own namespace stayed on the cluster, the
// record carried disposition residue-left with an EMPTY residue array — naming nothing, which a next-run gate
// keying on len(Residue) > 0 waves straight through — and the worker was held forever for a run whose only
// cluster write it could not undo was one it had not made.
//
// The worker going back is the deliberate half, and the disposition still reporting residue is the other:
// every object still standing here is one this run did not create, so holding contains nothing — the taint
// and label go back exactly as they were found, which is the state the previous attempt's leftovers were
// already sitting in — but the name is taken, the next run under this id collides with it just the same, and
// the record is what carries that.
func TestRunTearsDownAroundAStaleFixtureFromAPreviousAttempt(t *testing.T) {
	variant, err := queuelab.ArmAHonor.PolicyVariant()
	if err != nil {
		t.Fatalf("policy variant: %v", err)
	}
	// The flavor is built by the real builder so its name is whatever teardown will enumerate, and it carries
	// the variant this arm requires — so applyFixtures fails on the TRANSACTION check rather than on the
	// variant check, which is the case that reaches teardown with a foreign object at one of its own names.
	fs, err := queuelab.BuildFixtures(queuelab.StudyReclaim, variant, "tx-previous", "r7", "queuelab-r7")
	if err != nil {
		t.Fatalf("build fixtures: %v", err)
	}
	stale := fs.Flavor.DeepCopy()
	stale.SetUID("rf-uid-previous")
	inner := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil), stale).
		WithInterceptorFuncs(interceptor.Funcs{Create: stampUIDOnCreate}).Build()
	c, calls := recordRunCalls(t, inner)
	now, sleep := fakeClock(time.Unix(0, 0))

	o, _, res, left := run(context.Background(), func() (client.WithWatch, error) { return c, nil },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker",
		time.Duration(horizonSec)*time.Second, now, sleep)

	if res != nil {
		t.Fatal("a run that failed setup must hand back no result")
	}
	if o.Disposition != dispResidueLeft {
		t.Fatalf("a name this run's teardown could not clear is %s, got %s: %s",
			dispResidueLeft, o.Disposition, o.Reason)
	}
	// The collision this run actually failed on has to survive the amendment, or the record says a name was
	// left behind without saying it is the same name that refused the run in the first place.
	if !strings.Contains(o.Reason, "applying fixtures") {
		t.Fatalf("the amended outcome dropped what run() originally decided as the cause, got %q", o.Reason)
	}
	if len(left) != 1 || left[0].Observation.Target.Name != stale.GetName() {
		t.Fatalf("residue is %+v; it must name the one object teardown refused to touch, so the record says "+
			"which name is taken rather than carrying an empty array", left)
	}
	if left[0].Absence != absenceForeign {
		t.Errorf("the stale flavor classified %v, want foreign", left[0].Absence)
	}

	got := calls()
	for _, call := range got {
		if call.Op == "delete" && call.Name == stale.GetName() {
			t.Fatalf("deleted %s %q, which a previous transaction created and may still be using",
				call.Kind, call.Name)
		}
	}
	del := firstIndexOf(got, "delete", "Namespace", 1)
	if del < 0 {
		t.Fatalf("this run's own namespace was never deleted; one foreign target must not strand the objects "+
			"the run really did create; calls: %+v", got)
	}
	rel := releasePatchIndex(got)
	if rel < 0 {
		t.Fatalf("the worker was never released though nothing this run created is still on the cluster; "+
			"calls: %+v", got)
	}
	if del > rel {
		t.Fatalf("released the worker at call %d before deleting the namespace at call %d; calls: %+v",
			rel, del, got)
	}
	// Asserted on the node, not only on the call log: "a patch happened" and "the markers are gone" are
	// different claims, and the next run acquires on the second one.
	var n corev1.Node
	if err := c.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &n); err != nil {
		t.Fatalf("read the worker back: %v", err)
	}
	if n.Labels[workerLabelKey] != "" || len(n.Spec.Taints) != 0 {
		t.Fatalf("the worker kept its dedication (labels %v, taints %v) for a run that created nothing still "+
			"standing; the next run finds a node that only looks busy", n.Labels, n.Spec.Taints)
	}
}

// residueHoldsWorker is the whole of that decision, so the mixed case is pinned here rather than through a
// second full run: one foreign object among objects this run really did leave behind must still hold the
// worker. Holding is decided by what is NOT foreign, not by whether anything foreign is present.
func TestResidueHoldsTheWorkerUnlessEverythingLeftIsSomebodyElses(t *testing.T) {
	foreign := residue{Observation: observation{Target: target{Kind: "ResourceFlavor", Name: "rf"}, Found: true,
		UID: "theirs", Foreign: true}, Absence: absenceForeign}
	ours := residue{Observation: observation{Target: target{Kind: "Namespace", Name: "ns"}, Found: true,
		UID: "u", WantUID: "u"}, Absence: absencePresent}
	unknown := residue{Observation: observation{Target: target{Kind: "Namespace", Name: "ns"},
		Err: errors.New("etcdserver: leader changed")}, Absence: absenceUnknown}

	for _, tc := range []struct {
		name string
		left []residue
		want bool
	}{
		{"nothing left", nil, false},
		{"only somebody else's names", []residue{foreign}, false},
		{"ours is still there", []residue{ours}, true},
		{"ours cannot be read", []residue{unknown}, true},
		// The one a "does any foreign object appear?" test cannot separate: our namespace may still be
		// running GPU Pods, and a foreign flavor alongside it says nothing about that.
		{"one of each", []residue{foreign, ours}, true},
		{"unreadable alongside a foreign one", []residue{foreign, unknown}, true},
	} {
		if got := residueHoldsWorker(tc.left); got != tc.want {
			t.Errorf("%s: residueHoldsWorker = %v, want %v", tc.name, got, tc.want)
		}
	}
}

// Residue is not a failure to compute a result — it is a fact about the cluster, and two things must follow
// from it: the outcome says so without losing what the run was already failing at, and the worker STAYS
// DEDICATED. Releasing it would strip the NoSchedule taint from a node whose namespace is still there, and
// an annotation cannot contain a GPU Pod; a teardown timeout deliberately sacrifices worker availability to
// preserve isolation.
//
// The namespace delete is refused rather than merely slow, because that is the shape that also proves the
// reason survives: a residue entry saying only "still present" reads as a slow finalizer.
func TestRunTeardownResidueAmendsTheOutcomeAndHoldsTheWorker(t *testing.T) {
	inner := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: func(ctx context.Context, c client.WithWatch, obj client.Object,
				opts ...client.CreateOption) error {
				if _, ok := obj.(*kueuev1beta2.ResourceFlavor); ok {
					return fmt.Errorf("resource flavor quota exhausted")
				}
				return stampUIDOnCreate(ctx, c, obj, opts...)
			},
			Delete: func(ctx context.Context, c client.WithWatch, obj client.Object,
				opts ...client.DeleteOption) error {
				if _, ok := obj.(*corev1.Namespace); ok {
					return apierrors.NewForbidden(schema.GroupResource{Resource: "namespaces"},
						obj.GetName(), errors.New("teardown may not delete namespaces"))
				}
				return c.Delete(ctx, obj, opts...)
			},
		}).Build()
	c, calls := recordRunCalls(t, inner)
	now, sleep := fakeClock(time.Unix(0, 0))

	o, _, res, left := run(context.Background(), func() (client.WithWatch, error) { return c, nil },
		queuelab.ArmAHonor, "r7", "queuelab-r7", "platform-worker",
		time.Duration(horizonSec)*time.Second, now, sleep)

	if res != nil {
		t.Fatal("a run that failed setup must hand back no result")
	}
	if o.Disposition != dispResidueLeft {
		t.Fatalf("a run whose teardown left objects behind is %s, got %s: %s",
			dispResidueLeft, o.Disposition, o.Reason)
	}
	// amend, not assignment: this run failed at setup AND then failed to clean up, and those are not the
	// same event. The record is the only account of it that survives the process.
	if !strings.Contains(o.Reason, "applying fixtures") {
		t.Fatalf("the amended outcome must keep what run() originally decided as the cause in its (after …) "+
			"chain, got %q", o.Reason)
	}
	if len(left) == 0 {
		t.Fatal("run() reported no residue for a namespace it was refused permission to delete; residue that " +
			"never leaves run() cannot reach the record")
	}
	found := false
	for _, r := range left {
		if r.Observation.Target.Name == "queuelab-r7" {
			found = true
		}
	}
	if !found {
		t.Fatalf("the residue must name the namespace that is still there, got %+v", left)
	}

	got := calls()
	if rel := releasePatchIndex(got); rel >= 0 {
		t.Fatalf("the worker was released at call %d despite residue; the next run would schedule onto a node "+
			"whose namespace is still there; calls: %+v", rel, got)
	}
	// Asserted on the node itself as well as on the call log, because "no second patch" and "the markers are
	// still installed" are different claims and the operator's recovery depends on the second one.
	var n corev1.Node
	if err := c.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &n); err != nil {
		t.Fatalf("read the worker back: %v", err)
	}
	if n.Labels[workerLabelKey] == "" {
		t.Fatal("the worker lost its dedication label while this run's namespace was still on the cluster")
	}
	if len(n.Spec.Taints) == 0 {
		t.Fatal("the worker lost its NoSchedule taint while this run's namespace was still on the cluster")
	}
}

// The same containment on the path that MEASURED SOMETHING, which is the case the whole teardown-before-
// release ordering exists for and the only one where the worker is holding live GPU Pods this run put there.
//
// Every other residue test in this package drives an early return: the fixture Create is refused, so run()
// never gets past setup and the inline branch on the happy path — the one that decides both that the worker
// stays and that no result is handed back — is reached by nothing. Deleting that branch outright and
// replacing it with `_ = holdWorker` left the entire package green, which is why this test exists rather than
// a stronger assertion somewhere cheaper.
//
// This test is real time, not simulated: it drives run() through the actual doseSec=40 protocol wait, the
// same as the other full-run tests here and for the same reason — the dose is a protocol constant the
// experiment's validity rests on and is deliberately not configurable. -short therefore does NOT check that a
// successful run holds its worker when teardown leaves residue.
func TestRunHoldsTheWorkerWhenTheHappyPathLeavesResidue(t *testing.T) {
	if testing.Short() {
		t.Skip("drives run() through the full 40-second protocol dose to reach the happy path; -short leaves " +
			"the happy-path worker hold and the no-result-on-residue rule unexercised")
	}
	inner := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(node(nil, nil)).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: fakeSchedulerCreate,
			Watch:  fakeSchedulerWatch,
			// Refused rather than merely slow, so the residue also carries WHY: a record saying only "still
			// present" reads as a finalizer taking its time.
			Delete: func(ctx context.Context, c client.WithWatch, obj client.Object,
				opts ...client.DeleteOption) error {
				if _, ok := obj.(*corev1.Namespace); ok {
					return apierrors.NewForbidden(schema.GroupResource{Resource: "namespaces"},
						obj.GetName(), errors.New("teardown may not delete namespaces"))
				}
				return c.Delete(ctx, obj, opts...)
			},
		}).Build()
	c, calls := recordRunCalls(t, inner)
	now, sleep := fakeClock(time.Unix(0, 0))

	o, events, res, left := run(context.Background(), func() (client.WithWatch, error) { return c, nil },
		queuelab.ArmNRef, "r8", "queuelab-r8", "platform-worker", 45*time.Second, now, sleep)

	// The run must genuinely have completed its protocol, or this test is another early-return test wearing a
	// longer sleep. The owner row is submitted only after the victim has been Ready for the whole 40-second
	// dose, so an event for it is evidence the schedule ran to its last step; and the outcome carrying no
	// "(after …)" chain is evidence run() reached teardown with nothing already decided against it, which
	// only the path through reconstruction and the cardinality check does.
	submittedOwner := false
	for _, e := range events {
		if e.Job == queuelab.OwnerRow {
			submittedOwner = true
		}
	}
	if !submittedOwner {
		t.Fatalf("no event for the %q row; this run never reached the end of the schedule, so it cannot be "+
			"testing the happy path's teardown at all: %+v", queuelab.OwnerRow, events)
	}
	if strings.Contains(o.Reason, "(after ") {
		t.Fatalf("the outcome carries an earlier failure in its chain (%q); this run returned early and the "+
			"happy path's own branch is still untested", o.Reason)
	}

	if o.Disposition != dispResidueLeft {
		t.Fatalf("a run that measured cleanly and then could not remove its namespace is %s, got %s: %s",
			dispResidueLeft, o.Disposition, o.Reason)
	}
	// A sound measurement is still withheld, by the same rule the release-failure path follows: the number is
	// handed back only once the run is over, and this one is not over — its namespace is still on the cluster
	// and its worker is still dedicated to it.
	if res != nil {
		t.Fatal("a run holding its worker for residue handed back a result; nothing downstream distinguishes " +
			"that number from one produced by a run that finished")
	}
	found := false
	for _, r := range left {
		if r.Observation.Target.Name == "queuelab-r8" {
			found = true
		}
	}
	if !found {
		t.Fatalf("the residue must name the namespace that is still there, got %+v", left)
	}

	got := calls()
	if firstIndexOf(got, "delete", "Namespace", 1) < 0 {
		t.Fatalf("teardown never even attempted the namespace delete; calls: %+v", got)
	}
	if rel := releasePatchIndex(got); rel >= 0 {
		t.Fatalf("the worker was released at call %d though this run's namespace — and the GPU Pods it holds "+
			"— are still there; calls: %+v", rel, got)
	}
	var n corev1.Node
	if err := c.Get(context.Background(), client.ObjectKey{Name: "platform-worker"}, &n); err != nil {
		t.Fatalf("read the worker back: %v", err)
	}
	if n.Labels[workerLabelKey] == "" {
		t.Fatal("the worker lost its dedication label while this run's namespace was still on the cluster")
	}
	if len(n.Spec.Taints) == 0 {
		t.Fatal("the worker lost its NoSchedule taint while this run's namespace was still on the cluster; " +
			"an annotation means nothing to the scheduler and a GPU Pod would land on it")
	}
}
