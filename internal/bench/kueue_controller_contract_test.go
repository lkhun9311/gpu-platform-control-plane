package bench

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	"sigs.k8s.io/yaml"
)

// The Kueue controller EKS runs is the v0.18.3 release, vendored byte for byte under config/kueue-controller
// (docs/superpowers/specs/2026-10-16-nccl-groundwork-design.md, section 1). These pin what that rests on.

const kueueDir = "config/kueue-controller"

// kueueRelease reads RELEASE's key=value lines.
func kueueRelease(t *testing.T) map[string]string {
	t.Helper()
	out := map[string]string{}
	for line := range strings.SplitSeq(readRepoFile(t, kueueDir+"/RELEASE"), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			out[k] = v
		}
	}
	for _, k := range []string{"version", "url", "sha256", "size", "image", "digest"} {
		if out[k] == "" {
			t.Fatalf("%s/RELEASE has no %s", kueueDir, k)
		}
	}
	return out
}

// objects decodes every document of a multi-document YAML file.
func objects(t *testing.T, rel string) []map[string]any {
	t.Helper()
	dec := utilyaml.NewYAMLOrJSONDecoder(strings.NewReader(readRepoFile(t, rel)), 4096)
	var out []map[string]any
	for {
		var obj map[string]any
		if err := dec.Decode(&obj); err != nil {
			if errors.Is(err, io.EOF) {
				return out
			}
			t.Fatalf("decode %s: %v", rel, err)
		}
		if obj != nil {
			out = append(out, obj)
		}
	}
}

// get walks a decoded object by keys; a missing step yields nil.
func get(obj any, path ...string) any {
	for _, p := range path {
		m, ok := obj.(map[string]any)
		if !ok {
			return nil
		}
		obj = m[p]
	}
	return obj
}

func name(obj map[string]any) string { s, _ := get(obj, "metadata", "name").(string); return s }

// The vendored file is the release file. A hand edit, a re-download of a different version or a line-ending
// conversion changes the hash, and the Application would then deploy something RELEASE does not describe.
//
// Mutation that turns this red: change one byte of manifests.yaml, or the sha256 in RELEASE.
func TestTheVendoredKueueIsTheRelease(t *testing.T) {
	rel := kueueRelease(t)
	b, err := os.ReadFile("../../" + kueueDir + "/manifests.yaml")
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	if got := hex.EncodeToString(sum[:]); got != rel["sha256"] {
		t.Errorf("manifests.yaml has sha256 %s, RELEASE records %s", got, rel["sha256"])
	}
	if got := strconv.Itoa(len(b)); got != rel["size"] {
		t.Errorf("manifests.yaml is %s bytes, RELEASE records %s", got, rel["size"])
	}
	if !strings.Contains(rel["url"], "/"+rel["version"]+"/manifests.yaml") {
		t.Errorf("RELEASE's url %s is not the %s manifest", rel["url"], rel["version"])
	}
}

// The release names one image, and the kustomization pins that image by the digest RELEASE records.
//
// A tag can be moved to other bytes; the digest cannot. And a second image in a later release would run
// unpinned, which this catches by requiring the release's image set to be exactly the one the pin rewrites.
//
// Mutation that turns this red: drop the digest from the kustomization's images entry, or change its name.
func TestTheKueueControllerIsPinnedByDigest(t *testing.T) {
	rel := kueueRelease(t)
	var images []string
	for _, obj := range objects(t, kueueDir+"/manifests.yaml") {
		spec, _ := get(obj, "spec", "template", "spec").(map[string]any)
		for _, field := range []string{"initContainers", "containers"} {
			list, _ := spec[field].([]any)
			for _, c := range list {
				if img, ok := get(c, "image").(string); ok {
					images = append(images, img)
				}
			}
		}
	}
	if !slices.Equal(images, []string{rel["image"]}) {
		t.Fatalf("the release runs images %v, want exactly [%s]", images, rel["image"])
	}
	var kust struct {
		Images []struct {
			Name, NewName, NewTag, Digest string
		} `json:"images"`
	}
	if err := yaml.Unmarshal([]byte(readRepoFile(t, kueueDir+"/kustomization.yaml")), &kust); err != nil {
		t.Fatal(err)
	}
	repo, _, _ := strings.Cut(rel["image"], ":")
	if len(kust.Images) != 1 || kust.Images[0].Name != repo || kust.Images[0].Digest != rel["digest"] ||
		kust.Images[0].NewName != "" || kust.Images[0].NewTag != "" {
		t.Errorf("the kustomization's images are %+v, want one entry renaming nothing and pinning %s to %s",
			kust.Images, repo, rel["digest"])
	}
}

