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

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
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
