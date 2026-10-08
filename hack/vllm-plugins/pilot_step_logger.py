"""The prospective-admission pilot's step logger: step_logging_scheduler.py's records, made provably complete.

Loaded with `--scheduler-cls pilot_step_logger.PilotStepLoggingScheduler` and this directory on PYTHONPATH.

Why a new file and not an edit. step_logging_scheduler.py is a frozen instrument: hack/tail-crossing-model/
step_boundary.py compares every archived step-boundary and confirmation cell's plugin hash with that file, so an
edit would make every archived run refuse. This file records the same events, in the same format, plus what the
pilot's completeness rule needs (docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md,
"The measurement pilot" and build item 6):

    every record carries "seq", numbered from 1 in the order the scheduler thread produced it;
    every flush record carries "first_seq" and "last_seq", the first and last seq of the batch it closes;
    every "add" record carries "priority", the priority the scheduler received the request with;
    {"ev": "terminal", "seq_written": n, "seq_produced": n, "buffered": n, "last_step": k, "wall": ns,
     "sentinel_mtime": ns}
        -- written by the writer thread when the sentinel file STEP_LOG_PATH + ".sentinel" appears or changes

The terminal record is how capture learns, without stopping the engine, that everything produced before it was
written: complete only when seq_written == seq_produced and buffered == 0. The scheduler thread flushes its buffer
whenever the engine is idle, which capture ensures with its fence before writing the sentinel; if the buffer is not
yet empty the terminal record says so, and capture writes the sentinel again until it is or its bound expires.

It subclasses the synchronous Scheduler, as the original does, and changes no scheduling decision.
"""

import json
import os
import queue
import threading
import time

from vllm.v1.core.sched.scheduler import Scheduler

MAX_BUFFERED = 2_000_000
SENTINEL_POLL_S = 1.0


class PilotStepLoggingScheduler(Scheduler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._step_log_path = os.environ.get("STEP_LOG_PATH", "/tmp/step-log.jsonl")
        self._sentinel_path = self._step_log_path + ".sentinel"
        self._buf = []
        self._overflowed = False
        self._step_index = 0
        # Read by the writer thread for the terminal record; a plain int, so a read is atomic under the GIL.
        self._seq_produced = 0
        self._seq_written = 0
        self._sentinel_seen = None
        self._queue = queue.SimpleQueue()
        self._writer = threading.Thread(target=self._write_loop, name="pilot-step-log-writer", daemon=True)
        self._writer.start()

    def _keep(self, rec):
        if len(self._buf) >= MAX_BUFFERED:
            if not self._overflowed:
                self._overflowed = True
                self._seq_produced += 1
                self._buf.append({"ev": "overflow", "seq": self._seq_produced, "mono": time.monotonic_ns(),
                                  "dropped_after": MAX_BUFFERED})
            return
        self._seq_produced += 1
        rec["seq"] = self._seq_produced
        self._buf.append(rec)

    def _write_loop(self):
        while True:
            try:
                recs, start, ready = self._queue.get(timeout=SENTINEL_POLL_S)
            except queue.Empty:
                self._maybe_terminal()
                continue
            ready.wait()
            self._write(recs, start)
            self._maybe_terminal()

    def _maybe_terminal(self):
        # Only the writer writes to the file, so the terminal record follows every batch it has already written.
        try:
            mtime = os.stat(self._sentinel_path).st_mtime_ns
        except FileNotFoundError:
            return
        if mtime == self._sentinel_seen:
            return
        self._sentinel_seen = mtime
        rec = {"ev": "terminal", "seq_written": self._seq_written, "seq_produced": self._seq_produced,
               "buffered": len(self._buf), "last_step": self._step_index, "wall": time.time_ns(),
               "sentinel_mtime": mtime}
        with open(self._step_log_path, "a") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")

    def _write(self, recs, start):
        with open(self._step_log_path, "a") as f:
            for rec in recs:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")
        end = time.monotonic_ns()
        first = recs[0]["seq"] if recs else None
        last = recs[-1]["seq"] if recs else None
        with open(self._step_log_path, "a") as f:
            f.write(json.dumps({"ev": "flush", "mono": start, "end": end, "records": len(recs),
                                "first_seq": first, "last_seq": last}, separators=(",", ":")) + "\n")
        if last is not None:
            self._seq_written = last

    def _flush(self, ready):
        recs, self._buf = self._buf, []
        self._queue.put((recs, time.monotonic_ns(), ready))

    @staticmethod
    def _anchor():
        a = time.monotonic_ns()
        w = time.time_ns()
        return [a, w, time.monotonic_ns()]

    def add_request(self, request):
        s0 = time.monotonic_ns()
        rec = {"ev": "add", "id": request.request_id, "mono": s0, "anchor": self._anchor(),
               "arrival_wall": int(request.arrival_time * 1e9), "prompt": request.num_prompt_tokens,
               "priority": request.priority}
        self._keep(rec)
        rec["self"] = time.monotonic_ns() - s0
        return super().add_request(request)

    def schedule(self, *args, **kwargs):
        t0 = time.monotonic_ns()
        out = super().schedule(*args, **kwargs)
        t1 = time.monotonic_ns()
        if out.total_num_scheduled_tokens > 0:
            self._step_index += 1
            computed = {}
            for rid in out.num_scheduled_tokens:
                req = self.requests.get(rid)
                computed[rid] = (req.num_computed_tokens - out.num_scheduled_tokens[rid]) if req is not None else -1
            rec = {"ev": "sched", "step": self._step_index, "t0": t0, "t1": t1, "anchor": self._anchor(),
                   "tokens": dict(out.num_scheduled_tokens), "computed": computed}
            self._keep(rec)
            rec["self"] = time.monotonic_ns() - t1
        return out

    def update_from_output(self, scheduler_output, model_runner_output):
        t2 = time.monotonic_ns()
        out = super().update_from_output(scheduler_output, model_runner_output)
        t3 = time.monotonic_ns()
        rec = None
        if scheduler_output.total_num_scheduled_tokens > 0:
            rec = {"ev": "done", "step": self._step_index, "t2": t2, "t3": t3}
            self._keep(rec)
        ready = threading.Event()
        if self._buf and not self.has_requests():
            self._flush(ready)
        if rec is not None:
            rec["self"] = time.monotonic_ns() - t3
        ready.set()
        return out
