# S2, engine half: does the engine stop when the client connection closes?

Issues #578 (simulator) and #580 (vLLM v0.27.1 on CPU). The gateway half is #572: on `client_gone` or `idle_timeout` the gateway records the cut and closes the upstream connection without a clean end, so from the engine's side the gateway is a client that went away.
This page asks what the engine does next, measured directly against the engine, not through the gateway.

## Setup

- One sequence at a time (`--max-num-seqs 1`), so a one-token probe can only be answered from a free slot.
  Each run starts with three idle probes; a probe's time to first SSE event in excess of that idle baseline is the release measure, with a 2 s threshold in every run, and the engine also has to reach idle afterwards.
- The probe must answer HTTP 200 with no SSE error and exactly one generated token; metrics need HTTP 200, both gauges and one engine; counters are read once five scrapes over one second agree.
- Cases (`abort.py`); each row is valid with its preconditions checked, or invalid with the reason, and a run with an invalid row exits non-zero:
  - `control` streams to `[DONE]` and must produce the full token count;
  - `busy_control` probes while a stream still runs and must not count as released, so a probe cannot overtake a running request; a run where it does fails;
  - `stream_cut` closes after five SSE events, valid only while the stream is still open;
  - `plain_cut` closes a non-streamed request one second in, valid only if it was running and no response had arrived;
  - `prefill_baseline` sends a long prompt (1,500 words behind a nonce, so never a prefix-cache hit) uncut and records its prompt tokens and time to first SSE event;
  - `prefill_cut` sends it again and closes at 0.4 of that time, valid only if no SSE event had arrived and the probe then waited at least 0.1 s past the baseline, which shows the engine was occupied by the request;
  - `queued_cut` queues a request behind a holder, closes it while it waits, and counts as released only if the holder still delivered at least five events after the queue cleared, since the waiting gauge also falls when a queued request starts.
- Simulator: `run.sh <sim-commit> <out.jsonl> [reps [abort.py options]]`, 100 ms per token, 100 ms to first token unless `SIM_TTFT` sets it, 50 tokens.
- vLLM: `run-vllm-cpu.sh <out.jsonl> [reps]`, `vllm/vllm-openai-cpu` pinned by digest, the vLLM version read inside the container (0.27.1), `Qwen/Qwen2.5-0.5B-Instruct` at a pinned revision, 300 tokens; the server log is kept beside the rows.
- Both pick a free port, refuse a port answered by anything but the engine they started, and write `<out>.manifest.json`; all four manifests name harness commit `ceec7bb3`, clean.

## Result (2026-11-15, three repetitions per cell, 54 rows, all valid)

| engine | case | probe excess over idle | released | generation counter delta | success counter delta |
|---|---|---:|---|---:|---|
| vLLM 0.27.1 CPU | control (11.3 to 12.1 s) | −0.047 to 0.008 s | 3 of 3 | 301 | 2 × `length` |
| vLLM 0.27.1 CPU | busy_control | 11.16 to 11.50 s | 0 of 3, as required | 301 | 2 × `length` |
| vLLM 0.27.1 CPU | stream_cut | 0.021 to 0.023 s | 3 of 3 | 5 | 1 × `length` |
| vLLM 0.27.1 CPU | plain_cut | −0.045 to 0.018 s | 3 of 3 | 24, 28, 29 | 1 × `length` |
| vLLM 0.27.1 CPU | prefill_cut (cut 0.19 to 0.21 s; uncut first event 0.47 to 0.52 s; 1,548 prompt tokens) | 0.278 to 0.290 s | 3 of 3 | 1 | 1 × `length` |
| vLLM 0.27.1 CPU | queued_cut | queue cleared 0.035 to 0.089 s after the cut; holder then sent 295 to 297 more events | 3 of 3 | 301 | 2 × `length` |
| simulator main `4361040` | stream_cut | 0.300 to 0.301 s | 3 of 3 | 1 | 1 × `length` |
| simulator main | plain_cut | 4.008 to 4.009 s | 0 of 3 | 51 | 2 × `length` |
| simulator main | prefill_cut (cut 0.04 s, first event at 0.10 s) | 0.160 s | 3 of 3 | 1 | 1 × `length` |
| simulator main | queued_cut | queue cleared 4.93 s, with no holder event after it | 0 of 3 | 51 | 2 × `length` |
| simulator main, 5 s to first token | prefill_cut (cut 2.0 s) | 3.099 to 3.100 s | 0 of 3 | 1 | 1 × `length` |
| simulator before #815, `ee5597e` | stream_cut | 4.609 s | 0 of 3 | 51 | 2 × `length` |

