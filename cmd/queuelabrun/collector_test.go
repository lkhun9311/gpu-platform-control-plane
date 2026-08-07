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
	"testing"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/queuelab"
)

// A signal landing while a barrier is unmet must be reported as itself, not swallowed by the 2-second poll:
// this proves waitBarrier returns on the first cancelled select rather than continuing to poll toward the
// horizon, which is exactly what would make a Ctrl-C during a long barrier wait look hung.
func TestWaitBarrierReturnsPromptlyOnCancelledContext(t *testing.T) {
	scheme := testScheme(t)
	if err := platformv1.AddToScheme(scheme); err != nil {
		t.Fatalf("add platformv1 to scheme: %v", err)
	}
	fc := fake.NewClientBuilder().WithScheme(scheme).Build()
	col := newCollector(fc, "ns", "r1")

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	// Far enough out that only the cancelled select, not the deadline, could end this quickly. The job named
	// here does not exist, so barrierHolds's first check reports "not met" (not an error) and the wait would
	// otherwise poll every 2 s until the deadline.
	deadline := time.Now().Add(time.Hour)
	b := queuelab.Barrier{Kind: queuelab.BarrierPending, Job: "does-not-exist"}

	start := time.Now()
	err := waitBarrier(ctx, fc, "ns", b, col, deadline)
	elapsed := time.Since(start)

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want an error wrapping context.Canceled, got %v", err)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("waitBarrier took %v to return on an already-cancelled context; it must not poll to the deadline", elapsed)
	}
}

// The main goroutine used to call col.builder.Desync directly while the four watch goroutines were still
// running and still calling Observe through flush under col.mu, and LedgerBuilder has no locking of its own:
// invalid, events, lastEvent and ready are plain fields. That is a data race on the single field that
// decides whether the run may produce a number at all.
//
// The whole test suite was green under -race before this fix and proved nothing, because no test ran the
// live collector with concurrent watch goroutines. This one does: one goroutine plays the watch side
// (submitObserved takes col.mu and calls Observe, exactly as flush does) while the test goroutine plays the
// main side. Run under -race it fails on the unlocked Desync and passes on the locked one.
func TestCollectorDesyncIsSerialisedWithTheWatchGoroutines(t *testing.T) {
	scheme := testScheme(t)
	if err := platformv1.AddToScheme(scheme); err != nil {
		t.Fatalf("add platformv1 to scheme: %v", err)
	}
	fc := fake.NewClientBuilder().WithScheme(scheme).Build()
	col := newCollector(fc, "ns", "r1")

	const rounds = 500
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < rounds; i++ {
			col.submitObserved(queuelab.TrainingTraceRow{Name: "victim"}, fmt.Sprintf("uid-%d", i),
				&platformv1.MLTrainingJob{})
		}
	}()
	for i := 0; i < rounds; i++ {
		col.desync("barrier before step 0 (victim): deadline")
	}
	<-done

	// Reading the builder is safe only now, which is the same discipline run() follows after col.wait().
	if col.builder.Err() == nil {
		t.Fatal("the desync must have invalidated the run; the test did not exercise what it exists for")
	}
}
