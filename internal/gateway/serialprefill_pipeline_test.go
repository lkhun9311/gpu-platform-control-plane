package gateway

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("the serial-prefill admitter in the pipeline", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`

	// The second standard request reaches the engine only once the first one's response has sent a body byte, the
	// gateway's sign that its prefill is done.
	// Mutation that turns this red: release the prefill on the status line instead of the first body byte.
	It("forwards the next standard request only after the previous one's first body byte", func() {
		var reached atomic.Int32
		release := make(chan struct{})
		var once sync.Once
		open := func() { once.Do(func() { close(release) }) }
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			n := reached.Add(1)
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			if n == 1 {
				<-release
			}
			_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"))
			w.(http.Flusher).Flush()
		}))
		defer up.Close()
		defer open()
		s := newSerialPrefillAdmitter(10e9)
		gw := httptest.NewServer(newAdmissionServer(up.URL, tierStandard, AdmissionSerialPrefill, s).Handler())
		defer gw.Close()

		send := func() *http.Response {
			req, _ := http.NewRequest(http.MethodPost, gw.URL+"/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+testKey)
			resp, err := http.DefaultClient.Do(req)
			Expect(err).NotTo(HaveOccurred())
			return resp
		}
		first := send()
		defer func() { _ = first.Body.Close() }()
		Expect(first.StatusCode).To(Equal(http.StatusOK))

		done := make(chan *http.Response, 1)
		go func() { done <- send() }()
		Consistently(func() int32 { return reached.Load() }, "200ms").Should(Equal(int32(1)),
			"the second standard request reached the engine while the first had sent only its status line")

		open()
		_, _ = io.ReadAll(first.Body)
		second := <-done
		defer func() { _ = second.Body.Close() }()
		Expect(second.StatusCode).To(Equal(http.StatusOK))
		Expect(reached.Load()).To(Equal(int32(2)))
	})
})
