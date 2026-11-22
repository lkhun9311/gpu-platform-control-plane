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
// It exists for experiments/gateway-replica-limit and hack/gateway-shared-ratelimit.
// Both measure which requests a tenant's rate limit admitted.
// Each request goes through internal/bench's HTTPSender, so a response is judged by the benchmark harness's rule.
// The rule matters because a 200 whose stream was cut is an admitted request but not a served one.
// The loadgen this replaced drained the body, ignored the read error and counted every 200 as success.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/lkhun9311/gpu-mlops-platform-control-plane/internal/bench"
)

// chatPath is the path HTTPSender appends to its base URL.
const chatPath = "/v1/chat/completions"

// The outcomes are a closed vocabulary, so the scorer can partition rows without parsing error text.
const (
	// outcomeCompleted is a 200 whose stream sent data: [DONE] with no error, the only success.
	outcomeCompleted = "completed"
	// outcomeStreamCut is a 200 whose stream broke, stopped before [DONE], or carried an error object.
	outcomeStreamCut = "stream_cut"
	// outcomeLimited is a 429.
	outcomeLimited = "rate_limited"
	// outcome5xx is any 5xx status, which the gateway uses for an undecided limit and for backend failures.
	outcome5xx = "http_5xx"
	// outcomeHTTPOther is any other non-200 status.
	outcomeHTTPOther = "http_other"
	// outcomeTimeout is a request whose deadline expired, before or after a status arrived; the status column says which.
	outcomeTimeout = "timeout"
	// outcomeCancelled is a request in flight when the loadgen itself was interrupted.
	// It says nothing about the gateway.
	outcomeCancelled = "cancelled"
	// outcomeTransport is a connection that failed with no HTTP answer.
	outcomeTransport = "transport"
	// outcomeUnsent is a scheduled request the loadgen never dispatched because it was interrupted first.
	outcomeUnsent = "unsent"
)

type row struct {
	seq     int
	sentMs  float64
	wroteMs float64
	// ttftMs is the first content frame after dispatch, -1 when none arrived.
	ttftMs float64
	// latencyMs is dispatch to the sender's return, which covers the whole stream, -1 for an unsent row.
	latencyMs float64
	status    int
	outcome   string
	// done says the stream sent its own data: [DONE] marker.
	done bool
	// errKind is HTTPSender's ErrorKind, empty on success.
	errKind string
	// streamErr is the in-band error text or the missing-marker note, empty when there was none.
	streamErr string
}

