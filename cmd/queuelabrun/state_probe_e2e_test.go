package main

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

// The whole mode, end to end, against a cluster that behaves the way the probe needs it to.
//
// Every other test in this package drives a piece: the Pod builder, the verifier, the handoff helper. None
// of them reaches past `stateProbe`'s early return — the only test that called it passed a nil client and an
// empty class — so everything the function does after acquiring the worker was unexecuted by the suite. Two
// independent reviews said the same thing, and a perturbation confirmed it: deleting the capture wiring left
// the full package green.
//
// What this file adds is the one shape that can see provenance. The double reports the writer's node from
// the SERVER's copy, so a regression that filled the observation in from the `-worker` flag instead — which
// is non-empty and therefore passes every emptiness guard — is caught by the second case below and by
// nothing else.

// probeDouble stands in for the three cluster roles the fake client has none of: the apiserver assigning
// identities, the scheduler choosing a node, and the kubelet publishing a terminal status.
//
// It stamps NOTHING on Create. That is the whole point rather than an economy: controller-runtime's real
// Create decodes the server's response back into the caller's object, so a double that did the same would
// leave `writer.UID` populated in the caller's copy — and a regression reading the caller's object instead
// of the cluster's would then pass. Identity appears only on the way back OUT of a Get.
type probeDouble struct {
	mu sync.Mutex
	// node is what the scheduler is pretending to have chosen for each Pod, by name.
	node map[string]string
	// gone counts how many Gets a deleted Pod survives before it disappears.
	//
	// The fake client removes a finalizer-free object synchronously on Delete, so without this "the writer
	// is absent when the reader is created" would hold even for a probe that deleted and moved straight on.
	// Graceful deletion is what makes the wait mean something.
	gone map[string]int
	// calls is an ordered log of what the probe did, so the test can assert the ORDER rather than the final
	// state — which deferred cleanup would also produce.
	calls []string
}

func newProbeDouble(writerNode string) *probeDouble {
	return &probeDouble{
		node: map[string]string{"writer": writerNode, "reader": "platform-worker"},
		gone: map[string]int{},
	}
}

// writerNameOf turns the reader's name into its predecessor's. Both are `sp-<short id>-<half>`, so the
// suffix is the only difference and the double can name one from the other without being told.
func writerNameOf(readerName string) string {
	return strings.TrimSuffix(readerName, "-reader") + "-writer"
}

func (d *probeDouble) half(name string) string {
	if strings.HasSuffix(name, "-writer") {
		return "writer"
	}
	return "reader"
}

func (d *probeDouble) log(what string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.calls = append(d.calls, what)
}

func (d *probeDouble) history() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.calls...)
}

