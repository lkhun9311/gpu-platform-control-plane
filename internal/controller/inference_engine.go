package controller

import (
	"fmt"
	"strconv"
	"strings"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/util/intstr"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

const (
	// admissionAnnotation records on the Pod template which admission its arguments were rendered for.
	// The status gate reads it to tell a capped template from an uncapped one without parsing arguments.
	admissionAnnotation = "platform.lkhun9311.github.io/admission"

	// renderedGenerationAnnotation records on the Deployment which InferenceDeployment generation it was last rendered for.
	// Writing it on every new generation forces an Update, which a stale cached Deployment loses on its resourceVersion.
	// Without it, a cache still holding an older capped Deployment could make a turn from Off back to HoldCap look already rolled out.
	// It lives on the Deployment's metadata, not the template, so a change that does not touch the engine does not restart it.
	renderedGenerationAnnotation = "platform.lkhun9311.github.io/rendered-generation"

	// holdCapPrefillThreshold is the only prefill cap measured; a field would ship an unmeasured setting.
	holdCapPrefillThreshold = 384

	// exclusiveGPULabel marks a node whose GPUs are not shared; see the node groups in infra/aws/cluster/eks.tf.
	exclusiveGPULabel = "platform.lkhun9311.github.io/gpu"
)

// vllmProfile is one measured engine configuration.
type vllmProfile struct {
	// args are the measured settings, in the order config/vllm/deployment.yaml and the pilot render them.
	// The pilot's step-logging scheduler and iteration-detail logging are absent: they only instrumented the run, and its unprotected arm carried them too.
	args []string
	// instanceTypes are the nodes the profile was measured on, so a cluster with other GPUs cannot run it under its name.
	instanceTypes []string
}

var vllmProfiles = map[string]vllmProfile{
	platformv1.VLLMProfileV0271A10G: {
		args: []string{
			"--dtype=half",
			"--max-model-len=16384",
			"--max-num-seqs=64",
			"--gpu-memory-utilization=0.90",
			"--no-enable-prefix-caching",
			// 512, not the base manifest's 2048: the pilot replaced it (PP_BUDGET), and the measurement is the pilot's.
			"--max-num-batched-tokens=512",
			"--scheduling-policy=priority",
			"--no-async-scheduling",
		},
		// The g5 sizes that carry exactly one A10G; the measured sessions ran on g5.xlarge.
		instanceTypes: []string{"g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g5.8xlarge", "g5.16xlarge"},
	},
}

// holdCapRequested reports whether the spec asks for HoldCap.
func holdCapRequested(infd *platformv1.InferenceDeployment) bool {
	return infd.Spec.Admission != nil && infd.Spec.Admission.Mode == platformv1.AdmissionModeHoldCap
}

// vllmArgs renders the engine's command line: the Hub repository, the profile, the routing names and the pinned revision.
// The CEL rule on the spec guarantees the hf:// form, so the prefix is only removed here.
func vllmArgs(infd *platformv1.InferenceDeployment, p vllmProfile) []string {
	rev := infd.Spec.Engine.VLLM.ModelRevision
	args := append([]string{strings.TrimPrefix(infd.Spec.Model.StorageURI, "hf://")}, p.args...)
	args = append(args,
		fmt.Sprintf("--port=%d", servingPort(infd)),
		"--served-model-name="+infd.Spec.Model.Name,
		"--revision="+rev,
		"--tokenizer-revision="+rev,
	)
	if holdCapRequested(infd) {
		args = append(args, fmt.Sprintf("--long-prefill-token-threshold=%d", holdCapPrefillThreshold))
	}
	return args
}

// admissionLabel is the annotation value for the rendered template, decided by the same test that decided the cap.
func admissionLabel(infd *platformv1.InferenceDeployment) string {
	if holdCapRequested(infd) {
		return platformv1.AdmissionModeHoldCap
	}
	return platformv1.AdmissionModeOff
}

// mutateEngineDeployment renders the pinned engine onto the Deployment.
// It returns false for a profile with no rendering, which the CRD's enum makes unreachable and TestEveryProfileInTheCRDHasARendering keeps so.
func mutateEngineDeployment(infd *platformv1.InferenceDeployment, dep *appsv1.Deployment) bool {
	p, ok := vllmProfiles[infd.Spec.Engine.VLLM.Profile]
	if !ok {
		return false
	}
	if dep.Annotations == nil {
		dep.Annotations = map[string]string{}
	}
	dep.Annotations[renderedGenerationAnnotation] = strconv.FormatInt(infd.Generation, 10)
	// Recreate, so a capped and an uncapped engine never serve behind the Service at the same time.
	dep.Spec.Strategy = appsv1.DeploymentStrategy{Type: appsv1.RecreateDeploymentStrategyType}
	if dep.Spec.Template.Annotations == nil {
		dep.Spec.Template.Annotations = map[string]string{}
	}
	dep.Spec.Template.Annotations[admissionAnnotation] = admissionLabel(infd)
	health := corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromString("http")}}
	gpu := *resource.NewQuantity(int64(infd.Spec.GPUCount), resource.DecimalSI)
	dep.Spec.Template.Spec.Containers = []corev1.Container{{
		Name: "server",
		// spec.image, which the CEL rule pins to the measured digest, so a mirror of that digest is what runs.
		Image: infd.Spec.Image,
		Args:  vllmArgs(infd, p),
		Ports: []corev1.ContainerPort{{Name: "http", ContainerPort: servingPort(infd)}},
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{nvidiaGPUResource: gpu},
			Limits:   corev1.ResourceList{nvidiaGPUResource: gpu},
		},
		VolumeMounts: []corev1.VolumeMount{
			{Name: "dshm", MountPath: "/dev/shm"},
			{Name: "hf-cache", MountPath: "/root/.cache/huggingface"},
		},
		// Weights download and memory profiling take minutes, so startup is split from readiness as in config/vllm/deployment.yaml.
		StartupProbe:   &corev1.Probe{ProbeHandler: health, PeriodSeconds: 10, FailureThreshold: 90},
		ReadinessProbe: &corev1.Probe{ProbeHandler: health, PeriodSeconds: 5},
	}}
	shm := resource.MustParse("1Gi")
	dep.Spec.Template.Spec.Volumes = []corev1.Volume{
		// The engine's ring buffer needs more than a container's default 64 MiB /dev/shm.
		{Name: "dshm", EmptyDir: &corev1.EmptyDirVolumeSource{Medium: corev1.StorageMediumMemory, SizeLimit: &shm}},
		{Name: "hf-cache", EmptyDir: &corev1.EmptyDirVolumeSource{}},
	}
	// Matches the taint infra/aws/cluster/eks.tf puts on the GPU node groups.
	dep.Spec.Template.Spec.Tolerations = []corev1.Toleration{{
		Key: "nvidia.com/gpu", Operator: corev1.TolerationOpEqual, Value: "present", Effect: corev1.TaintEffectNoSchedule,
	}}
	dep.Spec.Template.Spec.Affinity = &corev1.Affinity{NodeAffinity: &corev1.NodeAffinity{
		RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{NodeSelectorTerms: []corev1.NodeSelectorTerm{{
			MatchExpressions: []corev1.NodeSelectorRequirement{
				{Key: corev1.LabelInstanceTypeStable, Operator: corev1.NodeSelectorOpIn, Values: p.instanceTypes},
				// The sharing node group is the same A10G advertised as several nvidia.com/gpu, so one of them is not the whole card the profile's 0.90 memory share assumes.
				// Only the exclusive GPU groups in infra/aws/cluster/eks.tf carry this label.
				{Key: exclusiveGPULabel, Operator: corev1.NodeSelectorOpIn, Values: []string{"true"}},
			},
		}}},
	}}
	return true
}

// clearEngineResidue removes what mutateEngineDeployment set, when a Deployment it rendered goes back to the generic container.
// Only a template carrying the annotation is touched, so a legacy Deployment keeps whatever else manages it.
func clearEngineResidue(dep *appsv1.Deployment) {
	if _, rendered := dep.Spec.Template.Annotations[admissionAnnotation]; !rendered {
		return
	}
	delete(dep.Spec.Template.Annotations, admissionAnnotation)
	delete(dep.Annotations, renderedGenerationAnnotation)
	// The zero strategy is defaulted back to RollingUpdate, which a generic multi-replica service relies on.
	dep.Spec.Strategy = appsv1.DeploymentStrategy{}
	dep.Spec.Template.Spec.Volumes = nil
	dep.Spec.Template.Spec.Tolerations = nil
	dep.Spec.Template.Spec.Affinity = nil
}
