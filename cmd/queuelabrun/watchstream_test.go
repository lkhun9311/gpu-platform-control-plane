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
	"net/http"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	watchtools "k8s.io/client-go/tools/watch"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

// The adapter's whole reason to exist is that RetryWatcher hands it a metav1.ListOptions carrying the
// resourceVersion to resume from, and that value has to reach the API server or the stream silently
// restarts from now and loses every edge in the gap.
func TestWatchAdapterPassesTheResumeOptionsThrough(t *testing.T) {
	var seen *client.ListOptions
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithInterceptorFuncs(interceptor.Funcs{
		Watch: func(ctx context.Context, cl client.WithWatch, obj client.ObjectList, opts ...client.ListOption) (watch.Interface, error) {
			lo := &client.ListOptions{}
			lo.ApplyOptions(opts)
			seen = lo
			return cl.Watch(ctx, obj, opts...)
		},
	}).Build()

	a := newWatchAdapter(c, "ns-a", func() client.ObjectList { return &corev1.PodList{} })
	w, err := a.WatchWithContext(context.Background(), metav1.ListOptions{
		ResourceVersion:     "1234",
		AllowWatchBookmarks: true,
	})
	if err != nil {
		t.Fatalf("watch: %v", err)
	}
	defer w.Stop()

	if seen == nil || seen.Raw == nil {
		t.Fatal("the adapter must pass the raw ListOptions through, or the resume version never reaches the server")
	}
	if seen.Raw.ResourceVersion != "1234" {
		t.Fatalf("resume version lost: got %q, want 1234", seen.Raw.ResourceVersion)
	}
	if !seen.Raw.AllowWatchBookmarks {
		t.Fatal("bookmark requests must survive, or RetryWatcher cannot advance its resume version between events")
	}
	if seen.Namespace != "ns-a" {
		t.Fatalf("namespace lost: got %q", seen.Namespace)
	}
}

// NewRetryWatcherWithContext returns as soon as it launches its receive goroutine, before its first watch
// has necessarily succeeded, so a barrier built on construction can release while the watch is still
// failing. The signal has to come from inside the call that actually established one.
func TestWatchAdapterSignalsOnlyAfterAWatchActuallySucceeds(t *testing.T) {
	fail := true
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithInterceptorFuncs(interceptor.Funcs{
		Watch: func(ctx context.Context, cl client.WithWatch, obj client.ObjectList, opts ...client.ListOption) (watch.Interface, error) {
			if fail {
				return nil, errors.New("apiserver unreachable")
			}
			return cl.Watch(ctx, obj, opts...)
		},
	}).Build()

	a := newWatchAdapter(c, "ns-a", func() client.ObjectList { return &corev1.PodList{} })

	if _, err := a.WatchWithContext(context.Background(), metav1.ListOptions{}); err == nil {
		t.Fatal("the first attempt was rigged to fail")
	}
	select {
	case <-a.Established():
		t.Fatal("a failed watch must not signal establishment")
	default:
	}

	fail = false
	w, err := a.WatchWithContext(context.Background(), metav1.ListOptions{})
	if err != nil {
		t.Fatalf("watch: %v", err)
	}
	defer w.Stop()

	select {
	case <-a.Established():
	case <-time.After(time.Second):
		t.Fatal("a successful watch must signal establishment")
	}
}

// scriptedWatcher returns a pre-programmed watch per call so a test can drive RetryWatcher's reconnect,
// its 410 handling and its permanent-termination paths without a cluster.
type scriptedWatcher struct {
	mu    sync.Mutex
	calls []func(opts metav1.ListOptions) (watch.Interface, error)
	seen  []string // the resume version each call was asked for
}

func (s *scriptedWatcher) WatchWithContext(_ context.Context, opts metav1.ListOptions) (watch.Interface, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seen = append(s.seen, opts.ResourceVersion)
	if len(s.calls) == 0 {
		return nil, errors.New("script exhausted")
	}
	next := s.calls[0]
	s.calls = s.calls[1:]
	return next(opts)
}

// podAtVersion builds the smallest object RetryWatcher will accept, which is one carrying a
// resourceVersion, because an event without one aborts the watcher rather than advancing it.
func podAtVersion(name, rv string) *corev1.Pod {
	return &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		Namespace:       "ns-a",
		Name:            name,
		ResourceVersion: rv,
	}}
}