Deltas include the probe (1 token, 1 `length`) and, for `control`, `busy_control` and `queued_cut`, the uncut request (300 or 50 tokens, 1 `length`).
In every run every `control` released and every `busy_control` did not, with the same 2 s threshold.

- On vLLM 0.27.1 on CPU, closing the connection stopped the request in every case tried: a running stream, a running non-streamed request, a request cut before its first SSE event, and a queued one. A probe sent right after the cut was answered within 0.023 s of an idle engine's time for the running cuts and within 0.290 s for the cut before the first event; a queued request left the queue within 0.089 s while the request ahead of it kept running.
- The cut before the first event delayed the probe by about the rest of the uncut time to first event (0.47 to 0.52 s less the 0.19 to 0.21 s already spent). That fits the engine finishing the work it had started for the request and then stopping; which phase that work was in is not something these rows show.
- On vLLM no cut added to `vllm:request_success_total`, `finished_reason="abort"` included; every success delta is the probe's and the holder's. Tokens produced before the cut did reach `vllm:generation_tokens_total` (4 for `stream_cut`; 23, 27 and 28 for `plain_cut`), so the generation counter shows what was reported, not a complete count of the work done. In the v0.27.1 source the output processor drops an aborted request's state before the statistics that feed the success counter, which explains this; that part is reading, not measurement.
- The simulator behaves like vLLM only for a running streamed cut, and notices it about three tokens late. It keeps a non-streamed request to the end, keeps a queued one in the queue until it would start, and notices a cut before the first event only after its first output, about the rest of the time to first token later; llm-d/llm-d-inference-sim#815 documents the same limits. A streamed request it aborts adds no tokens to its counters; one it runs to the end adds all of them.
- Each case was seen not to release where the engine keeps the request, with the same script and threshold: the simulator before #815 for `stream_cut`, current main for `plain_cut` and `queued_cut`, and a 5 s first token for `prefill_cut`.

## What this licenses and what it does not

- It licenses, for vLLM 0.27.1 on CPU with one sequence: when the client connection closes, which is what the gateway does on `client_gone` and `idle_timeout`, the engine was free for the next request within the times above in every case tried.
- It does not measure a GPU. The cancellation path is the engine's frontend and scheduler code and is expected to carry over, but GPU builds differ in async scheduling, batching and step length, which can change how much is produced after a cut and how long release takes; a time promised for production needs the production configuration measured.
- It does not go through the gateway; requests went straight to the engine on fresh HTTP/1.1 sockets.
- One model and one sequence: with several sequences a cut frees one seat in a batch, not the engine.
- On counting: a request cut by its client did not appear in `vllm:request_success_total` in any run here, so that counter cannot show how many were cut. The gateway's `gpuaas_gateway_responses_cut_short_total{tenant,model,cause}` (#572, `docs/05_LLM_SERVING_GATEWAY.md`) counts responses that had started and then ended early, including `upstream_aborted`. Because vLLM can send a streamed response's headers before its first token, whether a given cut is in that counter depends on whether the response had started at the gateway, not on the engine phase; that was not measured here.
- The simulator stands in for vLLM only for a running streamed cut; anything that cuts non-streamed, queued or pre-first-event requests needs vLLM.
