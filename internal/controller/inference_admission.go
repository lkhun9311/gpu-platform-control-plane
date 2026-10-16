package controller

import (
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
	// dep is not a cached copy from before this generation: mutateEngineDeployment stamps every generation on it, so such a copy differs and its Update fails on resourceVersion.
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

// Reasons for the EngineInForce condition (platformv1.ConditionEngineInForce).
const (
	infdReasonEngineInForce  = "RenderedEngineInForce"
	infdReasonEngineRollout  = "RenderedEngineRolloutInProgress"
	infdReasonEngineScaled0  = "ScaledToZero"
	infdReasonEngineDegraded = "Degraded"
)

// engineInForce reports whether every Pod serving the Service runs a template this controller rendered from spec.engine.
//
// The gateway binds a tier on such a backend in Off as well as HoldCap, and a request carrying a priority to an engine
// that was not rendered with priority scheduling may be refused. So, as with HoldCap, the desired spec is not enough:
// the rendered template must have rolled out, with nothing older still serving. Every rendered template carries the
// admission annotation, HoldCap or Off; a template without it is not one this controller rendered from spec.engine.
func engineInForce(infd *platformv1.InferenceDeployment, dep *appsv1.Deployment) metav1.Condition {
	cond := func(status metav1.ConditionStatus, reason, msg string) metav1.Condition {
		return metav1.Condition{Type: platformv1.ConditionEngineInForce, Status: status, Reason: reason, Message: msg,
			ObservedGeneration: infd.Generation}
	}
	if infd.Spec.Replicas == 0 {
		return cond(metav1.ConditionFalse, infdReasonEngineScaled0, "no engine is running")
	}
	if dep.Status.ObservedGeneration < dep.Generation {
		return cond(metav1.ConditionFalse, infdReasonEngineRollout, "the Deployment has not observed its current template")
	}
	if _, rendered := dep.Spec.Template.Annotations[admissionAnnotation]; !rendered {
		return cond(metav1.ConditionFalse, infdReasonEngineRollout, "the current template is not rendered from spec.engine")
	}
	s, want := dep.Status, infd.Spec.Replicas
	if dep.Spec.Replicas == nil || *dep.Spec.Replicas != want || s.Replicas != want || s.UpdatedReplicas != want ||
		s.ReadyReplicas != want || (s.TerminatingReplicas != nil && *s.TerminatingReplicas != 0) {
		return cond(metav1.ConditionFalse, infdReasonEngineRollout, "the rendered engine is not yet the only one serving")
	}
	return cond(metav1.ConditionTrue, infdReasonEngineInForce, "every serving Pod runs the rendered engine")
}

// setEngineStatus writes the EngineInForce condition, or removes it when the spec renders no engine.
func setEngineStatus(st *platformv1.InferenceDeploymentStatus, infd *platformv1.InferenceDeployment, cond metav1.Condition) {
	if infd.Spec.Engine == nil {
		meta.RemoveStatusCondition(&st.Conditions, platformv1.ConditionEngineInForce)
		return
	}
	meta.SetStatusCondition(&st.Conditions, cond)
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
