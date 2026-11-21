# llm-d#3089: forwarding passthrough responses as they arrive

Issue: https://github.com/llm-d/llm-d/issues/3089.
Code: `llm-d/llm-d-router`, main at `fd30dea8`.

## Problem

A gRPC server-streaming call routed through the EPP with `passthrough-parser` reaches the client only after the backend has finished.
In the reproduction (18 messages, 80 ms apart) the first message arrives about 1,455 ms after the call through the EPP, and about 83 ms without the EPP.

The EPP decides per request whether to forward response chunks as they arrive or to hold the whole body:

- `passthrough.ParseRequest` never sets `Body.Stream`.
- `pkg/epp/handlers/server.go` copies `Body.Stream` into `modelServerStreaming` (main `:829-831`).
- At response headers only a `text/event-stream` content type turns it on (main `:866-871`).
- With it off, each response body chunk is appended to `respBody` and nothing goes back to the proxy (main `:901-905`).
- gRPC ends a response with trailers, so `finishResponse` in the trailers branch sends the whole body at once (main `:907-915`).

The buffering exists for parsers that need the complete body: the JSON parsers read usage from it and the EPP rewrites the model name in it.
`passthrough-parser` does neither, so for it the buffering only adds latency and holds the body in EPP memory.

## Options

**A. `passthrough-parser` sets `Body.Stream` for gRPC requests.**
The EPP then takes its existing streaming path.
It is a one-line change and it fixes the latency (prototype: 83 ms to first message).
It is rejected because `Body.Stream` means "the client asked for a token stream", and the streaming path acts on that meaning:
it records inter-token latency per chunk, labels TTFT as streaming, runs the model-name rewrite on every chunk, and calls the response hooks per chunk.
A unary gRPC call would be labelled as a token stream, and a gRPC message gap would be recorded as inter-token latency.
It also fixes only gRPC: a passthrough HTTP response without an event-stream content type stays buffered.

**B. The parser declares that it does not read or change the response (chosen).**
`ParseResult` gets an `OpaqueResponse` field.
When it is set, the EPP forwards each response chunk unchanged as it arrives and does not accumulate it.
Completion, termination, first-byte time, dynamic metadata and the terminal response hook still run once at the end of the response.
No token usage is invented for the opaque response.
Every other parser keeps its contract: a non-streaming response is passed to `ParseResponse` once, complete.
Delivery (forward now or hold) is separated from stream semantics (is this a token stream).

**C. The EPP treats every `application/grpc` response as a stream.**
It fixes the issue but changes the vLLM gRPC parser's contract.
`test/integration/epp` `TestFullDuplexStreamed_GRPC_KubeInferenceObjectiveRequest` cases `response buffering: multi-chunk` and `response with token usage` fail, because they pin buffering for unary vLLM gRPC responses whose usage is read from the complete message.

**D. `passthrough-parser` sets `SkipResponseProcessing`.**
The EPP then leaves the response path at the request phase.
Latency is fixed, but the EPP no longer sees the end of the response: the termination cause becomes `not observed`, no outcome is recorded, the request counts as finished when the request phase ends instead of when the response ends, and response-time dynamic metadata (for example a request cost reported to the proxy) is lost.
Schedulers that count in-flight work would under-count long streams.

## API contract (B)

```go
type ParseResult struct {
	// ...
	// OpaqueResponse reports that the parser neither reads nor rewrites the response body.
	// The EPP then forwards each response body chunk unchanged as it arrives instead of buffering the body,
	// and calls ParseResponse once, at the end of the response, with an empty body.
	// A response the EPP already streams, such as text/event-stream, is handled as a stream.
	OpaqueResponse bool
}
```

- Set by `passthrough-parser` only.
- Precedence: an event-stream response stays on the streaming path even when `OpaqueResponse` is set.
- End of response: an end-of-stream body chunk, or trailers for gRPC.
  With trailers, the EPP sends one empty body response that carries the final dynamic metadata, then the trailers response.
