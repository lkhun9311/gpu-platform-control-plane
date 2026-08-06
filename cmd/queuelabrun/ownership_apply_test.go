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
	"fmt"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func testScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatalf("add to scheme: %v", err)
	}
	return scheme
}

func conflictErr(name string) error {
	return apierrors.NewConflict(schema.GroupResource{Resource: "nodes"}, name, fmt.Errorf("conflict"))
}

// The optimistic lock only does its job if a 409 makes the caller re-read and re-decide rather than resend
// the same patch: this is the mechanism the whole design exists for, and until now nothing exercised it.
func TestAcquireWorkerRetriesConflictWithFreshReadAndDecide(t *testing.T) {
	n := node(nil, nil)
	var getCalls, patchCalls int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			getCalls++
			return c.Get(ctx, key, obj, opts...)
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			patchCalls++
			if patchCalls == 1 {
				return conflictErr(obj.GetName())
			}
			return c.Patch(ctx, obj, patch, opts...)
		},
	}).Build()

	j, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-a", "r1", "A-honor")
	if err != nil {
		t.Fatalf("acquire must succeed once the second attempt lands: %v", err)
	}
	if j.TxID != "tx-a" {
		t.Fatalf("journal txid = %q, want tx-a", j.TxID)
	}
	if patchCalls != 2 {
		t.Fatalf("want exactly 2 patch attempts (1 conflict + 1 success), got %d", patchCalls)
	}
	// One Get per acquire-loop attempt (2) plus verifyAcquired's own Get (1): the second patch attempt can
	// only have succeeded against the tracker's current resourceVersion if it was built from a fresh Get
	// rather than resending the stale patch built from the first Get.
	if getCalls != 3 {
		t.Fatalf("want 3 gets (2 acquire attempts + 1 verify), got %d — the retry did not re-read", getCalls)
	}
}

// A conflict that never clears must not spin forever: it has to refuse once the bound is exhausted.
func TestAcquireWorkerRefusesAfterConflictBoundNotSpin(t *testing.T) {
	n := node(nil, nil)
	var getCalls, patchCalls int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			getCalls++
			return c.Get(ctx, key, obj, opts...)
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			patchCalls++
			return conflictErr(obj.GetName())
		},
	}).Build()

	_, err := acquireWorker(context.Background(), fc, "platform-worker", "tx-b", "r1", "A-honor")
	if err == nil {
		t.Fatal("acquire must refuse once the conflict bound is exhausted")
	}
	if patchCalls != acquireAttempts {
		t.Fatalf("want exactly %d patch attempts (the bound), got %d — it did not stop spinning",
			acquireAttempts, patchCalls)
	}
	if getCalls != acquireAttempts {
		t.Fatalf("want exactly %d gets (one fresh read per attempt), got %d", acquireAttempts, getCalls)
	}
}

// A refusal from decideAcquire is a decision about observed state, not a transient failure, so it must
// return on the first read without touching the API server again.
func TestAcquireWorkerReturnsRefusalWithoutRetry(t *testing.T) {
	good, err := encodeJournal(testJournal())
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	n := node(map[string]string{workerLabelKey: "r7"}, map[string]string{journalKey: good}, ourTaint())
	var getCalls, patchCalls int
	fc := fake.NewClientBuilder().WithScheme(testScheme(t)).WithObjects(n).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			getCalls++
			return c.Get(ctx, key, obj, opts...)
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch,
			opts ...client.PatchOption) error {
			patchCalls++
			return c.Patch(ctx, obj, patch, opts...)
		},
	}).Build()

	_, err = acquireWorker(context.Background(), fc, "platform-worker", "tx-c", "r9", "A-honor")
	var r *refusal
	if err == nil || !asRefusal(err, &r) || r.Reason != reasonForeignOwner {
		t.Fatalf("want a foreign-owner refusal, got %v", err)
	}
	if getCalls != 1 {
		t.Fatalf("want exactly 1 get, got %d — a refusal must not be retried", getCalls)
	}
	if patchCalls != 0 {
		t.Fatalf("want 0 patches, got %d — a refusal must not attempt to write", patchCalls)
	}
}
