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
	"testing"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
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
