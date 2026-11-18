# Diagnostic probe for the vLLM #67811 measurement, loaded through PYTHONPATH.
# It wraps AdaptivePrefillController.begin, commit and complete once that module is imported, and traces each call.
# The PR logs nothing about its controller, and run1's probe stopped after 200 calls, all inside the serial warm-up.
# Run 2 needs the stalled phase itself: the per-token cost the GPU feeds back, and the allowance that follows from it.
# Each event is one JSON line; a cap bounds the file, since about 70 steps a second for 130 s is around 30,000 events.
import importlib.abc
import importlib.util
import json
import os
import sys
import time

_TARGET = "vllm.v1.core.sched.adaptive_prefill"
_OUT = os.environ.get("AP_PROBE_DIR", "/out")
_CAP = 200000


def _patch(module):
    cls = getattr(module, "AdaptivePrefillController", None)
    if cls is None or getattr(cls, "_ap_probe", False):
        return
    begin, commit, complete = cls.begin, cls.commit, cls.complete
    state = {"n": 0, "f": None}
    path = os.path.join(_OUT, "probe-%s-%d.jsonl" % (os.environ.get("AP_SLOT", "x"), os.getpid()))

    def emit(row):
        state["n"] += 1
        if state["n"] > _CAP:
            return
        try:
            if state["f"] is None:
                # Line buffering keeps what was written when the engine is killed at the timeout.
                state["f"] = open(path, "a", buffering=1)
            state["f"].write(json.dumps(row) + "\n")
        except OSError:
            pass

    def ctl(self):
        # The controller's own state after the call, so a reader can recompute the next allowance by hand.
        return {"token_ms": self.token_ms, "decode_ms": self.decode_ms, "scale": self.scale,
                "credit_ms": self.credit_ms, "pending": len(self.pending),
                "inflight_ms": sum(p.reserved_ms for p in self.pending.values())}

    def traced_begin(self, now, decode_reqs, max_tokens, prefill_ids):
        inflight = sum(p.reserved_ms for p in self.pending.values())
        budget = begin(self, now, decode_reqs, max_tokens, prefill_ids)
        emit({"ev": "begin", "t": time.time(), "decode_reqs": decode_reqs, "prefill_reqs": len(prefill_ids),
              "inflight_before_ms": inflight, "limit_ms": budget.limit_ms, "request_limit_ms": budget.request_limit_ms,
              "force_progress": budget.force_progress, **ctl(self)})
        return budget

    def traced_commit(self, step_id, budget, actual, contexts, decode_reqs, now):
        result = commit(self, step_id, budget, actual, contexts, decode_reqs, now)
        prefill = {r: c for r, c in actual.items() if r in contexts}
        step = self.pending.get(step_id)
        emit({"ev": "commit", "t": time.time(), "step": step_id, "decode_reqs": decode_reqs,
              "prefill_reqs": len(prefill), "prefill_tokens": sum(prefill.values()),
              "units": step.units if step else None, "reserved_ms": step.reserved_ms if step else None, **ctl(self)})
        return result

    def traced_complete(self, step_id, device_ms):
        step = self.pending.get(step_id)
        result = complete(self, step_id, device_ms)
        emit({"ev": "complete", "t": time.time(), "step": step_id, "device_ms": device_ms,
              "units": step.units if step else None, "decode_reqs": step.decode_reqs if step else None, **ctl(self)})
        return result

    cls.begin, cls.commit, cls.complete = traced_begin, traced_commit, traced_complete
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
