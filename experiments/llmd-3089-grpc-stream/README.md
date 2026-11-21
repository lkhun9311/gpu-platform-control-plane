# llm-d#3089: gRPC server-streaming replies held until end of stream behind the EPP

Issue: https://github.com/llm-d/llm-d/issues/3089 (llm-d v1.0.0, agentgateway v1.7.0, `passthrough-parser`).
The code lives in `llm-d/llm-d-router` (tag `v1.0.0`, main at `fd30dea8`).

## Setup (CPU only, kind)

- kind cluster `llm-d-3089`, private kubeconfig, deleted after the runs.
- `backend/`: `grpc.testing.TestService/StreamingOutputCall`, 18 messages, 80 ms apart, each carrying its send time.
- `client/`: runs in a pod in the same cluster and prints time to first message (TTFM), gaps between messages, and per-message lag (receive time minus send time, same kernel clock).
- EPP: `config/charts/llm-d-router-standalone` from tag `v1.0.0`, rendered with `deploy/values-epp.yaml`.
  That is the chart's agentgateway sidecar preset with image `cr.agentgateway.dev/agentgateway:v1.7.0` and `router.epp.parsers: [passthrough-parser]`.
- Control `agw-plain`: the same agentgateway v1.7.0 image routing to the plain Service, no EPP (`deploy/agentgateway-plain.yaml`).
- Control `direct`: the client calls the Service with no gateway.
- `measure.sh` interleaves the three arms, 10 runs each.
  `summarize.py` exits non-zero if any run lost a message or errored, and it was checked to fail on a bad row.
- `swap-epp.sh` re-applies the same rendered chart with another EPP image.

## Results (10 runs per arm, medians)

| EPP build | arm | TTFM ms (min-max) | gap ms (median) | lag of message 1 ms |
|---|---|---|---:|---:|
| v1.0.0 (released image) | epp | 1454.7 (1452.5-1465.7) | 0.00 | 1371.5 |
| | agw-plain | 83.4 (81.8-92.5) | 80.60 | 0.4 |
| | direct | 82.4 (81.5-90.6) | 80.60 | 0.2 |
| main `fd30dea8` | epp | 1455.9 (1453.5-1463.1) | 0.00 | 1371.5 |
| v1.0.0 + prototype | epp | 83.3 (82.6-90.4) | 80.69 | 0.5 |
| main + prototype | epp | 83.5 (82.9-93.1) | 80.70 | 0.6 |

Controls stayed at 82-84 ms TTFM and 80.6 ms gaps in every round; raw rows are in `results/`.
Through the unpatched EPP all 18 messages arrive together about 1.45 s after the call, matching the issue.

## Mechanism

EPP trace (`--v=5`, v1.0.0) for one call: the response headers carry `content-type: application/grpc`, a response-body message reaches the EPP every ~80 ms, and `HandleResponseBody` runs once at the end with `len(responseBytes)=504, endOfStream=true` (18 frames).

- `passthrough.ParseRequest` returns a body with `Stream` unset (v1.0.0 `pkg/epp/framework/plugins/requesthandling/parsers/passthrough/passthrough.go:74-81`, main same file `:75-82`).
- The EPP copies that into `modelServerStreaming` (v1.0.0 `pkg/epp/handlers/server.go:644-646`, main `:829-831`).
- At response headers only `text/event-stream` switches it on (v1.0.0 `server.go:680-681`, main `:866-871`).
- With it off, each response body chunk is appended to `respBody` and nothing is sent back (v1.0.0 `server.go:709-713`, main `:901-905`).
- gRPC ends the stream with trailers, so `finishResponse` in the trailers branch sends the whole body in one response (v1.0.0 `server.go:715-723` and `:781-786`, main `:907-915`).

## Prototype

`prototype-main.patch`: `passthrough-parser` sets `Stream` when the request content type is gRPC, so the EPP takes its existing per-chunk path.
Only that parser changes; OpenAI, vLLM HTTP/gRPC and SGLang parsers are untouched.
`prototype-v1.0.0-measurement-only.patch` is the same logic on the release tag, used only for the measurement above.

`rejected-variant-server-content-type.patch` treats every `application/grpc` response as streaming in the EPP server.
It fixes this issue but fails `test/integration/epp` `TestFullDuplexStreamed_GRPC_KubeInferenceObjectiveRequest` cases `response buffering: multi-chunk` and `response with token usage`, which pin buffering for unary vLLM gRPC responses.

## Comparison of main, option A and option B

`design-note.md` describes the options, the chosen API (option B) and its tests, and holds the comparison results.
`setup-cmp.sh` creates the cluster, `compare.sh` runs the streaming, unary and JSON phases per EPP image, and `summarize_cmp.py` turns `results/cmp/` into the tables there.
`deploy/rendered-agw-openai.yaml` is `rendered-agw.yaml` with `openai-parser` ahead of `passthrough-parser`, for the JSON control.
`latency_dist.py`, `c128-interleaved.sh`, `c128-cold.sh` and `fault.sh` (with `metrics_row.py` and `fault_summary.py`) produce the tail-latency, concurrency-128 and fault-injection results under `results/tail/`, `results/fault/` and `results/fault-rep2/`; `design-note.md` holds the tables.
