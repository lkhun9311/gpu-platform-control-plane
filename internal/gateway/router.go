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

package gateway

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"slices"
	"time"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// ErrNoRoute is the sentinel reported when no InferenceDeployment serves the requested model.
//
// Design rationale (design spec Error codes section): an unknown model must get a 404.
//
// This signals "no such model" rather than a read failure, so the caller translates it to 404.
var ErrNoRoute = errors.New("no inferencedeployment for model")

// BackendRef identifies the resolved serving backend, not just its URL.
//
// A later scraper task needs the namespace, name, and port to build the backend's metrics URL and manage its telemetry lifecycle, which a bare *url.URL cannot provide.
type BackendRef struct {
	// Namespace and Name locate the InferenceDeployment, and its same-named Service, that serves the request.
	Namespace string
	Name      string
	// Port is the Service port the InferenceDeployment serves on.
	Port int32
	// URL is the in-cluster address the proxy forwards the request to.
	URL *url.URL
	// Model is the requested model name, carried through for metric labels.
	Model string
	// Admission is AdmissionHoldCap when the controller reports the cap in force for this object's current generation.
	// Empty means the gateway's process-wide mode applies, as it did before backends had a mode.
	Admission AdmissionMode
	// MaxHold is a HoldCap backend's hold, from its spec, and zero for any other.
	MaxHold time.Duration
	// PriorityScheduled says the controller reports its rendered engine serving this backend, and every engine it
	// renders schedules by request priority (internal/controller/inference_engine.go, pinned by a test there).
	// False for a backend the controller does not render, whose engine may reject a priority it was not built for.
	PriorityScheduled bool
	// Routing is the routing policy the InferenceDeployment's spec names, empty when it names none.
	// It is read from the spec because the gateway alone applies it: nothing is rendered or rolled out for it.
	Routing string
}

// specRouting is the policy an InferenceDeployment asks for, or "".
func specRouting(d *platformv1.InferenceDeployment) string {
	if d.Spec.Routing == nil {
		return ""
	}
	return d.Spec.Routing.Policy
}

// enginePriorityScheduled reports whether the controller says its rendered engine is the one serving d.
//
// Read from the EngineInForce condition, never from spec.engine alone, for the reason backendAdmission reads HoldCap
// from status: adding spec.engine to a backend says what is wanted, and until the rollout completes the Pods serving it
// are the old ones, which may not accept a priority. A condition from an older generation is not trusted.
func enginePriorityScheduled(d *platformv1.InferenceDeployment) bool {
	if d.Spec.Engine == nil || d.Spec.Engine.VLLM == nil {
		return false
	}
	c := meta.FindStatusCondition(d.Status.Conditions, platformv1.ConditionEngineInForce)
	return c != nil && c.Status == metav1.ConditionTrue && c.ObservedGeneration == d.Generation
}

// backendAdmission reads the mode in force from status, never from the spec alone, because the spec says what was asked and only the controller knows when the capped engine is the one serving.
// A spec still asking for HoldCap is required as well, so turning HoldCap off takes effect here before the controller catches up.
// A status from an older generation is not trusted, so a maxHold edit leaves the backend on the process-wide mode until the controller reports HoldCap again; that loses protection for a moment and never holds requests for an engine without the cap.
func backendAdmission(d *platformv1.InferenceDeployment) (AdmissionMode, time.Duration) {
	a, st := d.Spec.Admission, d.Status.Admission
	if a == nil || a.Mode != platformv1.AdmissionModeHoldCap || a.MaxHold == nil {
		return "", 0
	}
	if st == nil || st.Mode != platformv1.AdmissionModeHoldCap || st.ObservedGeneration != d.Generation {
		return "", 0
	}
	return AdmissionHoldCap, a.MaxHold.Duration
}

// servingPort returns the port the InferenceDeployment serves on.
//
// spec.port carries +kubebuilder:default=8080, so anything that went through the API server already has it set and zero cannot occur in production.
//
// The fake client used in tests applies no defaulting, though, and a URL built on port 0 is unroutable, hence the same fallback here.
func servingPort(infd *platformv1.InferenceDeployment) int32 {
	if infd.Spec.Port == 0 {
		return 8080
	}
	return infd.Spec.Port
}

