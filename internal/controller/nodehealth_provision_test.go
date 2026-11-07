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

package controller

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

func provisionNode(name string, gpus string, labels map[string]string) *corev1.Node {
	n := &corev1.Node{Name: name, Labels: labels}
	if gpus != "" {
		n.Status.Capacity = corev1.ResourceList{nvidiaGPUResource: resource.MustParse(gpus)}
	}
	return n
}

// provisionRun reconciles the given node name once against the objects and returns every NodeHealth afterwards.
func provisionRun(t *testing.T, name string, objs ...client.Object) []platformv1.NodeHealth {
	t.Helper()
	c := fake.NewClientBuilder().WithScheme(gfScheme(t)).WithObjects(objs...).Build()
	r := &NodeHealthProvisioner{Client: c, Scheme: c.Scheme(), APIReader: c}
	if _, err := r.Reconcile(context.Background(), ctrl.Request{Name: name}); err != nil {
		t.Fatalf("reconcile %s: %v", name, err)
	}
	var list platformv1.NodeHealthList
	if err := c.List(context.Background(), &list); err != nil {
		t.Fatal(err)
	}
	return list.Items
}

// Mutations that turn this red: drop the create, or the GPU check, or the existing-NodeHealth check, or the skip label.
func TestTheProvisionerGivesEachGPUNodeOneNodeHealth(t *testing.T) {
	t.Run("a GPU node with none gets one, marked as provisioned", func(t *testing.T) {
		got := provisionRun(t, "gpu-1", provisionNode("gpu-1", "4", nil))
		if len(got) != 1 || got[0].Name != "gpu-1" || got[0].Spec.NodeName != "gpu-1" || got[0].Labels[labelProvisionedBy] != provisionedByValue {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("a node without GPUs gets none", func(t *testing.T) {
		if got := provisionRun(t, "cpu-1", provisionNode("cpu-1", "", nil)); len(got) != 0 {
			t.Fatalf("got %+v", got)
		}
		if got := provisionRun(t, "gpu-0", provisionNode("gpu-0", "0", nil)); len(got) != 0 {
			t.Fatalf("a node advertising 0 GPUs got %+v", got)
		}
	})
	t.Run("a GPU node an operator already gave a NodeHealth under another name gets no second", func(t *testing.T) {
		mine := &platformv1.NodeHealth{Name: "nh-ops", Spec: platformv1.NodeHealthSpec{NodeName: "gpu-1"}}
		if got := provisionRun(t, "gpu-1", provisionNode("gpu-1", "1", nil), mine); len(got) != 1 || got[0].Name != "nh-ops" {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("a GPU node labelled to be skipped gets none", func(t *testing.T) {
		n := provisionNode("gpu-1", "1", map[string]string{labelNodeHealthSkip: nodeHealthSkipValue})
		if got := provisionRun(t, "gpu-1", n); len(got) != 0 {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("a NodeHealth of the node's name for another node is left alone", func(t *testing.T) {
		other := &platformv1.NodeHealth{Name: "gpu-1", Spec: platformv1.NodeHealthSpec{NodeName: "gpu-9"}}
		got := provisionRun(t, "gpu-1", provisionNode("gpu-1", "1", nil), other)
		if len(got) != 1 || got[0].Spec.NodeName != "gpu-9" || got[0].Labels[labelProvisionedBy] != "" {
			t.Fatalf("got %+v", got)
		}
	})
}

// Mutation that turns this red: delete every NodeHealth of a gone node, or none.
func TestTheProvisionerRemovesOnlyItsOwnNodeHealthOfAGoneNode(t *testing.T) {
	own := &platformv1.NodeHealth{Name: "gone", Labels: map[string]string{labelProvisionedBy: provisionedByValue},
		Spec: platformv1.NodeHealthSpec{NodeName: "gone"}}
	ops := &platformv1.NodeHealth{Name: "nh-ops", Spec: platformv1.NodeHealthSpec{NodeName: "gone"}}
	got := provisionRun(t, "gone", own, ops)
	if len(got) != 1 || got[0].Name != "nh-ops" {
		t.Fatalf("got %+v", got)
	}
}
