package controller

import (
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"

	admissionregistrationv1 "k8s.io/api/admissionregistration/v1"
	"sigs.k8s.io/yaml"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The controller writes the label in Go and the ValidatingWebhookConfiguration selects on it in YAML, and
// nothing else makes the two agree. A pair of values that must match with no check between them is the shape
// of the defect this whole change exists to close: the guard's coverage was correct in both files and
// connected by nothing but a person remembering.
//
// This reads the manifest rather than a copy of it, so a rename on either side is a failing test rather than
// a namespace that quietly stops being guarded.
//
// Mutation that turns this red: change either constant in api/v1/labels.go, or the selector in
// config/webhook/manifests.yaml.
func TestTheEnforcementLabelMatchesTheWebhookSelector(t *testing.T) {
	path := filepath.Join("..", "..", "config", "webhook", "manifests.yaml")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	manifest := string(b)

	want := platformv1.QuotaEnforcedLabel + ": " + quoted(platformv1.QuotaEnforcedValue)
	if !strings.Contains(manifest, want) {
		t.Fatalf("no webhook selects on %q with value %q; the controller would label namespaces nothing reads",
			platformv1.QuotaEnforcedLabel, platformv1.QuotaEnforcedValue)
	}

	// Both device guards must carry it, not just one. A selector present on the Pod guard alone would leave
	// the Job guard applying everywhere, and vice versa -- and the two were written to close halves of the
	// same bypass.
	//
	// Each entry is split at its own "- name:" line, which is where the entries actually begin. An earlier
	// version of this loop delimited on the wrong key, so Index returned -1, the slice ran to end-of-file,
	// and every hook was checked against every OTHER hook's selector. It passed while one guard had no
	// selector at all -- caught by mutating the manifest, which is the only reason this comment exists.
	// Each guard's selector is parsed and compared whole. Containment alone passed when one guard selected the
	// right key with a wrong value, because the right pair appeared on the other guard (codex review r8).
	docs := strings.Split(manifest, "\n---")
	var cfg admissionregistrationv1.ValidatingWebhookConfiguration
	found := false
	for _, d := range docs {
		var probe admissionregistrationv1.ValidatingWebhookConfiguration
		if err := yaml.Unmarshal([]byte(d), &probe); err == nil && probe.Kind == "ValidatingWebhookConfiguration" {
			cfg, found = probe, true
		}
	}
	if !found {
		t.Fatalf("%s holds no ValidatingWebhookConfiguration", path)
	}
	wantSelector := map[string]string{platformv1.QuotaEnforcedLabel: platformv1.QuotaEnforcedValue}
	for _, hook := range []string{"vgpupod.kb.io", "vgpujob.kb.io"} {
		var w *admissionregistrationv1.ValidatingWebhook
		for i := range cfg.Webhooks {
			if cfg.Webhooks[i].Name == hook {
				w = &cfg.Webhooks[i]
			}
		}
		if w == nil {
			t.Fatalf("the manifest defines no webhook named %s", hook)
		}
		sel := w.NamespaceSelector
		if sel == nil || len(sel.MatchExpressions) != 0 || !maps.Equal(sel.MatchLabels, wantSelector) {
			t.Fatalf("%s selects namespaces by %+v, want exactly matchLabels %v: anything else leaves governed "+
				"namespaces unguarded or reaches kube-system", hook, sel, wantSelector)
		}
	}
}

// quoted quotes the value the way the manifest writes it, so the containment check above cannot pass on a
// prefix -- "true" must not match a hypothetical "truent".
func quoted(v string) string { return "\"" + v + "\"" }
