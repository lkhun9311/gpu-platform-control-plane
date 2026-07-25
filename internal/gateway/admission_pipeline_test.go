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

// Pipeline-level admission specs: same package as proxy_test.go, reusing its testGatewayNS/testSecret/testTenant/testTenantNS/testModel fixtures, newInfD, newRouterClient, authedRequest, and expectJSONError helpers.
package gateway

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	platformv1 "github.com/lkhun9311/gpu-mlops-platform-control-plane/api/v1"
)

// eligibleLongBody is a chat-completions body whose single message is exactly 16384 characters, which readRequestMeta estimates at ceil(16384/4) = 4096 input tokens: precisely the default long-input threshold, so it belongs to the eligible standard-long population.
var eligibleLongBody = `{"model":"` + testModel + `","messages":[{"role":"user","content":"` + strings.Repeat("a", 16384) + `"}]}`

// newAdmissionServer builds a Server like newProxyServer in proxy_test.go, but with a tier annotation on the policy and a caller-supplied admission mode/admitter, so pipeline specs can drive both the tier resolution and the admission stage end to end.
func newAdmissionServer(upstream, tier string, mode AdmissionMode, admitter Admitter) *Server {
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: testSecret, Namespace: testGatewayNS},
		Data:       map[string][]byte{testKey: []byte(testTenant)},
	}
	annotations := map[string]string{}
	if tier != "" {
		annotations[tierAnnotation] = tier
	}
	policy := &platformv1.GPUQuotaPolicy{
		ObjectMeta: metav1.ObjectMeta{Name: "vision-policy", Annotations: annotations},
		Spec: platformv1.GPUQuotaPolicySpec{
			Tenant:          testTenant,
			TargetNamespace: testTenantNS,
			// A generous rate limit so no spec here accidentally hits the RPM limiter instead of admission control.
			RateLimit: &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 6000, Burst: 100},
		},
	}
	infd := newInfD("llama", testTenantNS, testModel, 8080, time.Now())

	s := &Server{
		Client:       newRouterClient(secret, policy, infd),
		Namespace:    testGatewayNS,
		APIKeySecret: testSecret,
		buckets:      newBucketRegistry(),
		mode:         mode,
		admitter:     admitter,
	}
	if upstream != "" {
		u, err := url.Parse(upstream)
		Expect(err).NotTo(HaveOccurred())
		s.backendOverride = func(string) *url.URL { return u }
	}
	s.markReady()
	return s
}

var _ = Describe("admission pipeline placement", func() {
	var up *httptest.Server

	BeforeEach(func() {
		up = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
	})
	AfterEach(func() { up.Close() })

	It("rejects an eligible standard-long request over budget with a 429 carrying code input_rate_limit", func() {
		// burst 0 leaves nothing for any weighted request to consume, so the eligible request is refused outright.
		s := newAdmissionServer(up.URL, tierStandard, AdmissionStaticCap, newStaticCapAdmitter(0, 0, 4096))
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(eligibleLongBody))
		Expect(rr.Code).To(Equal(http.StatusTooManyRequests))
		expectJSONError(rr, reasonInputRateLimit)
	})

	It("lets a premium request over the same budget reach the proxy", func() {
		s := newAdmissionServer(up.URL, tierPremium, AdmissionStaticCap, newStaticCapAdmitter(0, 0, 4096))
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(eligibleLongBody))
		// Premium is outside the eligible population, so it never touches the exhausted bucket.
		Expect(rr.Code).To(Equal(http.StatusOK))
	})

	It("lets every request through when mode is off, even one that would be rejected under static-cap", func() {
		s := newAdmissionServer(up.URL, tierStandard, AdmissionOff, offAdmitter{})
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(eligibleLongBody))
		Expect(rr.Code).To(Equal(http.StatusOK))
	})

	It("defaults to off when no admitter has been configured at all", func() {
		// A zero-value Server (nil admitter, empty mode), as every pre-admission-guard test in proxy_test.go and server_test.go builds: production and existing tests must keep behaving exactly as before this guard existed.
		s := newAdmissionServer(up.URL, tierStandard, "", nil)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, authedRequest(eligibleLongBody))
		Expect(rr.Code).To(Equal(http.StatusOK))
	})
})