// waitFor polls a condition under a bounded deadline because RetryWatcher's reconnect is timer-driven,
// so the interesting states appear a restart delay later rather than synchronously.
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("condition was not reached within the deadline")
}

// A break in the middle of a stream must resume from the last delivered version, not from the baseline —
// resuming from the baseline would redeliver, and resuming from now would lose the gap.
func TestWatchStreamResumesFromTheLastDeliveredVersion(t *testing.T) {
	first := watch.NewFake()
	second := watch.NewFake()
	s := &scriptedWatcher{calls: []func(metav1.ListOptions) (watch.Interface, error){
		func(metav1.ListOptions) (watch.Interface, error) { return first, nil },
		func(metav1.ListOptions) (watch.Interface, error) { return second, nil },
	}}

	rw, err := watchtools.NewRetryWatcherWithContext(context.Background(), "100", s)
	if err != nil {
		t.Fatalf("retry watcher: %v", err)
	}
	defer rw.Stop()

	go func() {
		first.Modify(podAtVersion("p1", "105"))
		first.Stop()
	}()
	<-rw.ResultChan()

	// The second call must ask for 105, the version of the event actually delivered.
	waitFor(t, func() bool { s.mu.Lock(); defer s.mu.Unlock(); return len(s.seen) == 2 })
	s.mu.Lock()
	got := s.seen[1]
	s.mu.Unlock()
	if got != "105" {
		t.Fatalf("resumed from %q, want 105 — resuming from the baseline redelivers and resuming from now loses the gap", got)
	}
}

// A baseline resource version of "" or "0" makes RetryWatcher start from now rather than from a known
// point, which is a silent continuity hole, and RetryWatcher itself rejects both.
func TestWatchStreamRefusesAnUnusableBaselineVersion(t *testing.T) {
	for _, rv := range []string{"", "0"} {
		if _, err := watchtools.NewRetryWatcherWithContext(context.Background(), rv, &scriptedWatcher{}); err == nil {
			t.Fatalf("baseline %q must be refused", rv)
		}
	}
}

// baselineRV is what the interceptor below stamps on the baseline list, standing in for the version a real
// API server would return.
const baselineRV = "1000"

// streamOnScript starts a real watchStream whose baseline comes from a fake client but whose watches come
// from a script, because the terminal paths under test are ones a fake client will never produce.
//
// The List interceptor exists because the fake client returns lists with an empty resource version, which
// is precisely the unresumable point the component refuses, so without it no test could get past the
// baseline at all.
func streamOnScript(ctx context.Context, t *testing.T, seed []client.Object,
	calls ...func(metav1.ListOptions) (watch.Interface, error)) (*watchStream, *scriptedWatcher) {
	t.Helper()
	s := &scriptedWatcher{calls: calls}
	c := fake.NewClientBuilder().WithScheme(fullScheme(t)).WithObjects(seed...).WithInterceptorFuncs(interceptor.Funcs{
		List: func(ctx context.Context, cl client.WithWatch, list client.ObjectList, opts ...client.ListOption) error {
			if err := cl.List(ctx, list, opts...); err != nil {
				return err
			}
			list.SetResourceVersion(baselineRV)
			return nil
		},
		Watch: func(ctx context.Context, _ client.WithWatch, _ client.ObjectList, opts ...client.ListOption) (watch.Interface, error) {
			lo := &client.ListOptions{}
			lo.ApplyOptions(opts)
			raw := metav1.ListOptions{}
			if lo.Raw != nil {
				raw = *lo.Raw
			}
			return s.WatchWithContext(ctx, raw)
		},
	}).Build()

	ws, err := startWatchStream(ctx, c, "ns-a", func() client.ObjectList { return &corev1.PodList{} })
	if err != nil {
		t.Fatalf("start watch stream: %v", err)
	}
	return ws, s
}

// The baseline is the only thing a later gap can be measured against, so it has to be the list's own
// resource version and the list's own object count rather than anything inferred afterwards.
func TestWatchStreamCapturesTheBaselineItListed(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	held := watch.NewFake()
	defer held.Stop()
	ws, script := streamOnScript(ctx, t, []client.Object{podAtVersion("p1", ""), podAtVersion("p2", "")},
		func(metav1.ListOptions) (watch.Interface, error) { return held, nil })
	defer ws.Stop()

	base := ws.Baseline()
	if base.ResourceVersion != baselineRV {
		t.Fatalf("baseline resource version %q, want the list's own %q", base.ResourceVersion, baselineRV)
	}
	if base.Objects != 2 {
		t.Fatalf("baseline counted %d objects, want 2", base.Objects)
	}

	// The watch has to be started from that exact version, or the baseline describes a point the stream
	// never actually resumed from and the gap between them is invisible.
	select {
	case <-ws.Established():
	case <-time.After(5 * time.Second):
		t.Fatal("the stream never established a watch")
	}
	script.mu.Lock()
	first := script.seen[0]
	script.mu.Unlock()
	if first != base.ResourceVersion {
		t.Fatalf("the first watch resumed from %q but the baseline claims %q", first, base.ResourceVersion)
	}
}

