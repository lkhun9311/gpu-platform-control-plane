"""A fake SGLang server for the #51628 kit r4's offline test, served from the fake tree the kit installs.

It behaves as the source it is installed from: when the tree's mamba.py holds prewarm.patch's prewarm_prefill_kernels,
it logs the prewarm line and compiles the scan before ready; otherwise the scan compiles on the first burst, as r2 saw.
FAKE_SCENARIO picks what else happens:
  improved   (default) BASE compiles 12 Mamba2 kernels on the first burst; FIX compiles 1
  nochange   FIX compiles as many after ready as BASE, prewarm line and all
  gatefail   no line disables prefill CUDA graph, in either arm
  noprewarm  the patched tree does not log the prewarm line
  foreign    the Mamba2 kernels compile from the image's own tree, not the installed one
"""

import argparse
import logging
import os
import signal
import sys
import threading
import time
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import triton
from sglang.srt.utils import triton_load_watch

SCENARIO = os.environ.get("FAKE_SCENARIO", "improved")
PKG = os.path.dirname(os.path.abspath(__file__))
MAMBA = "sglang.kernels.ops.mamba.triton_ops.ssd_chunk_scan"
STATE = "sglang.kernels.ops.mamba.triton_ops.ssd_chunk_state"
MISC = "sglang.srt.mem_cache.memory_pool"
KDIR = "/sgl-workspace/sglang/python/sglang" if SCENARIO == "foreign" else PKG
mixer = os.path.join(PKG, "srt", "layers", "attention", "mamba", "mamba.py")
PATCHED = os.path.isfile(mixer) and "def prewarm_prefill_kernels" in open(mixer).read()

p = argparse.ArgumentParser()
p.add_argument("--model-path", required=True)
p.add_argument("--trust-remote-code", action="store_true")
a = p.parse_args()
if not os.path.isfile(os.path.join(a.model_path, "config.json")):
    sys.exit("fake server: no config.json in the model path")
logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(message)s", stream=sys.stdout)
log = logging.getLogger("fake")
log.info("server_args=%s", vars(a))


def kcompile(name, module, seconds, rel="kernels/ops/mamba/triton_ops/ssd_chunk_scan.py"):
    """Compile a fake kernel through Triton's listener, defined in a file of the tree (or the image's, for foreign)."""

    def f():
        pass

    f.__name__ = name
    f.__module__ = module
    f.__code__ = f.__code__.replace(co_filename=os.path.join(KDIR, rel))
    triton._emit(triton.JITFunction(f), seconds, False)


def scan_compiles(n_scan, n_state):
    for i in range(n_scan):
        kcompile("_chunk_scan_fwd_kernel", MAMBA, 1.0 + i / 100)
    for i in range(n_state):
        kcompile("_chunk_state_varlen_kernel", STATE, 0.4, "kernels/ops/mamba/triton_ops/ssd_chunk_state.py")


kcompile("write_req_to_token_pool_triton", MISC, 0.09, "srt/mem_cache/memory_pool.py")
kcompile("_chunk_cumsum_fwd_kernel", MAMBA, 0.3)
# The TreeCore the server picks, as SGLang's registry would: Rust only with a cached build and the toolchain it fingerprints.
cache = os.path.expanduser(os.environ.get("SGLANG_CACHE_DIR", "~/.cache/sglang"))
built = os.path.isdir(os.path.join(cache, "rust_extensions", "artifacts"))
if os.environ.get("SGLANG_UNIFIED_RADIX_TREE_CORE_BACKEND") == "python":
    core = "UnifiedTreeCore"
elif built and os.environ.get("RUSTUP_HOME"):
    core = "RustUnifiedTreeCore"
else:
    log.info("Using the Python TreeCore: the Rust TreeCore toolchain is unavailable")
    core = "UnifiedTreeCore"
log.info("Init Unified Radix Cache. Components: (FULL, MAMBA). Tree Core: %s", core)
if SCENARIO != "gatefail":
    log.info("Disable prefill CUDA graph because some layers do not apply Standard GQA")
if PATCHED:
    scan_compiles(11, 4)
    if SCENARIO != "noprewarm":
        log.info("Prewarmed the Mamba2 prefill scan for 1 layer geometries in 2.4 s.")
log.info("Capture target decode CUDA graph begin. backend=full")
triton_load_watch.install()
triton_load_watch.mark_serving_started()
state = {"bursts": 0}
lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            return
        if self.path.startswith("/fake_burst"):
            with lock:
                state["bursts"] += 1
                stall = 0.0
                if state["bursts"] == 1:
                    if not PATCHED or SCENARIO == "nochange":
                        scan_compiles(8, 4)
                        stall = 9000.0
                    else:
                        # One specialisation the prewarm cannot cover still compiles after ready.
                        kcompile("_chunk_scan_fwd_kernel", MAMBA, 0.5)
                        stall = 600.0
            body = json.dumps({"stall_ms": stall}).encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


srv = ThreadingHTTPServer(("127.0.0.1", 30000), H)
signal.signal(signal.SIGTERM, lambda *_: (srv.server_close(), os._exit(0)))
threading.Thread(target=srv.serve_forever, daemon=True).start()
log.info("The server is fired up and ready to roll!")
while True:
    time.sleep(1)
