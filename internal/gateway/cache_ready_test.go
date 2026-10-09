package gateway

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// When the cache says it has synced -- the moment the gateway reports ready -- every kind the request path reads
// is already cached. Before, Secret and GPUQuotaPolicy informers started on the first request, which each waited
// one or two 100 ms sync polls: the pilot's 103 and 204 ms first-request lags.
//
// It needs a real API server, so it fails rather than skips without envtest's binaries: a skip reads as a pass.
// Mutation that turns it red: remove the GetInformer registrations from NewCache.
func TestNewCacheHasEveryRequestPathKindSyncedWhenReady(t *testing.T) {
	assets := os.Getenv("KUBEBUILDER_ASSETS")
	if assets == "" {
		assets = filepath.Join("..", "..", "bin", "k8s", "1.36.2-linux-amd64")
	}
	if _, err := os.Stat(filepath.Join(assets, "kube-apiserver")); err != nil {
		t.Fatalf("no envtest binaries at %s (set KUBEBUILDER_ASSETS or run make setup-envtest): %v", assets, err)
	}
	env := &envtest.Environment{
		BinaryAssetsDirectory: assets,
		CRDDirectoryPaths:     []string{filepath.Join("..", "..", "config", "crd", "bases")},
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := env.Start()
	if err != nil {
		t.Fatalf("start envtest: %v", err)
	}
	defer func() { _ = env.Stop() }()

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	if err := platformv1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	ca, _, err := NewCache(ctx, cfg, scheme, "default")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = ca.Start(ctx) }()
	if !ca.WaitForCacheSync(ctx) {
		t.Fatal("the cache never synced")
	}
	for _, o := range []client.Object{&corev1.Secret{}, &platformv1.GPUQuotaPolicy{}, &platformv1.InferenceDeployment{}} {
		// Not blocking: an informer created now would start unsynced, and that is the failure this test exists for.
		inf, err := ca.GetInformer(ctx, o, cache.BlockUntilSynced(false))
		if err != nil {
			t.Fatalf("%T: %v", o, err)
		}
		if !inf.HasSynced() {
			t.Errorf("%T was not cached when the gateway would have reported ready", o)
		}
	}
}
