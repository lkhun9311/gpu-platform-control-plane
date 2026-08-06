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
