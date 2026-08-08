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
	"sync"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
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
