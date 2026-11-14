# S2, engine half: does the engine stop when the client connection closes?

Issues #578 (simulator) and #580 (vLLM v0.27.1 on CPU). The gateway half is #572: on `client_gone` or `idle_timeout` the gateway records the cut and closes the upstream connection without a clean end, so from the engine's side the gateway is a client that went away.
This page asks what the engine does next.

## Setup

- One sequence at a time (`--max-num-seqs 1`), so a one-token probe sent right after the cut is the release signal: its time to first byte is short when the slot is free and about the rest of the cut request when it is not.
- Cases (`abort.py`):
  - `control` reads the stream to `[DONE]`;
  - `stream_cut` closes after five frames;
  - `plain_cut` closes one second into a non-streamed request;
  - `prefill_cut` streams a long prompt (1,500 words behind a per-request nonce, so it is never a prefix-cache hit) and closes before the first token;
  - `queued_cut` queues a request behind a holder, closes it while it waits, and reads the waiting gauge instead of the probe, since the holder keeps the slot.
- `abort.py` exits non-zero if the control does not release, because then the probe measures the harness and not the engine.
- Simulator: `run.sh <sim-commit> <out.jsonl> [reps [abort.py options]]` builds `llm-d-inference-sim` at the commit, 100 ms to first token (`SIM_TTFT` overrides it) and per token, 50 tokens; each row carries the commit.
- vLLM: `run-vllm-cpu.sh <out.jsonl> [reps]` runs `vllm/vllm-openai-cpu` v0.27.1 pinned by digest with `Qwen/Qwen2.5-0.5B-Instruct`, 300 tokens at about 0.04 s each after warm-up, and a 2 s release threshold; each row carries the image and model.
- Both scripts pick a free port and refuse a run whose port is answered by anything other than the engine they started.

## Result (2026-11-14, three repetitions per cell, rows in `results/`)

| engine | case | release signal | released | tokens from the cut request | counted as |
|---|---|---:|---|---:|---|
| vLLM v0.27.1 CPU | control | probe 0.027 to 0.078 s | yes | 300 | `length` |
| vLLM v0.27.1 CPU | stream_cut | probe 0.093 to 0.094 s | yes | 4 | nothing |
| vLLM v0.27.1 CPU | plain_cut | probe 0.083 to 0.093 s | yes | 28 | nothing |
| vLLM v0.27.1 CPU | prefill_cut | probe 0.380 to 0.384 s | yes | 0 | nothing |
| vLLM v0.27.1 CPU | queued_cut | waiting cleared 0.077 to 0.177 s | yes | 0 | nothing |
| simulator main `4361040` | stream_cut | probe 0.401 s | yes | 0 | nothing |
| simulator main `4361040` | plain_cut | probe 4.111 s | **no** | 50 | `length` |
| simulator main `4361040` | queued_cut | waiting cleared 4.957 to 4.966 s | **no** | 0 | nothing |
| simulator main, 3 s to first token | prefill_cut | probe 5.601 to 5.602 s | **no** | 0 | nothing |
| simulator before #815, `ee5597e` | stream_cut | probe 4.710 s | **no** | 50 | `length` |

"Tokens from the cut request" is `generated_tokens_incl_probe` less the probe's one token and, for `queued_cut`, the holder's 300 or 50; "counted as" is the change in `vllm:request_success_total` less the probe's and the holder's `length`.

- vLLM v0.27.1 stops a cut request in every case, streamed or not, running, in prefill or queued, and the slot is free within a tenth of a second. A cut during prefill releases after about 0.38 s, which is about the rest of that prefill: the step already running finishes, nothing is decoded after it.
- vLLM counts the tokens a cut request already produced in `vllm:generation_tokens_total` but adds nothing to `vllm:request_success_total`, `finished_reason="abort"` included: a request cut by its client is not visible as a finished request at all.
- The simulator matches vLLM for a running streamed request only. A non-streamed request, a queued request and a request still before its first token are held until the simulator next writes, as llm-d/llm-d-inference-sim#815 documents.
- Each case was also seen to fail: the simulator before #815 holds a streamed cut, current main holds a queued cut and a cut before a 3 s first token, and the same script reports each as not released. A case that cannot fail would not show that vLLM passes it.

## What this licenses and what it does not

- It licenses: when the gateway closes the upstream connection, vLLM v0.27.1 frees the slot for the next request within about a tenth of a second, or within the rest of a prefill step, so the gateway's admission does not have to wait out a request whose client has gone.
- CPU is not the GPU the product runs on. The behaviour (abort, no further decoding, the counters) is the engine's code path and does not depend on the device; the times do, and a prefill step on a GPU is a different length.
- One model, one sequence at a time. With several sequences a cut frees one seat in a batch rather than the whole engine, which this does not measure.
- A metric gap follows for anyone reading the engine: requests cut by clients are missing from `vllm:request_success_total`, so a success ratio computed from it overstates completion, and the gateway's own `gpuaas_gateway_responses_cut_short_total` (#572) is the count of them.
- The simulator stands in for vLLM only for a running streamed cut; experiments that cut non-streamed, queued or pre-first-token requests need vLLM.