// olderInfD reports whether a takes precedence over b.
//
// The earlier creationTimestamp wins, and on an exact tie the lexicographically smaller name wins.
//
// The name tie-break is what makes the order total: creationTimestamp has second granularity, so two objects created in the same second compare equal and a timestamp-only rule leaves them unordered.
//
// Names are unique within a namespace, so comparing them always decides.
//
// olderPolicy in ratelimit.go applies the same rule to GPUQuotaPolicy.
func olderInfD(a, b *platformv1.InferenceDeployment) bool {
	if a.CreationTimestamp.Equal(&b.CreationTimestamp) {
		// Same timestamp, so tie-break on ascending name.
		return a.Name < b.Name
	}
	return a.CreationTimestamp.Before(&b.CreationTimestamp)
}

// backendsFor resolves the requested model to every InferenceDeployment serving it, ordered head first, or ErrNoRoute if none does.
//
// Design rationale (design spec Components section): the lookup goes through the ModelNameIndex field index on the cache, so it needs no CR field selector and no per-request apiserver call.
//
// Scoping the lookup to the policy's TargetNamespace is what isolates tenants: distinct tenants commonly serve the same model name, so dropping the namespace would leak requests across them.
//
// Design rationale (design spec Identity model section): nothing stops two InferenceDeployments from serving the same model.
//
// Requests must not bounce between backends in that case, so exactly one is chosen by a deterministic rule (oldest wins, ties break on ascending name) and the duplicate is logged.
// backendsFor returns every backend serving the model, ordered, head first.
func (s *Server) backendsFor(ctx context.Context, policy *platformv1.GPUQuotaPolicy, model string) ([]*BackendRef, error) {
	var list platformv1.InferenceDeploymentList
	if err := s.Client.List(ctx, &list,
		client.InNamespace(policy.Spec.TargetNamespace),
		client.MatchingFields{ModelNameIndex: model}); err != nil {
		return nil, fmt.Errorf("list inferencedeployments: %w", err)
	}
	if len(list.Items) == 0 {
		return nil, ErrNoRoute
	}

	// Sorted oldest-first, and the ORDER is the routing policy rather than a tidiness detail.
	//
	// A second deployment serving the same model used to be logged as an operator problem and then discarded.
	// It is the ordinary shape of a served model — a rollout, a second replica set, a spare — and discarding it
	// meant a request failed whenever the one chosen backend was down, while a healthy alternative sat one
	// list entry away. The head stays exactly what it was, so a single-backend model routes identically and no
	// existing behaviour moves; the tail is what fallback walks.
	//
	// Oldest-first rather than newest, because a request must resolve deterministically across gateway
	// replicas: two gateways picking different heads for the same model would make latency depend on which
	// one a client happened to reach.
	//
	// A routing policy that every candidate names reorders this list per request (routing.go); without one this
	// order is the routing.
	sorted := make([]*platformv1.InferenceDeployment, 0, len(list.Items))
	for i := range list.Items {
		sorted = append(sorted, &list.Items[i])
	}
	slices.SortFunc(sorted, func(a, b *platformv1.InferenceDeployment) int {
		switch {
		case olderInfD(a, b):
			return -1
		case olderInfD(b, a):
			return 1
		default:
			return 0
		}
	})
	refs := make([]*BackendRef, 0, len(sorted))
	for _, d := range sorted {
		port := servingPort(d)
		// The controller names the Service after the InferenceDeployment in the same namespace, so the in-cluster address is http://<name>.<namespace>.svc:<port>.
		u, err := url.Parse(fmt.Sprintf("http://%s.%s.svc:%d", d.Name, d.Namespace, port))
		if err != nil {
			return nil, fmt.Errorf("parse backend url: %w", err)
		}
		mode, maxHold := backendAdmission(d)
		refs = append(refs, &BackendRef{Namespace: d.Namespace, Name: d.Name, Port: port, URL: u, Model: model, Admission: mode, MaxHold: maxHold,
			PriorityScheduled: enginePriorityScheduled(d), Routing: specRouting(d)})
	}
	return refs, nil
}
