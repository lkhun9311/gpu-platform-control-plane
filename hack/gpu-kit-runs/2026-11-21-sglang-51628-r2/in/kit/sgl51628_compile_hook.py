"""Record every Triton compilation in this process, with its wall-clock time, into $SGL51628_COMPILE_LOG.

measure.sh loads this module from a .pth file, so it runs at the start of every Python process in the container.
Without SGL51628_COMPILE_LOG it does nothing, so only the servers it launches with that variable are recorded.
It sets triton.knobs.compilation.listener before SGLang starts.
SGLang's own watch (sglang.srt.utils.triton_load_watch) keeps the listener it finds and calls it first, so both see every compilation.
The record does not depend on SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS, which the servers keep at its default.
Each record is one JSON line written with one os.write on an O_APPEND descriptor, so processes do not interleave lines.
"""

import json
import os
import sys
import time

_PATH = os.environ.get("SGL51628_COMPILE_LOG")
# Set once the listener is in, so a later install() does not wrap SGLang's watch, which by then holds this listener, a second time.
_installed = False


def _write(record):
    # A failure to record must never stop the server, so errors are dropped here and show as missing records.
    try:
        fd = os.open(_PATH, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, (json.dumps(record, sort_keys=True) + "\n").encode())
        finally:
            os.close(fd)
    except OSError:
        pass


def _module_of(src):
    # src is Triton's ASTSource; its fn is the JITFunction, whose fn is the Python function.
    fn = getattr(src, "fn", None)
    inner = getattr(fn, "fn", fn)
    return getattr(inner, "__module__", None)


def _short(value, limit=400):
    try:
        text = repr(value)
    except Exception as exc:  # noqa: BLE001
        text = f"<unprintable {type(exc).__name__}>"
    return text[:limit]


def make_listener(prev):
    """The listener that records one compilation, then calls the listener it replaced."""

    def listener(*, src, metadata, metadata_group, times, cache_hit):
        t = time.time()
        try:
            total = getattr(times, "total", None)
            record = {
                "event": "compile",
                "pid": os.getpid(),
                "t": t,
                "name": getattr(src, "name", None),
                "module": _module_of(src),
                "total_us": total if isinstance(total, (int, float)) else None,
                "cache_hit": bool(cache_hit),
                "constants": _short(getattr(src, "constants", None)),
                "signature": _short(getattr(src, "signature", None)),
            }
            if isinstance(metadata, dict):
                record["hash"] = metadata.get("hash")
            _write(record)
        except Exception as exc:  # noqa: BLE001
            _write({"event": "listener_error", "pid": os.getpid(), "t": t, "error": _short(exc)})
        if prev is not None:
            prev(src=src, metadata=metadata, metadata_group=metadata_group, times=times, cache_hit=cache_hit)

    return listener


def install():
    """Install the listener once per process, and record whether it was installed."""
    global _installed
    if not _PATH:
        return False
    if _installed:
        return True
    record = {"event": "install", "pid": os.getpid(), "t": time.time(), "exe": sys.executable}
    try:
        import triton.knobs as knobs

        compilation = getattr(knobs, "compilation", None)
        if compilation is None or not hasattr(compilation, "listener"):
            raise RuntimeError("triton.knobs.compilation.listener is not in this Triton")
        compilation.listener = make_listener(compilation.listener)
        _installed = True
        record["installed"] = True
        try:
            import triton

            record["triton"] = getattr(triton, "__version__", None)
        except Exception:  # noqa: BLE001
            pass
    except Exception as exc:  # noqa: BLE001
        record["installed"] = False
        record["error"] = _short(exc)
    _write(record)
    return record["installed"]


install()
