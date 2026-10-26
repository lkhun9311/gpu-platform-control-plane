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
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gpufault"
)

// Reasons the GPUSignal condition carries when a node's exporter could not be read.
const (
	signalReasonFresh         = "Fresh"
	signalReasonNoObservation = "NoObservation"
	signalReasonStale         = "Stale"
	signalReasonNoExporter    = "NoExporter"
	signalReasonAmbiguous     = "AmbiguousExporter"
	signalReasonScrapeFailed  = "ScrapeFailed"
	signalReasonNoCards       = "NoCards"
)

// GPUFaultObservation is the last thing the scraper learned about one node.
type GPUFaultObservation struct {
	// LastSuccess is when the last scrape that could be assessed returned; zero if none has.
	LastSuccess time.Time
	// Assessment is that scrape's policy reading; it is meaningless when LastSuccess is zero.
	Assessment gpufault.Assessment
	// FaultSince is when the first scrape carrying the current non-empty fingerprint returned.
	//
	// It is the time the platform first knew of this fault, and the start of every hop it performs.
	FaultSince time.Time
	// ReadingSince is when the first scrape carrying the current reading, every value included, returned.
	ReadingSince time.Time
	// LastFailure and FailureReason describe the most recent attempt that failed, if it is newer than LastSuccess.
	LastFailure   time.Time
	FailureReason string
	FailureDetail string
}

// GPUFaultStore holds one observation per node, written by the scraper and read by the reconciler.
//
// It is in memory on purpose: everything the reconciler concludes from it is written to the NodeHealth and the
// Node, so a restarted operator starts from what it recorded rather than from what it remembered, and an
// observation that died with the process is replaced by the next scrape.
type GPUFaultStore struct {
	mu    sync.RWMutex
	nodes map[string]GPUFaultObservation
}

// NewGPUFaultStore returns an empty store.
func NewGPUFaultStore() *GPUFaultStore {
	return &GPUFaultStore{nodes: map[string]GPUFaultObservation{}}
}

// Get returns the node's observation, and whether there is one.
func (s *GPUFaultStore) Get(node string) (GPUFaultObservation, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	o, ok := s.nodes[node]
	return o, ok
}

// recordSuccess stores an assessed scrape and reports whether the fingerprint changed.
func (s *GPUFaultStore) recordSuccess(node string, at time.Time, a gpufault.Assessment) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	o := s.nodes[node]
	before := o.Assessment.Fingerprint()
	readingBefore := o.Assessment.Reading()
	fp := a.Fingerprint()
	switch {
	case fp == "":
		o.FaultSince = time.Time{}
	case fp != before || o.FaultSince.IsZero():
		o.FaultSince = at
	}
	if a.Reading() != readingBefore || o.ReadingSince.IsZero() {
		o.ReadingSince = at
	}
	o.Assessment = a
	o.LastSuccess = at
	s.nodes[node] = o
	// Freshness changes are the caller's to notice, tick by tick; this reports only a change in what was read.
	// The reading names every field, so a fault, a missing field and a benign change all count.
	return a.Reading() != readingBefore
}

// recordFailure stores a failed attempt; the last successful assessment is kept, and its age decides staleness.
// It reports whether this failure starts a run of failures or changes their reason, which is when it is logged.
func (s *GPUFaultStore) recordFailure(node string, at time.Time, reason, detail string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	o := s.nodes[node]
	transition := !o.LastFailure.After(o.LastSuccess) || o.FailureReason != reason
	o.LastFailure = at
	o.FailureReason = reason
	o.FailureDetail = detail
	s.nodes[node] = o
	return transition
}

// failing reports whether the node's most recent attempt failed.
func (s *GPUFaultStore) failing(node string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	o, ok := s.nodes[node]
	return ok && o.LastFailure.After(o.LastSuccess)
}

// scrapeConcurrency bounds the scrapes in flight in one tick: enough that a fleet of slow exporters costs about
// one timeout per tick, few enough that a large cluster does not open thousands of connections at once.
const scrapeConcurrency = 64

// GPUFaultSourceConfig is how the operator finds and reads each node's DCGM exporter.
type GPUFaultSourceConfig struct {
	// Namespace and Selector find the exporter Pods; one Running, Ready Pod per node is required.
	Namespace string
	Selector  labels.Selector
	// Port is the exporter's metrics port on the Pod IP.
	Port int
	// Interval is the scrape period; the registration sets it equal to the exporter's 1 s collection period,
	// because scraping faster reads the same cached snapshot again.
	Interval time.Duration
	// Timeout bounds one scrape; it must be shorter than Interval or scrapes would overlap.
	Timeout time.Duration
	// StaleAfter is how old the last successful scrape may be before the signal is no longer fresh.
	StaleAfter time.Duration
}

