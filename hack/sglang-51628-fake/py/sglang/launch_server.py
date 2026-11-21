"""A fake SGLang server for the #51628 kit's offline test.

It takes only the flags the kit passes, logs the lines measure.sh and verdict.py read, and compiles fake kernels through Triton's listener.
FAKE_SCENARIO picks what happens:
  repro     (default) Mamba2 kernels compile on the first burst; with --warmups prefill_shapes they compile at startup instead
  norepro   Mamba2 kernels compile at startup; only a small copy kernel compiles on the first burst
  gatefail  the server captures a prefill CUDA graph and logs no disabling line
  hookdead  compilations reach SGLang's warning but not the listener chain, so the hook records nothing
  latedisable the disabling line is there, and so is a prefill capture
For kit r3, which always runs with --warmups prefill_shapes, three more print Triton's autotune report:
  moveall   the warmup autotunes and specialises the chunked scan; no Mamba2 kernel compiles after ready
  movesome  the warmup autotunes one key; the first burst autotunes a second key and specialises, and c16-r1 specialises once
  noeffect  the warmup compiles nothing Mamba2, and the first burst specialises the chunked scan 60 times
FAKE_SPLICE=1 glues a log line into one config line of the report, as r2's buffered stdout did.
"""

import argparse
import json
import logging
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import triton
from sglang.srt.utils import triton_load_watch

SCENARIO = os.environ.get("FAKE_SCENARIO", "repro")
MAMBA = "sglang.kernels.ops.mamba.triton_ops.ssd_chunk_scan"
STATE = "sglang.kernels.ops.mamba.triton_ops.ssd_chunk_state"
MISC = "sglang.srt.mem_cache.memory_pool"

p = argparse.ArgumentParser()
p.add_argument("--model-path", required=True)
p.add_argument("--trust-remote-code", action="store_true")
p.add_argument("--warmups")
a = p.parse_args()
if not os.path.isfile(os.path.join(a.model_path, "config.json")):
    sys.exit("fake server: no config.json in the model path")
logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(message)s", stream=sys.stdout)
log = logging.getLogger("fake")
log.info("server_args=%s", vars(a))


def compile_(name, module, seconds):
    if SCENARIO == "hookdead":
        # The SGLang warning fires but the chain to the hook is cut.
        class T:
            total = seconds * 1e6

        class S:
            pass

        s = S()
        s.name = name
        if triton_load_watch._serving_started and seconds >= float(os.environ.get("SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS", "1.0")):
            triton_load_watch.logger.warning(
                "Triton kernel '%s' took %.2f s to compile after serving started. "
                "Serving-time compilation can stall the engine; pre-compile it during engine init.",
                name,
                seconds,
            )
        return
    triton.fake_compile(name, module, seconds)


SIG = {"x_ptr": "*bf16", "seqlen": "i32", "BLOCK_SIZE_M": "constexpr", "BLOCK_SIZE_N": "constexpr"}
# A second autotune key comes from new argument dtypes, so its signature differs, as r2's second _chunk_scan_fwd_kernel key did.
SIG2 = {"x_ptr": "*bf16", "seqlen": "i32", "BLOCK_SIZE_M": "constexpr", "BLOCK_SIZE_N": "constexpr", "idx_ptr": "*i32"}
CONFIGS = [(32, 32, 8, 2), (64, 32, 4, 3), (64, 64, 4, 1)]


def cfg_text(m, n, w, st):
    return f"BLOCK_SIZE_M: {m}, BLOCK_SIZE_N: {n}, num_warps: {w}, num_ctas: 1, num_stages: {st}, maxnreg: None"


def autotune(key, attrs, sig=SIG, best=2, splice=False):
    """Compile every config for one specialisation and print Triton's report for it."""
    for i, (m, n, w, st) in enumerate(CONFIGS):
        triton.fake_compile("_chunk_scan_fwd_kernel", MAMBA, 0.5, constants={(2,): m, (3,): n}, signature=sig, attrs=attrs, num_warps=w, num_stages=st)
        tail = "[2026-11-21 02:33:36] INFO:     127.0.0.1:50142 - \"GET /health HTTP/1.1\" 503" if splice and i == 1 else ""
        print(f"Autotuning kernel _chunk_scan_fwd_kernel with config {cfg_text(m, n, w, st)}{tail}", flush=True)
    print(f"Triton autotuning for function _chunk_scan_fwd_kernel,\nwith key as {key},\nfinished after 1.50s,\n"
          f"best config selected: {cfg_text(*CONFIGS[best])};", flush=True)


def specialise(attrs, seconds=1.0, sig=SIG2):
    m, n, w, st = CONFIGS[2]
    triton.fake_compile("_chunk_scan_fwd_kernel", MAMBA, seconds, constants={(2,): m, (3,): n}, signature=sig, attrs=attrs, num_warps=w, num_stages=st)


KEY1 = "(256, 64, 128, True, 'torch.float32')"
KEY2 = "(256, 64, 128, True, 'torch.float32', 'torch.int32')"
A16 = {(0,): [["tt.divisibility", 16]]}
A16B = {(0,): [["tt.divisibility", 16]], (1,): [["tt.divisibility", 16]]}
A1 = {}
compile_("write_req_to_token_pool_triton", MISC, 0.09)
if SCENARIO in ("gatefail", "latedisable"):
    if SCENARIO == "latedisable":
        log.info("Disable prefill CUDA graph because some layers do not apply Standard GQA")
    log.info("Capture target prefill CUDA graph begin. backend=breakable, num_tokens=[4, 8]")
    compile_("_chunk_scan_fwd_kernel", MAMBA, 0.8)
else:
    log.info("Disable prefill CUDA graph because some layers do not apply Standard GQA")
warm = a.warmups == "prefill_shapes"
if SCENARIO == "norepro" or (SCENARIO == "repro" and warm):
    compile_("_chunk_scan_fwd_kernel", MAMBA, 1.2)
    compile_("_chunk_state_fwd_kernel", STATE, 0.4)
log.info("Capture target decode CUDA graph begin. backend=full")
triton_load_watch.install()
triton_load_watch.mark_serving_started()
compile_("_small_copy_kernel", MISC, 0.1)
if warm:
    log.info("Running warmup prefill_shapes")
    if SCENARIO in ("moveall", "movesome"):
        autotune(KEY1, A16, splice=os.environ.get("FAKE_SPLICE") == "1")
    if SCENARIO == "moveall":
        specialise(A16B, sig=SIG)
        autotune(KEY2, A16, SIG2)
    log.info("Warmup ended")
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
                first = state["bursts"] == 1
                stall = 0.0
                if first:
                    if SCENARIO in ("repro", "hookdead") and not warm:
                        compile_("_chunk_scan_fwd_kernel", MAMBA, 1.45)
                        compile_("_chunk_scan_fwd_kernel", MAMBA, 1.0)
                        compile_("_chunk_state_fwd_kernel", STATE, 0.3)
                        stall = 2750.0
                    if SCENARIO == "movesome":
                        autotune(KEY2, A16, SIG2)
                        specialise(A1, 1.2)
                        stall = 1500.0
                    if SCENARIO == "noeffect":
                        for i in range(60):
                            specialise({(0,): [["tt.divisibility", 16]], (9,): i}, 0.2)
                        stall = 2500.0
                    compile_("_small_copy_kernel", MISC, 0.12)
                if SCENARIO == "movesome" and "seed=161" in self.path:
                    specialise(A16B, 1.0)
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
