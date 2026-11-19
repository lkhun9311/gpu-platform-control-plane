# llm-d-router #2881 on main: release-then-reject

Flow control releases a request, and a few milliseconds later the concurrency-detector filter, configured with
`failOpen: false`, removes every endpoint, so the client gets `503 rejected-no-endpoints`.
This lab reproduces that on llm-d-router main and measures the alternatives on the same seeded load.

## Pins

| | |
|---|---|
| llm-d-router | `e922a7ae2538328d7ad9c87a6f391b7d0fbf313e`, which was `refs/heads/main` on 2026-11-19 11:52 UTC (checked with `git ls-remote`) |
| before #3065 | `69a3af43a9ca0dc24a300e13f887051f0578f30e`, the first parent of #3065's merge `211fbd0b` (2026-10-07), 561 commits before `e922a7ae`: comparing it with main is observational, not an A/B of #3065 alone |
| #3173 | PR head `a51390da` cherry-picked onto `e922a7ae` without conflicts, giving local commit `19a68cfe` |
| simulator | `llm-d-inference-sim` `6ab9d4b2`, the image `hack/llmd-kv-lab.sh` builds |
| cluster | one kind node `kindest/node:v1.31.12`, kind v0.33.0, built by upstream `scripts/kind-dev-env.sh` from the pinned checkout (Istio gateway, `vllm-render` tokenizer) |

Each EPP image is built from its commit's `Dockerfile.epp` and labelled with that commit; `lab.sh` refuses an image whose label differs.

## Setup

