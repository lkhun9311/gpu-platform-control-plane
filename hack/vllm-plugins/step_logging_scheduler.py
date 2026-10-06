"""A vLLM v0.27.1 scheduler that records each engine step's boundaries and the requests it scheduled.

Loaded with `--scheduler-cls step_logging_scheduler.StepLoggingScheduler` and this directory on PYTHONPATH.

Why it exists. The stock iteration log has no request ids and no step boundaries, so the 2026-10-06 logged-engine
pilot could not say what a staggered late prefill waited for before its first step
(docs/superpowers/specs/2026-10-06-a-timing-family-for-the-logged-synchronous-engine.md, "Result of the pilot").
This class adds exactly that and nothing else: it changes no scheduling decision, only timestamps around the
three calls the engine core already makes (v1/engine/core.py, EngineCore.step).

It subclasses the synchronous Scheduler, which is what vLLM uses with --no-async-scheduling; under async
scheduling the core pipelines steps and these boundaries would not mean what they say here.

No I/O happens while the engine is busy. Records go to an in-memory list, and when the engine has drained -- no
request left after a step's update, which in these traces is between episodes -- the list is handed to a
background thread that writes it. Writing inline would have delayed the publication of the episode's last output
(found by review); the thread's start and end are recorded, so the evaluator can show every write finished before
the next request arrived. A buffer that grows past MAX_BUFFERED records is not truncated: the
next record says so and the evaluator refuses the cell, because a silently shortened log reads as a complete one.

Every record carries the plugin's own cost: "self" is the nanoseconds the wrapper spent outside the engine's
own calls for that event, so the instrument's overhead is measured on every step rather than assumed.

One JSON object per line goes to STEP_LOG_PATH (default /tmp/step-log.jsonl):

    {"ev": "add",   "id": ..., "mono": ns, "wall": ns, "prompt": n, "self": ns}
    {"ev": "sched", "step": k, "t0": ns, "t1": ns, "wall1": ns, "tokens": {id: n, ...}, "computed": {id: n, ...}, "self": ns}
    {"ev": "done",  "step": k, "t2": ns, "t3": ns, "self": ns}
    {"ev": "flush", "mono": ns, "end": ns, "records": n}
    {"ev": "overflow", "mono": ns, "dropped_after": n}

"mono", t0..t3 are time.monotonic_ns(); "wall"/"wall1" are time.time_ns() read beside them, an anchor between the
engine's clock and the client's. t0..t1 is scheduling; t1..t2 is the batch's execution as the core waits for it;
t2..t3 is the scheduler update. "computed" is each scheduled request's computed tokens before this step, so a
request's prompt progress is known without replaying the log.
"""

import json
import os
import threading
import time

from vllm.v1.core.sched.scheduler import Scheduler

MAX_BUFFERED = 2_000_000


class StepLoggingScheduler(Scheduler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._step_log_path = os.environ.get("STEP_LOG_PATH", "/tmp/step-log.jsonl")
        self._buf = []
        self._overflowed = False
        self._step_index = 0
        self._writer = None
        self._write_lock = threading.Lock()

    def _keep(self, rec):
        if len(self._buf) >= MAX_BUFFERED:
            if not self._overflowed:
                self._overflowed = True
                self._buf.append({"ev": "overflow", "mono": time.monotonic_ns(), "dropped_after": MAX_BUFFERED})
            return
        self._buf.append(rec)

    def _write(self, recs, start):
        # One writer at a time and in order, so two drains close together cannot interleave their records.
        with self._write_lock:
            with open(self._step_log_path, "a") as f:
                for rec in recs:
                    f.write(json.dumps(rec, separators=(",", ":")) + "\n")
                f.write(json.dumps({"ev": "flush", "mono": start, "end": time.monotonic_ns(), "records": len(recs)},
                                   separators=(",", ":")) + "\n")

    def _flush(self):
        recs, self._buf = self._buf, []
        self._writer = threading.Thread(target=self._write, args=(recs, time.monotonic_ns()), daemon=False)
        self._writer.start()

    def add_request(self, request):
        s0 = time.monotonic_ns()
        rec = {"ev": "add", "id": request.request_id, "mono": s0, "wall": time.time_ns(),
               "prompt": request.num_prompt_tokens}
        rec["self"] = time.monotonic_ns() - s0
        self._keep(rec)
        return super().add_request(request)

    def schedule(self, *args, **kwargs):
        t0 = time.monotonic_ns()
        out = super().schedule(*args, **kwargs)
        t1 = time.monotonic_ns()
        # A step that schedules nothing is not a step the iteration log records either, so it gets no index.
        if out.total_num_scheduled_tokens > 0:
            self._step_index += 1
            computed = {}
            for rid in out.num_scheduled_tokens:
                req = self.requests.get(rid)
                # num_computed_tokens has already advanced by this step's tokens when schedule() returns.
                computed[rid] = (req.num_computed_tokens - out.num_scheduled_tokens[rid]) if req is not None else -1
            rec = {"ev": "sched", "step": self._step_index, "t0": t0, "t1": t1, "wall1": time.time_ns(),
                   "tokens": dict(out.num_scheduled_tokens), "computed": computed}
            rec["self"] = time.monotonic_ns() - t1
            self._keep(rec)
        return out

    def update_from_output(self, scheduler_output, model_runner_output):
        t2 = time.monotonic_ns()
        out = super().update_from_output(scheduler_output, model_runner_output)
        t3 = time.monotonic_ns()
        if scheduler_output.total_num_scheduled_tokens > 0:
            self._keep({"ev": "done", "step": self._step_index, "t2": t2, "t3": t3,
                        "self": time.monotonic_ns() - t3})
        # Drained: nothing is waiting or running, so writing now delays no request.
        if self._buf and not self.has_requests():
            self._flush()
        return out
