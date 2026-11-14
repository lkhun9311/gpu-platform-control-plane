package controller

import (
	"encoding/json"
	"fmt"
	"slices"
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

	// renderedEngineAnnotation records on the Pod template the image and the full argument list the engine was rendered with, as JSON.
	// It is on the template so every Pod carries the engine it runs, and a benchmark row read off a Pod is traced to its flags without knowing the profile table.
	// It changes only when the container's image or args change, which restart the engine anyway.
	renderedEngineAnnotation = "platform.lkhun9311.github.io/rendered-engine"

	// holdCapPrefillThreshold is the only prefill cap measured; a field would ship an unmeasured setting.
	holdCapPrefillThreshold = 384

	// exclusiveGPULabel marks a node whose GPUs are not shared; see the node groups in infra/aws/cluster/eks.tf.
	exclusiveGPULabel = "platform.lkhun9311.github.io/gpu"
)

// renderedEngine is the value of renderedEngineAnnotation.
type renderedEngine struct {
	Image string   `json:"image"`
	Args  []string `json:"args"`
}

// vllmProfile is one measured engine configuration.
type vllmProfile struct {
	// args are the measured settings, in the order config/vllm/deployment.yaml and the pilot render them.
	// The pilot's step-logging scheduler and iteration-detail logging are absent: they only instrumented the run, and its unprotected arm carried them too.
	args []string
	// instanceTypes are the nodes the profile was measured on, so a cluster with other GPUs cannot run it under its name.
	instanceTypes []string
}

// measuredA10GArgs are the admission study's engine settings, shared by both profiles.
// cachingArg is the one setting the prefix-cache profile changes, kept apart so the two cannot drift in anything else.
func measuredA10GArgs(cachingArg string) []string {
	return []string{
		"--dtype=half",
		"--max-model-len=16384",
		"--max-num-seqs=64",
		"--gpu-memory-utilization=0.90",
		cachingArg,
		// 512, not the base manifest's 2048: the pilot replaced it (PP_BUDGET), and the measurement is the pilot's.
		"--max-num-batched-tokens=512",
		"--scheduling-policy=priority",
		"--no-async-scheduling",
	}
}

// a10gInstanceTypes are the g5 sizes that carry exactly one A10G; the measured sessions ran on g5.xlarge.
var a10gInstanceTypes = []string{"g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g5.8xlarge", "g5.16xlarge"}

var vllmProfiles = map[string]vllmProfile{
	platformv1.VLLMProfileV0271A10G: {
		args:          measuredA10GArgs("--no-enable-prefix-caching"),
		instanceTypes: a10gInstanceTypes,
	},
	// The routing study needs engines that keep shared prefixes, so caching is on and nothing else moves.
	// The CRD refuses HoldCap on this profile, because HoldCap was measured with caching off.
	platformv1.VLLMProfileV0271A10GPrefixCache: {
		args:          measuredA10GArgs("--enable-prefix-caching"),
		instanceTypes: a10gInstanceTypes,
	},
}

// vllmRelease is a vLLM release the experimental profile may run, with its flags spelled as that release accepts them.
// A newer release may rename or drop a flag, so a row is added only after its args were checked against that release's `vllm serve --help`.
type vllmRelease struct {
	// digest is the image the flags were reviewed against; the CEL rule on the spec repeats it.
	digest string
	// args are the measured A10G settings without the async-scheduling flag, which the spec chooses.
	args []string
	// asyncOn and asyncOff are this release's spelling of the two async-scheduling choices.
	asyncOn, asyncOff string
}

// experimentalReleases are the reviewed rows; the CRD enum on experimental.release and TestEveryReleaseInTheCRDHasAReviewedRow keep them equal.
var experimentalReleases = map[string]vllmRelease{
	// Spelled out rather than taken from measuredA10GArgs, so a newer row is a literal list a reviewer reads against its release.
	// TestExperimentalV0271WithAsyncOffRendersTheValidatedEngine holds this row to the validated profile.
	platformv1.VLLMReleaseV0271: {
		digest: platformv1.VLLMV0271Digest,
		args: []string{
			"--dtype=half",
			"--max-model-len=16384",
			"--max-num-seqs=64",
			"--gpu-memory-utilization=0.90",
			"--no-enable-prefix-caching",
			"--max-num-batched-tokens=512",
			"--scheduling-policy=priority",
		},
		asyncOn:  "--async-scheduling",
		asyncOff: "--no-async-scheduling",
	},
}

// engineProfile resolves the spec's engine to a rendering, or reports false for any combination nobody reviewed.
// The CRD refuses each such combination first; refusing here as well means a CRD that drifts from the table renders nothing rather than guessed flags.
func engineProfile(infd *platformv1.InferenceDeployment) (vllmProfile, bool) {
	v := infd.Spec.Engine.VLLM
	// HoldCap was measured on one profile only, so the cap is never rendered onto another.
	if holdCapRequested(infd) && v.Profile != platformv1.VLLMProfileV0271A10G {
		return vllmProfile{}, false
	}
	if v.Profile != platformv1.VLLMProfileExperimentalA10G {
		if v.Experimental != nil {
			return vllmProfile{}, false
		}
		p, ok := vllmProfiles[v.Profile]
		return p, ok
	}
	if v.Experimental == nil {
		return vllmProfile{}, false
	}
	rel, ok := experimentalReleases[v.Experimental.Release]
	if !ok || !strings.HasSuffix(infd.Spec.Image, "@"+rel.digest) {
		return vllmProfile{}, false
	}
	var async string
	switch v.Experimental.AsyncScheduling {
	case platformv1.AsyncSchedulingEnabled:
		async = rel.asyncOn
	case platformv1.AsyncSchedulingDisabled:
		async = rel.asyncOff
	default:
		return vllmProfile{}, false
	}
	// Last, where the validated profiles put --no-async-scheduling, so async off renders their argument order exactly.
	return vllmProfile{args: append(slices.Clone(rel.args), async), instanceTypes: a10gInstanceTypes}, true
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
// It returns false for a combination with no rendering, which the CRD's enums and CEL rules make unreachable and the parity tests keep so.
func mutateEngineDeployment(infd *platformv1.InferenceDeployment, dep *appsv1.Deployment) bool {
	p, ok := engineProfile(infd)
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
	args := vllmArgs(infd, p)
	// A struct of strings cannot fail to marshal, so the error carries nothing.
	rendered, _ := json.Marshal(renderedEngine{Image: infd.Spec.Image, Args: args})
	dep.Spec.Template.Annotations[renderedEngineAnnotation] = string(rendered)
	health := corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{Path: "/health", Port: intstr.FromString("http")}}
	gpu := *resource.NewQuantity(int64(infd.Spec.GPUCount), resource.DecimalSI)
	dep.Spec.Template.Spec.Containers = []corev1.Container{{
		Name: "server",
		// spec.image, which the CEL rules pin to a measured or reviewed digest, so a mirror of that digest is what runs.
		Image: infd.Spec.Image,
		Args:  args,
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
	delete(dep.Spec.Template.Annotations, renderedEngineAnnotation)
	delete(dep.Annotations, renderedGenerationAnnotation)
	// The zero strategy is defaulted back to RollingUpdate, which a generic multi-replica service relies on.
	dep.Spec.Strategy = appsv1.DeploymentStrategy{}
	dep.Spec.Template.Spec.Volumes = nil
	dep.Spec.Template.Spec.Tolerations = nil
	dep.Spec.Template.Spec.Affinity = nil
}
