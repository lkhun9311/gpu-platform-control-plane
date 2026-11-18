# Diagnostic probe for the vLLM #67811 measurement, loaded through PYTHONPATH.
# It wraps AdaptivePrefillController.begin, commit and complete, and PrefillBudget.limit, once that module is imported.
# The PR logs nothing about its controller, and run1's probe stopped after 200 calls, all inside the serial warm-up.
# Run 2 needs the stalled phase itself: what the GPU feeds back, the allowance that follows, and which prompts got none.
# Each event is one JSON line; a cap bounds the file, since about 70 steps a second for 130 s is around 30,000 events.
import atexit
import importlib.abc
import importlib.util
import json
import os
import sys
import time

_TARGET = "vllm.v1.core.sched.adaptive_prefill"
_OUT = os.environ.get("AP_PROBE_DIR", "/out")
_CAP = 200000
# Writes go through a buffer flushed at most every half second, so the scheduler loop pays for a memory append,
# not a file write per event; a kill at the timeout loses at most the last half second.
_FLUSH_S = 0.5


def _patch(module):
    cls = getattr(module, "AdaptivePrefillController", None)
    budget_cls = getattr(module, "PrefillBudget", None)
    if cls is None or budget_cls is None or getattr(cls, "_ap_probe", False):
        return
    begin, commit, complete, limit = cls.begin, cls.commit, cls.complete, budget_cls.limit
    state = {"n": 0, "f": None, "last_flush": time.monotonic(), "probe_s": 0.0}
    path = os.path.join(_OUT, "probe-%s-%d.jsonl" % (os.environ.get("AP_SLOT", "x"), os.getpid()))

    def emit(row):
        state["n"] += 1
        if state["n"] > _CAP:
            if state["n"] == _CAP + 1:
                row = {"ev": "cap", "t": time.time()}
            else:
                return
        try:
            if state["f"] is None:
                state["f"] = open(path, "a")
                # The engine core exits through its own signal handling, so the last buffered rows are flushed there.
                atexit.register(state["f"].flush)
            # The probe's own cumulative time rides on every row, so its cost to the scheduler loop is measured.
            row["probe_s"] = state["probe_s"]
            state["f"].write(json.dumps(row) + "\n")
            now = time.monotonic()
            if now - state["last_flush"] >= _FLUSH_S:
                state["f"].flush()
                state["last_flush"] = now
        except OSError:
            pass

    def timed(fn):
        def run(*args, **kwargs):
            t0 = time.perf_counter()
            try:
                return fn(*args, **kwargs)
            finally:
                state["probe_s"] += time.perf_counter() - t0
        return run

    def ctl(self):
        # The controller's own state after the call, so a reader can recompute the next allowance by hand.
        return {"token_ms": self.token_ms, "decode_ms": self.decode_ms, "scale": self.scale,
                "credit_ms": self.credit_ms, "pending": len(self.pending),
                "inflight_ms": sum(p.reserved_ms for p in self.pending.values())}

    def traced_limit(self, request_id, tokens, context):
        granted = limit(self, request_id, tokens, context)
        t0 = time.perf_counter()
        # Per-budget tallies: a waiting prompt that keeps getting zero is the starvation the CPU replay predicts.
        tally = self.__dict__.setdefault("_ap_limits", {})
        tally[request_id] = (granted, tokens, context)
        state["probe_s"] += time.perf_counter() - t0
        return granted

    def traced_begin(self, now, decode_reqs, max_tokens, prefill_ids):
        inflight = sum(p.reserved_ms for p in self.pending.values())
        budget = begin(self, now, decode_reqs, max_tokens, prefill_ids)
        timed(emit)({"ev": "begin", "t": time.time(), "now": now, "decode_reqs": decode_reqs,
                     "prefill_reqs": len(prefill_ids), "inflight_before_ms": inflight, "limit_ms": budget.limit_ms,
                     "request_limit_ms": budget.request_limit_ms, "force_progress": budget.force_progress,
                     **ctl(self)})
        return budget

    def traced_commit(self, step_id, budget, actual, contexts, decode_reqs, now):
        result = commit(self, step_id, budget, actual, contexts, decode_reqs, now)
        t0 = time.perf_counter()
        prefill = {r: [c, contexts[r]] for r, c in actual.items() if r in contexts}
        limits = getattr(budget, "_ap_limits", {})
        step = self.pending.get(step_id)
        row = {"ev": "commit", "t": time.time(), "now": now, "step": step_id, "decode_reqs": decode_reqs,
               "prefill": prefill, "prefill_tokens": sum(c for c, _ in prefill.values()),
               "limit_calls": len(limits), "limit_zero": sorted(r for r, (g, _, _) in limits.items() if g == 0),
               "limit_granted": {r: g for r, (g, _, _) in limits.items() if g},
               "units": step.units if step else None, "reserved_ms": step.reserved_ms if step else None,
               **ctl(self)}
        state["probe_s"] += time.perf_counter() - t0
        timed(emit)(row)
        return result

    def traced_complete(self, step_id, device_ms):
        step = self.pending.get(step_id)
        result = complete(self, step_id, device_ms)
        timed(emit)({"ev": "complete", "t": time.time(), "step": step_id, "device_ms": device_ms,
                     "units": step.units if step else None, "decode_reqs": step.decode_reqs if step else None,
                     **ctl(self)})
        return result

    cls.begin, cls.commit, cls.complete = traced_begin, traced_commit, traced_complete
    budget_cls.limit = traced_limit
    cls._ap_probe = True


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path, target=None):
        if name != _TARGET:
            return None
        sys.meta_path.remove(self)
        spec = importlib.util.find_spec(name)
        if spec is None or spec.loader is None:
            return spec
        exec_module = spec.loader.exec_module

        def wrapped(module):
            exec_module(module)
            _patch(module)

        spec.loader.exec_module = wrapped
        return spec


sys.meta_path.insert(0, _Finder())