// A 410 is the one terminal cause the API server states outright, and it means the resume version is gone
// and the gap can no longer be closed, so the stream must end and keep the status as evidence.
func TestWatchStreamEndsOnAForwardedGone(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	gone := watch.NewFakeWithChanSize(1, false)
	gone.Error(&metav1.Status{
		Status:  metav1.StatusFailure,
		Code:    http.StatusGone,
		Reason:  metav1.StatusReasonExpired,
		Message: "too old resource version",
	})
	ws, _ := streamOnScript(ctx, t, nil,
		func(metav1.ListOptions) (watch.Interface, error) { return gone, nil })
	defer ws.Stop()

	ev, ok := <-ws.ResultChan()
	if !ok {
		t.Fatal("the 410 must reach the caller, not be consumed on its way through")
	}
	if ev.Type != watch.Error {
		t.Fatalf("forwarded event type %q, want Error", ev.Type)
	}

	select {
	case <-ws.End():
	case <-time.After(5 * time.Second):
		t.Fatal("a 410 is permanent, so the stream must end rather than reconnect forever")
	}
	end := ws.Ended()
	if end.Cancelled {
		t.Fatal("nobody cancelled this stream, so reporting it as cancelled would hide a lost gap")
	}
	if end.LastStatus == nil {
		t.Fatal("the forwarded status is the only evidence of the cause and must be kept")
	}
	if end.LastStatus.Code != http.StatusGone {
		t.Fatalf("kept status code %d, want %d", end.LastStatus.Code, http.StatusGone)
	}
}

// Some permanent failures close the watcher without forwarding anything at all — a Forbidden that reaches
// RetryWatcher wrapped is one, since it recognises the reason but cannot assert the concrete status type.
// Continuity is just as lost there, so the ending must still not read as a caller cancellation.
func TestWatchStreamEndsOnAPermanentFailureThatForwardsNothing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	forbidden := apierrors.NewForbidden(schema.GroupResource{Resource: "pods"}, "", errors.New("no watch permission"))
	ws, _ := streamOnScript(ctx, t, nil,
		func(metav1.ListOptions) (watch.Interface, error) { return nil, fmt.Errorf("watch pods: %w", forbidden) })
	defer ws.Stop()

	select {
	case <-ws.End():
	case <-time.After(5 * time.Second):
		t.Fatal("a permanent establishment failure must end the stream rather than retry forever")
	}
	if ev, ok := <-ws.ResultChan(); ok {
		t.Fatalf("nothing was forwarded on this path, yet the caller saw %v", ev)
	}
	end := ws.Ended()
	if end.Cancelled {
		t.Fatal("no cause was observed, but the caller did not cancel either, so this must read as a lost stream")
	}
	if end.LastStatus != nil {
		t.Fatalf("no status was forwarded, so claiming one would be evidence the stream never saw: %v", end.LastStatus)
	}
}

// Cancelling the caller's context is the one ending that is not a lost gap, and it is the only one the
// component can name with certainty, so it must be reported as such and nothing else must borrow it.
func TestWatchStreamEndsAsCancelledWhenTheCallerCancels(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	held := watch.NewFake()
	defer held.Stop()
	ws, _ := streamOnScript(ctx, t, nil,
		func(metav1.ListOptions) (watch.Interface, error) { return held, nil })

	select {
	case <-ws.Established():
	case <-time.After(5 * time.Second):
		t.Fatal("the stream never established a watch")
	}
	select {
	case <-ws.End():
		t.Fatal("the stream ended before anyone cancelled it")
	default:
	}

	cancel()
	select {
	case <-ws.End():
	case <-time.After(5 * time.Second):
		t.Fatal("cancelling the caller's context must end the stream")
	}
	if !ws.Ended().Cancelled {
		t.Fatal("a caller cancellation reported as anything else would look like a lost gap")
	}
}
