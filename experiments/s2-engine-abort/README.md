# S2, engine half: does the engine stop when the client connection closes?

Issues #578 (simulator) and #580 (vLLM v0.27.1 on CPU). The gateway half is #572: on `client_gone` or `idle_timeout` the gateway records the cut and closes the upstream connection without a clean end, so from the engine's side the gateway is a client that went away.
This page asks what the engine does next.

## Setup

- One sequence at a time (`--max-num-seqs 1`), so a one-token probe can only be answered from a free slot.
  Each run starts with three idle probes; release is judged on a probe's time to first SSE event in excess of that idle baseline, and the engine also has to reach idle afterwards.
- The probe has to answer HTTP 200, carry no SSE error and finish with one `length`; metrics need HTTP 200, both gauges, and one engine; counters are read once two scrapes 0.2 s apart agree.
- Cases (`abort.py`), each row either valid with its preconditions checked or invalid with the reason:
  - `control` reads a stream to `[DONE]` and records its duration;
  - `busy_control` probes while a stream is still running, which must not count as released, or the probe could overtake a request;
  - `stream_cut` closes after five SSE events;
  - `plain_cut` closes one second into a non-streamed request;
  - `prefill_baseline` sends the long prompt (1,500 words behind a nonce, so never a prefix-cache hit) uncut and records its prompt tokens and time to first event;
  - `prefill_cut` sends it again and closes at 0.4 of that time, valid only if no SSE event had arrived and the probe then waited past the baseline, which shows the engine was working on it;
  - `queued_cut` queues a request behind a holder drained and timed on its own thread and closes it while it waits; it is released only if the queue clears while the holder still runs, since the waiting gauge also falls when a request starts.
- Simulator: `run.sh <sim-commit> <out.jsonl> [reps [abort.py options]]`, 100 ms per token and to first token (`SIM_TTFT` overrides the latter), 50 tokens.
- vLLM: `run-vllm-cpu.sh <out.jsonl> [reps]`, `vllm/vllm-openai-cpu` v0.27.1 pinned by digest, `Qwen/Qwen2.5-0.5B-Instruct`, 300 tokens, a 2 s release threshold.
- Both pick a free port, refuse a port answered by anything but the engine they started, and write `<out>.manifest.json` with the engine, model revision, arguments and the harness commit; every manifest here names `dded6aa1`, clean.

## Result (2026-11-14, three repetitions per cell, all rows valid)

| engine | case | probe excess over idle | released | generation counter delta | success counter delta |
|---|---|---:|---|---:|---|
| vLLM v0.27.1 CPU | control (11.2 s) | 0.000 s | yes | 301 | 2 × `length` |
| vLLM v0.27.1 CPU | busy_control | 11.08 to 11.14 s | no, as required | 301 | 2 × `length` |
| vLLM v0.27.1 CPU | stream_cut | 0.064 to 0.067 s | yes | 5 | 1 × `length` |
| vLLM v0.27.1 CPU | plain_cut | 0.043 to 0.063 s | yes | 29 to 30 | 1 × `length` |
| vLLM v0.27.1 CPU | prefill_cut (cut 0.19 s, uncut first event 0.47 to 0.48 s, 1,548 prompt tokens) | 0.281 to 0.338 s | yes | 1 | 1 × `length` |
| vLLM v0.27.1 CPU | queued_cut | queue cleared 0.066 to 0.103 s, holder ran 11.1 s more | yes | 301 | 2 × `length` |
| simulator main `4361040` | stream_cut | 0.301 s | yes | 1 | 1 × `length` |
| simulator main | plain_cut | 4.01 s | no | 51 | 2 × `length` |
| simulator main | queued_cut | queue cleared 4.93 s, with the holder | no | 51 | 2 × `length` |
| simulator main, 3 s to first token | prefill_cut (cut 1.2 s) | 1.90 s | no | 1 | 1 × `length` |
| simulator before #815, `ee5597e` | stream_cut | 4.61 s | no | 51 | 2 × `length` |

Each delta includes the probe (1 token, 1 `length`) and, for `control`, `busy_control` and `queued_cut`, the uncut request (300 or 50 tokens, 1 `length`).
`busy_control` was not released in any run on either engine, and every control was.

- On vLLM v0.27.1 on CPU, a request whose client closes is stopped whether it was streamed or not, running, in prefill or waiting in the queue. A probe sent right after the cut got the slot within 0.07 s of an idle engine for running requests, within 0.34 s for a cut during prefill, and a queued request left the queue within 0.10 s while the request ahead of it kept running for another 11 s.
- A cut during prefill delayed the probe by 0.28 to 0.34 s, about the 0.47 s prefill less the 0.19 s already spent; this is consistent with the prefill already running being finished or interrupted at a step boundary, and the rows do not say which.
- No cut on vLLM added to `vllm:request_success_total`, `finished_reason="abort"` included: the success delta is the probe's and the holder's only. Tokens a cut request had already produced did reach `vllm:generation_tokens_total` (4 for `stream_cut`, 28 or 29 for `plain_cut`, beyond the probe's). v0.27.1's output processor drops an aborted request's state before the finished-request statistics that feed the success counter, which explains the gap; that is a reading of the source, not a measurement.
- The simulator matches vLLM for a running streamed request only. It keeps a non-streamed request to the end, keeps a queued one until it would start, and notices a cut before the first token only at its first write, as llm-d/llm-d-inference-sim#815 documents. It also adds a cut request's tokens to no counter, so its zero deltas are accounting, not proof that nothing was generated.
- Each case was seen to fail where an engine does not release, with the same script: the simulator before #815 for `stream_cut`, current main for `plain_cut` and `queued_cut`, and a 3 s first token for `prefill_cut`.

## What this licenses and what it does not

- It licenses, for vLLM v0.27.1 on CPU with one sequence: closing the connection, which is what the gateway does on `client_gone` and `idle_timeout`, frees the engine for the next request in the observed times above, in every case tried.
- It does not measure a GPU. The cancellation path is the engine's frontend and scheduler code and is expected to carry over, but that is an expectation: a GPU build's async scheduling, batching and step lengths can change how much is produced after a cut and how long release takes, and the production configuration has to be measured before a time is promised.
- It does not go through the gateway; requests went straight to the engine on fresh HTTP/1.1 sockets. The gateway closing its upstream connection is #572's measurement.
- One model and one sequence: with several sequences a cut frees one seat in a batch, not the engine.
- On counting: a request cut by its client never reaches `vllm:request_success_total`, so that counter alone does not show how many requests were cut. The gateway's `gpuaas_gateway_responses_cut_short_total{tenant,model,cause}` (#572, `docs/05_LLM_SERVING_GATEWAY.md`) counts only responses that had started and then ended early, including `upstream_aborted`; a request cut before its response started, such as a queued or in-prefill one, is in neither.
- The simulator stands in for vLLM only for a running streamed cut; anything that cuts non-streamed, queued or pre-first-token requests needs vLLM.