- Three simulator pods with `--max-num-seqs=4 --time-to-first-token=100ms --inter-token-latency=10ms`, random mode.
- One EPP replica, log verbosity 4 (upstream's default in this environment).
- `epp-{requests,tokens,hybrid}.yaml`: flow control on, the `concurrency-detector` as both the saturation detector and a scheduling filter, `headroom: 0`, `failOpen: false`.
  Requests mode allows 4 requests per pod.
  Tokens and hybrid modes allow 1024 tokens per pod.
  The token cost of a request is its prompt tokens (from the `token-producer`, rendered by `vllm-render`) plus its `max_tokens` (`addEstimatedOutputTokens: true`).
  These are the detector's policy units, an estimate the limit is written in; they are not KV-cache occupancy or GPU work.
- `preserve-request-id.yaml`: an EnvoyFilter that keeps the client's `x-request-id`, so a client 503 joins to the EPP log line that caused it.
  Without it the gateway replaces the id.
- `loadgen`: open-loop, seeded.
  Burst load: 40 bursts of 24 streaming chat requests, each burst spread over 20 ms, burst gaps exponential with mean 1.5 s.
  Control: 2 requests a burst with the same seed.
  It is not the burst schedule thinned out: a smaller burst takes fewer draws from the seeded source, so every burst gap after the first differs.
  Prompts are 20 to 200 words, `max_tokens` 16 to 64 with `ignore_eos`, so each request lasts 0.26 to 0.74 s.
  Seeds 1, 2 and 3 give the same arrivals, prompts and `max_tokens` in every arm of the same burst size.
  The load is built to find admission failures (24 requests in 20 ms against a 1024-token budget and fixed simulator latency); it shows they exist, not how often they occur in production.

`run.sh MODE LABEL SEED` restarts the EPP and the simulators, streams the full EPP log, snapshots EPP metrics before and after, sends the load, and records each prompt's token count from the render server.
`matrix.sh`, `alternatives.sh` and `sensitivity.sh` are the exact sequences that produced `runs/`.

## What is counted

The EPP log is scored per **attempt**: each `Flow control outcome` line opens one, and the filter, routing and failure lines that follow belong to it.
An attempt is released then rejected when it holds:

1. `Flow control outcome` with `outcome: Dispatched` (`pkg/epp/requestcontrol/admission.go`),
2. `Filter eliminated all endpoints` with `plugin: conc/concurrency-detector` (`pkg/epp/scheduling/scheduler_profile.go`).

A request is **released then rejected** when one of its attempts is, and its last attempt ends in `Failed to process request` with `ServiceUnavailable - no endpoints available` (`pkg/epp/handlers/server.go`).
The per-attempt form is there so a re-queue design, which releases one request more than once, can be scored; an earlier version keyed everything by request id, and a second release would have overwritten the first.
Every one of the 36 committed runs has exactly one attempt per request (`attempts_per_request` in each `summary.json`), so the change does not alter any count here.
`analyze.py` refuses a run where one id is received twice, because two requests' attempts could not be told apart.

In every run the count equals the client's `503 rejected-no-endpoints` count, joined by id, and the `llm_d_epp_scheduler_attempts_total{status="failure"}` delta.
No client 503 lacks those lines and no client 200 lacks its routing lines.

The per-pod load at a rejection is rebuilt from the same log: a routed request adds 1 request and its token cost to its pod when its `inflight-load-producer` PreRequest completes, and removes both at its `endOfStream` chunk.
The rebuild uses log timestamps, not the producer's counters, and it cannot see dispatch reservations.
The columns derived from it describe the rebuild:

- **a pod fit at release**: on the rebuilt load at the release log line, some pod passed the filter's test (`detector.go` `admits`) for this request, and none did at the rejection; this is consistent with requests dispatched in between taking the room, and is a label on the rebuild, not observed decision state.
- **no pod fit at release**: no pod passed the filter's test even at release, on the rebuilt load.
- **EPP-counted requests < max-num-seqs**: some pod had fewer than 4 requests counted by the EPP at the rejection.
  It is not the engine's observed state, and it does not mean a GPU or the simulator was idle.

Client-side measures:

- Percentiles are nearest-rank: the value at 1-based rank ceil(p/100 * n) of the sorted sample.
  The version at `685ddf02` documented nearest-rank but computed round(p/100 * (n-1)); re-scoring moved some TTFT and FC queue percentiles by a few milliseconds and no count (see the end of this file).
- TTFT and FC queue percentiles are over successful completions only, so an arm that rejects requests drops them from these percentiles and looks faster than it is.
  `e2e_ms_all_requests_*` covers every request, rejections included.
- **Successful completion throughput** is successful completions over first send to last completion.
  It applies no latency target, so it is not SLO goodput; earlier versions called it goodput.
- A successful completion is a 200 with no client error; records written by the current loadgen must also end with `data: [DONE]` and carry no error event or unparseable event.
  The 36 committed runs predate those fields, so for them the rule is status and client error only (`success_rule` in `summary.json`).
  As a weaker check, every one of their 20,883 200s has exactly `max_tokens + 4` `data:` lines, consistent with a full stream of one token per event plus fixed framing.
- Generated tokens are the server's `usage.completion_tokens` (`generated_tok_s`), which the committed runs did not record, so they report `null`.
  `requested_max_tokens_of_successes_per_s` is the requested `max_tokens`, labelled as requested.
- TTFT is the first stream event that carries generated text in records from the current loadgen.
  In the committed runs it is the first `data:` line, whatever it carried (`ttft_definition` in `summary.json`).
- FC queue is the `x-llm-d-flow-queue-duration-ms` response header.

## Results

Totals over seeds 1 to 3 (per-run rows: `python3 table.py runs/*`).

| arm | requests | 200 | 503 | released then rejected | a pod fit at release (rebuilt) | no pod fit at release (rebuilt) | successful completions/s by seed | FC queue p50 ms by seed | routed over the detector limit |
|---|---|---|---|---|---|---|---|---|---|
| requests, burst | 2880 | 2880 | 0 | 0 | 0 | 0 | 20.0 / 15.7 / 15.3 | 4115 / 702 / 889 | 0 |
| tokens, burst | 2880 | 1077 | 1803 | 1803 (62.6%) | 656 | 1147 | 8.8 / 6.8 / 5.1 | 0 / 0 / 0 | 3 |
| hybrid, burst | 2880 | 1567 | 1313 | 1313 (45.6%) | 133 | 1180 | 14.3 / 9.4 / 6.7 | 396 / 3 / 0 | 1 |
| each mode, control | 240 each | 240 each | 0 | 0 | - | - | 1.0 / 1.3 / 1.2 | 0 | 0 |
| requests, burst, before #3065 | 2880 | 1341 | 1539 | 1539 (53.4%) | 1539 | 0 | 9.6 / 8.0 / 7.6 | 0 / 0 / 0 | 5 |
| tokens, burst, `failOpen: true` | 2880 | 2880 | 0 | 0 | - | - | 19.5 / 15.6 / 15.2 | 4392 / 597 / 918 | 1927 |
| hybrid, burst, `failOpen: true` | 2880 | 2880 | 0 | 0 | - | - | 19.6 / 15.6 / 15.2 | 4509 / 776 / 963 | 1211 |
| tokens, burst, #3173 | 2880 | 2853 | 27 | 27 (0.9%) | 25 | 2 | 17.6 / 15.4 / 14.6 | 6800 / 1399 / 1776 | 94 |
| hybrid, burst, #3173 | 2880 | 2858 | 22 | 22 (0.8%) | 21 | 1 | 17.7 / 15.4 / 14.6 | 6769 / 1375 / 1837 | 78 |
| tokens, burst, 2048-token budget | 2880 | 1827 | 1053 | 1053 (36.6%) | 319 | 733 | 13.9 / 11.5 / 9.1 | 0 / 0 / 0 | 6 |

No run had a 429, another status, or a client error.

- Requests mode does not reproduce on main, and does on #3065's parent under the same load: 472 to 564 per run, every one labelled "a pod fit at release" with every pod at 4 or more EPP-counted requests at rejection.
  This is consistent with #3065 closing the gap for requests mode; the two builds are 561 commits apart, so it does not isolate #3065.
- Tokens and hybrid modes reproduce on main in every burst run and never in a control.
- In tokens mode 810 of 1803 rejections had a pod with fewer than 4 EPP-counted requests; in hybrid mode all 1313 did.
  That is the EPP's count of routed requests, not evidence of an idle engine or GPU.
- With `failOpen: true` nothing is rejected, but in tokens mode 1927 of 2880 routed requests took their pod over the 1024-token limit (peak 4358 tokens and 15 requests on one pod), and 1700 went past the simulator's 4 sequence slots.
- With #3173, rejections fall to 5 to 11 per run, almost all labelled "a pod fit at release", and the requests wait in flow control instead (queue p50 1.4 to 6.8 s).
- That wait costs latency and throughput against fail-open on every seed, e.g. seed 1 in tokens mode: TTFT p99 15.39 s against 10.61 s, 17.56 against 19.53 successful completions/s.
  The per-seed table of TTFT, e2e and throughput for baseline, fail-open and #3173 is in `DESIGN-RECORD.md` section 2; success-only percentiles favour the arms that reject.

Release to rejection took a median of 4.1 to 6.3 ms in tokens mode, 1.1 to 1.2 ms in hybrid mode, and 0.1 to 0.4 ms with #3173.

`runs/20261119T122136Z-tokens-burst-s1/trace-example.txt`, `runs/20261119T123357Z-hybrid-burst-s1/trace-example.txt` and `runs/20261119T125934Z-requests-burst-pre3065-s1/trace-example.txt` each follow one rejected request from client send to client 503.

## Limits of this measurement

- The rebuilt load lags the producer's counters by the gap between a counter update and its log line, and the release log line follows the saturation read it acted on.
  On 960 releases a run the rebuild put the pool at or above 1 for 0 to 1 releases in the 1024-token tokens and fail-open arms and 24 in one 2048-token run; flow control releases only below 1.
  In 1 of 1053 rejections of the 2048-token arm the rebuild says a pod fit at rejection.
- The fit split is a description of the rebuild, not a causal attribution: a request can need both the intervening dispatches and the incoming-token check to be rejected.
- Throughput is successful completion throughput, not SLO goodput, and the committed records carry neither generated-token counts nor stream terminators (see What is counted).
- One EPP replica, no subsetting header: cause 3 of the thread (#3077) is not exercised.
- The simulator, not vLLM: its slots are `--max-num-seqs`, and its latency is fixed per token.
- The burst load overloads the pool; seed 1 is the heaviest, which is why its queue waits stand apart.

## Reproduce

```
hack/llmd-2881/lab.sh up requests
hack/llmd-2881/matrix.sh && hack/llmd-2881/alternatives.sh && hack/llmd-2881/sensitivity.sh
python3 hack/llmd-2881/analyze.py hack/llmd-2881/runs/* && python3 hack/llmd-2881/table.py hack/llmd-2881/runs/*
hack/llmd-2881/lab.sh down
```

`alternatives.sh` needs `gpuaas-llmd-2881/epp:19a68cfe1099` (#3173 on main) and `gpuaas-llmd-2881/epp:69a3af43a9ca` built first.
The committed runs keep `epp-scored.log.gz`, the log lines the scoring reads; `analyze.py` re-scores them to the same `summary.json` as the full logs did.
`python3 hack/llmd-2881/test_analyze.py` and `go test ./hack/llmd-2881/loadgen/` check the per-attempt scoring, the percentile and the stream-completion rules.

## Deterministic design tests

`phase2/` holds a local test harness for llm-d-router main `e922a7ae` that compares baseline, a model of #3173, a bounded re-queue and a rank-then-reserve design around main's real detector, plus two tests of the inflight-load producer with duplicate request ids.
Apply and run it on a checkout of `e922a7ae`:

```
git apply hack/llmd-2881/phase2/lab2881-harness.patch   # in the llm-d-router checkout
LAB2881_OUT=results.json go test ./pkg/epp/framework/plugins/flowcontrol/saturationdetector/concurrency/ -run Lab2881 -v
go test ./pkg/epp/framework/plugins/requesthandling/dataproducer/inflightload/ -run Lab2881 -v
python3 hack/llmd-2881/phase2/table_p2.py results.json
```

What it found, and its limits, are in `DESIGN-RECORD.md` section 3.

## Re-scoring against `685ddf02`

The current `analyze.py` was run over all 36 committed runs and compared field by field with the summaries committed at `685ddf02`.
No status count, 503 count, released-then-rejected count, fit label, routing count or throughput changed, and every field the per-case records in `rtr-cases.jsonl.gz` had before is unchanged; each record gained `attempt`, `final_attempt` and `in_request_rtr`.
Only percentiles moved, from the percentile fix: TTFT p50 by 0.003 to 22 ms, TTFT p99 by 0.07 to 251 ms (the largest, hybrid #3173 seed 3, 5371 to 5622 ms), FC queue p50 in 4 runs by 2 to 23 ms, FC queue p99 in 14 runs by 7 to 251 ms, and release-to-rejection medians by under 0.07 ms.
Every range quoted in the public comment (release to rejection 4.1 to 6.3 ms, 1.1 to 1.2 ms, #3173 FC queue p50 1.4 to 6.8 s) still holds.
