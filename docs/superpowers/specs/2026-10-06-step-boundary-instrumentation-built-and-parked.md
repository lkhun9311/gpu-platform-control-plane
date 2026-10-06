# Step-boundary instrumentation — built, validated on CPU, and parked

Date: 2026-10-06 · A decision record, not a registration. **No card is bought by this page.**

**Why it exists.** The logged-engine pilot (`2026-10-06-a-timing-family-for-the-logged-synchronous-engine.md`) failed. Every staggered late prefill's client TTFT exceeded the model's account of its own steps by at least 11 ms, and the archive could not say why: the stock iteration log has no request ids and no step boundaries. The owner approved designing new instrumentation and asked whether it is worth building. I and codex `gpt-6-astra` judged that independently, from the v0.27.1 source extracted from the pinned image (`vllm/vllm-openai@sha256:0a51ea5b…`).

## 1. What was built, at no cost

`hack/vllm-plugins/step_logging_scheduler.py` is a subclass of v0.27.1's synchronous `Scheduler`, loaded with `--scheduler-cls`. It changes no scheduling decision. It writes one JSON line per event:
- a request's arrival in the scheduler, with monotonic and wall-clock stamps;
- each step's `schedule()` entry and exit, with the request ids and tokens scheduled;
- the entry to `update_from_output()`, which the engine core calls right after the batch's result is retrieved.

A client's `X-Request-Id` becomes the engine's id as `chatcmpl-<id>-<8 random characters>` (`v1/engine/input_processor.py:249`), so a client row joins its engine records by prefix.

**Validated on v0.27.1's CPU build** (`vllm/vllm-openai-cpu:v0.27.1-x86_64`), Qwen2.5-0.5B-Instruct, `--no-async-scheduling`, `--enable-logging-iteration-details`, a 512-token budget. The workload was two 600-word decoders and a late 300-word prefill sent 3 s after them, each with an `X-Request-Id`.
- The plugin recorded 65 steps against the stock log's 65 Iteration lines, one to one. The tokens scheduled per step matched in all 65.
- Its `schedule()`-exit to `update_from_output()`-entry window exceeded the stock `elapsed_ms` by 0.09 to 0.26 ms (median 0.12). That is consistent with the stock timer starting after dispatch and stopping at retrieval (`v1/engine/core.py:595-611`).
- `schedule()` itself took a median 0.058 ms and at most 0.270 ms.
- All three requests joined by prefix.

**What that validation does not show:** anything about the A10G. That covers overhead, CUDA completion semantics and transferable timings. The first CPU step took 42 s of warm-up, which is a property of the CPU build.

## 2. What astra added

- **The subclass cannot separate execution from result retrieval.** Both happen between the two scheduler calls. A complete record needs stamps in the engine loop itself (`v1/engine/core.py:595`, and output publication near `:1442`), kept in bounded memory with no per-step text formatting or file writes. That is a design judgment, not a measured overhead.
- **The scheduler's queued event (an engine-core event type in vLLM's `v1/engine/__init__.py:157`) event misses frontend and IPC waiting,** so an exhaustive decomposition of a late prefill's TTFT also needs receipt stamps in the API server.
- **OpenTelemetry tracing gives request-level spans, not the step-by-request matrix.** The `--collect-detailed-traces` model and worker options have no V1 timing consumer in this source.
- **Clocks.** A monotonic stamp relates to the client's Unix stamps only through bracketed realtime readings, with uncertainty of half the bracket. Client and engine should share a host.
- **Cost.** A new instrument needs its own overhead gate, given I1's history: paired on and off cells with between-block uncertainty, sized from the noisiest endpoint. Session 5's paired cells took 26,426 s (7.34 h) of cell time, against 13,092 s (3.64 h) for logged cells alone (both re-summed by astra; the second re-derived by me). So a properly powered session is not covered by the $4–$6 first estimated.

## 3. Decision

**Parked: no engine-loop patch and no paid session now.** Both of us agree. The instrument works and joins requests to steps on the real engine code, at no cost so far. But its only downstream use, an iteration-level simulator acting as an admission controller and M5-b's successor, is far off. A powered overhead gate plus the measurement would cost about 7 to 8 hours of card time and more build. It is reconsidered when a concrete decision depends on why mixing fails, and then as its own registration with:
- the overhead gate first;
- an exhaustive accounting of a late prefill's TTFT;
- the family frozen before any data.
