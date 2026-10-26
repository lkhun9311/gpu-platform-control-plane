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
	"flag"
	"fmt"
	"time"

	"k8s.io/apimachinery/pkg/labels"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/event"
)

// GPUFaultFlags are the operator flags of the DCGM fault path.
//
// Every one is inert until Source is "dcgm": the path is opt-in, because a platform that taints nodes on a
// signal its operator never deployed would be quarantining on the absence of an exporter.
type GPUFaultFlags struct {
	Source         string
	Namespace      string
	Selector       string
	Port           int
	Interval       time.Duration
	Timeout        time.Duration
	StaleAfter     time.Duration
	EvictWorkloads bool
}

// Bind registers the flags. The defaults are the registration's (docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md):
// a 1 s scrape matching the exporter's 1 s collection, a 0.8 s timeout, and stale after 5 s.
func (f *GPUFaultFlags) Bind(fs *flag.FlagSet) {
	fs.StringVar(&f.Source, "gpu-fault-source", "",
		`Where GPU fault signals come from: "" (off) or "dcgm" (scrape each node's DCGM exporter).`)
	fs.StringVar(&f.Namespace, "gpu-fault-exporter-namespace", "gpu-platform-control-plane-system",
		"Namespace of the DCGM exporter Pods.")
	fs.StringVar(&f.Selector, "gpu-fault-exporter-selector", "app.kubernetes.io/component=dcgm-exporter",
		"Label selector of the DCGM exporter Pods; exactly one Running, Ready Pod per node is read.")
	fs.IntVar(&f.Port, "gpu-fault-exporter-port", 9400, "The exporter's metrics port on its Pod IP.")
	fs.DurationVar(&f.Interval, "gpu-fault-scrape-interval", time.Second, "How often each node's exporter is scraped.")
	fs.DurationVar(&f.Timeout, "gpu-fault-scrape-timeout", 800*time.Millisecond,
		"How long one scrape may take; must be shorter than the interval.")
	fs.DurationVar(&f.StaleAfter, "gpu-fault-stale-after", 5*time.Second,
		"How old the last successful scrape may be before the GPU signal is not fresh; must exceed the interval.")
	fs.BoolVar(&f.EvictWorkloads, "gpu-fault-evict-workloads", false,
		"Deactivate, and later reactivate, the Kueue Workloads of GPU Pods on a node with a latched GPU fault.")
}

// Setup builds the path from the flags and adds its scraper to the manager.
// It returns nil, and adds nothing, when the path is off.
func (f *GPUFaultFlags) Setup(mgr ctrl.Manager) (*GPUFaultConfig, error) {
	switch f.Source {
	case "":
		if f.EvictWorkloads {
			return nil, fmt.Errorf("--gpu-fault-evict-workloads needs --gpu-fault-source; nothing would ever be evicted")
		}
		return nil, nil
	case "dcgm":
	default:
		return nil, fmt.Errorf("--gpu-fault-source=%q: the only source is dcgm", f.Source)
	}
	sel, err := labels.Parse(f.Selector)
	if err != nil {
		return nil, fmt.Errorf("--gpu-fault-exporter-selector: %w", err)
	}
	cfg := GPUFaultSourceConfig{
		Namespace: f.Namespace, Selector: sel, Port: f.Port,
		Interval: f.Interval, Timeout: f.Timeout, StaleAfter: f.StaleAfter,
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	store := NewGPUFaultStore()
	// Buffered so that one slow reconcile does not stall the scrape of every other node.
	events := make(chan event.GenericEvent, 1024)
	src := &GPUFaultSource{
		Config: cfg, Reader: mgr.GetClient(), PodReader: mgr.GetAPIReader(), Store: store, Events: events,
	}
	if err := mgr.Add(src); err != nil {
		return nil, fmt.Errorf("add gpu fault source: %w", err)
	}
	return &GPUFaultConfig{
		Store: store, StaleAfter: f.StaleAfter, EvictWorkloads: f.EvictWorkloads,
		APIReader: mgr.GetAPIReader(), Recorder: mgr.GetEventRecorder("nodehealth-gpufault"), Events: events,
	}, nil
}
