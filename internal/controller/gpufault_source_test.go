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

package controller

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/event"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// fakeExporter serves whatever body it is given, or a status code.
type fakeExporter struct {
	mu     sync.Mutex
	body   string
	status int
}

func (f *fakeExporter) set(body string, status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.body, f.status = body, status
}

func (f *fakeExporter) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	w.WriteHeader(f.status)
	_, _ = w.Write([]byte(f.body))
}

func exporterPod(name, node, ip string) *corev1.Pod {
	return &corev1.Pod{
		Name: name, Namespace: "sys", Labels: map[string]string{"app.kubernetes.io/component": "dcgm-exporter"},
		Spec: corev1.PodSpec{NodeName: node},
		Status: corev1.PodStatus{Phase: corev1.PodRunning, PodIP: ip,
			Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}},
	}
}

type sourceRig struct {
	src *GPUFaultSource
	exp *fakeExporter
	now time.Time
}

func newSourceRig(t *testing.T, extraPods ...client.Object) *sourceRig {
	t.Helper()
	exp := &fakeExporter{status: http.StatusOK}
	srv := httptest.NewServer(exp)
	t.Cleanup(srv.Close)
	host, portStr, err := net.SplitHostPort(srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(portStr)
	nh := &platformv1.NodeHealth{Name: "nh-1", Spec: platformv1.NodeHealthSpec{NodeName: "gpu-1"}}
	objs := append([]client.Object{nh, exporterPod("exp-1", "gpu-1", host)}, extraPods...)
	c := fake.NewClientBuilder().WithScheme(gfScheme(t)).WithObjects(objs...).Build()
	g := &sourceRig{exp: exp, now: gfT0}
	g.src = &GPUFaultSource{
		Config: GPUFaultSourceConfig{Namespace: "sys", Selector: labels.SelectorFromSet(labels.Set{"app.kubernetes.io/component": "dcgm-exporter"}),
			Port: port, Interval: time.Second, Timeout: 800 * time.Millisecond, StaleAfter: 5 * time.Second},
		Reader: c, PodReader: c, Store: NewGPUFaultStore(), Events: make(chan event.GenericEvent, 16),
		HTTP: srv.Client(), Now: func() time.Time { return g.now },
	}
	return g
}

func (g *sourceRig) tick(t *testing.T) int {
	t.Helper()
	g.src.Tick(context.Background())
	n := 0
	for {
		select {
		case <-g.src.Events:
			n++
		default:
			return n
		}
	}
}

const (
	healthyBody = `DCGM_FI_DEV_XID_ERRORS{gpu="0",UUID="GPU-a"} 0
DCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu="0",UUID="GPU-a"} 0
DCGM_FI_DEV_ECC_SBE_VOL_TOTAL{gpu="0",UUID="GPU-a"} 0
`
	faultBody = `DCGM_FI_DEV_XID_ERRORS{gpu="0",UUID="GPU-a"} 79
DCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu="0",UUID="GPU-a"} 0
`
)

func TestGPUFaultSourceWakesOnlyOnChangeAndStampsFirstSight(t *testing.T) {
	g := newSourceRig(t)
	g.exp.set(healthyBody, http.StatusOK)
	if n := g.tick(t); n != 1 {
		t.Fatalf("first tick woke %d times, want 1 (freshness gained)", n)
	}
	g.now = g.now.Add(time.Second)
	if n := g.tick(t); n != 0 {
		t.Fatalf("an unchanged scrape woke the reconciler %d times", n)
	}
	g.exp.set(faultBody, http.StatusOK)
	g.now = g.now.Add(time.Second)
	faultAt := g.now
	if n := g.tick(t); n != 1 {
		t.Fatalf("a new fault woke %d times", n)
	}
	g.now = g.now.Add(time.Second)
	g.tick(t)
	o, _ := g.src.Store.Get("gpu-1")
	if !o.FaultSince.Equal(faultAt) || o.Assessment.Fingerprint() != "GPU-a/DCGM_FI_DEV_XID_ERRORS=79" {
		t.Fatalf("FaultSince %s fingerprint %q; want the first scrape carrying it, %s", o.FaultSince, o.Assessment.Fingerprint(), faultAt)
	}
}

func TestGPUFaultSourceFailuresKeepTheLastReadingUntilStale(t *testing.T) {
	g := newSourceRig(t)
	g.exp.set(faultBody, http.StatusOK)
	g.tick(t)
	g.exp.set("", http.StatusInternalServerError)
	g.now = g.now.Add(2 * time.Second)
	if n := g.tick(t); n != 0 {
		t.Fatalf("a failed scrape inside StaleAfter woke the reconciler")
	}
	o, _ := g.src.Store.Get("gpu-1")
	if o.FailureReason != signalReasonScrapeFailed || o.Assessment.Fingerprint() == "" {
		t.Fatalf("failure %q, reading %q", o.FailureReason, o.Assessment.Fingerprint())
	}
	g.now = g.now.Add(4 * time.Second)
	if n := g.tick(t); n != 1 {
		t.Fatalf("going stale woke the reconciler %d times, want 1", n)
	}
}

func TestGPUFaultSourceRefusesWhatItCannotAttribute(t *testing.T) {
	// Two exporters on one node: either could be wrong, so neither is read.
	g := newSourceRig(t, exporterPod("exp-2", "gpu-1", "127.0.0.2"))
	g.exp.set(faultBody, http.StatusOK)
	g.tick(t)
	o, _ := g.src.Store.Get("gpu-1")
	if o.FailureReason != signalReasonAmbiguous || !o.LastSuccess.IsZero() {
		t.Fatalf("two exporters: %+v", o)
	}
	// An exporter with none of the fields has said nothing about the cards.
	g = newSourceRig(t)
	g.exp.set(`DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-a"} 50`+"\n", http.StatusOK)
	g.tick(t)
	if o, _ := g.src.Store.Get("gpu-1"); o.FailureReason != signalReasonNoCards || !o.LastSuccess.IsZero() {
		t.Fatalf("no fields: %+v", o)
	}
}

// Slow exporters cost one timeout per tick, not one per node: scraped serially, five 400 ms exporters take 2 s.
func TestGPUFaultSourceScrapesNodesConcurrently(t *testing.T) {
	slow := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(400 * time.Millisecond)
		_, _ = w.Write([]byte(healthyBody))
	})
	srv := httptest.NewServer(slow)
	t.Cleanup(srv.Close)
	host, portStr, err := net.SplitHostPort(srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(portStr)
	var objs []client.Object
	for i := range 5 {
		n := "gpu-" + strconv.Itoa(i)
		objs = append(objs, &platformv1.NodeHealth{Name: "nh-" + n, Spec: platformv1.NodeHealthSpec{NodeName: n}},
			exporterPod("exp-"+n, n, host))
	}
	c := fake.NewClientBuilder().WithScheme(gfScheme(t)).WithObjects(objs...).Build()
	src := &GPUFaultSource{
		Config: GPUFaultSourceConfig{Namespace: "sys", Selector: labels.SelectorFromSet(labels.Set{"app.kubernetes.io/component": "dcgm-exporter"}),
			Port: port, Interval: time.Second, Timeout: 800 * time.Millisecond, StaleAfter: 5 * time.Second},
		Reader: c, PodReader: c, Store: NewGPUFaultStore(), Events: make(chan event.GenericEvent, 16), HTTP: srv.Client(),
	}
	start := time.Now()
	src.Tick(context.Background())
	if took := time.Since(start); took > 1500*time.Millisecond {
		t.Fatalf("one tick over five 400 ms exporters took %s", took)
	}
	for i := range 5 {
		if o, ok := src.Store.Get("gpu-" + strconv.Itoa(i)); !ok || o.LastSuccess.IsZero() {
			t.Fatalf("gpu-%d not scraped: %+v", i, o)
		}
	}
}

func TestGPUFaultSourceConfigRefusals(t *testing.T) {
	sel := labels.SelectorFromSet(labels.Set{"a": "b"})
	good := GPUFaultSourceConfig{Namespace: "n", Selector: sel, Port: 9400, Interval: time.Second, Timeout: 800 * time.Millisecond, StaleAfter: 5 * time.Second}
	if err := good.Validate(); err != nil {
		t.Fatal(err)
	}
	for name, mut := range map[string]func(*GPUFaultSourceConfig){
		"empty selector":        func(c *GPUFaultSourceConfig) { c.Selector = labels.Everything() },
		"timeout not < period":  func(c *GPUFaultSourceConfig) { c.Timeout = time.Second },
		"stale not > period":    func(c *GPUFaultSourceConfig) { c.StaleAfter = time.Second },
		"no namespace":          func(c *GPUFaultSourceConfig) { c.Namespace = "" },
		"port out of range":     func(c *GPUFaultSourceConfig) { c.Port = 0 },
		"non-positive interval": func(c *GPUFaultSourceConfig) { c.Interval = 0 },
	} {
		c := good
		mut(&c)
		if err := c.Validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
