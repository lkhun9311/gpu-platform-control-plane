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
	"maps"
	"strconv"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// Labels a distributed job's Pods carry so its rendezvous Service selects them and nothing else.
//
// The UID is the half that matters: a job deleted and recreated under the same name has Pods that may still be terminating, and selecting on the name alone would put them behind the new incarnation's rank-0 address.
const (
	mltjNameLabel = "platform.lkhun9311.github.io/mltrainingjob"
	mltjUIDLabel  = "platform.lkhun9311.github.io/mltrainingjob-uid"
)

// RendezvousPort is the MASTER_PORT every rank is given.
//
// 29500 is torch.distributed's own default, so a workload that ignores the variable still lands on the same port.
const RendezvousPort = 29500

// rendezvousServiceSuffix keeps the Service clear of the InferenceDeployment controller's, which take a CR's bare name.
const rendezvousServiceSuffix = "-ddp"

// jobCompletionIndexAnnotation is where the Job controller writes each Indexed Pod's index.
//
// RANK is read from it by fieldRef because $(JOB_COMPLETION_INDEX) cannot be referenced: the Job controller appends that variable after the template's own, and a reference only resolves to variables declared before it.
const jobCompletionIndexAnnotation = "batch.kubernetes.io/job-completion-index"

// The condition that says whether a distributed job's rendezvous Service is this job's own.
//
// It is never written for a job without distributed, so its absence there says nothing about a Service.
const (
	mltjCondRendezvous           = "RendezvousService"
	mltjReasonServiceReady       = "ServiceOwned"
	mltjReasonServiceConflict    = "ServiceConflict"
	mltjReasonServiceTerminating = "ServiceTerminating"
)

// RendezvousServiceName is the headless Service whose DNS records give each rank its peers' addresses.
func RendezvousServiceName(mltj *platformv1.MLTrainingJob) string {
	return mltj.Name + rendezvousServiceSuffix
}

// applyDistributed turns the ordinary single-template Job into one Indexed Job of worldSize ranks.
//
// It only adds to what BuildJob rendered, so a job without distributed never reaches it and renders as it always did.
func applyDistributed(job *batchv1.Job, mltj *platformv1.MLTrainingJob) {
	world := mltj.Spec.Distributed.WorldSize
	svc := RendezvousServiceName(mltj)

	// Indexed gives each Pod a stable index, hostname <job>-<index> and the annotation RANK is read from.
	job.Spec.CompletionMode = new(batchv1.IndexedCompletion)
	job.Spec.Parallelism = new(world)
	job.Spec.Completions = new(world)

	// Zero, because the Job controller's retry is per index: it would replace one failed rank, and a replacement cannot rejoin a group whose other ranks are mid-step, while a replaced rank 0 would replace the store the others are connected to.
	job.Spec.BackoffLimit = new(int32(0))

	tmpl := &job.Spec.Template
	tmpl.Labels = map[string]string{mltjNameLabel: mltj.Name, mltjUIDLabel: string(mltj.UID)}
	tmpl.Spec.Subdomain = svc

	c := &tmpl.Spec.Containers[0]
	c.Env = append(c.Env,
		corev1.EnvVar{Name: "WORLD_SIZE", Value: strconv.Itoa(int(world))},
		corev1.EnvVar{Name: "MASTER_ADDR", Value: fmt.Sprintf("%s-0.%s.%s.svc", mltj.Name, svc, mltj.Namespace)},
		corev1.EnvVar{Name: "MASTER_PORT", Value: strconv.Itoa(RendezvousPort)},
		corev1.EnvVar{Name: "RANK", ValueFrom: &corev1.EnvVarSource{
			FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.annotations['" + jobCompletionIndexAnnotation + "']"},
		}},
	)
}

