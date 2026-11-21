import importlib.abc, importlib.machinery, json, os, sys

_TARGET = "vllm.v1.core.sched.scheduler"


def _wrap(module):
    cls = getattr(module, "Scheduler", None)
    if cls is None or getattr(cls.__init__, "__srpf_observed__", False):
        return
    init = cls.__init__

    def __init__(self, *args, **kwargs):
        init(self, *args, **kwargs)
        try:
            out = os.environ.get("SRPF_OBSERVE_DIR", "/tmp/srpf-observe")
            os.makedirs(out, exist_ok=True)
            threshold = getattr(self, "srpf_starvation_threshold", None)
            record = {"pid": os.getpid(), "file": getattr(module, "__file__", None),
                      "threshold": threshold if isinstance(threshold, int) else repr(threshold),
                      "env": os.environ.get("VLLM_ENABLE_SRPF"),
                      "starvation": os.environ.get("VLLM_SRPF_STARVATION_THRESHOLD")}
            tmp = os.path.join(out, ".%d.tmp" % os.getpid())
            with open(tmp, "w") as f:
                json.dump(record, f)
            os.replace(tmp, os.path.join(out, "%d-%d.json" % (os.getpid(), id(self))))
        except Exception as e:
            sys.stderr.write("srpf_observe: %r\n" % (e,))

    __init__.__srpf_observed__ = True
    cls.__init__ = __init__


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path, target=None):
        if name != _TARGET:
            return None
        spec = importlib.machinery.PathFinder.find_spec(name, path)
        if spec is None or spec.loader is None or not hasattr(spec.loader, "exec_module"):
            return spec
        run = spec.loader.exec_module

        def exec_module(module):
            run(module)
            _wrap(module)

        spec.loader.exec_module = exec_module
        return spec


sys.meta_path.insert(0, _Finder())
