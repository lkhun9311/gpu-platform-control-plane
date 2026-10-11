package controller

import (
	"strconv"

	appsv1 "k8s.io/api/apps/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

const (
	// infdCondAdmissionInForce says whether the admission the spec asks for is the one running.
	infdCondAdmissionInForce = "AdmissionInForce"
	infdReasonHoldCapInForce = "HoldCapInForce"
	infdReasonNotRequested   = "NotRequested"
)

// admissionInForce decides the mode the gateway may act on.
// HoldCap is reported only once every Pod serving the Service runs a template rendered with the cap.
// Holding requests for an engine without the cap is the case to avoid, while a capped engine left unheld only loses protection.
// So every doubt reports Off.
func admissionInForce(infd *platformv1.InferenceDeployment, dep *appsv1.Deployment) (string, metav1.Condition) {
	off := func(reason, msg string) (string, metav1.Condition) {
		return platformv1.AdmissionModeOff, metav1.Condition{Type: infdCondAdmissionInForce, Status: metav1.ConditionFalse,
			Reason: reason, Message: msg, ObservedGeneration: infd.Generation}
	}
	if !holdCapRequested(infd) {
		return off(infdReasonNotRequested, "the spec asks for no admission")
	}
	if infd.Spec.Replicas == 0 {
		return off(infdReasonScaledZero, "no engine is running")
	}
	// The Deployment was written for this generation by an Update the apiserver accepted, so it is not a stale cached copy.
	if dep.Annotations[renderedGenerationAnnotation] != strconv.FormatInt(infd.Generation, 10) {
		return off(infdReasonRollout, "the Deployment has not been rendered for this generation")
	}
	if dep.Status.ObservedGeneration < dep.Generation {
		return off(infdReasonRollout, "the Deployment has not observed its current template")
	}
	if dep.Spec.Template.Annotations[admissionAnnotation] != platformv1.AdmissionModeHoldCap {
		return off(infdReasonRollout, "the current template is not rendered with the cap")
	}
	// Status.Replicas leaves out terminating Pods, so they are checked on their own where the apiserver reports them.
	// Recreate is what keeps an old Pod from serving beside the new one: it deletes every old Pod before creating any.
	s := dep.Status
	if dep.Spec.Replicas == nil || *dep.Spec.Replicas != 1 || s.Replicas != 1 || s.UpdatedReplicas != 1 || s.ReadyReplicas != 1 ||
		(s.TerminatingReplicas != nil && *s.TerminatingReplicas != 0) {
		return off(infdReasonRollout, "the capped engine is not yet the only one serving")
	}
	return platformv1.AdmissionModeHoldCap, metav1.Condition{Type: infdCondAdmissionInForce, Status: metav1.ConditionTrue,
		Reason: infdReasonHoldCapInForce, Message: "the capped engine is the only one serving", ObservedGeneration: infd.Generation}
}

// setAdmissionStatus writes the mode in force, or removes it when the spec asks for none.
func setAdmissionStatus(st *platformv1.InferenceDeploymentStatus, infd *platformv1.InferenceDeployment, mode string, cond metav1.Condition) {
	if infd.Spec.Admission == nil {
		st.Admission = nil
		meta.RemoveStatusCondition(&st.Conditions, infdCondAdmissionInForce)
		return
	}
	st.Admission = &platformv1.InferenceAdmissionStatus{Mode: mode, ObservedGeneration: infd.Generation}
	meta.SetStatusCondition(&st.Conditions, cond)
}