// config/kueue-crds is what envtest and test/e2e load in place of Kueue, so its schemas must be the release's.
//
// They are allowed to differ in exactly two places, by name: which version is stored, and the conversion stanza.
// envtest runs no conversion webhook, so the fixtures store v1beta1 and convert by None. Anything else that
// differs is a test environment admitting objects the cluster would refuse, or the reverse.
//
// Mutation that turns this red: change a type or add a property in one fixture's schema.
func TestTheKueueCRDFixturesHaveTheReleaseSchemas(t *testing.T) {
	release := map[string]map[string]any{}
	for _, obj := range objects(t, kueueDir+"/manifests.yaml") {
		if obj["kind"] == "CustomResourceDefinition" {
			release[name(obj)] = obj
		}
	}
	entries, err := os.ReadDir("../../config/kueue-crds")
	if err != nil {
		t.Fatal(err)
	}
	compared := 0
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".yaml") {
			continue
		}
		for _, fixture := range objects(t, "config/kueue-crds/"+e.Name()) {
			want, ok := release[name(fixture)]
			if !ok {
				t.Errorf("%s defines %s, which the release does not ship", e.Name(), name(fixture))
				continue
			}
			byName := map[string]any{}
			for _, v := range get(want, "spec", "versions").([]any) {
				byName[get(v, "name").(string)] = v
			}
			for _, v := range get(fixture, "spec", "versions").([]any) {
				vname := get(v, "name").(string)
				rv, ok := byName[vname]
				if !ok {
					t.Errorf("%s version %s is not in the release", name(fixture), vname)
					continue
				}
				if !reflect.DeepEqual(get(v, "schema"), get(rv, "schema")) {
					t.Errorf("%s version %s: the fixture's schema differs from the release's", name(fixture), vname)
				}
				if get(v, "served") != get(rv, "served") {
					t.Errorf("%s version %s: served %v, the release serves %v", name(fixture), vname, get(v, "served"), get(rv, "served"))
				}
				compared++
			}
		}
	}
	// Four fixtures, and each must carry at least the version the operator reads.
	if compared < 4 {
		t.Errorf("compared %d fixture versions, want at least one for each of the 4 fixtures", compared)
	}
}

// Kueue's certificate manager writes the CA bundle into objects Argo also syncs, and self-heal would revert it on
// every pass unless each field is ignored. The fields are read off the release, not off a list kept by hand: every
// CRD that converts by webhook, both webhook configurations, and the certificate Secret.
//
// Mutation that turns this red: delete one entry from the Application's ignoreDifferences.
func TestTheKueueApplicationIgnoresWhatKueueWrites(t *testing.T) {
	var app struct {
		Spec struct {
			IgnoreDifferences []struct {
				Group, Kind, Name, Namespace string
				JSONPointers                 []string `json:"jsonPointers"`
				JQPathExpressions            []string `json:"jqPathExpressions"`
			} `json:"ignoreDifferences"`
			SyncPolicy struct {
				SyncOptions []string `json:"syncOptions"`
			} `json:"syncPolicy"`
		} `json:"spec"`
	}
	if err := yaml.Unmarshal([]byte(readRepoFile(t, "config/argocd/kueue.yaml")), &app); err != nil {
		t.Fatal(err)
	}
	ignored := map[string][]string{}
	for _, d := range app.Spec.IgnoreDifferences {
		ignored[d.Kind+"/"+d.Name] = append(slices.Clone(d.JSONPointers), d.JQPathExpressions...)
	}
	want := map[string]string{}
	for _, obj := range objects(t, kueueDir+"/manifests.yaml") {
		switch obj["kind"] {
		case "CustomResourceDefinition":
			if get(obj, "spec", "conversion", "strategy") == "Webhook" {
				want["CustomResourceDefinition/"+name(obj)] = "/spec/conversion/webhook/clientConfig/caBundle"
			}
		case "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration":
			want[obj["kind"].(string)+"/"+name(obj)] = ".webhooks[]?.clientConfig.caBundle"
		case "Secret":
			want["Secret/"+name(obj)] = "/data"
		}
	}
	// Five converting CRDs, two webhook configurations and one Secret in v0.18.3; fewer means the read went wrong.
	if len(want) != 8 {
		t.Fatalf("found %d objects Kueue writes certificates into, want 8: %v", len(want), want)
	}
	for key, field := range want {
		if !slices.Contains(ignored[key], field) {
			t.Errorf("%s: Kueue writes %s and the Application does not ignore it", key, field)
		}
	}
	for key := range ignored {
		if _, ok := want[key]; !ok {
			t.Errorf("the Application ignores %s, which the release does not ship as a certificate target", key)
		}
	}
	if !slices.Contains(app.Spec.SyncPolicy.SyncOptions, "RespectIgnoreDifferences=true") {
		t.Error("without RespectIgnoreDifferences=true the ignored fields are still overwritten on sync")
	}
}

