package gateway

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
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
// It reads through the client rather than asking for informers, which would create a missing one and race it.
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
	ca, cl, err := NewCache(ctx, cfg, scheme, "default")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = ca.Start(ctx) }()
	if !ca.WaitForCacheSync(ctx) {
		t.Fatal("the cache never synced")
	}
	// Each read the request path makes, through the gateway's own client. The cache refuses a kind it was not given
	// before start, so a missing registration fails here at once instead of racing an informer this test created.
	if err := cl.Get(ctx, types.NamespacedName{Name: "gateway-api-keys", Namespace: "default"}, &corev1.Secret{}); !apierrors.IsNotFound(err) {
		t.Errorf("the Secret read was not served from the cache: %v", err)
	}
	if err := cl.List(ctx, &platformv1.GPUQuotaPolicyList{}); err != nil {
		t.Errorf("the GPUQuotaPolicy read was not served from the cache: %v", err)
	}
	if err := cl.List(ctx, &platformv1.InferenceDeploymentList{}, client.InNamespace("default"), client.MatchingFields{ModelNameIndex: "m"}); err != nil {
		t.Errorf("the InferenceDeployment read was not served from the cache: %v", err)
	}
}
