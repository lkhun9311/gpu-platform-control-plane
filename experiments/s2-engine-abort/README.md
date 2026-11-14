# S2, engine half: does the engine stop when the client connection closes?

Issue #578. The gateway half is #572: on `client_gone` or `idle_timeout` the gateway records the cut and closes the upstream connection without a clean end, so from the engine's side the gateway is a client that went away.
This page asks what the engine does next.

## Setup

- Engine: `llm-d-inference-sim` built from source at a pinned commit, `--max-num-seqs 1`, 100 ms to first token and per token, `max_tokens` 50 with `ignore_eos`, so a full request takes about 5 s.
- One slot, so a one-token probe sent right after the cut is the release signal: its time to first byte is about 0.1 s when the slot is free and about the rest of the first request when it is not.
- Three cases, three repetitions each: `control` reads the stream to `[DONE]`; `stream_cut` closes after five frames; `plain_cut` closes one second into a non-streamed request.
- `abort.py` exits non-zero if the control does not release, because then the probe measures the harness and not the engine.
- Run: `experiments/s2-engine-abort/run.sh <sim-commit> <out.jsonl> 3`. Each row carries the simulator commit.

## Result (2026-11-14, rows in `results/`)

| simulator | case | probe time to first byte | released | 3 of 3 |
|---|---|---:|---|---|
| main `4361040` | control | 0.101 s | yes | identical |
| main `4361040` | stream_cut | 0.401 s | yes | identical |
| main `4361040` | plain_cut | 4.111 s | **no** | identical |
| before #815, `ee5597e` | control | 0.101 s | yes | identical |
| before #815, `ee5597e` | stream_cut | 4.710 s | **no** | identical |
| before #815, `ee5597e` | plain_cut | 4.111 s | **no** | identical |

- On current main a streamed request is stopped about 0.3 s after its client closes, roughly three tokens: the simulator notices at the first failed write, and the first writes after a close still succeed into the socket buffer.
- A non-streamed request runs to the end for a client that is gone and holds the only slot for the remaining 4 s; it is then counted as a success with `finished_reason="length"` and all 50 tokens.
- The run at the commit before llm-d/llm-d-inference-sim#815 is the check that the probe can see a failure: there the streamed cut also holds the slot to the end, and the same script reports it as not released.
- The aborted stream is invisible in the counters on main: neither its tokens nor a finish reason are added (`generated_tokens_incl_probe` is the probe's 1, `success_delta` is the probe's `length`).

## What this licenses and what it does not

- It licenses: with this simulator, a gateway that closes the upstream connection mid-stream frees the engine slot within a few tokens, and a gateway that gives up on a non-streamed request does not.
- The non-streamed result is the simulator's documented limit, not vLLM's behaviour. llm-d/llm-d-inference-sim#815 says a non-streamed request runs to completion and that a client leaving while queued or before the first token is noticed only at the first write after it; vLLM's chat and completion routes are wrapped in `with_cancellation`, which cancels the handler, streamed or not, when the client disconnects (`vllm/entrypoints/serve/utils/api_utils.py`, read at vLLM `2ab8e2f`, not run).
- So the gateway's admission and the engine's `num_requests_running` agree after a streamed cut on this simulator, and nothing here says how long a real vLLM takes, or what it does for a queued request or one still in prefill. That needs a vLLM run, CPU or GPU, and is the follow-up.
- Simulator counters are not vLLM's: vLLM has a `finished_reason="abort"` label on `vllm:request_success_total`, and whether a client disconnect increments it was not checked.
