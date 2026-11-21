"""A fake Triton whose compilations go through triton.knobs.compilation.listener, as Triton 3.8's do.

A @jit kernel compiles at its first launch; fake_compile lets the fake server compile a named kernel from a named module.
"""

import time

from . import knobs, language  # noqa: F401

__version__ = "3.8.0-fake"


class _Times:
    def __init__(self, us):
        self.total = us


class _Src:
    def __init__(self, fn):
        self.fn = fn
        self.name = fn.fn.__name__
        self.constants = {"BLOCK": 256}
        self.signature = {"x_ptr": "*fp32"}


class JITFunction:
    def __init__(self, fn):
        self.fn = fn
        self._compiled = False

    def __getitem__(self, grid):
        def launch(*args, **kwargs):
            if not self._compiled:
                self._compiled = True
                _emit(self, 0.05, False)

        return launch


def jit(fn):
    return JITFunction(fn)


def _emit(jitfn, seconds, cache_hit):
    time.sleep(min(seconds, 0.05))
    listener = getattr(knobs.compilation, "listener", None)
    if listener is not None:
        listener(src=_Src(jitfn), metadata={"hash": "fake"}, metadata_group={}, times=_Times(seconds * 1e6), cache_hit=cache_hit)


def fake_compile(name, module, seconds, cache_hit=False):
    """Compile the kernel NAME defined in MODULE, taking SECONDS, through the listener."""

    def f():
        pass

    f.__name__ = name
    f.__module__ = module
    _emit(JITFunction(f), seconds, cache_hit)
