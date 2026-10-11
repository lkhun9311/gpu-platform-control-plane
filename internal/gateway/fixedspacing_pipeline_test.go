package gateway

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("the fixed-spacing admitter in the pipeline", func() {
	body := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hello"}],"stream":true}`

	// The second standard request reaches the engine one spacing after the first, although the first has sent no
	// content at all: the control's clock does not wait for the engine, which is the whole of its difference.
	// Mutation that turns this red: admit a standard request without waiting out the spacing.
	It("forwards the next standard request one spacing after the previous, without waiting for its content", func() {
		const spacing = 300 * time.Millisecond
		var mu sync.Mutex
		var reached []time.Time
		release := make(chan struct{})
		up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			mu.Lock()
			reached = append(reached, time.Now())
			n := len(reached)
			mu.Unlock()
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			if n == 1 {
				<-release
			}
			_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n"))
		}))
		defer up.Close()
		f := newFixedSpacingAdmitter(spacing, 10*time.Second)
		gw := httptest.NewServer(newAdmissionServer(up.URL, tierStandard, AdmissionFixedSpacing, f).Handler())
		defer gw.Close()
		// Deferred last so it runs first: the gateway's Close waits for the first stream, which waits for this.
		defer close(release)
		send := func() {
			req, _ := http.NewRequest(http.MethodPost, gw.URL+"/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+testKey)
			resp, err := http.DefaultClient.Do(req)
			Expect(err).NotTo(HaveOccurred())
			go func() { _, _ = io.Copy(io.Discard, resp.Body); _ = resp.Body.Close() }()
		}
		go send()
		Eventually(func() int { mu.Lock(); defer mu.Unlock(); return len(reached) }, "2s").Should(Equal(1))
		go send()
		Eventually(func() int { mu.Lock(); defer mu.Unlock(); return len(reached) }, "2s").Should(Equal(2),
			"the second contender never reached the engine while the first had sent no content")
		mu.Lock()
		gap := reached[1].Sub(reached[0])
		mu.Unlock()
		Expect(gap).To(BeNumerically(">=", spacing-20*time.Millisecond))
		Expect(gap).To(BeNumerically("<", spacing+150*time.Millisecond))
	})
})
