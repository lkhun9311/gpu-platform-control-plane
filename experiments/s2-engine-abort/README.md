# S2, engine half: does the engine stop when the client connection closes?

Issues #578 (simulator) and #580 (vLLM v0.27.1 on CPU). The gateway half is #572: on `client_gone` or `idle_timeout` the gateway records the cut and closes the upstream connection without a clean end, so from the engine's side the gateway is a client that went away.
This page asks what the engine does next, measured directly against the engine, not through the gateway.

## Setup

- One sequence at a time (`--max-num-seqs 1`), so a one-token probe can only be answered from a free slot.
  Each run starts with three idle probes. The measure is a probe's time to first SSE event in excess of that idle baseline, so it is a delay relative to an idle engine, not a time from the cut to release.
  A row counts as released when that excess, the probe's completion in excess of the baseline, and the time from the probe's completion to idle are all under 2 s, the same threshold in every run.
- The probe must answer HTTP 200 with no SSE error and exactly one generated token; metrics need HTTP 200, both gauges, one engine and every sample parsed; counters are read once five scrapes over one second agree, a heuristic window rather than a guarantee that no later update exists.
- Cases (`abort.py`); each row is valid with its preconditions checked, or invalid with the reason, and a run with an invalid row exits non-zero:
  - `control` streams to `[DONE]` and must produce the full token count;
  - `busy_control` probes while a stream still runs and must not count as released, so a probe cannot overtake a running request; a run where it does fails;
  - `stream_cut` closes after five SSE events, valid only if the stream is open with no finish reason yet;
  - `plain_cut` closes a non-streamed request one second in, valid only if it was running and not a byte of response had arrived;
  - `prefill_baseline` sends a long prompt (1,500 words behind a nonce, so never a prefix-cache hit) uncut and records its prompt tokens and time to first SSE event;
  - `prefill_cut` sends it again and closes at 0.4 of that time, valid only if no SSE event had arrived and the probe then waited at least 0.1 s past the baseline;
  - `queued_cut` queues a request behind a holder and closes it while it waits; it counts as removed only if the queue cleared within 2 s and the holder still delivered at least five events afterwards, since the waiting gauge also falls when a queued request starts.
- Simulator: `run.sh <sim-commit> <out.jsonl> [reps [abort.py options]]`, 100 ms per token, 100 ms to first token unless `SIM_TTFT` sets it, 50 tokens.
- vLLM: `run-vllm-cpu.sh <out.jsonl> [reps]`, `vllm/vllm-openai-cpu` pinned by digest, the vLLM version read inside the container (0.27.1), `Qwen/Qwen2.5-0.5B-Instruct` at a pinned revision, 300 tokens; the server log is kept beside the rows.
- Both pick a free port, refuse a port answered by anything but the engine they started, and write `<out>.manifest.json`; all four manifests name harness commit `4e453979`, clean.

## Result (2026-11-15, three repetitions per cell)

63 case rows, all valid, plus one idle-baseline record per run.

| engine | case | measured | released / removed | generation counter delta | success counter delta |
|---|---|---|---|---:|---|
| vLLM 0.27.1 CPU | control (11.7 to 13.5 s) | probe excess −0.001 to 0.051 s | 3 of 3 | 301 | 2 × `length` |
| vLLM 0.27.1 CPU | busy_control | probe excess 11.86 to 12.16 s | 0 of 3, as required | 301 | 2 × `length` |
| vLLM 0.27.1 CPU | stream_cut | probe excess 0.069 to 0.071 s | 3 of 3 | 5 | 1 × `length` |
| vLLM 0.27.1 CPU | plain_cut | probe excess 0.006 to 0.070 s | 3 of 3 | 25 to 28 | 1 × `length` |
| vLLM 0.27.1 CPU | prefill_cut (cut 0.19 to 0.21 s; uncut first event 0.48 to 0.53 s; 1,548 prompt tokens) | probe excess 0.316 to 0.428 s | 3 of 3 | 1 | 1 × `length` |
| vLLM 0.27.1 CPU | queued_cut | queue cleared 0.043 to 0.078 s after the cut; holder then sent 296 more events and finished 12.0 to 12.2 s after the cut | 3 of 3 removed | 301 | 2 × `length` |
| simulator main `4361040` | stream_cut | probe excess 0.300 to 0.303 s | 3 of 3 | 1 | 1 × `length` |
| simulator main | plain_cut | probe excess 4.009 s | 0 of 3 | 51 | 2 × `length` |
| simulator main | prefill_cut (cut 0.04 s, first event at 0.10 s) | probe excess 0.160 s | 3 of 3 | 1 | 1 × `length` |
| simulator main | queued_cut | queue cleared 4.93 to 4.94 s, with no holder event after it | 0 of 3 removed | 51 | 2 × `length` |
| simulator main, 5 s to first token | prefill_cut (cut 2.0 s) | probe excess 3.100 to 3.101 s | 0 of 3 | 1 | 1 × `length` |
| simulator before #815, `ee5597e` | stream_cut | probe excess 4.609 to 4.610 s | 0 of 3 | 51 | 2 × `length` |

