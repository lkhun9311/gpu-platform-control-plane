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
	"time"

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
	defaultAdmissionLongThreshold = 4096   // tokens; shared by static-cap and kv-aware
)

// defaultAdmissionKV* are kv-aware's tuning defaults.
//
// Design rationale (design spec v1 Mechanism section; v2 Arm C, "Wire mode + flags"): these are
// test/dev starting points only, not tuned numbers. W (waiting threshold) in particular is
// model/hardware/max-num-seqs dependent and calibrated from the saturation sweep on the paid
// GPU pilot; maxStaleness defaults to 3x the scrape interval, matching the design spec's own
// example.
const (
	defaultAdmissionKVEngageUsage    = 0.85
	defaultAdmissionKVReleaseUsage   = 0.75
	defaultAdmissionKVWaitingThresh  = 8 // W; test/dev only, see design spec v1 Mechanism section
	defaultAdmissionKVReleaseSustain = 30 * time.Second
	defaultAdmissionKVScrapeInterval = 2 * time.Second
	defaultAdmissionKVMaxStaleness   = 6 * time.Second // 3x defaultAdmissionKVScrapeInterval
	// A backend under steady traffic is routed to constantly, so this only ever expires one that has stopped
	// receiving requests: it has either been deleted or has nothing to be under pressure about, and both want
	// its scraper stopped and its gauges gone. Far above maxStaleness so a backend cannot be evicted while the
	// guard is still treating its last reading as usable.
	defaultAdmissionKVIdleTimeout   = 15 * time.Minute
	defaultAdmissionKVScrapeTimeout = 1 * time.Second
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

		admissionKVEngageUsage    float64
		admissionKVReleaseUsage   float64
		admissionKVWaitingThresh  int
		admissionKVReleaseSustain time.Duration
		admissionKVScrapeInterval time.Duration
		admissionKVMaxStaleness   time.Duration
		admissionKVScrapeTimeout  time.Duration
		admissionKVIdleTimeout    time.Duration
	)
	flag.StringVar(&admissionModeFlag, "admission-mode", string(gateway.AdmissionOff),
		"Admission control mode on the inference path: off, static-cap, or kv-aware.")
	flag.Float64Var(&admissionStaticRate, "admission-static-rate", defaultAdmissionStaticRate,
		"static-cap mode: sustained per-backend input-token refill rate, in tokens/sec.")
	flag.IntVar(&admissionStaticBurst, "admission-static-burst", defaultAdmissionStaticBurst,
		"static-cap mode: per-backend input-token bucket burst capacity, in tokens.")
	flag.IntVar(&admissionLongThreshold, "admission-long-threshold", defaultAdmissionLongThreshold,
		"static-cap and kv-aware modes: minimum estimated input tokens for a standard-tier "+
			"request to enter the eligible population.")
	flag.Float64Var(&admissionKVEngageUsage, "admission-kv-engage-usage", defaultAdmissionKVEngageUsage,
		"kv-aware mode: KV-cache usage fraction above which a backend engages. Test/dev "+
			"default; real value is tuned on the paid GPU pilot.")
	flag.Float64Var(&admissionKVReleaseUsage, "admission-kv-release-usage", defaultAdmissionKVReleaseUsage,
		"kv-aware mode: KV-cache usage fraction below which a backend may release. Test/dev "+
			"default; real value is tuned on the paid GPU pilot.")
	flag.IntVar(&admissionKVWaitingThresh, "admission-kv-waiting-threshold", defaultAdmissionKVWaitingThresh,
		"kv-aware mode: waiting-queue depth (W) above which a backend engages. "+
			"Model/hardware/max-num-seqs dependent; test/dev default only, real value comes "+
			"from the saturation sweep.")
	flag.DurationVar(&admissionKVReleaseSustain, "admission-kv-release-sustain", defaultAdmissionKVReleaseSustain,
		"kv-aware mode: how long usage and waiting must stay under the release thresholds "+
			"before a backend releases.")
	flag.DurationVar(&admissionKVScrapeInterval, "admission-kv-scrape-interval", defaultAdmissionKVScrapeInterval,
		"kv-aware mode: how often each registered backend's /metrics endpoint is scraped.")
	flag.DurationVar(&admissionKVMaxStaleness, "admission-kv-max-staleness", defaultAdmissionKVMaxStaleness,
		"kv-aware mode: how long since the last successful scrape before the guard bypasses "+
			"(admits) rather than acting on stale telemetry.")
	flag.DurationVar(&admissionKVIdleTimeout, "admission-kv-idle-timeout", defaultAdmissionKVIdleTimeout,
		"how long a backend may go unrouted before its scraper is stopped and its gauges removed; "+
			"must be well above --admission-kv-scrape-interval")
	flag.DurationVar(&admissionKVScrapeTimeout, "admission-kv-scrape-timeout", defaultAdmissionKVScrapeTimeout,
		"kv-aware mode: HTTP timeout for a single /metrics scrape.")
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
	admitter, stopAdmitter, err := newAdmitter(admissionMode, admitterFlags{
		staticRate:    admissionStaticRate,
		staticBurst:   admissionStaticBurst,
		longThreshold: admissionLongThreshold,
		kv: gateway.KVAwareConfig{
			EngageUsage:    admissionKVEngageUsage,
			ReleaseUsage:   admissionKVReleaseUsage,
			WaitingThresh:  admissionKVWaitingThresh,
			ReleaseSustain: admissionKVReleaseSustain,
			ScrapeInterval: admissionKVScrapeInterval,
			MaxStaleness:   admissionKVMaxStaleness,
			IdleTimeout:    admissionKVIdleTimeout,
			HTTPTimeout:    admissionKVScrapeTimeout,
			LongThreshold:  admissionLongThreshold,
		},
	})
	if err != nil {
		log.Error(err, "configure admission control", "mode", admissionModeFlag)
		os.Exit(1)
	}
	// Stop any scrapers the admitter started (a no-op for off/static-cap) once the gateway is
	// signaled to shut down, so a graceful stop never leaves scrape goroutines running past
	// process shutdown.
	go func() {
		<-ctx.Done()
		stopAdmitter()
	}()

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