// Validate refuses a configuration the reconciler's guarantees do not hold under.
func (c GPUFaultSourceConfig) Validate() error {
	switch {
	case c.Namespace == "":
		return fmt.Errorf("gpu fault source: no exporter namespace")
	case c.Selector == nil || c.Selector.Empty():
		return fmt.Errorf("gpu fault source: an empty exporter selector would match every Pod in %s", c.Namespace)
	case c.Port <= 0 || c.Port > 65535:
		return fmt.Errorf("gpu fault source: exporter port %d", c.Port)
	case c.Interval <= 0 || c.Timeout <= 0:
		return fmt.Errorf("gpu fault source: interval %s and timeout %s must both be positive", c.Interval, c.Timeout)
	case c.Timeout >= c.Interval:
		return fmt.Errorf("gpu fault source: timeout %s is not shorter than the interval %s", c.Timeout, c.Interval)
	case c.StaleAfter <= c.Interval:
		// One missed scrape must not read as stale, or every slow scrape would flap the signal.
		return fmt.Errorf("gpu fault source: stale-after %s must exceed the interval %s", c.StaleAfter, c.Interval)
	}
	return nil
}

// GPUFaultSource scrapes every NodeHealth's node's exporter on a fixed period and wakes the reconciler when
// what it knows about a node changes.
type GPUFaultSource struct {
	Config GPUFaultSourceConfig
	// Reader lists NodeHealths; the manager's cached client is fine for that.
	Reader client.Reader
	// PodReader lists exporter Pods. It is the uncached API reader, so that the operator does not start a
	// cluster-wide Pod informer to find a handful of DaemonSet Pods.
	PodReader client.Reader
	Store     *GPUFaultStore
	// Events receives one GenericEvent per NodeHealth to reconcile; the reconciler's controller watches it.
	Events chan event.GenericEvent
	// HTTP is the client scrapes use; nil means a client with Config.Timeout.
	HTTP *http.Client
	// Now is the clock; nil means time.Now.
	Now func() time.Time

	// lastFresh remembers each node's freshness at the previous tick, so a change of it wakes the reconciler.
	lastFresh map[string]bool
}

// NeedLeaderElection is true: two operators scraping and tainting at once would race each other's patches.
func (s *GPUFaultSource) NeedLeaderElection() bool { return true }

