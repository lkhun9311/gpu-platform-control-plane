package controller

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/util/yaml"
	"sigs.k8s.io/controller-runtime/pkg/client"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// The refusals are the only part of the HoldCap contract the cluster keeps on its own, so each is driven through a
// real apiserver rather than read off the markers.
var _ = Describe("InferenceDeployment HoldCap validation", func() {
	ctx := context.Background()
	const rev = "aa8e72537993ba99e69dfaafa59ed015b17504d1"
	const ns = "holdcap-validation"

	BeforeEach(func() {
		err := k8sClient.Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns}})
		if err != nil {
			Expect(client.IgnoreAlreadyExists(err)).To(Succeed())
		}
	})
	AfterEach(func() {
		Expect(k8sClient.DeleteAllOf(ctx, &platformv1.InferenceDeployment{}, client.InNamespace(ns))).To(Succeed())
	})

	holdCap := func(name string) *platformv1.InferenceDeployment {
		return &platformv1.InferenceDeployment{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
			Spec: platformv1.InferenceDeploymentSpec{
				Model:    platformv1.InferenceModel{Name: "qwen", StorageURI: "hf://Qwen/Qwen2.5-3B-Instruct"},
				Image:    platformv1.VLLMV0271Image,
				GPUCount: 1,
				Replicas: 1,
				Engine: &platformv1.InferenceEngine{VLLM: &platformv1.VLLMEngine{
					Profile: platformv1.VLLMProfileV0271A10G, ModelRevision: rev}},
				Admission: &platformv1.InferenceAdmission{
					Mode: platformv1.AdmissionModeHoldCap, MaxHold: &metav1.Duration{Duration: 25 * time.Second}},
			},
		}
	}
	refused := func(obj *platformv1.InferenceDeployment, message string) {
		err := k8sClient.Create(ctx, obj)
		Expect(err).To(HaveOccurred(), "the apiserver accepted an object the rule exists to refuse")
		Expect(err.Error()).To(ContainSubstring(message))
	}
	createSample := func(file, name string) error {
		raw, err := os.ReadFile(filepath.Join("..", "..", "config", "samples", file))
		Expect(err).NotTo(HaveOccurred())
		var obj map[string]any
		Expect(yaml.Unmarshal(raw, &obj)).To(Succeed())
		u := &unstructured.Unstructured{Object: obj}
		u.SetNamespace(ns)
		u.SetName(name)
		return k8sClient.Create(ctx, u)
	}

	It("accepts the measured configuration", func() {
		Expect(k8sClient.Create(ctx, holdCap("accepted"))).To(Succeed())
	})

	// The digest is what was measured; the registry is only where it is pulled from, and the ECR mirror keeps pulls off the NAT.
	It("accepts the same digest from a mirror", func() {
		o := holdCap("mirror")
		o.Spec.Image = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mirror/vllm-openai@" + platformv1.VLLMV0271Digest
		Expect(k8sClient.Create(ctx, o)).To(Succeed())
	})

	It("refuses HoldCap without an engine it renders", func() {
		o := holdCap("no-engine")
		o.Spec.Engine = nil
		refused(o, "HoldCap requires spec.engine")
	})

	It("refuses HoldCap without a hold, and a hold without HoldCap", func() {
		o := holdCap("no-hold")
		o.Spec.Admission.MaxHold = nil
		refused(o, "maxHold is set exactly when")
		o = holdCap("hold-off")
		o.Spec.Admission.Mode = platformv1.AdmissionModeOff
		refused(o, "maxHold is set exactly when")
	})

	It("refuses a hold outside the measured range", func() {
		for _, d := range []time.Duration{500 * time.Millisecond, 26 * time.Second} {
			o := holdCap("hold-range")
			o.Spec.Admission.MaxHold = &metav1.Duration{Duration: d}
			refused(o, "between 1s and 25s")
		}
	})

	It("refuses HoldCap on more than one replica", func() {
		o := holdCap("two-replicas")
		o.Spec.Replicas = 2
		refused(o, "replicas at most 1")
	})

	// gpuCount 0 would render nvidia.com/gpu: 0 for a vLLM container, and 2 is not the profile.
	It("refuses an engine on anything but one GPU, with or without HoldCap", func() {
		for _, n := range []int32{0, 2} {
			o := holdCap("gpus")
			o.Spec.Admission = nil
			o.Spec.GPUCount = n
			refused(o, "requires gpuCount 1")
		}
	})

	It("refuses an engine whose model is not on the Hub", func() {
		o := holdCap("s3-model")
		o.Spec.Model.StorageURI = "s3://models/qwen"
		refused(o, "hf://<org>/<repo>")
	})

	// With engine set the controller renders spec.image, so a different digest would run an unmeasured engine.
	It("refuses an engine on any image but the pinned digest", func() {
		for _, img := range []string{"vllm/vllm-openai:v0.27.1", "vllm/vllm-openai@sha256:" + "00" + platformv1.VLLMV0271Digest[9:]} {
			o := holdCap("other-image")
			o.Spec.Image = img
			refused(o, "pinned to the vLLM v0.27.1 digest")
		}
	})

	It("refuses a model revision that is not a commit", func() {
		o := holdCap("short-rev")
		o.Spec.Engine.VLLM.ModelRevision = "main"
		refused(o, "modelRevision")
	})

	It("still accepts the committed legacy sample unchanged", func() {
		Expect(createSample("platform_v1_inferencedeployment.yaml", "legacy-sample")).To(Succeed())
	})

	// The digest lives in three places: the Go constant, the CEL literal and the hand-written manifest.
	// The specs above pin the first two together; this pins the manifest to them.
	It("pins the same digest the hand-written vLLM manifest runs", func() {
		raw, err := os.ReadFile(filepath.Join("..", "..", "config", "vllm", "deployment.yaml"))
		Expect(err).NotTo(HaveOccurred())
		m := regexp.MustCompile(`(?m)^\s*image:\s*(\S+)\s*$`).FindAllStringSubmatch(string(raw), -1)
		Expect(m).To(HaveLen(1))
		Expect(m[0][1]).To(Equal(platformv1.VLLMV0271Image))
	})
})