- Accounting for an opaque response: response size, first-byte time (recorded as TTFT with `streaming="false"`), completion time, termination cause from `grpc-status`.
  Token counts stay zero.
- Memory: the EPP holds at most the chunk it is sending; Process reads at most a fixed number of chunks ahead of a slow reader.

## Risks

- TTFT for passthrough responses changes meaning.
  On main it equals the full response time, because the first byte is recorded when the buffered body is released.
  Under B it is the time to the first response byte.
- The model-name rewrite no longer runs on passthrough response bodies.
  `passthrough-parser` sets no model name, so on main the rewrite is a no-op for it; a configuration that sets both a client and a target model name for a passthrough route would see the backend's model name.
- The empty body response at trailers time is an extra ext_proc message for gRPC.
  The unary check below shows that bytes, headers and trailers reach the client unchanged through agentgateway v1.7.0 and Envoy.
- A third-party parser opts in only by setting the field, so no existing parser changes behaviour.

## Tests

All tests use the real `passthrough-parser` and `StreamingServer.Process`.
The regression tests are synchronized: the fake proxy sends message 2 only after the EPP has sent message 1 back, so an EPP that holds the response until the trailers times out on message 1.
No test uses a sleep as its oracle; the 5 s timeouts only turn a missing response into a failure instead of a hang.

| test | what it pins | on main `fd30dea8` |
|---|---|---|
| `TestProcessForwardsPassthroughGRPCMessageBeforeBackendFinishes` | message 1 is forwarded while the backend holds message 2; request still counted as running; final dynamic metadata before trailers; one terminal hook; running gauge back to 0 | fails |
| `TestProcessPassthroughResponseProtocols` (11 cases) | unary, server streaming, zero messages, non-zero `grpc-status`, split inside the 5-byte prefix, split inside a payload, several frames per chunk, one 200 kB message, SSE with and without content type, JSON over HTTP: bytes unchanged, each chunk out before the next comes in, one terminal hook, termination cause, no usage invented, gauge back to 0, event streams keep per-chunk inter-token latency | 9 of 11 fail; zero messages and SSE with content type pass on both (controls) |
| `TestProcessPassthroughTrailersOnlyResponse` | gRPC error as headers with end of stream: no body response, one terminal hook | passes on both (control) |
| `TestProcessPassthroughDisconnectAfterFirstMessage` | client leaves after message 1: termination cause `client disconnect`, gauge back to 0 | fails |
| `TestProcessPassthroughSlowReaderBoundsReadAhead` | a slow reader stops the EPP pulling more than 3 chunks ahead | fails |
| `TestProcessPassthroughLongStreamKeepsMemoryFlat` | 66 MB streamed, live heap growth under 16 MiB | fails |
| `TestProcessNonStreamingJSONParserReceivesCompleteBody` | the OpenAI parser gets the complete body once; model name rewritten across a fragment boundary; usage recorded | passes on both (contract) |
| `TestProcessChatCompletionsSSEUsageAccounting` | chat-completions SSE forwarded per chunk with usage split across chunks | passes on both (contract) |
| `TestPassthroughParser_ParseRequest` | `passthrough-parser` sets `OpaqueResponse` | does not compile on main (field absent) |
| `test/integration/epp` `TestPassthroughGRPCServerStreamForwardsEachMessage` | same lockstep through the configured EPP and ext_proc gRPC server, with a `request-attribute-reporter` cost in the final dynamic metadata | fails ("waiting for message 1") |

Commands (router worktree, Go 1.27.4):

```
go test -race -count=1 ./pkg/epp/handlers/ ./pkg/epp/framework/plugins/requesthandling/parsers/...
KUBEBUILDER_ASSETS=<envtest 1.36.2> go test -race -count=1 ./test/integration/epp/
go test -race -count=30 -run 'TestProcess(ForwardsPassthrough|Passthrough|NonStreamingJSON|ChatCompletionsSSE)' ./pkg/epp/handlers/
make lint
KUBEBUILDER_ASSETS=<envtest 1.36.2> go test -race -count=1 ./...
```