// admitterFlags bundles every admission-mode flag value newAdmitter needs, since the three modes
// together take more parameters than reads well as a positional argument list.
type admitterFlags struct {
	staticRate    float64
	staticBurst   int
	longThreshold int
	kv            gateway.KVAwareConfig
}

// noopStop is the stop function newAdmitter returns for modes that start no background work.
func noopStop() {}

// newAdmitter builds the gateway.Admitter matching mode and a stop function the caller must
// invoke on shutdown, or an error if mode is not recognized.
//
// Design rationale (design spec Build order section, step 2 vs step 3): off and static-cap start
// no scrapers, so their stop function is a no-op; kv-aware's is scraperManager.Stop, returned by
// gateway.NewKVAwareAdmitter, so every backend's scrape goroutine actually stops on shutdown
// rather than leaking.
//
// An unrecognized mode string fails startup rather than silently falling back to a different
// mode: a typo in --admission-mode must stop the gateway, not silently disable the guard.
func newAdmitter(mode gateway.AdmissionMode, f admitterFlags) (gateway.Admitter, func(), error) {
	switch mode {
	case gateway.AdmissionOff:
		return gateway.NewOffAdmitter(), noopStop, nil
	case gateway.AdmissionStaticCap:
		return gateway.NewStaticCapAdmitter(f.staticRate, f.staticBurst, f.longThreshold), noopStop, nil
	case gateway.AdmissionKVAware:
		admitter, stop := gateway.NewKVAwareAdmitter(f.kv)
		return admitter, stop, nil
	default:
		return nil, noopStop, fmt.Errorf("unknown admission mode %q", mode)
	}
}
