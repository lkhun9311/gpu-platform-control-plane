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
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	batchv1 "k8s.io/api/batch/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The state volume is the one part of the rendered Pod no canary reads, so this is the only instrument on it.
//
// The termination canary fingerprints the template BuildJob renders for templateProbeJob, and that probe
// declares no state volume on purpose: the canary SCHEDULES its probe as a real Pod, and a probe naming a
// claim nobody created would sit Pending forever. Keeping it out is what left every canary taken before this
// field valid, and the price is that the mount path is covered by no reading the canary takes. The
// pre-registration therefore made a controller-path test a requirement of this work rather than an option.
//
// These specs are not a second copy of the BuildJob unit tests beside them, and the difference is the
// apiserver. Those call the renderer directly, so they would pass unchanged if the generated CRD schema
// REJECTED the field, or if the reconciler built its Job from something other than BuildJob. Here the create
// proves the schema admits what the Go type declares, and the Get proves the value survived the round trip
// into the Job the controller actually created.
var _ = Describe("MLTrainingJob state volume", func() {
	const ns = "default"

	// jobFor creates an MLTrainingJob and drives reconciles until the owned Job exists, then returns it.
	//
	// The claim it names is never created. Nothing in this path requires it to exist: the Job object is
	// stored regardless, and only a kubelet scheduling the Pod would care -- which is the same reason the
	// missing claim surfaces as a Pending Pod in a real cluster rather than as a rejected Job.
	jobFor := func(sv *platformv1.StateVolume) *batchv1.Job {
		GinkgoHelper()
		key := types.NamespacedName{Name: "statevol-" + rand.String(5), Namespace: ns}
		Expect(k8sClient.Create(ctx, &platformv1.MLTrainingJob{
			ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace},
			Spec: platformv1.MLTrainingJobSpec{
				Queue: "team-a", Image: "trainer:v1", GPUCount: 1, Parallelism: 1, Completions: 1,
				StateVolume: sv,
			},
		})).To(Succeed())
		DeferCleanup(func() {
			_ = k8sClient.Delete(ctx, &platformv1.MLTrainingJob{
				ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace},
			})
		})

		r := &MLTrainingJobReconciler{Client: cachedClient, Scheme: cachedClient.Scheme()}
		for range 3 {
			_, err := r.Reconcile(ctx, reconcile.Request{NamespacedName: key})
			Expect(err).NotTo(HaveOccurred())
		}

		job := &batchv1.Job{}
		Expect(k8sClient.Get(ctx, key, job)).To(Succeed())
		return job
	}

	It("mounts the declared claim into the container that runs the workload", func() {
		job := jobFor(&platformv1.StateVolume{ClaimName: "resume-state", MountPath: "/state"})
		pod := job.Spec.Template.Spec

		Expect(pod.Volumes).To(HaveLen(1))
		Expect(pod.Volumes[0].PersistentVolumeClaim).NotTo(BeNil(),
			"an emptyDir here would die with the Pod, so a resuming workload would restore nothing and "+
				"report the resume as having worked")
		Expect(pod.Volumes[0].PersistentVolumeClaim.ClaimName).To(Equal("resume-state"))

		// The mount has to land in the trainer, not merely somewhere in the Pod. A volume attached to a Pod
		// whose workload container cannot see it is storage nothing reads.
		Expect(pod.Containers[0].Name).To(Equal("trainer"))
		Expect(pod.Containers[0].VolumeMounts).To(HaveLen(1))
		Expect(pod.Containers[0].VolumeMounts[0].Name).To(Equal(pod.Volumes[0].Name))
		Expect(pod.Containers[0].VolumeMounts[0].MountPath).To(Equal("/state"))
	})

	It("renders what it always rendered when no volume is declared", func() {
		job := jobFor(nil)
		Expect(job.Spec.Template.Spec.Volumes).To(BeEmpty(),
			"a job asking for no state volume must render the template it rendered before the field existed, "+
				"or every canary taken before this change is comparing two different mechanisms")
		Expect(job.Spec.Template.Spec.Containers[0].VolumeMounts).To(BeEmpty())
	})
})