func (d *probeDouble) interceptors() interceptor.Funcs {
	return interceptor.Funcs{
		Create: func(ctx context.Context, c client.WithWatch, obj client.Object,
			opts ...client.CreateOption) error {
			if p, ok := obj.(*corev1.Pod); ok {
				// The reader's creation is the moment succession is decided, so the double checks the
				// predecessor's absence HERE rather than leaving the test to look afterwards. Afterwards is
				// too late and too weak: deferred cleanup deletes the writer on the way out, so "the writer
				// is gone at the end" holds even for a probe that never waited.
				//
				// A first version of this file recorded the call order and nothing else, and a perturbation
				// that replaced the absence wait with a bare delete stayed green — the writer was still in
				// the store when the reader was created, and no assertion looked.
				if d.half(p.Name) == "reader" {
					var pred corev1.Pod
					err := c.Get(ctx, client.ObjectKey{Namespace: p.Namespace, Name: writerNameOf(p.Name)}, &pred)
					if err == nil {
						d.log("reader-created-while-writer-present")
					}
				}
				d.log("create/" + d.half(p.Name))
			}
			if pvc, ok := obj.(*corev1.PersistentVolumeClaim); ok {
				// The claim's UID IS read off the caller's object by the probe, because that is what the real
				// Create gives it. Stamping it here is modelling the apiserver, not leaking provenance: the
				// probe compares it later against the cluster's copy, and the double keeps them equal.
				pvc.UID = types.UID("pvc-uid-1")
				d.log("create/claim")
			}
			return c.Create(ctx, obj, opts...)
		},
		Delete: func(ctx context.Context, c client.WithWatch, obj client.Object,
			opts ...client.DeleteOption) error {
			if p, ok := obj.(*corev1.Pod); ok {
				// Graceful deletion: the object stays in the store and keeps answering Gets for a while, and
				// only then goes. The fake client removes a finalizer-free object synchronously, so without
				// this a probe that deleted and moved straight on would find its predecessor already absent
				// and "waited for absence" would be indistinguishable from "issued a delete".
				//
				// The removal happens in the Get that runs the grace out, NOT here — see the Get
				// interceptor. Deleting here instead would make the store agree with the caller immediately,
				// which is the behaviour this is modelling away from.
				d.log("delete/" + d.half(p.Name))
				d.mu.Lock()
				d.gone[p.Name] = 2 // answers two more Gets, then the third removes it
				d.mu.Unlock()
				return nil
			}
			return c.Delete(ctx, obj, opts...)
		},
		Get: func(ctx context.Context, c client.WithWatch, key client.ObjectKey, obj client.Object,
			opts ...client.GetOption) error {
			// Delegate FIRST and propagate any error: a double that synthesised an object the store does not
			// have would answer for a Pod that was never created.
			if err := c.Get(ctx, key, obj, opts...); err != nil {
				return err
			}
			switch o := obj.(type) {
			case *corev1.Pod:
				d.mu.Lock()
				left, deleting := d.gone[o.Name]
				if deleting {
					if left <= 0 {
						delete(d.gone, o.Name)
						d.mu.Unlock()
						// The grace has run out, so the object leaves the STORE as well as this answer.
						//
						// Removing it here rather than only reporting NotFound is what makes the reader's
						// creation check mean something: that check reads the store directly, and a double
						// that answered NotFound while keeping the object would report a writer still
						// present at the moment of succession for a probe that had waited correctly.
						_ = c.Delete(ctx, &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
							Namespace: o.Namespace, Name: o.Name,
						}})
						// The standard constructor, not a hand-rolled error type: apierrors.IsNotFound is
						// what awaitProbeGone tests the result with, and an error that merely reads like a
						// NotFound would make absence unreachable and time the probe out instead.
						return apierrors.NewNotFound(corev1.Resource("pods"), o.Name)
					}
					d.gone[o.Name] = left - 1
				}
				node := d.node[d.half(o.Name)]
				d.mu.Unlock()
				o.UID = types.UID("pod-uid-" + d.half(o.Name))
				o.Spec.NodeName = node
				o.Status.Phase = corev1.PodSucceeded
				o.Status.ContainerStatuses = []corev1.ContainerStatus{{
					Name:  probeTrainerContainer,
					State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 0}},
				}}
			case *corev1.PersistentVolumeClaim:
				o.UID = types.UID("pvc-uid-1")
				o.Status.Phase = corev1.ClaimBound
				o.Spec.VolumeName = "pv-1"
			}
			return nil
		},
	}
}

// probeCluster is a free worker plus the double.
func probeCluster(t *testing.T, d *probeDouble) client.WithWatch {
	t.Helper()
	return fake.NewClientBuilder().WithScheme(testScheme(t)).
		WithObjects(
			node(nil, nil),
			&corev1.PersistentVolume{
				ObjectMeta: metav1.ObjectMeta{Name: "pv-1"},
				Spec: corev1.PersistentVolumeSpec{
					PersistentVolumeReclaimPolicy: corev1.PersistentVolumeReclaimDelete,
				},
			},
		).
		WithInterceptorFuncs(d.interceptors()).Build()
}

// advancingClock is a clock whose sleep moves time, so a polling loop that stops making progress times out
// instead of hanging the package.
func advancingClock() (func() time.Time, func(time.Duration)) {
	cur := time.Unix(0, 0)
	var mu sync.Mutex
	return func() time.Time { mu.Lock(); defer mu.Unlock(); return cur },
		func(d time.Duration) { mu.Lock(); defer mu.Unlock(); cur = cur.Add(d) }
}