Deltas are over the whole row and include the probe (1 token, 1 `length`) and, for `control`, `busy_control` and `queued_cut`, the uncut request (300 or 50 tokens, 1 `length`).
In every run every `control` released and every `busy_control` did not, with the same thresholds.

- On vLLM 0.27.1 on CPU, closing the connection ended the request in every case tried. After a running stream or a running non-streamed request was cut, a probe was answered within 0.071 s of an idle engine's time, completed within 0.1 s of sending, and the engine was idle within 0.005 s after the probe completed. After a cut before the first SSE event, the probe was 0.316 to 0.428 s slower than idle. A queued request left the queue within 0.078 s of its cut while the request ahead of it kept running for another 12 s; that shows the cancelled request was removed, not that the engine was free sooner.
- For the cut before the first event, the uncut time to first event less the time of the cut was 0.286 to 0.320 s in the same rep, against excesses of 0.316 to 0.428 s; in one rep the probe waited 0.14 s longer than that remainder. That is consistent with the engine finishing work it had already started for the request and then stopping; the rows do not identify the engine phase, and an SSE event not yet seen by the client does not rule out a token already computed.
- On the vLLM CPU runs no cut added to `vllm:request_success_total`, `finished_reason="abort"` included; every success delta there is the probe's and the holder's. The cut requests did add to `vllm:generation_tokens_total` over the row (4 in each `stream_cut`; 24, 26 and 27 for `plain_cut`), which is what the engine reported, not a count of work split at the moment of the cut. In the v0.27.1 source the output processor drops an aborted request's state before the statistics that feed the success counter, which fits this; that part is reading, not measurement.
- The simulator behaves like vLLM only for a running streamed cut, which it ends about three tokens late. It runs a non-streamed request to the end, keeps a queued one in the queue until it would start, and reacts to a cut before the first event only after its first output; llm-d/llm-d-inference-sim#815 documents the same limits. A streamed request it aborts adds no tokens to its counters; one it runs to the end adds all of them and a `length`.
- Each case was seen not to release, or not to remove, where the engine keeps the request, with the same script and thresholds: the simulator before #815 for `stream_cut`, current main for `plain_cut` and `queued_cut`. For `prefill_cut` the 5 s first token shows the threshold failing on lateness: that simulator still ended the request, 3.1 s later than idle.

## What this licenses and what it does not

- It licenses, for vLLM 0.27.1 on CPU with one sequence: when the client connection closes, which is what the gateway does on `client_gone` and `idle_timeout`, the engine ended the request in every case tried, a running request's slot served a new probe within 0.071 s of idle, and a queued request left the queue within 0.078 s.
- It does not measure a GPU. The cancellation path is the engine's frontend and scheduler code and is expected to carry over, but v0.27.1 turns async scheduling off on CPU and GPU builds differ in batching and step length, which can change how much is produced after a cut and how long release takes; a time promised for production needs the production configuration measured.
- It does not go through the gateway; requests went straight to the engine on fresh HTTP/1.1 sockets.
- One model and one sequence: with several sequences a cut frees one seat in a batch, not the engine.
- On counting: on these vLLM CPU runs a request cut by its client never appeared in `vllm:request_success_total`, so that counter cannot show how many were cut. The gateway's `gpuaas_gateway_responses_cut_short_total{tenant,model,cause}` (#572, `docs/05_LLM_SERVING_GATEWAY.md`) counts responses that had started and then ended early, including `upstream_aborted`. vLLM can send a streamed response's headers before its first token, so whether a given cut is in that counter depends on whether the response had started at the gateway, not on the engine phase; that was not measured here.
- The simulator stands in for vLLM only for a running streamed cut; anything that cuts non-streamed, queued or pre-first-event requests needs vLLM.