// The shared flavor stays empty, because five kind harnesses apply it to workers with no train label; the EKS
// placement is the kustomization's patch.
//
// Mutation that turns this red: put the nodeLabels into config/kueue/resourceflavor.yaml.
func TestTheSharedFlavorCarriesNoPlacement(t *testing.T) {
	flavors := objects(t, "config/kueue/resourceflavor.yaml")
	if len(flavors) != 1 || name(flavors[0]) != "gpu" {
		t.Fatalf("config/kueue/resourceflavor.yaml holds %d objects, want the one gpu flavor", len(flavors))
	}
	if spec, _ := flavors[0]["spec"].(map[string]any); len(spec) != 0 {
		t.Errorf("the shared gpu flavor has spec %v; placement belongs in %s's patch", spec, kueueDir)
	}
	kust := readRepoFile(t, kueueDir+"/kustomization.yaml")
	for _, want := range []string{"platform.lkhun9311.github.io/train: \"true\"", "key: nvidia.com/gpu", "value: present", "effect: NoSchedule"} {
		if !strings.Contains(kust, want) {
			t.Errorf("%s/kustomization.yaml does not carry %q", kueueDir, want)
		}
	}
}

// Kueue's visibility API is aggregated: the API server calls the Service each APIService names, on that Service's
// target port. The EKS module opens only its recommended webhook ports from the control plane, so every port an
// APIService needs must be opened in infra/aws/cluster/eks.tf, or the APIService stays unavailable and Argo holds
// the Application's first wave unhealthy, which keeps the gpu flavor in the second wave from ever being applied.
//
// Mutation that turns this red: delete the 8082 rule from eks.tf, or change the release's target port.
func TestTheNodesAdmitKueuesAggregatedAPI(t *testing.T) {
	objs := objects(t, kueueDir+"/manifests.yaml")
	services := map[string]map[string]any{}
	for _, obj := range objs {
		if obj["kind"] == "Service" {
			services[name(obj)] = obj
		}
	}
	ports := map[string]bool{}
	for _, obj := range objs {
		if obj["kind"] != "APIService" {
			continue
		}
		svc := services[get(obj, "spec", "service", "name").(string)]
		if svc == nil {
			t.Fatalf("APIService %s names a Service the release does not ship", name(obj))
		}
		for _, p := range get(svc, "spec", "ports").([]any) {
			ports[strconv.Itoa(int(get(p, "targetPort").(float64)))] = true
		}
	}
	if len(ports) == 0 {
		t.Fatal("found no port an APIService needs, so the read went wrong")
	}
	tf := readRepoFile(t, "infra/aws/cluster/eks.tf")
	start := strings.Index(tf, "node_security_group_additional_rules")
	if start < 0 {
		t.Fatal("eks.tf sets no node_security_group_additional_rules")
	}
	// The block ends at the first line closing it at the module's indentation.
	block, _, _ := strings.Cut(tf[start:], "\n  }\n")
	// Matched by regex, not by text, because terraform fmt realigns the equals signs whenever a longer key appears.
	rule := regexp.MustCompile(`(?s)\{[^{}]*\}`)
	for port := range ports {
		open := false
		for _, r := range rule.FindAllString(block, -1) {
			if regexp.MustCompile(`from_port\s*=\s*`+port+`\b`).MatchString(r) &&
				regexp.MustCompile(`to_port\s*=\s*`+port+`\b`).MatchString(r) &&
				regexp.MustCompile(`type\s*=\s*"ingress"`).MatchString(r) &&
				regexp.MustCompile(`source_cluster_security_group\s*=\s*true`).MatchString(r) {
				open = true
			}
		}
		if !open {
			t.Errorf("an APIService needs the control plane to reach port %s on the nodes, and eks.tf opens no ingress rule for it from the cluster security group", port)
		}
	}
}