All pass except three packages that fail identically on main because they need a prepared cluster or `helm dependency build`: `test/e2e`, `test/coordinator/e2e/coordinator`, `test/e2e/utils/standalone`.

Mutations (each applied alone to B, then `go test ./pkg/epp/handlers/ ./pkg/epp/framework/plugins/requesthandling/parsers/passthrough/`):

| mutation | failing tests |
|---|---|
| `passthrough-parser` does not set `OpaqueResponse` | the parser test, the regression test, 9 protocol cases, disconnect, slow reader, memory |
| the opaque forwarding branch is removed | the regression test, 9 protocol cases, disconnect, slow reader, memory |
| the guard is removed: every request is opaque | `TestProcessNonStreamingJSONParserReceivesCompleteBody`, 4 cases of the existing `TestProcessRetainsToolCallingTelemetryOnResponseTermination` |
| the terminal `HandleResponseBody` call for an end-of-stream opaque chunk is removed | protocol cases `JSON over HTTP` and `SSE without content type` |
| opaque takes precedence over an event stream | protocol case `SSE with content type` |

## Measurements

CPU only, one kind node (`llm-d-3089-cmp`), deleted after the runs.
The backend streams 18 messages 80 ms apart; each message carries its send time, and client and backend read the same kernel clock.

EPP images, built with `Dockerfile.epp` and tagged with their source:

- `main-fd30dea8`: main `fd30dea8`.
- `a-fd30dea8-proto`: main plus `prototype-main.patch` (option A).
- `b-867d3423`: option B.
  The B branch head is `afb0ccf3`; it differs from `867d3423` only in a test file.

Each image runs in the same rendered `llm-d-router-standalone` chart (`--v=2`), behind agentgateway v1.7.0 (`deploy/rendered-agw.yaml`) and behind the chart's Envoy v1.33.2 with HTTP/2 upstream (`deploy/rendered-envoy-h2.yaml`).
Controls: `direct` (client to the backend Service) and `agw-plain` (agentgateway v1.7.0 to the Service, no EPP).

```
./setup-cmp.sh llm-d-3089-cmp <private kubeconfig> llmd3089-grpcstream:cmp <three EPP images>
CONTROLS=1 ./compare.sh agw deploy/rendered-agw.yaml results/cmp/agw <main> <A> <B>
JSON=1 ./compare.sh agw-passthrough deploy/rendered-agw.yaml results/cmp/json-passthrough <main> <A> <B> <main> <A> <B> <main> <A> <B>
JSON=1 ./compare.sh agw-openai deploy/rendered-agw-openai.yaml results/cmp/json-openai <main> <A> <B> <main> <A> <B> <main> <A> <B>
./compare.sh envoy deploy/rendered-envoy-h2.yaml results/cmp/envoy <main> <A> <B>
python3 summarize_cmp.py results/cmp/agw results/cmp/envoy
```

`summarize_cmp.py` exits non-zero when a stream lost a message or errored, a unary digest differs from the direct call, or a JSON request failed.
It was checked to fail on a stream row with 17 messages and on a unary row with a changed digest.

### Server-streaming gRPC

Sample sizes per arm: concurrency 1 is 10 runs of 1 call, concurrency 8 is 5 runs of 8 calls (40), concurrency 32 is 5 runs of 32 calls (160).
"Before done" is the fraction of messages 1 to 17 the client received before the backend sent message 18.

