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
	"fmt"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// labelProvisionedBy marks a NodeHealth the provisioner created, the only kind it ever deletes.
const (
	labelProvisionedBy  = "platform.lkhun9311.github.io/provisioned-by"
	provisionedByValue  = "nodehealth-provisioner"
	labelNodeHealthSkip = "platform.lkhun9311.github.io/nodehealth"
	nodeHealthSkipValue = "skip"
)

// NodeHealthProvisioner gives every GPU node a NodeHealth.
//
// The fault path scrapes only nodes a NodeHealth names, and the readiness quarantine taints only those, so a GPU node
// that joins without one is watched by nothing until an operator remembers to create it; in a fleet that is a node
// joining every few minutes.
// It is off unless --provision-nodehealth is set, because a cluster whose NodeHealth objects are written by hand or by
// a session runner would otherwise get a second one for the same node, and two NodeHealths would both manage its taint.
type NodeHealthProvisioner struct {
	client.Client
	Scheme *runtime.Scheme
	// APIReader lists NodeHealths past the cache: one an operator created a moment ago must count, or the provisioner
	// would add a second for the same node.
	APIReader client.Reader
}

// Reconcile is keyed by a Node's name.
func (r *NodeHealthProvisioner) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	var all platformv1.NodeHealthList
	if err := r.APIReader.List(ctx, &all); err != nil {
		return ctrl.Result{}, fmt.Errorf("list nodehealths: %w", err)
	}
	var naming []platformv1.NodeHealth
	for i := range all.Items {
		if all.Items[i].Spec.NodeName == req.Name {
			naming = append(naming, all.Items[i])
		}
	}

	var node corev1.Node
	if err := r.Get(ctx, req.NamespacedName, &node); err != nil {
		if !apierrors.IsNotFound(err) {
			return ctrl.Result{}, fmt.Errorf("get node %s: %w", req.Name, err)
		}
		// The node is gone: its own NodeHealths go with it, an operator's stay for the operator to read and remove.
		for i := range naming {
			nh := &naming[i]
			if nh.Labels[labelProvisionedBy] != provisionedByValue {
				continue
			}
			if err := r.Delete(ctx, nh, client.Preconditions{UID: &nh.UID}); err != nil && !apierrors.IsNotFound(err) {
				return ctrl.Result{}, fmt.Errorf("delete nodehealth %s of a deleted node: %w", nh.Name, err)
			}
			log.Info("Deleted the NodeHealth of a node that is gone", "nodehealth", nh.Name, "node", req.Name)
		}
		return ctrl.Result{}, nil
	}

	if len(naming) > 0 || !hasGPU(&node) || node.Labels[labelNodeHealthSkip] == nodeHealthSkipValue {
		return ctrl.Result{}, nil
	}
	nh := &platformv1.NodeHealth{
		Name:   node.Name,
		Labels: map[string]string{labelProvisionedBy: provisionedByValue},
		Spec:   platformv1.NodeHealthSpec{NodeName: node.Name},
	}
	switch err := r.Create(ctx, nh); {
	case apierrors.IsAlreadyExists(err):
		// A NodeHealth of this name that names another node is someone else's object; it is never taken over.
		log.Info("A NodeHealth named after this GPU node already exists for another node; not creating one", "node", node.Name)
		return ctrl.Result{}, nil
	case err != nil:
		return ctrl.Result{}, fmt.Errorf("create nodehealth for gpu node %s: %w", node.Name, err)
	}
	log.Info("Created a NodeHealth for a GPU node", "node", node.Name)
	return ctrl.Result{}, nil
}

// hasGPU reports whether the node advertises NVIDIA devices, which it does once the device plugin has registered.
func hasGPU(node *corev1.Node) bool {
	q, ok := node.Status.Capacity[nvidiaGPUResource]
	return ok && q.Sign() > 0
}

// SetupWithManager registers the provisioner on Node events only: an operator who deletes a provisioned NodeHealth
// gets it back at the node's next status change, and one who wants a node left alone labels it nodehealth=skip.
func (r *NodeHealthProvisioner) SetupWithManager(mgr ctrl.Manager) error {
	if r.APIReader == nil {
		return fmt.Errorf("nodehealth provisioner without an API reader")
	}
	return ctrl.NewControllerManagedBy(mgr).For(&corev1.Node{}).Named("nodehealth-provisioner").Complete(r)
}
