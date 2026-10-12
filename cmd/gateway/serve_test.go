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
	"io"
	"net"
	"net/http"
	"os"
	"sync/atomic"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	"sigs.k8s.io/yaml"
)

// startServe runs serve on loopback listeners with h as the API handler, and returns the API address, the
// channel serve's result arrives on and a counter of how many times the admitter's stop was called.
func startServe(t *testing.T, ctx context.Context, h http.Handler, grace time.Duration) (string, <-chan error, *atomic.Int32) {
	t.Helper()
	apiLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	metricsLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var stops atomic.Int32
	done := make(chan error, 1)
	go func() {
		done <- serve(ctx, &http.Server{Handler: h}, apiLn, &http.Server{Handler: http.NotFoundHandler()},
			metricsLn, grace, func() { stops.Add(1) })
	}()
	return "http://" + apiLn.Addr().String(), done, &stops
}

// TestServeWaitsForInFlightRequestsBeforeReturning pins the drain itself: after the signal, serve must not
// return while a request is still being answered, and that request must complete whole.
// main returns when serve does, so a serve that returned at the signal would end the process mid-response.
func TestServeWaitsForInFlightRequestsBeforeReturning(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	h := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(entered)
		<-release
		_, _ = io.WriteString(w, "whole")
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr, done, stops := startServe(t, ctx, h, 5*time.Second)

	type reply struct {
		code int
		body string
		err  error
	}
	got := make(chan reply, 1)
	go func() {
		resp, err := http.Get(addr + "/")
		if err != nil {
			got <- reply{err: err}
			return
		}
		defer func() { _ = resp.Body.Close() }()
		b, err := io.ReadAll(resp.Body)
		got <- reply{code: resp.StatusCode, body: string(b), err: err}
	}()

	<-entered
	cancel()
	select {
	case err := <-done:
		t.Fatalf("serve returned (%v) while a request was still in flight", err)
	case <-time.After(300 * time.Millisecond):
	}
	if n := stops.Load(); n != 0 {
		t.Fatalf("the admitter was stopped %d time(s) while a request was still being admitted", n)
	}

	close(release)
	r := <-got
	if r.err != nil || r.code != http.StatusOK || r.body != "whole" {
		t.Fatalf("the in-flight request ended as code %d body %q err %v, want 200 %q", r.code, r.body, r.err, "whole")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve returned %v after a clean drain, want nil", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("serve did not return after the last request finished")
	}
	if n := stops.Load(); n != 1 {
		t.Fatalf("the admitter was stopped %d time(s), want once", n)
	}
}

// TestServeGivesUpAtTheGrace pins the other side: a request that never finishes must not hold serve past its
// grace, or the kubelet's SIGKILL rather than this program decides when the request is cut.
func TestServeGivesUpAtTheGrace(t *testing.T) {
	entered := make(chan struct{})
	never := make(chan struct{})
	defer close(never)
	h := http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		close(entered)
		<-never
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr, done, stops := startServe(t, ctx, h, 200*time.Millisecond)
	go func() {
		if resp, err := http.Get(addr + "/"); err == nil {
			_ = resp.Body.Close()
		}
	}()

	<-entered
	start := time.Now()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve returned %v at the grace, want nil: a cut request is logged, not a serving failure", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("serve was still waiting 3s after a 200ms grace")
	}
	if took := time.Since(start); took < 200*time.Millisecond {
		t.Fatalf("serve returned after %v, before its 200ms grace", took)
	}
	if n := stops.Load(); n != 1 {
		t.Fatalf("the admitter was stopped %d time(s), want once", n)
	}
}

// TestShutdownGraceFitsThePodsGrace pins the deployed manifest against shutdownGrace.
// The kubelet SIGKILLs the container when terminationGracePeriodSeconds ends, so a pod grace at or under
// shutdownGrace hands the decision to cut a request back to the kubelet, which is what the drain exists to stop.
func TestShutdownGraceFitsThePodsGrace(t *testing.T) {
	b, err := os.ReadFile("../../config/gateway/deployment.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var d appsv1.Deployment
	if err := yaml.Unmarshal(b, &d); err != nil {
		t.Fatal(err)
	}
	p := d.Spec.Template.Spec.TerminationGracePeriodSeconds
	if p == nil {
		t.Fatal("config/gateway/deployment.yaml sets no terminationGracePeriodSeconds; the default would apply unseen")
	}
	if pod := time.Duration(*p) * time.Second; shutdownGrace >= pod {
		t.Fatalf("shutdownGrace %v is not under the pod's terminationGracePeriodSeconds %v", shutdownGrace, pod)
	}
}