| gateway | EPP | c | TTFM ms p50 | TTFM ms p95 | gap ms p50 | before done | lag of message 1 ms p50 |
|---|---|---:|---:|---:|---:|---:|---:|
| agentgateway | main | 1 | 1455.5 | 1463.6 | 0.00 | 0.000 | 1371.6 |
| agentgateway | main | 8 | 1451.8 | 1453.5 | 0.00 | 0.000 | 1368.8 |
| agentgateway | main | 32 | 1461.3 | 1474.0 | 0.00 | 0.000 | 1372.2 |
| agentgateway | A | 1 | 83.0 | 89.9 | 80.72 | 1.000 | 0.6 |
| agentgateway | A | 8 | 83.1 | 84.0 | 80.64 | 1.000 | 0.6 |
| agentgateway | A | 32 | 84.3 | 84.8 | 80.66 | 1.000 | 0.7 |
| agentgateway | B | 1 | 83.3 | 86.5 | 80.65 | 1.000 | 0.6 |
| agentgateway | B | 8 | 83.2 | 84.2 | 80.66 | 1.000 | 0.6 |
| agentgateway | B | 32 | 84.3 | 85.9 | 80.53 | 1.000 | 0.7 |
| agentgateway | none (agw-plain) | 1 | 82.7 | 94.9 | 80.70 | 1.000 | 0.4 |
| agentgateway | none (agw-plain) | 8 | 83.5 | 85.0 | 80.59 | 1.000 | 0.4 |
| agentgateway | none (agw-plain) | 32 | 82.9 | 84.9 | 80.61 | 1.000 | 0.5 |
| none (direct) | none | 1 | 82.1 | 104.6 | 80.71 | 1.000 | 0.2 |
| none (direct) | none | 8 | 82.5 | 82.7 | 80.62 | 1.000 | 0.2 |
| none (direct) | none | 32 | 82.6 | 82.8 | 80.67 | 1.000 | 0.2 |
| Envoy | main | 1 | 1453.5 | 1461.4 | 0.00 | 0.000 | 1369.3 |
| Envoy | main | 8 | 1454.5 | 1457.5 | 0.00 | 0.000 | 1370.2 |
| Envoy | main | 32 | 1458.1 | 1458.5 | 0.00 | 0.000 | 1372.4 |
| Envoy | A | 1 | 83.6 | 95.0 | 80.66 | 1.000 | 0.6 |
| Envoy | A | 8 | 84.1 | 84.7 | 80.43 | 1.000 | 0.7 |
| Envoy | A | 32 | 86.9 | 100.9 | 80.59 | 1.000 | 1.6 |
| Envoy | B | 1 | 83.8 | 90.9 | 80.64 | 1.000 | 0.6 |
| Envoy | B | 8 | 84.2 | 85.7 | 80.53 | 1.000 | 0.7 |
| Envoy | B | 32 | 87.7 | 94.1 | 80.49 | 1.000 | 1.2 |

Every call received all 18 messages.
On main every message arrives in one burst after the backend finishes, behind both gateways.
Under A and B the median first message arrives 0.3 to 5.1 ms after the no-EPP control (agw-plain for agentgateway, direct for Envoy, which has no plain-Envoy arm) and the 80 ms spacing is kept, at every concurrency.
A and B do not differ measurably in latency.

### Unary gRPC through passthrough

3 `UnaryCall`s per arm with a 100,000-byte payload; the backend sets the payload's SHA-256 as a response header and as a trailer.
Under main, A and B, behind both gateways, the 100,008-byte response message, the header and the trailer are identical to the direct call.
The empty body response B sends at trailers time does not change what the client receives.

### EPP CPU and memory

Non-streaming JSON control: 8 workers, 250 requests each (2,000 per pass), a 1 KiB OpenAI-style completion, 3 interleaved passes per image.
CPU is the EPP process's utime plus stime over the pass, read from `/proc`.
Every response body had the same SHA-256 in every arm.

