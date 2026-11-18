# Diagnostic probe for the vLLM #67811 measurement, loaded through PYTHONPATH in every arm.
# It wraps AdaptivePrefillController.complete once that module is imported, and records what the controller is fed.
# The PR logs nothing about its controller, so this is the only evidence that GPU timing reaches it.
# In an arm without --adaptive-prefill the controller is never built, so the wrapper never runs.
import importlib.abc
import importlib.util
import json
import os
import sys
import time

_TARGET = "vllm.v1.core.sched.adaptive_prefill"
_OUT = os.environ.get("AP_PROBE_DIR", "/out")


def _patch(module):
    cls = getattr(module, "AdaptivePrefillController", None)
    if cls is None or getattr(cls, "_ap_probe", False):
        return
    original = cls.complete
    seen = {"n": 0}
    path = os.path.join(_OUT, "probe-%s-%d.jsonl" % (os.environ.get("AP_SLOT", "x"), os.getpid()))

    def complete(self, step_id, device_ms):
        result = original(self, step_id, device_ms)
        seen["n"] += 1
        n = seen["n"]
        # Only the first steps are written, which the unscored warm-up covers; after them the wrapper only counts,
        # so the adaptive arm's scored runs carry no extra I/O that the other arms lack.
        if n <= 200:
            try:
                with open(path, "a") as f:
                    f.write(json.dumps({"n": n, "t": time.time(), "device_ms": device_ms, "token_ms": self.token_ms,
                                        "decode_ms": self.decode_ms, "scale": getattr(self, "scale", None)}) + "\n")
            except OSError:
                pass
        return result

    cls.complete = complete
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
