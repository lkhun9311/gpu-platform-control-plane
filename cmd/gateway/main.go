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
	"flag"
	"fmt"
	"net/http"
	"os"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/gateway"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

// defaultAdmissionStaticRate and its siblings are static-cap's tuning defaults.
//
// Design rationale (design spec Arm B section, "Tuning procedure"): the real values come from an
// offline simulation against a C pilot's admitted-work fraction and are frozen before the
// confirmatory run, not chosen here.
//
// These defaults exist only so the flag has some starting value; every real run overrides them
// explicitly via --admission-static-rate/--admission-static-burst.
const (
	defaultAdmissionStaticRate    = 2000.0 // tokens/sec
	defaultAdmissionStaticBurst   = 8192   // tokens
	defaultAdmissionLongThreshold = 4096   // tokens; shared by static-cap and, later, kv-aware
)

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	log := ctrl.Log.WithName("gateway")
	ctx := ctrl.SetupSignalHandler()

	var (
		admissionModeFlag      string
		admissionStaticRate    float64
		admissionStaticBurst   int
		admissionLongThreshold int
	)
	flag.StringVar(&admissionModeFlag, "admission-mode", string(gateway.AdmissionOff),
		"Admission control mode on the inference path: off, static-cap, or kv-aware.")
	flag.Float64Var(&admissionStaticRate, "admission-static-rate", defaultAdmissionStaticRate,
		"static-cap mode: sustained per-backend input-token refill rate, in tokens/sec.")
	flag.IntVar(&admissionStaticBurst, "admission-static-burst", defaultAdmissionStaticBurst,
		"static-cap mode: per-backend input-token bucket burst capacity, in tokens.")
	flag.IntVar(&admissionLongThreshold, "admission-long-threshold", defaultAdmissionLongThreshold,
		"static-cap mode: minimum estimated input tokens for a standard-tier request to enter the eligible population.")
	flag.Parse()

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

	// Resolve the flag to an Admitter before touching the cache or apiserver, so a bad flag fails
	// fast rather than after the gateway has already started reading Kubernetes.
	admissionMode := gateway.AdmissionMode(admissionModeFlag)
	admitter, err := newAdmitter(admissionMode, admissionStaticRate, admissionStaticBurst, admissionLongThreshold)
	if err != nil {
		log.Error(err, "configure admission control", "mode", admissionModeFlag)
		os.Exit(1)
	}

	cfg := ctrl.GetConfigOrDie()
	// Settle the namespace before building the cache.
	//
	// It is hoisted here because NewCache needs it to confine the Secret watch.
	//
	// Server.Namespace needs the same value below.
	//
	// Were the two to disagree, the gateway would watch one namespace and look for the Secret in another.
	//
	// Every request would fall to 401.
	//
	// Deriving both from one variable makes that mismatch impossible.
	namespace := envOr("GATEWAY_NAMESPACE", "default")
	ca, cl, err := gateway.NewCache(ctx, cfg, scheme, namespace)
	if err != nil {
		log.Error(err, "build cache")
		os.Exit(1)
	}

	s := &gateway.Server{
		Client:       cl,
		Namespace:    namespace,
		APIKeySecret: envOr("GATEWAY_API_KEY_SECRET", "gateway-api-keys"),
	}
	// Turn on the per-tenant token bucket registry.
	//
	// It happens here rather than in the struct literal because bucketRegistry is unexported to the gateway package.
	//
	// The package exposes one method and main merely states the intent to rate limit.
	//
	// Skipping this call would leave buckets nil while serving, so the gateway guards that case.
	s.InitRateLimiter()
	// Install the admission-control implementation resolved from --admission-mode above.
	//
	// Why here rather than in the struct literal: SetAdmitter is exported for the same reason
	// InitRateLimiter is (admitter is unexported to the gateway package), and mode travels with it
	// so the metrics label can never disagree with which Admitter is actually running.
	s.SetAdmitter(admissionMode, admitter)

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

// newAdmitter builds the gateway.Admitter matching mode, or an error if mode cannot be served yet.
//
// Design rationale (design spec Build order section, step 2 vs step 3): kv-aware's exposition
// parser, pressure state machine, and scraper are a separate task, so this returns a clear startup
// error rather than silently falling back to a different mode, which would mask a misconfigured
// deployment as "the guard just isn't doing anything".
//
// An unrecognized mode string fails the same way, for the same reason: a typo in --admission-mode
// must stop the gateway, not silently disable the guard.
func newAdmitter(mode gateway.AdmissionMode, staticRate float64, staticBurst, longThreshold int) (
	gateway.Admitter, error,
) {
	switch mode {
	case gateway.AdmissionOff:
		return gateway.NewOffAdmitter(), nil
	case gateway.AdmissionStaticCap:
		return gateway.NewStaticCapAdmitter(staticRate, staticBurst, longThreshold), nil
	case gateway.AdmissionKVAware:
		return nil, fmt.Errorf("kv-aware admission mode is not yet available")
	default:
		return nil, fmt.Errorf("unknown admission mode %q", mode)
	}
}