func (s *GPUFaultSource) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Start runs the scrape loop until the context ends.
func (s *GPUFaultSource) Start(ctx context.Context) error {
	if err := s.Config.Validate(); err != nil {
		return err
	}
	if s.HTTP == nil {
		s.HTTP = &http.Client{Timeout: s.Config.Timeout}
	}
	s.lastFresh = map[string]bool{}
	t := time.NewTicker(s.Config.Interval)
	defer t.Stop()
	for {
		s.Tick(ctx)
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

// Tick scrapes every node once and wakes the reconciler for each node whose state changed.
//
// Exported so tests can drive the loop one step at a time without a ticker.
func (s *GPUFaultSource) Tick(ctx context.Context) {
	log := logf.FromContext(ctx).WithName("gpu-fault-source")
	if s.lastFresh == nil {
		s.lastFresh = map[string]bool{}
	}
	var nhs platformv1.NodeHealthList
	if err := s.Reader.List(ctx, &nhs); err != nil {
		log.Error(err, "Could not list NodeHealth resources; no node is scraped this tick")
		return
	}
	exporters, err := s.exportersByNode(ctx)
	// Every node is scraped at once, at most scrapeConcurrency at a time, so that a slow or unreachable
	// exporter costs its own node a timeout and not every other node's cadence: scraped one after another, ten
	// dead exporters would take eight seconds per tick, past both the interval and stale-after (codex review).
	changed := make([]bool, len(nhs.Items))
	var wg sync.WaitGroup
	sem := make(chan struct{}, scrapeConcurrency)
	for i := range nhs.Items {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			changed[i] = s.scrapeNode(ctx, nhs.Items[i].Spec.NodeName, exporters, err)
		}(i)
	}
	wg.Wait()
	for i := range nhs.Items {
		nh := &nhs.Items[i]
		node := nh.Spec.NodeName
		changed := changed[i]
		fresh := s.fresh(node)
		if prev, seen := s.lastFresh[node]; !seen || prev != fresh {
			changed = true
		}
		s.lastFresh[node] = fresh
		if changed {
			// A send that would block is dropped rather than stalling every other node's scrape: the next
			// change, or the next freshness transition, sends again, and the reconciler also runs on every
			// Node heartbeat.
			select {
			case s.Events <- event.GenericEvent{Object: &platformv1.NodeHealth{ObjectMeta: nh.ObjectMeta}}:
			default:
				log.Info("Reconcile wake-up dropped; the queue is full", "nodehealth", nh.Name)
			}
		}
	}
}

// fresh reports whether the node's last successful scrape is young enough to act on.
func (s *GPUFaultSource) fresh(node string) bool {
	o, ok := s.Store.Get(node)
	return ok && !o.LastSuccess.IsZero() && s.now().Sub(o.LastSuccess) <= s.Config.StaleAfter
}

// exportersByNode maps each node to the IPs of its Running, Ready exporter Pods.
func (s *GPUFaultSource) exportersByNode(ctx context.Context) (map[string][]string, error) {
	var pods corev1.PodList
	if err := s.PodReader.List(ctx, &pods, client.InNamespace(s.Config.Namespace),
		client.MatchingLabelsSelector{Selector: s.Config.Selector}); err != nil {
		return nil, err
	}
	out := map[string][]string{}
	for i := range pods.Items {
		p := &pods.Items[i]
		if p.Spec.NodeName == "" || p.Status.PodIP == "" || p.Status.Phase != corev1.PodRunning || !podReady(p) ||
			p.DeletionTimestamp != nil {
			continue
		}
		out[p.Spec.NodeName] = append(out[p.Spec.NodeName], p.Status.PodIP)
	}
	return out, nil
}

func podReady(p *corev1.Pod) bool {
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

// scrapeNode reads one node's exporter and records the outcome; it reports whether the reconciler should run.
func (s *GPUFaultSource) scrapeNode(ctx context.Context, node string, exporters map[string][]string, listErr error) bool {
	log := logf.FromContext(ctx).WithName("gpu-fault-source")
	// Failures are logged when a run of them starts or changes reason, not on every tick: a node with no
	// exporter would otherwise log once a second for as long as it exists. The log is the evidence that a
	// detection was slow because a scrape failed, rather than because the mechanism is other than described.
	fail := func(reason, detail string) bool {
		if s.Store.recordFailure(node, s.now(), reason, detail) {
			log.Info("GPU fault scrape failing", "node", node, "reason", reason, "detail", detail)
		}
		gpuFaultScrapeTotal.WithLabelValues(reason).Inc()
		return false
	}
	if listErr != nil {
		return fail(signalReasonNoExporter, "listing exporter Pods failed: "+listErr.Error())
	}
	ips := exporters[node]
	switch len(ips) {
	case 0:
		return fail(signalReasonNoExporter, fmt.Sprintf("no Running, Ready Pod matching %s in %s on this node",
			s.Config.Selector, s.Config.Namespace))
	case 1:
	default:
		// Two exporters on one node could disagree, and choosing one would let the wrong one decide.
		return fail(signalReasonAmbiguous, fmt.Sprintf("%d exporter Pods on this node", len(ips)))
	}
	url := "http://" + net.JoinHostPort(ips[0], strconv.Itoa(s.Config.Port)) + "/metrics"
	sctx, cancel := context.WithTimeout(ctx, s.Config.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(sctx, http.MethodGet, url, nil)
	if err != nil {
		return fail(signalReasonScrapeFailed, err.Error())
	}
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return fail(signalReasonScrapeFailed, err.Error())
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	_ = resp.Body.Close()
	if err != nil {
		return fail(signalReasonScrapeFailed, "read body: "+err.Error())
	}
	if resp.StatusCode != http.StatusOK {
		return fail(signalReasonScrapeFailed, fmt.Sprintf("HTTP %d from %s", resp.StatusCode, url))
	}
	// The receipt time, not the request time: it is the earliest moment the platform could know the value.
	at := s.now()
	readings, err := gpufault.ParseExposition(body)
	if err != nil {
		return fail(signalReasonScrapeFailed, err.Error())
	}
	a, err := gpufault.Assess(readings)
	if err != nil {
		return fail(signalReasonScrapeFailed, err.Error())
	}
	if a.Cards == 0 {
		// An exporter that serves none of the fields has said nothing about the cards, which is not health.
		return fail(signalReasonNoCards, "the scrape carried none of the fault fields for any card")
	}
	gpuFaultScrapeTotal.WithLabelValues("ok").Inc()
	if s.Store.failing(node) {
		log.Info("GPU fault scrape recovered", "node", node)
	}
	return s.Store.recordSuccess(node, at, a)
}