// BuildRendezvousService renders the headless Service a distributed job's ranks resolve each other through.
//
// publishNotReadyAddresses is what lets rank 0 be found before it is Ready: a rank waiting in rendezvous is not Ready, and without it every rank would wait for an address that is only published once the wait is over.
func BuildRendezvousService(mltj *platformv1.MLTrainingJob) *corev1.Service {
	return &corev1.Service{
		Name: RendezvousServiceName(mltj), Namespace: mltj.Namespace,
		Labels: map[string]string{mltjNameLabel: mltj.Name},
		Spec: corev1.ServiceSpec{
			ClusterIP:                corev1.ClusterIPNone,
			PublishNotReadyAddresses: true,
			Selector:                 map[string]string{mltjNameLabel: mltj.Name, mltjUIDLabel: string(mltj.UID)},
			// Protocol and targetPort are spelled out because the API server defaults both, and the drift check compares against what it stored.
			Ports: []corev1.ServicePort{{
				Name: "rendezvous", Protocol: corev1.ProtocolTCP,
				Port: RendezvousPort, TargetPort: intstr.FromInt32(RendezvousPort),
			}},
		},
	}
}

// ensureRendezvousService makes this job's Service exist, and reports whether it is this job's own.
//
// It creates and never adopts.
// controllerutil.CreateOrUpdate is not used because it would set an owner on a Service someone else created between our read and our write, and SetControllerReference compares owners by kind and name, not UID, so an earlier incarnation's Service would pass as ours.
// A create that loses that race fails with AlreadyExists, and the Service is judged on the next pass instead.
//
// A nil condition with ready false means "not decided yet": nothing is wrong, and the caller only waits.
func (r *MLTrainingJobReconciler) ensureRendezvousService(
	ctx context.Context, mltj *platformv1.MLTrainingJob,
) (ready bool, cond *metav1.Condition, err error) {
	desired := BuildRendezvousService(mltj)
	key := types.NamespacedName{Name: desired.Name, Namespace: desired.Namespace}

	var svc corev1.Service
	err = r.Get(ctx, key, &svc)
	switch {
	case apierrors.IsNotFound(err):
		if err := controllerutil.SetControllerReference(mltj, desired, r.Scheme); err != nil {
			return false, nil, fmt.Errorf("own rendezvous service %s: %w", key, err)
		}
		if err := r.Create(ctx, desired); err != nil {
			if apierrors.IsAlreadyExists(err) {
				// Ours from a previous pass the cache has not caught up with, or someone else's; the next read decides.
				return false, nil, nil
			}
			return false, nil, fmt.Errorf("create rendezvous service %s: %w", key, err)
		}
		return true, rendezvousCondition(metav1.ConditionTrue, mltjReasonServiceReady, ""), nil
	case err != nil:
		return false, nil, fmt.Errorf("get rendezvous service %s: %w", key, err)
	}

	// IsControlledBy compares UIDs, so a Service left by a deleted job of the same name is foreign here.
	if !metav1.IsControlledBy(&svc, mltj) {
		return false, rendezvousCondition(metav1.ConditionFalse, mltjReasonServiceConflict,
			"a Service named "+key.Name+" exists and is not owned by this MLTrainingJob; it is left untouched, and the job's Pods are not created until it is gone"), nil
	}
	if !svc.DeletionTimestamp.IsZero() {
		return false, rendezvousCondition(metav1.ConditionFalse, mltjReasonServiceTerminating,
			"this job's Service is being deleted; it is recreated once it is gone"), nil
	}

	// Ours, so drift is corrected; clusterIP is immutable and is not touched.
	if !equality.Semantic.DeepEqual(svc.Spec.Selector, desired.Spec.Selector) ||
		svc.Spec.PublishNotReadyAddresses != desired.Spec.PublishNotReadyAddresses ||
		!equality.Semantic.DeepEqual(svc.Spec.Ports, desired.Spec.Ports) {
		svc.Spec.Selector = desired.Spec.Selector
		svc.Spec.PublishNotReadyAddresses = desired.Spec.PublishNotReadyAddresses
		svc.Spec.Ports = desired.Spec.Ports
		if svc.Labels == nil {
			svc.Labels = map[string]string{}
		}
		maps.Copy(svc.Labels, desired.Labels)
		if err := r.Update(ctx, &svc); err != nil {
			return false, nil, fmt.Errorf("repair rendezvous service %s: %w", key, err)
		}
	}
	return true, rendezvousCondition(metav1.ConditionTrue, mltjReasonServiceReady, ""), nil
}

// rendezvousCondition builds the RendezvousService condition.
func rendezvousCondition(status metav1.ConditionStatus, reason, msg string) *metav1.Condition {
	return &metav1.Condition{Type: mltjCondRendezvous, Status: status, Reason: reason, Message: msg}
}
