"""SGLang 03fde9cc's triton_load_watch, reduced to its compile path: it keeps the listener it finds and calls it first."""

import logging
import os

logger = logging.getLogger("sglang.srt.utils.triton_load_watch")
_serving_started = False
_prev_compile_listener = None
_installed = False


def install():
    global _installed, _prev_compile_listener
    if _installed:
        return
    import triton.knobs as knobs

    compilation = getattr(knobs, "compilation", None)
    if compilation is None or not hasattr(compilation, "listener"):
        return
    _prev_compile_listener = compilation.listener
    compilation.listener = _on_compilation
    _installed = True


def mark_serving_started():
    global _serving_started
    _serving_started = True


def _on_compilation(*, src, metadata, metadata_group, times, cache_hit):
    if _prev_compile_listener is not None:
        _prev_compile_listener(src=src, metadata=metadata, metadata_group=metadata_group, times=times, cache_hit=cache_hit)
    if not _serving_started or cache_hit:
        return
    secs = times.total / 1e6
    if secs < float(os.environ.get("SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS", "1.0")):
        return
    logger.warning(
        "Triton kernel '%s' took %.2f s to compile after serving started. "
        "Serving-time compilation can stall the engine; pre-compile it during engine init.",
        src.name,
        secs,
    )
