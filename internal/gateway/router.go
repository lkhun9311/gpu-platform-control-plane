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

	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// ErrNoRoute is the sentinel reported when no InferenceDeployment serves the requested model.
//
// Design rationale (design spec Error codes section): an unknown model must get a 404.
// This signals "no such model" rather than a read failure, so the caller translates it to 404.
var ErrNoRoute = errors.New("no inferencedeployment for model")

// servingPort returns the port the InferenceDeployment serves on.
//
// spec.port carries +kubebuilder:default=8080, so anything that went through the API server already
// has it set and zero cannot occur in production. The fake client used in tests applies no
// defaulting, though, and a URL built on port 0 is unroutable — hence the same fallback here.
func servingPort(infd *platformv1.InferenceDeployment) int32 {
	if infd.Spec.Port == 0 {
		return 8080
	}
	return infd.Spec.Port
}

// olderInfD reports whether a takes precedence over b.
// The earlier creationTimestamp wins, and on an exact tie the lexicographically smaller name wins.
//
// The name tie-break is what makes the order total: creationTimestamp has second granularity, so two
// objects created in the same second compare equal and a timestamp-only rule leaves them unordered.
// Names are unique within a namespace, so comparing them always decides.
// olderPolicy in ratelimit.go applies the same rule to GPUQuotaPolicy.
func olderInfD(a, b *platformv1.InferenceDeployment) bool {
	if a.CreationTimestamp.Equal(&b.CreationTimestamp) {
		// Same timestamp, so tie-break on ascending name.
		return a.Name < b.Name
	}
	return a.CreationTimestamp.Before(&b.CreationTimestamp)
}

// backendFor resolves the requested model to the Service URL of the InferenceDeployment serving it,
// or ErrNoRoute if none does.
//
// Design rationale (design spec Components section): the lookup goes through the ModelNameIndex field
// index on the cache, so it needs no CR field selector and no per-request apiserver call.
// Scoping the lookup to the policy's TargetNamespace is what isolates tenants: distinct tenants
// commonly serve the same model name, so dropping the namespace would leak requests across them.
//
// Design rationale (design spec Identity model section): nothing stops two InferenceDeployments from
// serving the same model. Requests must not bounce between backends in that case, so exactly one is
// chosen by a deterministic rule — oldest wins, ties break on ascending name — and the duplicate is
// logged.
func (s *Server) backendFor(ctx context.Context, policy *platformv1.GPUQuotaPolicy, model string) (*url.URL, error) {
	var list platformv1.InferenceDeploymentList
	if err := s.Client.List(ctx, &list,
		client.InNamespace(policy.Spec.TargetNamespace),
		client.MatchingFields{ModelNameIndex: model}); err != nil {
		return nil, fmt.Errorf("list inferencedeployments: %w", err)
	}
	if len(list.Items) == 0 {
		return nil, ErrNoRoute
	}

	// Pick the oldest of the matches; the loop above guarantees at least one item.
	oldest := &list.Items[0]
	for i := range list.Items {
		if olderInfD(&list.Items[i], oldest) {
			oldest = &list.Items[i]
		}
	}

	// A duplicate is an operator-visible problem, but the request itself resolves deterministically,
	// so warn rather than fail.
	if len(list.Items) > 1 {
		log.FromContext(ctx).Info("multiple InferenceDeployments for model; using oldest",
			"model", model, "chosen", oldest.Name)
	}

	// The controller names the Service after the InferenceDeployment in the same namespace, so the
	// in-cluster address is http://<name>.<namespace>.svc:<port>.
	return url.Parse(fmt.Sprintf("http://%s.%s.svc:%d", oldest.Name, oldest.Namespace, servingPort(oldest)))
}
