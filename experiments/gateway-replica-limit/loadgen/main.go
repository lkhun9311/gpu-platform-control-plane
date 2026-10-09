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

// Command loadgen sends an open-loop request stream at the gateway and writes one row per request.
//
// It exists for experiments/gateway-replica-limit, where the only thing measured is which requests a tenant's
// rate limit admitted, so it records status codes and send times and nothing about latency distributions.
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
)

type row struct {
	seq    int
	sentMs float64
	status int
	errMsg string
}

func main() {
	url := flag.String("url", "", "chat completions URL")
	key := flag.String("key", "", "API key sent as a bearer token")
	model := flag.String("model", "", "model name in the request body")
	rate := flag.Float64("rate", 10, "requests per second")
	duration := flag.Duration("duration", 30*time.Second, "how long to send")
	pinned := flag.Bool("pinned", false, "send every request over one kept-alive connection")
	out := flag.String("out", "", "TSV file to write, one row per request")
	flag.Parse()
	if *url == "" || *key == "" || *model == "" || *out == "" || *rate <= 0 {
		fmt.Fprintln(os.Stderr, "loadgen: -url, -key, -model, -out and a positive -rate are required")
		os.Exit(2)
	}

	tr := &http.Transport{}
	if *pinned {
		// One connection for the whole run is what makes kube-proxy pick a Pod once instead of per request.
		tr.MaxConnsPerHost = 1
		tr.MaxIdleConnsPerHost = 1
	} else {
		// A new connection per request lets kube-proxy choose a Pod for every request, as independent clients would.
		tr.DisableKeepAlives = true
	}
	client := &http.Client{Transport: tr, Timeout: 10 * time.Second}
	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hello"}],"stream":true}`, *model)

	n := int(*rate * duration.Seconds())
	interval := time.Duration(float64(time.Second) / *rate)
	rows := make([]row, n)
	var wg sync.WaitGroup
	start := time.Now()
	for i := 0; i < n; i++ {
		// Open loop: each send waits for its own slot, never for an earlier answer, so a slow or refused
		// request cannot lower the offered rate and quietly keep the limiter unsaturated.
		time.Sleep(time.Until(start.Add(time.Duration(i) * interval)))
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sent := time.Since(start)
			r := row{seq: i, sentMs: float64(sent.Microseconds()) / 1000}
			req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, *url, bytes.NewBufferString(body))
			if err == nil {
				req.Header.Set("Authorization", "Bearer "+*key)
				req.Header.Set("Content-Type", "application/json")
				var resp *http.Response
				resp, err = client.Do(req)
				if err == nil {
					// Draining the body is what returns a kept-alive connection to the pool for the next request.
					_, _ = io.Copy(io.Discard, resp.Body)
					_ = resp.Body.Close()
					r.status = resp.StatusCode
				}
			}
			if err != nil {
				r.errMsg = err.Error()
			}
			rows[i] = r
		}(i)
	}
	wg.Wait()

	f, err := os.Create(*out)
	if err != nil {
		fmt.Fprintln(os.Stderr, "loadgen:", err)
		os.Exit(1)
	}
	fmt.Fprintln(f, "seq\tsent_ms\tstatus\terror")
	counts := map[int]int{}
	for _, r := range rows {
		fmt.Fprintf(f, "%d\t%.3f\t%d\t%s\n", r.seq, r.sentMs, r.status, r.errMsg)
		counts[r.status]++
	}
	if err := f.Close(); err != nil {
		fmt.Fprintln(os.Stderr, "loadgen:", err)
		os.Exit(1)
	}
	// Status 0 is a transport error with no HTTP answer, kept apart from every real status.
	fmt.Printf("sent=%d ok=%d limited=%d transport_errors=%d other=%d\n",
		n, counts[200], counts[429], counts[0], n-counts[200]-counts[429]-counts[0])
}
