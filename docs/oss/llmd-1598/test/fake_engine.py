"""A fake vLLM OpenAI server for the kit's offline tests.

It speaks the parts of vLLM 0.34.0 the kit and the EPP use: streamed `/v1/completions` over token-ID prompts with a usage record,
`/metrics` in vLLM's Prometheus names, `/reset_prefix_cache`, `/health` and `/v1/models`.
Prefix caching is modelled per 16-token block with an LRU of a fixed number of blocks, so cached_tokens behaves like the engine's.
Faults can be switched on per instance so the tests can show that the kit's checks fail when they should.
"""

import argparse
import json
import threading
import time
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BLOCK = 16


class Engine:
    def __init__(self, name, blocks, max_seqs, prefill_us_per_token, itl_ms, faults=()):
        self.name = name
        self.blocks = blocks
        self.max_seqs = max_seqs
        self.prefill_us = prefill_us_per_token
        self.itl = itl_ms / 1000.0
        self.faults = set(faults)
        self.lock = threading.Lock()
        self.slots = threading.Semaphore(max_seqs)
        self.cache = OrderedDict()
        self.running = 0
        self.waiting = 0
        self.c = dict(prompt=0, generation=0, cached=0, success=0, hits=0, queries=0)

    def _hashes(self, ids):
        out, h = [], 0
        for i in range(len(ids) // BLOCK):
            h = hash((h, tuple(ids[i * BLOCK:(i + 1) * BLOCK])))
            out.append(h)
        return out

    def admit(self, ids):
        # Longest cached prefix in whole blocks, then the request's own blocks become most recently used.
        hs = self._hashes(ids)
        with self.lock:
            n = 0
            for h in hs:
                if h in self.cache:
                    n += 1
                else:
                    break
            for h in hs:
                self.cache[h] = True
                self.cache.move_to_end(h)
            while len(self.cache) > self.blocks:
                self.cache.popitem(last=False)
        cached = n * BLOCK
        if cached >= len(ids):
            # vLLM always recomputes at least the last token.
            cached = max(0, (len(ids) - 1) // BLOCK * BLOCK)
        return cached

    def reset(self):
        with self.lock:
            if self.running or self.waiting or "reset_fails" in self.faults:
                return False
            self.cache.clear()
            return True

    def metrics(self):
        with self.lock:
            c = dict(self.c)
            run, wait = self.running, self.waiting
            usage = min(1.0, len(self.cache) / max(1, self.blocks))
        lbl = f'model_name="Qwen/Qwen2.5-3B-Instruct",engine="0"'
        lines = [
            f"vllm:num_requests_running{{{lbl}}} {run}",
            f"vllm:num_requests_waiting{{{lbl}}} {wait}",
            f"vllm:kv_cache_usage_perc{{{lbl}}} {usage}",
            f"vllm:prompt_tokens_total{{{lbl}}} {c['prompt']}",
            f"vllm:generation_tokens_total{{{lbl}}} {c['generation']}",
            f"vllm:prompt_tokens_cached_total{{{lbl}}} {c['cached']}",
            f"vllm:prefix_cache_hits_total{{{lbl}}} {c['hits']}",
            f"vllm:prefix_cache_queries_total{{{lbl}}} {c['queries']}",
            f"vllm:num_preemptions_total{{{lbl}}} 0",
            f'vllm:request_success_total{{finished_reason="length",{lbl}}} {c["success"]}',
            f'vllm:cache_config_info{{block_size="{BLOCK}",enable_prefix_caching="True",num_gpu_blocks="{self.blocks}",{lbl}}} 1.0',
            f'vllm:inter_token_latency_seconds_bucket{{le="+Inf",{lbl}}} {c["generation"]}',
            f"vllm:inter_token_latency_seconds_count{{{lbl}}} {c['generation']}",
            f"vllm:inter_token_latency_seconds_sum{{{lbl}}} {c['generation'] * self.itl}",
        ]
        return "\n".join(lines) + "\n"


def make_handler(eng):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype="application/json"):
            b = body.encode() if isinstance(body, str) else body
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path == "/metrics":
                return self._send(200, eng.metrics(), "text/plain; version=0.0.4")
            if self.path in ("/health", "/ping"):
                return self._send(200, "")
            if self.path == "/v1/models":
                return self._send(200, json.dumps({"object": "list", "data": [{"id": "Qwen/Qwen2.5-3B-Instruct", "object": "model"}]}))
            return self._send(404, "{}")

        def _body(self):
            # Envoy forwards the EPP's re-streamed body chunked, with no Content-Length, as vLLM's server accepts.
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                out = b""
                while True:
                    size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                    if size == 0:
                        while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                            pass
                        return out
                    out += self.rfile.read(size)
                    self.rfile.readline()
            n = int(self.headers.get("Content-Length", 0))
            return self.rfile.read(n) if n else b""

        def do_POST(self):
            raw = self._body()
            if self.path.startswith("/reset_prefix_cache"):
                return self._send(200, json.dumps({"success": eng.reset()}))
            if self.path != "/v1/completions":
                return self._send(404, "{}")
            req = json.loads(raw or b"{}")
            ids = req.get("prompt")
            if not isinstance(ids, list) or not all(isinstance(x, int) for x in ids):
                return self._send(400, json.dumps({"error": "this fake takes token-ID prompts only", "got": str(raw[:300])}))
            mt = int(req.get("max_tokens", 16))
            # vLLM's streaming response sends its status and headers before the request is even scheduled.
            # Its body starts only with the first token.
            # The first version of this fake sent headers after prefill, which hid that Envoy's first upstream byte is the
            # headers, and let the second pilot's bound pass offline and void every GPU burst.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.flush()
            with eng.lock:
                eng.waiting += 1
            eng.slots.acquire()
            with eng.lock:
                eng.waiting -= 1
                eng.running += 1
            try:
                cached = eng.admit(ids)
                time.sleep((len(ids) - cached) * eng.prefill_us / 1e6)

                def chunk(obj):
                    data = ("data: " + (obj if isinstance(obj, str) else json.dumps(obj)) + "\n\n").encode()
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                    self.wfile.flush()

                rid = "cmpl-" + str(time.monotonic_ns())
                for i in range(mt):
                    if i:
                        time.sleep(eng.itl)
                    chunk({"id": rid, "object": "text_completion", "choices": [{"index": 0, "text": " t", "finish_reason": None}], "usage": None})
                gen = mt + (1 if "token_off_by_one" in eng.faults else 0)
                usage = {"prompt_tokens": len(ids), "completion_tokens": mt, "total_tokens": len(ids) + mt,
                         "prompt_tokens_details": {"cached_tokens": cached}}
                if "drop_usage" not in eng.faults:
                    chunk({"id": rid, "object": "text_completion", "choices": [], "usage": usage})
                chunk("[DONE]")
                self.wfile.write(b"0\r\n\r\n")
                with eng.lock:
                    eng.c["prompt"] += len(ids)
                    eng.c["generation"] += gen
                    eng.c["cached"] += cached
                    eng.c["hits"] += cached
                    eng.c["queries"] += len(ids)
                    eng.c["success"] += 1
            except (BrokenPipeError, ConnectionResetError):
                # A client that goes away still cost the engine its prefill, as vLLM's counters would show.
                with eng.lock:
                    eng.c["prompt"] += len(ids)
                    eng.c["queries"] += len(ids)
            finally:
                with eng.lock:
                    eng.running -= 1
                eng.slots.release()

    return H


def serve(port, **kw):
    eng = Engine(**kw)
    srv = ThreadingHTTPServer(("127.0.0.1", port), make_handler(eng))
    srv.daemon_threads = True
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return eng, srv


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--blocks", type=int, default=4096)
    ap.add_argument("--max-seqs", type=int, default=16)
    ap.add_argument("--prefill-us", type=float, default=50.0)
    ap.add_argument("--itl-ms", type=float, default=5.0)
    ap.add_argument("--fault", action="append", default=[])
    a = ap.parse_args()
    serve(a.port, name=str(a.port), blocks=a.blocks, max_seqs=a.max_seqs, prefill_us_per_token=a.prefill_us, itl_ms=a.itl_ms, faults=a.fault)
    while True:
        time.sleep(3600)
