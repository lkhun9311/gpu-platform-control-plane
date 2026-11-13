package gateway

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	"sigs.k8s.io/yaml"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The gateway, running as the identity config/gateway/rbac.yaml ships, reads the api-keys Secret and no other Secret
// in its namespace, and its cache still syncs.
//
// Both halves need a real apiserver, because the claim is about authorization: a list or watch narrowed by the
// metadata.name field selector is authorized against the Role's resourceNames, and an unfiltered one is not.
// The comment this test replaced said the opposite, that resourceNames breaks the watch, and nothing had run it.
//
// Mutations that turn it red: drop the FieldSelector from NewCache (the cache never syncs), or drop resourceNames
// from the Role (the neighbouring Secret becomes readable).
func TestTheGatewayRoleReadsOnlyTheAPIKeySecret(t *testing.T) {
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
	admin, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		t.Fatal(err)
	}

	const ns = "gateway-ns"
	secretName := shippedAPIKeySecretName(t)
	var role rbacv1.Role
	var clusterRole rbacv1.ClusterRole
	shippedGatewayRBAC(t, &role, &clusterRole)
	role.Namespace = ns

	const user = "gateway-under-test"
	subjects := []rbacv1.Subject{{Kind: rbacv1.UserKind, APIGroup: rbacv1.GroupName, Name: user}}
	for _, o := range []client.Object{
		&corev1.Namespace{Name: ns},
		&corev1.Secret{Name: secretName, Namespace: ns, Data: map[string][]byte{"k": []byte("tenant-a")}},
		// What shares the namespace in practice: the webhook's serving certificate, private key included.
		&corev1.Secret{Name: "webhook-server-cert", Namespace: ns, Data: map[string][]byte{"tls.key": []byte("private")}},
		&role,
		&clusterRole,
		&rbacv1.RoleBinding{Name: "gateway", Namespace: ns, Subjects: subjects,
			RoleRef: rbacv1.RoleRef{APIGroup: rbacv1.GroupName, Kind: "Role", Name: role.Name}},
		&rbacv1.ClusterRoleBinding{Name: "gateway", Subjects: subjects,
			RoleRef: rbacv1.RoleRef{APIGroup: rbacv1.GroupName, Kind: "ClusterRole", Name: clusterRole.Name}},
	} {
		if err := admin.Create(ctx, o); err != nil {
			t.Fatalf("create %T %s: %v", o, o.GetName(), err)
		}
	}

	gw, err := env.AddUser(envtest.User{Name: user}, nil)
	if err != nil {
		t.Fatal(err)
	}
	ca, cl, err := NewCache(ctx, gw.Config(), scheme, ns, secretName)
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = ca.Start(ctx) }()
	syncCtx, syncCancel := context.WithTimeout(ctx, 20*time.Second)
	defer syncCancel()
	if !ca.WaitForCacheSync(syncCtx) {
		t.Fatal("the cache never synced under the shipped Role: its Secret list or watch was refused")
	}

	var keys corev1.Secret
	if err := cl.Get(ctx, types.NamespacedName{Namespace: ns, Name: secretName}, &keys); err != nil {
		t.Fatalf("the gateway could not read its own api-keys Secret: %v", err)
	}
	if string(keys.Data["k"]) != "tenant-a" {
		t.Fatalf("the api-keys Secret came back without its data: %v", keys.Data)
	}
	// Asked of the apiserver directly, not the cache, so this is the Role's answer rather than the selector's.
	direct, err := client.New(gw.Config(), client.Options{Scheme: scheme})
	if err != nil {
		t.Fatal(err)
	}
	err = direct.Get(ctx, types.NamespacedName{Namespace: ns, Name: "webhook-server-cert"}, &corev1.Secret{})
	if !apierrors.IsForbidden(err) {
		t.Fatalf("the gateway's identity could read another Secret in its namespace (err=%v)", err)
	}
}

// shippedAPIKeySecretName is the Secret name config/gateway/deployment.yaml gives the gateway.
func shippedAPIKeySecretName(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "config", "gateway", "deployment.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var dep appsv1.Deployment
	if err := yaml.Unmarshal(raw, &dep); err != nil {
		t.Fatal(err)
	}
	for _, c := range dep.Spec.Template.Spec.Containers {
		for _, e := range c.Env {
			if e.Name == "GATEWAY_API_KEY_SECRET" {
				return e.Value
			}
		}
	}
	t.Fatal("config/gateway/deployment.yaml sets no GATEWAY_API_KEY_SECRET")
	return ""
}

// shippedGatewayRBAC reads the Role and ClusterRole config/gateway/rbac.yaml ships.
func shippedGatewayRBAC(t *testing.T, role *rbacv1.Role, clusterRole *rbacv1.ClusterRole) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "config", "gateway", "rbac.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	var found int
	for doc := range strings.SplitSeq(string(raw), "\n---\n") {
		var meta metav1.TypeMeta
		if err := yaml.Unmarshal([]byte(doc), &meta); err != nil {
			t.Fatal(err)
		}
		switch meta.Kind {
		case "Role":
			if err := yaml.Unmarshal([]byte(doc), role); err != nil {
				t.Fatal(err)
			}
			found++
		case "ClusterRole":
			if err := yaml.Unmarshal([]byte(doc), clusterRole); err != nil {
				t.Fatal(err)
			}
			found++
		}
	}
	if found != 2 {
		t.Fatalf("config/gateway/rbac.yaml holds %d of the Role and ClusterRole this test reads", found)
	}
}