// An Application that applies server-side must also diff server-side, or Argo 2.13 cannot compare it at all.
//
// With ServerSideApply, Argo builds the live object against its bundled schema, which lacks a Deployment's
// status.terminatingReplicas; the comparison fails, the Application reads sync Unknown and self-heal stops.
// cert-manager read Unknown in all four paid EKS sessions before the fix, and the Kueue Application did on kind after a drift.
//
// Mutation that turns this red: delete the compare-options annotation from cert-manager.yaml or kueue.yaml.
func TestServerSideApplicationsDiffServerSide(t *testing.T) {
	entries, err := os.ReadDir("../../config/argocd")
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".yaml") || e.Name() == "kustomization.yaml" {
			continue
		}
		var app struct {
			Metadata struct {
				Annotations map[string]string `json:"annotations"`
			} `json:"metadata"`
			Spec struct {
				SyncPolicy struct {
					SyncOptions []string `json:"syncOptions"`
				} `json:"syncPolicy"`
			} `json:"spec"`
		}
		if err := yaml.Unmarshal([]byte(readRepoFile(t, "config/argocd/"+e.Name())), &app); err != nil {
			t.Fatalf("%s: %v", e.Name(), err)
		}
		if !slices.Contains(app.Spec.SyncPolicy.SyncOptions, "ServerSideApply=true") {
			continue
		}
		checked++
		if !strings.Contains(app.Metadata.Annotations["argocd.argoproj.io/compare-options"], "ServerSideDiff=true") {
			t.Errorf("%s applies server-side and diffs with Argo's own schema, which cannot read a current Deployment", e.Name())
		}
	}
	// cert-manager, crds and kueue apply server-side today; none found means the read went wrong.
	if checked < 3 {
		t.Errorf("found %d server-side Applications, want at least 3", checked)
	}
}

// The quota alert reads series Kueue publishes only with metrics.enableClusterQueueResources, so the configuration
// EKS deploys must turn it on, and must otherwise be the release's own, or an upgrade would leave a stale file behind.
//
// The file replaces the ConfigMap's whole data value, which keeps the release's name, so the Deployment would not
// roll on an edit; the Pod-template annotation is what rolls it, and only while it carries the file's hash.
//
// Mutations that turn this red: comment the line out again, change any other line of the file, drop the generator,
// or edit the file without updating the annotation.
func TestTheKueueConfigurationPublishesClusterQueueResources(t *testing.T) {
	const (
		file     = "controller_manager_config.yaml"
		released = "# enableClusterQueueResources: true\n"
		enabled  = "  enableClusterQueueResources: true\n"
	)
	var release string
	for _, obj := range objects(t, kueueDir+"/manifests.yaml") {
		if obj["kind"] == "ConfigMap" && name(obj) == "kueue-manager-config" {
			release, _ = get(obj, "data", file).(string)
		}
	}
	if strings.Count(release, released) != 1 {
		t.Fatalf("the release's %s carries %q %d times, want once; the release changed and this file must follow it",
			file, released, strings.Count(release, released))
	}
	ours := readRepoFile(t, kueueDir+"/"+file)
	if want := strings.Replace(release, released, enabled, 1); ours != want {
		t.Errorf("%s/%s differs from the release's configuration by more than enabling enableClusterQueueResources",
			kueueDir, file)
	}
	var cfg struct {
		Metrics struct {
			EnableClusterQueueResources bool `json:"enableClusterQueueResources"`
		} `json:"metrics"`
	}
	if err := yaml.Unmarshal([]byte(ours), &cfg); err != nil {
		t.Fatal(err)
	}
	if !cfg.Metrics.EnableClusterQueueResources {
		t.Errorf("%s/%s does not set metrics.enableClusterQueueResources", kueueDir, file)
	}

	var kust struct {
		ConfigMapGenerator []struct {
			Name, Namespace, Behavior string
			Files                     []string `json:"files"`
		} `json:"configMapGenerator"`
		Patches []struct {
			Patch string `json:"patch"`
		} `json:"patches"`
	}
	if err := yaml.Unmarshal([]byte(readRepoFile(t, kueueDir+"/kustomization.yaml")), &kust); err != nil {
		t.Fatal(err)
	}
	gen := kust.ConfigMapGenerator
	if len(gen) != 1 || gen[0].Name != "kueue-manager-config" || gen[0].Namespace != "kueue-system" ||
		gen[0].Behavior != "replace" || !slices.Equal(gen[0].Files, []string{file}) {
		t.Errorf("configMapGenerator is %+v, want kueue-manager-config in kueue-system replaced from %s", gen, file)
	}
	sum := sha256.Sum256([]byte(ours))
	rolled := false
	for _, p := range kust.Patches {
		var ops []struct{ Op, Path, Value string }
		if err := yaml.Unmarshal([]byte(p.Patch), &ops); err != nil {
			continue
		}
		for _, op := range ops {
			rolled = rolled || op.Op == "add" && op.Value == hex.EncodeToString(sum[:]) &&
				op.Path == "/spec/template/metadata/annotations/platform.lkhun9311.github.io~1kueue-config-sha256"
		}
	}
	if !rolled {
		t.Errorf("no patch sets the Pod-template annotation to %s's sha256 %s, so a running Kueue keeps its old configuration",
			file, hex.EncodeToString(sum[:]))
	}
}
