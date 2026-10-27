package controller

import (
	"os"
	"testing"

	"github.com/go-logr/logr"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/yaml"
)

// The exporter must be able to come back to a node this controller has quarantined.
//
// A latched fault clears automatically only on a fresh reading of zero, and the exporter is what produces it.
// The paid GPU fault session of 2026-10-27 took the exporter away with Xid 79 latched: once its Pod left,
// the DaemonSet did not place a new one on the tainted node, because it tolerated nvidia.com/gpu alone, and
// the latch could then be cleared only by hand.
// The taint is built by ensureGPUFaultTaint rather than restated here, so the key and effect cannot drift apart.
//
// Mutation that turns this red: delete the fault taint's toleration from config/dcgm-exporter/daemonset.yaml.
func TestTheExporterToleratesTheFaultTaintItIsNeededToClear(t *testing.T) {
	b, err := os.ReadFile("../../config/dcgm-exporter/daemonset.yaml")
	if err != nil {
		t.Fatalf("read the exporter DaemonSet: %v", err)
	}
	var ds appsv1.DaemonSet
	if err := yaml.UnmarshalStrict(b, &ds); err != nil {
		t.Fatalf("parse the exporter DaemonSet: %v", err)
	}
	if ds.Kind != "DaemonSet" || ds.Name != "dcgm-exporter" {
		t.Fatalf("read %s %q, not the dcgm-exporter DaemonSet; this test is reading a shape that has moved", ds.Kind, ds.Name)
	}
	var node corev1.Node
	if !ensureGPUFaultTaint(&node) || len(node.Spec.Taints) != 1 {
		t.Fatalf("ensureGPUFaultTaint put %v on an untainted node, want exactly the fault taint", node.Spec.Taints)
	}
	taint := node.Spec.Taints[0]
	for i := range ds.Spec.Template.Spec.Tolerations {
		// Kubernetes' own matching rule, so an Equal toleration with the wrong value or effect does not pass.
		if ds.Spec.Template.Spec.Tolerations[i].ToleratesTaint(logr.Discard(), &taint, false) {
			return
		}
	}
	t.Fatalf("the exporter tolerates %v but not the fault taint %s:%s, so it cannot return to a node the platform quarantined",
		ds.Spec.Template.Spec.Tolerations, taint.Key, taint.Effect)
}
