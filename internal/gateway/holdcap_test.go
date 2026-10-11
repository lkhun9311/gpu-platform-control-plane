package gateway

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"sigs.k8s.io/controller-runtime/pkg/metrics"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

var _ = Describe("holdCapTargets", func() {
	ref := func(name string, mode AdmissionMode) *BackendRef {
		return &BackendRef{Name: name, URL: &url.URL{Scheme: "http", Host: name}, Admission: mode}
	}
	names := func(refs []*BackendRef) []string {
		out := make([]string, 0, len(refs))
		for _, r := range refs {
			out = append(out, r.Name)
		}
		return out
	}
	// Mutation that must turn the third entry red: cut the list at the first tail HoldCap instead of dropping it.
	DescribeTable("a HoldCap head stands alone and a HoldCap tail entry is dropped, never entered",
		func(in []*BackendRef, want []string) {
			Expect(names(holdCapTargets(in))).To(Equal(want))
		},
		Entry("a HoldCap head alone", []*BackendRef{ref("h", AdmissionHoldCap)}, []string{"h"}),
		Entry("a HoldCap head with a spare", []*BackendRef{ref("h", AdmissionHoldCap), ref("o", "")}, []string{"h"}),
		Entry("a HoldCap backend between two plain ones", []*BackendRef{ref("a", ""), ref("h", AdmissionHoldCap), ref("c", "")}, []string{"a", "c"}),
		Entry("two HoldCap backends in the tail", []*BackendRef{ref("a", ""), ref("h1", AdmissionHoldCap), ref("h2", AdmissionHoldCap), ref("d", "")}, []string{"a", "d"}),
		Entry("a HoldCap backend last", []*BackendRef{ref("a", ""), ref("h", AdmissionHoldCap)}, []string{"a"}),
		Entry("no HoldCap backend", []*BackendRef{ref("a", ""), ref("b", "")}, []string{"a", "b"}),
	)
})

var _ = Describe("readRequestMeta's stream and choices", func() {
	parse := func(extra string) RequestMeta {
		body := `{"model":"m","messages":[{"role":"user","content":"hi"}]` + extra + `}`
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		_, meta, err := readRequestMeta(r, false)
		Expect(err).NotTo(HaveOccurred())
		return meta
	}
	// A value the gateway cannot read as a whole number is 0, so a HoldCap backend refuses it rather than guessing how many prefills it costs.
	DescribeTable("reads stream only as JSON true and n only as a whole number",
		func(extra string, stream bool, choices int) {
			meta := parse(extra)
			Expect(meta.Stream).To(Equal(stream))
			Expect(meta.Choices).To(Equal(choices))
		},
		Entry("both absent", ``, false, 1),
		Entry("streaming, two choices", `,"stream":true,"n":2`, true, 2),
		Entry("stream false", `,"stream":false`, false, 1),
		Entry("stream as a string", `,"stream":"true"`, false, 1),
		Entry("n null", `,"n":null`, false, 1),
		Entry("n written as a float", `,"n":2.0`, false, 2),
		Entry("n fractional", `,"n":1.5`, false, 0),
		Entry("n as a string", `,"n":"2"`, false, 0),
	)
})

var _ = Describe("the backend admission gauge", func() {
	now := time.Now()
	objects := func() []*platformv1.InferenceDeployment {
		return []*platformv1.InferenceDeployment{
			holdCapInfD("capped", now, platformv1.AdmissionModeHoldCap, platformv1.AdmissionModeHoldCap, 4),
			holdCapInfD("pending", now, platformv1.AdmissionModeHoldCap, platformv1.AdmissionModeOff, 4),
			holdCapInfD("plain", now, "", "", 0),
		}
	}
	const want = `
# HELP gpuaas_gateway_backend_admission_mode The admission the gateway applies to a backend, as a 1 on its mode label: hold-cap, or gateway for the process-wide mode.
# TYPE gpuaas_gateway_backend_admission_mode gauge
gpuaas_gateway_backend_admission_mode{mode="gateway",name="pending",namespace="vision"} 1
gpuaas_gateway_backend_admission_mode{mode="gateway",name="plain",namespace="vision"} 1
gpuaas_gateway_backend_admission_mode{mode="hold-cap",name="capped",namespace="vision"} 1
`
	// A deployment that asks for HoldCap before its controller reports it in force is served by the process-wide mode, and the gauge must say so.
	// Mutation that must turn this red: label from the spec's mode instead of backendAdmission.
	It("reports the mode the gateway applies, read at scrape time", func() {
		objs := objects()
		c := newBackendAdmissionCollector(newRouterClient(objs[0], objs[1], objs[2]))
		Expect(testutil.CollectAndCompare(c, strings.NewReader(want))).To(Succeed())
	})

	// The collector is only useful if the registry the /metrics handler serves holds it.
	It("is served from the gateway's registry once registered", func() {
		objs := objects()
		s := &Server{Client: newRouterClient(objs[0], objs[1], objs[2])}
		Expect(s.RegisterBackendAdmissionMetric()).To(Succeed())
		// Unregister matches by descriptor, so a second collector with no reader removes the one registered above.
		defer metrics.Registry.Unregister(newBackendAdmissionCollector(nil))
		Expect(testutil.GatherAndCompare(metrics.Registry, strings.NewReader(want), metricPrefix+"backend_admission_mode")).To(Succeed())
	})
})