| EPP config | EPP | CPU ms per request, median (min-max) | VmRSS MiB after, median (min-max) | latency ms p50 |
|---|---|---|---|---:|
| `passthrough-parser` only | main | 0.440 (0.440-0.445) | 75.0 (74.9-75.9) | 21.2 |
| `passthrough-parser` only | A | 0.485 (0.450-0.500) | 77.2 (76.9-77.6) | 21.4 |
| `passthrough-parser` only | B | 0.455 (0.445-0.535) | 75.0 (74.4-76.2) | 21.3 |
| `openai-parser` then `passthrough-parser` | main | 0.510 (0.460-0.675) | 75.4 (73.7-75.7) | 21.5 |
| `openai-parser` then `passthrough-parser` | A | 0.465 (0.455-0.475) | 74.4 (74.2-75.0) | 21.4 |
| `openai-parser` then `passthrough-parser` | B | 0.485 (0.455-0.530) | 75.6 (75.2-75.7) | 21.4 |

With the `openai-parser` config every request was parsed (EPP log `modelName: "m"` on all 664 routed requests in the B pod's log tail), so that row exercises the buffered full-body path B leaves unchanged.
With `passthrough-parser` only, the JSON response takes B's opaque path.
The differences are inside the pass-to-pass spread; at this response size neither A nor B changes EPP CPU or RSS measurably.

Streaming phase (210 calls per image, one pass): EPP CPU 2.67 to 3.00 ms per call and RSS 76 to 82 MiB for every image behind both gateways, with no ordering between images that repeats across gateways.

### Limits of these measurements

- One CPU node; client, gateway, EPP and backend share it.
- Images run one after another rather than interleaved for the streaming phase; the JSON phase is interleaved.
- The JSON body is 1 KiB, so the memory saved by not buffering a large response is shown by the unit test `TestProcessPassthroughLongStreamKeepsMemoryFlat`, not here.

## Tail latency, concurrency 128 and faults

Same cluster shape and images as above, on a new `llm-d-3089-cmp` cluster, deleted after the runs.
Tables come from `latency_dist.py` (p50, p95, p99, max per cell; p95 printed from 20 calls, p99 from 100) and `fault_summary.py`.
Calls in one run start together and their tails move together, so the run count is reported beside the call count.

```
CONTROLS=1 CELLS="1:100 8:40 32:10 128:3" ./compare.sh agw deploy/rendered-agw.yaml results/tail/agw <main> <A> <B>
CELLS="128:5" UNARY_RUNS=0 ./compare.sh agw deploy/rendered-agw.yaml results/tail/agw-c128 <main> <A> <B>
./c128-interleaved.sh deploy/rendered-agw.yaml results/tail/agw-c128-interleaved <main> <A> <B>
./c128-cold.sh deploy/rendered-agw.yaml results/tail/agw-c128-cold <B> <A>
CELLS="1:100 8:40 32:10" ./compare.sh envoy deploy/rendered-envoy-h2.yaml results/tail/envoy <main> <A> <B>
./fault.sh deploy/rendered-agw.yaml results/fault <main> <B> <A>        # repetition 1
./fault.sh deploy/rendered-agw.yaml results/fault-rep2 <main> <B> <A>   # repetition 2, adds forced-GC samples
python3 latency_dist.py results/tail/agw
python3 fault_summary.py results/fault-rep2
```

### Time to first message, agentgateway

c=1 to 32 from `results/tail/agw`; c=128 from `results/tail/agw-c128-interleaved`, where each EPP run is followed by an agw-plain run and a direct run.

| EPP | c | calls (runs) | p99 ms | p95 ms | p50 ms | max ms | gap p99 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| main | 1 | 100 (100) | 1468.8 | 1459.3 | 1454.0 | 1478.2 | 0.01 |
| main | 8 | 320 (40) | 1473.0 | 1459.6 | 1452.1 | 1473.0 | 0.01 |
| main | 32 | 320 (10) | 1478.5 | 1478.3 | 1454.0 | 1478.7 | 0.03 |
| main | 128 | 1280 (10) | 1484.6 | 1484.0 | 1457.6 | 1484.8 | 0.02 |
| B | 1 | 100 (100) | 97.1 | 91.7 | 83.2 | 101.4 | 81.13 |
| B | 8 | 320 (40) | 91.2 | 89.4 | 83.5 | 91.3 | 81.16 |
| B | 32 | 320 (10) | 86.2 | 86.2 | 84.3 | 86.2 | 81.25 |
| B | 128 | 1280 (10) | 213.3 | 211.2 | 88.8 | 213.4 | 81.35 |
| A | 1 | 100 (100) | 105.3 | 92.7 | 83.3 | 114.5 | 81.12 |
| A | 8 | 320 (40) | 99.4 | 90.8 | 83.4 | 99.5 | 81.11 |
| A | 32 | 320 (10) | 91.3 | 91.3 | 84.4 | 91.4 | 81.37 |
| A | 128 | 1280 (10) | 108.9 | 108.1 | 88.7 | 108.9 | 81.20 |
| none (agw-plain) | 1 | 100 (100) | 97.0 | 92.8 | 82.5 | 118.9 | 81.06 |
| none (agw-plain) | 8 | 320 (40) | 92.9 | 89.3 | 82.8 | 92.9 | 81.07 |
| none (agw-plain) | 32 | 320 (10) | 90.8 | 90.8 | 83.0 | 90.8 | 81.66 |
| none (agw-plain, beside B) | 128 | 1280 (10) | 119.9 | 119.7 | 85.0 | 119.9 | 81.25 |
| none (direct) | 1 | 100 (100) | 100.1 | 90.5 | 82.2 | 118.0 | 81.05 |
| none (direct) | 8 | 320 (40) | 96.5 | 90.7 | 82.3 | 96.6 | 81.06 |
| none (direct) | 32 | 320 (10) | 82.7 | 82.7 | 82.4 | 82.7 | 81.12 |
| none (direct, beside B) | 128 | 1280 (10) | 110.1 | 110.0 | 84.4 | 110.2 | 81.36 |

- p50 values recomputed from `results/cmp` with `latency_dist.py` match the published ones (agentgateway main 1455.5, 1451.8, 1461.3 ms and B 83.3, 83.2, 84.3 ms at c=1, 8, 32; Envoy main 1453.5 and B 83.8 ms at c=1).
  That earlier run had 10, 40 and 160 calls per cell, so its c=1 tail is the maximum of 10 calls; the tables here replace it.
- On main p50 and p99 both sit at the stream length (the 18th message is sent at about 1,440 ms), and every gap is under 1 ms.
- B's p99 at c=1 to 32 is between 4.6 ms below and 0.1 ms above agw-plain.
  The tail above the median is present without the EPP and without a gateway, so it comes from the shared node; it was not split further into GC and scheduling.
- c=128, B: run 1 (the first run after the EPP pod started) had all 128 calls between 210 and 213 ms; runs 2 to 10 had maxima of 88.3 to 98.8 ms (p99 over those 1,152 calls 98.7 ms; A 108.9 ms).
  `results/tail/agw-c128` (5 runs per image, no controls) also had a slow first run for B (p50 111.8 ms) and none for A.
  `c128-cold.sh` started a fresh EPP pod 6 times per image, alternating B and A: the first 128-call run's median was 97.8, 101.0, 89.6, 94.5, 96.9, 90.6 ms for B and 90.9, 93.2, 92.2, 90.0, 90.1, 90.8 ms for A; runs 2 and 3 were 86.7 to 101.1 ms for both.
  So the first burst on a fresh B pod is a few ms slower in most of these samples and was 125 ms slower once; the cause is not identified.
- c=256 is not valid here: agw-plain alone delayed 56 of 256 calls by a whole stream in each of two runs and none of 200 in two runs at c=200 (`results/tail/c256-probe`), consistent with a 200-stream limit per HTTP/2 connection (the client uses one).
  The chart's Envoy sets `max_concurrent_streams: 100`, so Envoy is measured up to c=32.
- Envoy (`results/tail/envoy`), p99 at c=1, 8, 32: main 1465.8, 1461.9, 1459.3 ms; B 96.9, 106.0, 94.3 ms; A 96.5, 109.0, 111.7 ms.
- Calls/s is set by the backend's fixed stream length (128 calls per 1.50 s run, 85 calls/s, for every arm), so it does not compare the EPPs.
- EPP CPU over the c=128-only pass (640 calls): main 0.97, A 1.19, B 1.13 ms per call; RSS after 84 to 88 MiB.
  Behind Envoy over the c=1 to 32 phase: main 3.88, A 6.73, B 6.18 ms per call; per-message forwarding sends 18 body responses per call where main sends one.

### Faults (agentgateway, `fault.sh`)

The normal consumer is 4 concurrent calls of 18 messages 80 ms apart, repeated.
Slow readers: 100 calls of 40 messages of 128 KiB, the client sleeping 1 s before each read.
Disconnect: 200 calls cancelled 400 ms after they start.
Kill: 16 calls of 40 messages, the backend process killed with SIGKILL 1.5 s in.

| | main | B | A |
|---|---|---|---|
| normal consumer alone, TTFM p50 / p95 / max (rep 1; rep 2) | 1452.3 / 1458.1 / 1462.8; 1452.6 / 1456.9 / 1459.5 | 83.2 / 90.7 / 93.2; 83.4 / 91.7 / 98.3 | 83.2 / 92.1 / 95.5; 83.6 / 92.0 / 93.6 |
| normal consumer beside 100 slow readers | 1453.8 / 1466.7 / 1467.8; 1452.6 / 1461.3 / 1462.5 | 83.8 / 94.0 / 183.8; 83.7 / 89.7 / 100.6 | 83.5 / 96.1 / 134.0; 83.6 / 90.7 / 100.3 |
| slow readers: calls with all 40 messages | 100 of 100, both reps | 100 of 100, both reps | 100 of 100, both reps |
| EPP heap in use midway through the slow readers (rep 1; rep 2) | 1176.9; 1143.1 MiB | 206.3; 379.3 MiB | 298.8; 448.5 MiB |
| disconnect: calls ended by the cancel at about 401 ms | 200 of 200, 0 messages received | 200 of 200, 4 messages received | 200 of 200, 4 or 5 messages |
| kill: calls ended with INTERNAL within 1.6 s | 16 of 16, 0 messages received | 16 of 16, 18 messages received | 16 of 16, 18 messages received |
| goroutines at base, after the last phase (rep 2) | 54, 54 | 54, 56 | 54, 54 (rep 1) |
| heap in use after a forced GC, base to end (rep 2) | 13.5 to 18.4 MiB | 14.0 to 18.8 MiB | rep 2 incomplete |
| requests without an outcome after each phase settled | 0 | 0 | 0 |

- No call reached the client's 60 s deadline, so no stream hung.
- Each completed request has one completion record: `request_outcome_total{outcome="completed"}` equals `response_size_bytes_count` after every phase, for every image.
- In rep 1 one run of 4 normal-consumer calls beside the slow readers started late under both B (up to 183.8 ms) and A (up to 134.0 ms); rep 2 had none above 101 ms.
  The p50 and p95 of the normal consumer do not move with the slow readers present.
- On main the EPP holds each slow reader's whole response (heap above 1.1 GiB midway); under A and B it holds what the gRPC flow-control windows and the 3-chunk read-ahead allow.
- With a backend killed mid-stream, A and B have already delivered the 18 messages sent before the kill; main delivers none, because it held them until the trailers.
- Accounting in the harness: a request rejected before routing (the backend restarting after the kill) records a `rejected` outcome without a `request_total` increment, so `metrics_row.py` leaves rejected outcomes out of the in-flight count.
  The first repetition's first attempt used the raw difference and reported negative in-flight counts; it was discarded and rerun.
- Rep 2's third kill hit kubelet's restart back-off on the backend pod, so A's kill phase in rep 2 has its 16 calls but no recovered phase.
- The EPP's running-requests gauge is not used: it counts only requests with a model name, and `passthrough-parser` sets none.
