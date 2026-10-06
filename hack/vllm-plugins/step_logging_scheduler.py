"""A vLLM v0.27.1 scheduler that records each engine step's boundaries and the requests it scheduled.

Loaded with `--scheduler-cls step_logging_scheduler.StepLoggingScheduler` and this directory on PYTHONPATH.

Why it exists. The stock iteration log has no request ids and no step boundaries, so the 2026-10-06 logged-engine
pilot could not say what a staggered late prefill waited for before its first step
(docs/superpowers/specs/2026-10-06-a-timing-family-for-the-logged-synchronous-engine.md, "Result of the pilot").
This class adds exactly that and nothing else: it changes no scheduling decision, only timestamps around the
three calls the engine core already makes (v1/engine/core.py, EngineCore.step).

It subclasses the synchronous Scheduler, which is what vLLM uses with --no-async-scheduling; under async
scheduling the core pipelines steps and these boundaries would not mean what they say here.

One JSON object per line goes to the file named by STEP_LOG_PATH (default /tmp/step-log.jsonl):

    {"ev": "add",   "id": ..., "mono": ns, "wall": ns, "prompt": n}
    {"ev": "sched", "step": k, "t0": ns, "t1": ns, "wall1": ns, "tokens": {id: n, ...}}
    {"ev": "done",  "step": k, "t2": ns}

"mono" and t0/t1/t2 are time.monotonic_ns(); "wall" and "wall1" are time.time_ns() read beside them, so every
record carries its own anchor between the engine's clock and the client's.
t0 to t1 is scheduling; t1 to t2 is the batch's execution as the core waits for it; t2 is when the core starts
processing the results, which is before the tokens are detokenized and sent.
"""

import json
import os
import time

from vllm.v1.core.sched.scheduler import Scheduler


class StepLoggingScheduler(Scheduler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        path = os.environ.get("STEP_LOG_PATH", "/tmp/step-log.jsonl")
        # Line-buffered, so a step's record is on disk when the step is, and a killed engine loses at most a line.
        self._step_log = open(path, "a", buffering=1)
        self._step_index = 0

    def _emit(self, rec):
        self._step_log.write(json.dumps(rec, separators=(",", ":")) + "\n")

    def add_request(self, request):
        self._emit({"ev": "add", "id": request.request_id, "mono": time.monotonic_ns(), "wall": time.time_ns(),
                    "prompt": request.num_prompt_tokens})
        return super().add_request(request)

    def schedule(self, *args, **kwargs):
        t0 = time.monotonic_ns()
        out = super().schedule(*args, **kwargs)
        t1 = time.monotonic_ns()
        # A step that schedules nothing is not a step the iteration log records either, so it gets no index.
        if out.total_num_scheduled_tokens > 0:
            self._step_index += 1
            self._emit({"ev": "sched", "step": self._step_index, "t0": t0, "t1": t1, "wall1": time.time_ns(),
                        "tokens": dict(out.num_scheduled_tokens)})
        return out

    def update_from_output(self, scheduler_output, model_runner_output):
        if scheduler_output.total_num_scheduled_tokens > 0:
            self._emit({"ev": "done", "step": self._step_index, "t2": time.monotonic_ns()})
        return super().update_from_output(scheduler_output, model_runner_output)