// newTenantAdmissionServer is newAdmissionServer with a caller-chosen tenant/key pair instead of the shared testTenant fixture.
//
// Why this exists: metrics.Registry is controller-runtime's process-wide singleton, shared by every spec in this suite, so admission_decisions_total{tenant="team-vision",...} accumulates across all of them in whatever order Ginkgo happens to run.
//
// A tenant value no other spec in the binary uses is what makes an exact counter assertion reproducible despite that shared state; every other label (mode, model, decision, reason) is not by itself enough, since other specs share those too.
func newTenantAdmissionServer(upstream, tenant, key, tier string, mode AdmissionMode, admitter Admitter) *Server {
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: testSecret, Namespace: testGatewayNS},
		Data:       map[string][]byte{key: []byte(tenant)},
	}
	annotations := map[string]string{}
	if tier != "" {
		annotations[tierAnnotation] = tier
	}
	policy := &platformv1.GPUQuotaPolicy{
		ObjectMeta: metav1.ObjectMeta{Name: tenant + "-policy", Annotations: annotations},
		Spec: platformv1.GPUQuotaPolicySpec{
			Tenant:          tenant,
			TargetNamespace: testTenantNS,
			RateLimit:       &platformv1.GPUQuotaRateLimit{RequestsPerMinute: 6000, Burst: 100},
		},
	}
	infd := newInfD("llama", testTenantNS, testModel, 8080, time.Now())

	s := &Server{
		Client:       newRouterClient(secret, policy, infd),
		Namespace:    testGatewayNS,
		APIKeySecret: testSecret,
		buckets:      newBucketRegistry(),
		mode:         mode,
		admitter:     admitter,
	}
	if upstream != "" {
		u, err := url.Parse(upstream)
		Expect(err).NotTo(HaveOccurred())
		s.backendOverride = func(string) *url.URL { return u }
	}
	s.markReady()
	return s
}

var _ = Describe("admission metrics", func() {
	It("counts an admit decision and its input tokens under mode off", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		defer up.Close()
		const tenant, key = "metrics-admit-tenant", "metrics-admit-key"
		s := newTenantAdmissionServer(up.URL, tenant, key, tierStandard, AdmissionOff, offAdmitter{})
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(eligibleLongBody))
		r.Header.Set("Authorization", "Bearer "+key)
		s.Handler().ServeHTTP(httptest.NewRecorder(), r)

		rr := httptest.NewRecorder()
		s.MetricsHandler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/metrics", nil))
		body := rr.Body.String()

		Expect(body).To(ContainSubstring(
			`gpuaas_gateway_admission_decisions_total{decision="admit",mode="off",model="` + testModel + `",reason="",tenant="` + tenant + `"} 1`))
		Expect(body).To(ContainSubstring(
			`gpuaas_gateway_admission_input_tokens_total{decision="admit",mode="off",tenant="` + tenant + `"} 4096`))
	})

	It("counts a reject decision and its input tokens under mode static-cap", func() {
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		defer up.Close()
		const tenant, key = "metrics-reject-tenant", "metrics-reject-key"
		s := newTenantAdmissionServer(up.URL, tenant, key, tierStandard, AdmissionStaticCap, newStaticCapAdmitter(0, 0, 4096))
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(eligibleLongBody))
		r.Header.Set("Authorization", "Bearer "+key)
		s.Handler().ServeHTTP(httptest.NewRecorder(), r)

		rr := httptest.NewRecorder()
		s.MetricsHandler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/metrics", nil))
		body := rr.Body.String()

		Expect(body).To(ContainSubstring(
			`gpuaas_gateway_admission_decisions_total{decision="reject",mode="static-cap",model="` + testModel + `",reason="input_rate_limit",tenant="` + tenant + `"} 1`))
		Expect(body).To(ContainSubstring(
			`gpuaas_gateway_admission_input_tokens_total{decision="reject",mode="static-cap",tenant="` + tenant + `"} 4096`))
	})
})
