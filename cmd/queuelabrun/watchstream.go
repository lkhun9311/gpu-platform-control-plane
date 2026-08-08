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
	"sync"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	watchtools "k8s.io/client-go/tools/watch"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// watchAdapter presents controller-runtime's client as the cache.WatcherWithContext that RetryWatcher
// needs.
//
// A second client-go client would also satisfy RetryWatcher, but it would duplicate the scheme, the REST
// config and the decoding path for the two CRDs this runner watches, for no behaviour the adapter cannot
// provide.
type watchAdapter struct {
	c       client.WithWatch
	ns      string
	newList func() client.ObjectList

	once        sync.Once
	established chan struct{}
}

func newWatchAdapter(c client.WithWatch, ns string, newList func() client.ObjectList) *watchAdapter {
	return &watchAdapter{c: c, ns: ns, newList: newList, established: make(chan struct{})}
}

// WatchWithContext starts one underlying watch at the resume version RetryWatcher asks for.
//
// The options are passed as Raw because that is the only path by which resourceVersion and the bookmark
// request reach the API server through controller-runtime; dropping them would silently restart the stream
// from now and lose every edge in the gap.
func (a *watchAdapter) WatchWithContext(ctx context.Context, opts metav1.ListOptions) (watch.Interface, error) {
	w, err := a.c.Watch(ctx, a.newList(), client.InNamespace(a.ns), &client.ListOptions{Raw: &opts})
	if err != nil {
		return nil, err
	}
	// Signalling here rather than at construction is the point: RetryWatcher builds before its first watch
	// has necessarily succeeded, so a barrier keyed on construction can release while the watch is still
	// failing and the run would burn experimental time unobserved.
	a.once.Do(func() { close(a.established) })
	return w, nil
}

// Established closes once at least one underlying watch has been successfully established.
//
// It does not mean the watch is currently healthy: an established watch can close immediately afterwards,
// and RetryWatcher will reconnect from the same resource version. Promising liveness would be promising
// something this type cannot observe.
func (a *watchAdapter) Established() <-chan struct{} { return a.established }

// streamBaseline is what the initial List established, and deliberately nothing more.
//
// The count is a plain number: deciding which of those objects carry lifecycle meaning is the integration
// slice's rule, and a component that answered it here would have decided a question this slice defers.
type streamBaseline struct {
	ResourceVersion string
	Objects         int
}

// streamEnd is what can actually be observed about why a stream stopped.
//
// RetryWatcher exposes only forwarded events, the closure of its channels, the caller's own ctx.Err() and
// whether the caller asked to stop. Some permanent establishment errors close without forwarding anything,
// cancellation races with forwarding, and a terminal error event can be lost when the internal send selects
// the cancelled context — so "410 versus another permanent reason" is not a distinction this type can
// always make.
//
// Cancelled and Stopped are the two endings the caller itself caused, and they are the only endings that
// are not a loss of continuity: an ending with neither set means the stream ended on its own, so the gap
// since the last delivered version can never be closed, whether or not LastStatus names a cause. Reading
// "not cancelled" alone as a lost stream would condemn every orderly shutdown, which is why Stopped exists.
//
// Stopped says the caller asked to stop before the stream finished ending, not that the stop was the cause,
// because a stop can race with a stream that was already dying.
//
// LastStatus is independent evidence when it is present, but its absence proves nothing: the wrapped
// Forbidden path terminates permanently while forwarding no event at all, so a stop racing that loss reads
// as Stopped with no status — indistinguishable, on these three fields alone, from an orderly shutdown. A
// caller that needs the distinction must establish it before stopping, with a non-blocking check of End(),
// rather than inferring it from a nil LastStatus afterwards.
type streamEnd struct {
	Cancelled  bool
	Stopped    bool
	LastStatus *metav1.Status
}