// A cluster whose storage behaves produces a pass, and the probe leaves nothing behind.
//
// Mutations that turn this red: skip the claim creation; skip either half; report the verdict without
// running verifyStateProbe.
func TestTheStateProbePassesOnAClusterWhoseStorageWorks(t *testing.T) {
	d := newProbeDouble("platform-worker")
	c := probeCluster(t, d)
	now, sleep := advancingClock()
	var out strings.Builder

	if err := stateProbe(context.Background(), c, "platform-worker", "fast-ssd", now, sleep, &out); err != nil {
		t.Fatalf("a cluster that binds a claim and hands a file between two Pods did not pass: %v\n%s",
			err, out.String())
	}
	if !strings.Contains(out.String(), "STORAGE PROBE PASSED") {
		t.Fatalf("the probe passed and did not say so:\n%s", out.String())
	}
	// The reclaim policy is reported, because an operator on a Retain class is accumulating storage.
	if !strings.Contains(out.String(), "reclaimPolicy=Delete") {
		t.Fatalf("the bound volume's reclaim policy was not reported:\n%s", out.String())
	}
	// And the worker went back with nothing unresolved.
	if !strings.Contains(out.String(), "worker platform-worker released\n") {
		t.Fatalf("the worker was not reported as cleanly released:\n%s", out.String())
	}

	// THE ORDER, asserted on the calls rather than on the final state: deferred cleanup deletes the writer
	// too, so "the writer is gone at the end" would hold even for a probe that never waited.
	h := d.history()
	iWriterDelete, iReaderCreate := -1, -1
	for i, call := range h {
		if call == "delete/writer" && iWriterDelete < 0 {
			iWriterDelete = i
		}
		if call == "create/reader" && iReaderCreate < 0 {
			iReaderCreate = i
		}
	}
	if iWriterDelete < 0 || iReaderCreate < 0 {
		t.Fatalf("the probe did not both delete the writer and create the reader: %v", h)
	}
	if iWriterDelete > iReaderCreate {
		t.Fatalf("the reader was created before the writer was deleted, so it was the writer's neighbour "+
			"rather than its successor: %v", h)
	}
	// And the stronger statement the order alone does not make: at the instant the reader was created, the
	// writer was ALREADY GONE from the store. A delete that was merely issued does not establish that.
	//
	// Mutation that turns this red: replace awaitProbeGone with a bare releaseProbe, which issues the delete
	// and moves on. The call order still looks right; this does not.
	for _, call := range h {
		if call == "reader-created-while-writer-present" {
			t.Fatalf("the reader was created while the writer was still present, so ReadWriteOnce was "+
				"holding one volume for two Pods and nothing was handed over: %v", h)
		}
	}
}

// THE case that distinguishes an observation from a copy of the flag.
//
// The double reports the writer as having run on another node. Every emptiness guard still passes — the
// value is non-empty — and the probe must refuse anyway, because `-worker` says where it ASKED the Pod to
// go and only the cluster says where it went.
//
// Mutations that turn this red: fill ids.writerNode from the nodeName parameter; fill ids.writerUID from
// writer.UID; drop the node comparison from verifyStateProbe.
func TestTheStateProbeRefusesAWriterTheClusterPutSomewhereElse(t *testing.T) {
	d := newProbeDouble("some-other-node")
	c := probeCluster(t, d)
	now, sleep := advancingClock()
	var out strings.Builder

	err := stateProbe(context.Background(), c, "platform-worker", "fast-ssd", now, sleep, &out)
	if err == nil {
		t.Fatalf("the probe passed although its writer ran on another node; what it established is about "+
			"storage it did not take a worker for:\n%s", out.String())
	}
	if !strings.Contains(err.Error(), "writer ran on") {
		t.Fatalf("the refusal does not name the half that moved: %v", err)
	}
	if strings.Contains(out.String(), "STORAGE PROBE PASSED") {
		t.Fatalf("a refused probe also printed a pass:\n%s", out.String())
	}
}
