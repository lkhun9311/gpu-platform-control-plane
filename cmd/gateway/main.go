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

// Command gateway runs the tenant-aware OpenAI-compatible serving gateway.
package main

import (
	"net/http"
	"os"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gateway"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	log := ctrl.Log.WithName("gateway")
	ctx := ctrl.SetupSignalHandler()

	// Register the core and platform types the gateway reads.
	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		log.Error(err, "register client-go scheme")
		os.Exit(1)
	}
	if err := platformv1.AddToScheme(scheme); err != nil {
		log.Error(err, "register platform scheme")
		os.Exit(1)
	}

	cfg := ctrl.GetConfigOrDie()
	ca, cl, err := gateway.NewCache(ctx, cfg, scheme)
	if err != nil {
		log.Error(err, "build cache")
		os.Exit(1)
	}

	s := &gateway.Server{
		Client:       cl,
		Namespace:    envOr("GATEWAY_NAMESPACE", "default"),
		APIKeySecret: envOr("GATEWAY_API_KEY_SECRET", "gateway-api-keys"),
	}

	// Start the cache and flip readiness once it has synced.
	go func() {
		if err := ca.Start(ctx); err != nil {
			log.Error(err, "cache stopped")
		}
	}()
	go func() {
		if ca.WaitForCacheSync(ctx) {
			s.MarkReady()
			log.Info("cache synced; gateway ready")
		}
	}()

	// Serve metrics/readiness on :8081 and the OpenAI-compatible API on :8080.
	go func() {
		if err := http.ListenAndServe(":8081", s.MetricsHandler()); err != nil {
			log.Error(err, "metrics server stopped")
		}
	}()
	log.Info("serving", "addr", ":8080")
	if err := http.ListenAndServe(":8080", s.Handler()); err != nil {
		log.Error(err, "serving stopped")
		os.Exit(1)
	}
}

// envOr returns the environment value for key or def when unset.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