// watchStream is one kind's continuous view: a baseline List, then a RetryWatcher resuming from it.
type watchStream struct {
	baseline streamBaseline
	adapter  *watchAdapter
	rw       *watchtools.RetryWatcher

	out  chan watch.Event
	done chan struct{}

	// stop is a second way out of the forwarding select, because cancelling RetryWatcher only closes the
	// channel forward reads from and cannot reach forward while it is parked on a send nobody is receiving.
	stopOnce sync.Once
	stop     chan struct{}

	mu  sync.Mutex
	end streamEnd
}

func startWatchStream(ctx context.Context, c client.WithWatch, ns string,
	newList func() client.ObjectList) (*watchStream, error) {
	list := newList()
	if err := c.List(ctx, list, client.InNamespace(ns)); err != nil {
		return nil, fmt.Errorf("baseline list for %s: %w", ns, err)
	}
	rv := list.GetResourceVersion()
	// RetryWatcher rejects both, and for the same reason this component must: an empty version starts the
	// watch from now, and "0" starts it from an arbitrary cached point, so neither gives a known baseline
	// that a later gap can be measured against.
	if rv == "" || rv == "0" {
		return nil, fmt.Errorf("baseline list for %s returned resource version %q, which is not a resumable point", ns, rv)
	}
	// ExtractList rather than meta.LenList because LenList reports 0 for anything it cannot walk, and a
	// baseline that silently reads as empty is exactly the kind of unobserved claim this component refuses.
	items, err := meta.ExtractList(list)
	if err != nil {
		return nil, fmt.Errorf("count baseline objects for %s: %w", ns, err)
	}
	n := len(items)

	a := newWatchAdapter(c, ns, newList)
	rw, err := watchtools.NewRetryWatcherWithContext(ctx, rv, a)
	if err != nil {
		return nil, fmt.Errorf("start watch for %s from %s: %w", ns, rv, err)
	}

	s := &watchStream{
		baseline: streamBaseline{ResourceVersion: rv, Objects: n},
		adapter:  a,
		rw:       rw,
		out:      make(chan watch.Event),
		done:     make(chan struct{}),
		stop:     make(chan struct{}),
	}
	go s.forward(ctx)
	return s, nil
}

// forward republishes the watcher's events and records what could be observed about the ending.
//
// The last forwarded error status is kept because that is where a 410 shows up when one is delivered at
// all; it is evidence when present and absent otherwise, never a claim about the cause.
func (s *watchStream) forward(ctx context.Context) {
	defer close(s.done)
	defer close(s.out)
	for ev := range s.rw.ResultChan() {
		if ev.Type == watch.Error {
			if st, ok := ev.Object.(*metav1.Status); ok {
				s.mu.Lock()
				s.end.LastStatus = st
				s.mu.Unlock()
			}
		}
		select {
		case s.out <- ev:
		case <-ctx.Done():
			// The caller is going away; stop republishing rather than blocking on a channel nobody reads.
		case <-s.stop:
			// Stop has to be sufficient on its own, because a caller that stops between reads leaves an event
			// parked here and would otherwise wait on an End that this goroutine can no longer reach.
		}
	}
	// Read the caller's context and the stop request only after the watcher has actually stopped, so an
	// ending the caller caused while the stream was already ending for another reason is not mistaken for
	// the reason.
	s.mu.Lock()
	s.end.Cancelled = ctx.Err() != nil
	select {
	case <-s.stop:
		s.end.Stopped = true
	default:
	}
	s.mu.Unlock()
}

func (s *watchStream) Baseline() streamBaseline       { return s.baseline }
func (s *watchStream) Established() <-chan struct{}   { return s.adapter.Established() }
func (s *watchStream) ResultChan() <-chan watch.Event { return s.out }
func (s *watchStream) End() <-chan struct{}           { return s.done }

// Stop ends the stream and is enough on its own: after it returns, End closes whatever forward was doing.
//
// The close is guarded because Stop is idempotent by contract and a caller racing a stream that is already
// ending on its own must not panic on a second close.
func (s *watchStream) Stop() {
	s.stopOnce.Do(func() { close(s.stop) })
	s.rw.Stop()
}

// Ended reports what was observed about the ending, and is only meaningful after End() is closed.
func (s *watchStream) Ended() streamEnd {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.end
}
