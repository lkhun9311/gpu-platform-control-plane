package gateway

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("the hold budget in the pipeline", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`

	// One request in prefill, one held, and the next one past the tenant's share: that one is answered 503 with its
	// reason and a retry hint, never 429, which internal/bench would count as the policy shedding work.
	// Mutations that turn this red: answer the hold refusals 429, or leave SetAdmitter without wiring the budget.
	It("refuses a request past the hold limits with 503 and names the limit", func() {
		var reached atomic.Int32
		release := make(chan struct{})
		var once sync.Once
		open := func() { once.Do(func() { close(release) }) }
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			if reached.Add(1) == 1 {
				<-release
			}
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"))
		}))
		defer up.Close()
		defer open()

		s := newAdmissionServer(up.URL, tierStandard, AdmissionSerialPrefill, nil)
		s.SetAdmitter(AdmissionSerialPrefill, newSerialPrefillAdmitter(10*time.Second))
		Expect(s.SetHoldLimits(HoldLimits{Requests: 1, Bytes: 1 << 20, TenantRequests: 1, TenantBytes: 1 << 20})).To(Succeed())
		gw := httptest.NewServer(s.Handler())
		defer gw.Close()

		send := func() *http.Response {
			req, _ := http.NewRequest(http.MethodPost, gw.URL+"/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+testKey)
			resp, err := http.DefaultClient.Do(req)
			Expect(err).NotTo(HaveOccurred())
			return resp
		}

		inPrefill := make(chan *http.Response, 1)
		go func() { inPrefill <- send() }()
		Eventually(reached.Load).Should(Equal(int32(1)))
		held := make(chan *http.Response, 1)
		go func() { held <- send() }()
		Eventually(func() int64 { total, _ := s.holds().usage(testTenant); return total.requests }).Should(Equal(int64(1)))

		refused := send()
		defer func() { _ = refused.Body.Close() }()
		Expect(refused.StatusCode).To(Equal(http.StatusServiceUnavailable))
		Expect(refused.Header.Get(HeaderAdmissionReason)).To(Equal(reasonHoldTenantFull))
		Expect(refused.Header.Get("Retry-After")).NotTo(BeEmpty())
		var payload struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		raw, _ := io.ReadAll(refused.Body)
		Expect(json.Unmarshal(raw, &payload)).To(Succeed(), string(raw))
		Expect(payload.Error.Code).To(Equal(reasonHoldTenantFull))

		open()
		for _, ch := range []chan *http.Response{inPrefill, held} {
			r := <-ch
			Expect(r.StatusCode).To(Equal(http.StatusOK))
			_, _ = io.ReadAll(r.Body)
			_ = r.Body.Close()
		}
		Eventually(func() holdUsage { total, _ := s.holds().usage(testTenant); return total }).Should(Equal(holdUsage{}))
	})

	// Limits that would refuse every request that ever waits are refused, and the ones in force stay.
	// Mutation that turns this red: configure before validating.
	It("keeps the previous limits when given invalid ones", func() {
		s := &Server{}
		Expect(s.SetHoldLimits(HoldLimits{Requests: 1, Bytes: 1, TenantRequests: 1, TenantBytes: 1})).To(Succeed())
		Expect(s.SetHoldLimits(HoldLimits{})).NotTo(Succeed())
		Expect(s.holds().limits).To(Equal(HoldLimits{Requests: 1, Bytes: 1, TenantRequests: 1, TenantBytes: 1}))
	})

	// A server never configured still bounds what it holds, because an unbounded default is the failure the budget stops.
	It("holds within the default limits when none were set", func() {
		Expect((&Server{}).holds().limits).To(Equal(DefaultHoldLimits))
	})
})