// outcomeOf classifies one result, taking the stream verdict from bench.DispositionOf rather than from the status.
func outcomeOf(res bench.SendResult) string {
	d := bench.DispositionOf(res)
	switch {
	case d == bench.DispositionCompleted:
		return outcomeCompleted
	case d == "timeout":
		return outcomeTimeout
	case d == "cancelled":
		return outcomeCancelled
	case res.HTTPStatus == 200:
		// Every other disposition of a 200 is a stream that did not finish, including one a sender left unterminated.
		return outcomeStreamCut
	case res.HTTPStatus == 429:
		return outcomeLimited
	case res.HTTPStatus >= 500 && res.HTTPStatus <= 599:
		return outcome5xx
	case res.HTTPStatus != 0:
		return outcomeHTTPOther
	default:
		return outcomeTransport
	}
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	fs.SetOutput(stderr)
	url := fs.String("url", "", "chat completions URL, ending in "+chatPath)
	key := fs.String("key", "", "API key sent as a bearer token")
	model := fs.String("model", "", "model name in the request body")
	rate := fs.Float64("rate", 10, "requests per second")
	duration := fs.Duration("duration", 30*time.Second, "how long to send")
	timeout := fs.Duration("timeout", 10*time.Second, "deadline for one request, stream included")
	maxTokens := fs.Int("max-tokens", 16, "max_tokens in the request body")
	pinned := fs.Bool("pinned", false, "send every request over one kept-alive connection")
	out := fs.String("out", "", "TSV file to write, one row per request")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *url == "" || *key == "" || *model == "" || *out == "" || *rate <= 0 || *timeout <= 0 {
		_, _ = fmt.Fprintln(stderr,
			"loadgen: -url, -key, -model, -out, a positive -rate and a positive -timeout are required")
		return 2
	}
	base, ok := strings.CutSuffix(*url, chatPath)
	if !ok {
		_, _ = fmt.Fprintf(stderr, "loadgen: -url %q does not end in %s\n", *url, chatPath)
		return 2
	}

	conn := bench.SenderConn{CloseEachRequest: true}
	if *pinned {
		// One connection for the whole run is what makes kube-proxy pick a Pod once instead of per request.
		// The drain returns that connection to the pool after a refusal or a finished stream, so the next request can use it.
		conn = bench.SenderConn{MaxIdleConnsPerHost: 1, MaxConnsPerHost: 1, DrainForReuse: true}
	}
	// Without -pinned each request carries Connection: close.
	// So kube-proxy chooses a Pod per request, as independent clients would.
	const tenant = "loadgen"
	sender := bench.NewHTTPSender(base, *model, map[string]string{tenant: *key}, *timeout, conn)

	// An interrupt cancels what is in flight and stops dispatch, and the rows written so far still reach the file.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	n := int(*rate * duration.Seconds())
	if n < 1 {
		_, _ = fmt.Fprintln(stderr, "loadgen: -rate times -duration schedules no request")
		return 2
	}
	interval := time.Duration(float64(time.Second) / *rate)
	rows := make([]row, n)
	for i := range rows {
		rows[i] = row{seq: i, sentMs: -1, wroteMs: -1, ttftMs: -1, latencyMs: -1, outcome: outcomeUnsent}
	}
	var wg sync.WaitGroup
	start := time.Now()
	for i := range n {
		// Open loop: each send waits for its own slot, never for an earlier answer, so a slow or refused
		// request cannot lower the offered rate and quietly keep the limiter unsaturated.
		t := time.NewTimer(time.Until(start.Add(time.Duration(i) * interval)))
		select {
		case <-ctx.Done():
			t.Stop()
		case <-t.C:
		}
		if ctx.Err() != nil {
			break
		}
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sentAt := time.Now()
			tr := bench.TraceRow{Index: i, Tenant: tenant, PromptLenChars: 5, MaxOutputTokens: *maxTokens}
			res := sender.Send(ctx, tr, sentAt.UnixNano())
			r := row{
				seq:       i,
				sentMs:    ms(sentAt.Sub(start)),
				wroteMs:   -1,
				ttftMs:    -1,
				latencyMs: ms(time.Since(sentAt)),
				status:    res.HTTPStatus,
				outcome:   outcomeOf(res),
				done:      res.StreamTerminated,
				errKind:   res.ErrorKind,
				streamErr: res.StreamError,
			}
			// The write stamp stays -1 until the request is on the wire: a pinned client queues requests for its
			// one connection inside the transport, and the limiter sees the write, not the dispatch.
			if !res.TransportWriteAt.IsZero() {
				r.wroteMs = ms(res.TransportWriteAt.Sub(start))
			}
			if !res.FirstContentAt.IsZero() {
				r.ttftMs = ms(res.FirstContentAt.Sub(sentAt))
			}
			rows[i] = r
		}(i)
	}
	wg.Wait()

	if err := writeRows(*out, rows); err != nil {
		_, _ = fmt.Fprintln(stderr, "loadgen:", err)
		return 1
	}
	counts := map[string]int{}
	statuses := map[int]int{}
	for _, r := range rows {
		counts[r.outcome]++
		if r.outcome != outcomeUnsent {
			statuses[r.status]++
		}
	}
	// The first five fields keep the old line's names, and ok now means a completed stream, not a 200.
	// transport_errors stays "no HTTP status", and other is every row the first three leave.
	other := n - counts[outcomeCompleted] - counts[outcomeLimited] - statuses[0]
	_, _ = fmt.Fprintf(stdout, "sent=%d ok=%d limited=%d transport_errors=%d other=%d "+
		"status200=%d stream_cut=%d timeout=%d cancelled=%d http5xx=%d unsent=%d\n",
		n, counts[outcomeCompleted], counts[outcomeLimited], statuses[0], other, statuses[200],
		counts[outcomeStreamCut], counts[outcomeTimeout], counts[outcomeCancelled], counts[outcome5xx], counts[outcomeUnsent])
	if ctx.Err() != nil {
		return 130
	}
	return 0
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

// writeRows writes the TSV, keeping the old five columns first so earlier readers still parse it.
func writeRows(path string, rows []row) (err error) {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := f.Close(); err == nil {
			err = cerr
		}
	}()
	// A short write would drop rows the scorer counts as requests never sent, so every write is checked.
	const header = "seq\tsent_ms\twrote_ms\tstatus\terror\toutcome\tdone\tttft_ms\tlatency_ms\terror_kind"
	if _, err := fmt.Fprintln(f, header); err != nil {
		return err
	}
	for _, r := range rows {
		// The error text is the only free-form column, so tabs and newlines in it cannot break a row.
		msg := strings.NewReplacer("\t", " ", "\n", " ").Replace(r.streamErr)
		done := 0
		if r.done {
			done = 1
		}
		if _, err := fmt.Fprintf(f, "%d\t%.3f\t%.3f\t%d\t%s\t%s\t%d\t%.3f\t%.3f\t%s\n",
			r.seq, r.sentMs, r.wroteMs, r.status, msg, r.outcome, done, r.ttftMs, r.latencyMs, r.errKind); err != nil {
			return err
		}
	}
	return nil
}
