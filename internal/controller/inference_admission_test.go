package controller

import (
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// rolledOut is a Deployment rendered for generation 5 whose HoldCap template has fully replaced every older Pod.
func rolledOut() *appsv1.Deployment {
	d := &appsv1.Deployment{}
	d.Generation = 3
	d.Annotations = map[string]string{renderedGenerationAnnotation: "5"}
	d.Spec.Replicas = new(int32(1))
	d.Spec.Template.Annotations = map[string]string{admissionAnnotation: platformv1.AdmissionModeHoldCap}
	d.Status = appsv1.DeploymentStatus{ObservedGeneration: 3, Replicas: 1, UpdatedReplicas: 1, ReadyReplicas: 1, TerminatingReplicas: new(int32(0))}
	return d
}

// Mutation that must turn this red: return HoldCap whenever the spec asks for it.
func TestAdmissionInForceOnlyAfterACompleteRollout(t *testing.T) {
	asked := engineInfD(platformv1.AdmissionModeHoldCap)
	asked.Generation = 5
	asked.Spec.Admission.MaxHold = &metav1.Duration{Duration: 25 * time.Second}
	notAsked := engineInfD(platformv1.AdmissionModeOff)
	notAsked.Generation = 5
	scaledZero := asked.DeepCopy()
	scaledZero.Spec.Replicas = 0
	cases := []struct {
		name   string
		infd   *platformv1.InferenceDeployment
		mutate func(*appsv1.Deployment)
		mode   string
		reason string
	}{
		{"complete", asked, func(*appsv1.Deployment) {}, platformv1.AdmissionModeHoldCap, infdReasonHoldCapInForce},
		{"complete where terminating Pods are not reported", asked, func(d *appsv1.Deployment) { d.Status.TerminatingReplicas = nil },
			platformv1.AdmissionModeHoldCap, infdReasonHoldCapInForce},
		{"not asked", notAsked, func(*appsv1.Deployment) {}, platformv1.AdmissionModeOff, infdReasonNotRequested},
		{"rendered for an older generation", asked, func(d *appsv1.Deployment) { d.Annotations[renderedGenerationAnnotation] = "4" },
			platformv1.AdmissionModeOff, infdReasonRollout},
		{"template not yet observed", asked, func(d *appsv1.Deployment) { d.Status.ObservedGeneration = 2 }, platformv1.AdmissionModeOff, infdReasonRollout},
		{"template uncapped", asked, func(d *appsv1.Deployment) {
			d.Spec.Template.Annotations[admissionAnnotation] = platformv1.AdmissionModeOff
		},
			platformv1.AdmissionModeOff, infdReasonRollout},
		{"old pod remains", asked, func(d *appsv1.Deployment) { d.Status.Replicas = 2 }, platformv1.AdmissionModeOff, infdReasonRollout},
		{"old pod terminating", asked, func(d *appsv1.Deployment) { d.Status.TerminatingReplicas = new(int32(1)) },
			platformv1.AdmissionModeOff, infdReasonRollout},
		{"new pod not ready", asked, func(d *appsv1.Deployment) { d.Status.ReadyReplicas = 0 }, platformv1.AdmissionModeOff, infdReasonRollout},
		{"new pod not updated", asked, func(d *appsv1.Deployment) { d.Status.UpdatedReplicas = 0 }, platformv1.AdmissionModeOff, infdReasonRollout},
		{"scaled to zero", scaledZero, func(d *appsv1.Deployment) { d.Spec.Replicas = new(int32(0)) }, platformv1.AdmissionModeOff, infdReasonScaledZero},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := rolledOut()
			c.mutate(d)
			mode, cond := admissionInForce(c.infd, d)
			if mode != c.mode || cond.Reason != c.reason {
				t.Fatalf("got %s/%s, want %s/%s", mode, cond.Reason, c.mode, c.reason)
			}
			if cond.Type != infdCondAdmissionInForce || (cond.Status == metav1.ConditionTrue) != (mode == platformv1.AdmissionModeHoldCap) {
				t.Fatalf("condition %+v does not agree with mode %s", cond, mode)
			}
			if cond.ObservedGeneration != c.infd.Generation {
				t.Fatalf("condition observed generation %d, want %d", cond.ObservedGeneration, c.infd.Generation)
			}
		})
	}
}
