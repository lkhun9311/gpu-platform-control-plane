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

// Package gateway implements the tenant-aware OpenAI-compatible serving gateway.
package gateway

import (
	"context"
	"fmt"
	"net/http"
	"sync/atomic"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// ModelNameIndex is the cache field-index key over InferenceDeployment.spec.model.name.
// Routing resolves a requested model to its Service via this index, with no CR field selector and no per-request apiserver call.
const ModelNameIndex = ".spec.model.name"

// Server holds the gateway's shared dependencies and HTTP handlers.
type Server struct {
	// Client reads InferenceDeployment, GPUQuotaPolicy, and the api-keys Secret from the scoped cache.
	Client client.Client
	// Namespace and APIKeySecret locate the api-keys Secret used to resolve tenants.
	Namespace    string
	APIKeySecret string
	// ready flips true once the cache has synced, gating readiness.
	ready atomic.Bool
}

// markReady marks the gateway ready to serve.
func (s *Server) markReady() { s.ready.Store(true) }

// MarkReady is the exported entry point for the binary to flip readiness after the cache's first sync.
func (s *Server) MarkReady() { s.markReady() }

// readyz returns 200 only once the cache has synced, else 503 so the Pod stays out of Service endpoints.
func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() {
		http.Error(w, "cache not synced", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// Handler is the serving mux on :8080.
// Later tasks add POST /v1/chat/completions.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/readyz", s.readyz)
	return mux
}

// MetricsHandler is the observability mux on :8081.
// Later tasks add /metrics.
func (s *Server) MetricsHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/readyz", s.readyz)
	return mux
}

// NewCache builds a scoped cache over the gateway's read set plus a delegating client that reads the cache and writes the apiserver.
// It registers the model-name field indexer used for routing.
func NewCache(ctx context.Context, cfg *rest.Config, scheme *runtime.Scheme) (cache.Cache, client.Client, error) {
	ca, err := cache.New(cfg, cache.Options{
		Scheme:           scheme,
		DefaultTransform: cache.TransformStripManagedFields(),
	})
	if err != nil {
		return nil, nil, fmt.Errorf("new cache: %w", err)
	}
	// Index InferenceDeployment by its served model name for routing lookups.
	if err := ca.IndexField(ctx, &platformv1.InferenceDeployment{}, ModelNameIndex, func(o client.Object) []string {
		return []string{o.(*platformv1.InferenceDeployment).Spec.Model.Name}
	}); err != nil {
		return nil, nil, fmt.Errorf("index %s: %w", ModelNameIndex, err)
	}
	cl, err := client.New(cfg, client.Options{Scheme: scheme, Cache: &client.CacheOptions{Reader: ca}})
	if err != nil {
		return nil, nil, fmt.Errorf("new delegating client: %w", err)
	}
	return ca, cl, nil
}
