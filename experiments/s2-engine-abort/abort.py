"""S2, engine half: does the engine stop a request when its client connection closes?

Issue #578. The gateway half is #572: on `client_gone` or `idle_timeout` the gateway closes the upstream
connection without a clean end, so from the engine's side the gateway is the client that went away.

The engine runs with one slot (`--max-num-seqs 1`) and 100 ms per token. Each case sends one request of
MAX_TOKENS tokens with `ignore_eos`, then:

  control      streams and reads up to the [DONE] frame;
  stream_cut   streams, reads five frames and closes the socket;
  plain_cut    sends a non-streamed request and closes the socket after one second.

Right after the cut a one-token streamed probe is sent.
With one slot, the probe's time to first byte is the release signal: a probe that waits out the rest of the
first request means the engine kept generating for a client that was gone.
A verdict is printed per case, and the run exits non-zero when the control itself does not release quickly,
because then the probe measures the harness, not the engine.

Standard library only. Usage: python3 -I abort.py PORT REPS
"""

from __future__ import annotations

import http.client
import json
import re
import socket
import sys
import time

HOST = "127.0.0.1"
MAX_TOKENS = 50
TOKEN_SECONDS = 0.1
# A probe slower than this waited on the first request; the full request would take MAX_TOKENS * TOKEN_SECONDS.
RELEASED_BELOW_SECONDS = 1.0


def metrics(port: int) -> dict:
    conn = http.client.HTTPConnection(HOST, port, timeout=5)
    conn.request("GET", "/metrics")
    text = conn.getresponse().read().decode()
    out = {}
    for name in ("num_requests_running", "num_requests_waiting", "generation_tokens_total"):
        found = re.search(r"^vllm:%s\{[^}]*\} ([0-9.e+]+)$" % name, text, re.M)
        # A counter appears only after its first observation, and an absent counter has counted nothing.
        out[name] = float(found.group(1)) if found else 0.0
    out["success"] = {
        reason: float(value)
        for reason, value in re.findall(
            r'^vllm:request_success_total\{finished_reason="([^"]+)"[^}]*\} ([0-9.e+]+)$', text, re.M)
    }
    return out


def send(port: int, stream: bool, max_tokens: int) -> socket.socket:
    # A raw socket, so closing it is a real disconnect and not a pooled connection kept alive by a client library.
    body = json.dumps({"model": "m", "messages": [{"role": "user", "content": "hi"}],
                       "max_tokens": max_tokens, "ignore_eos": True, "stream": stream}).encode()
    sock = socket.create_connection((HOST, port))
    sock.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: engine\r\nContent-Type: application/json\r\n"
                 b"Content-Length: %d\r\n\r\n" % len(body) + body)
    return sock


def read_until(sock: socket.socket, marker: bytes, count: int, timeout: float) -> None:
    sock.settimeout(timeout)
    buf = b""
    while buf.count(marker) < count:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("connection closed before %d x %r" % (count, marker))
        buf += chunk


def probe_ttfb(port: int) -> float:
    started = time.monotonic()
    sock = send(port, True, 1)
    read_until(sock, b"data:", 1, 30)
    ttfb = time.monotonic() - started
    sock.close()
    return ttfb


def wait_idle(port: int, since: float, limit: float = 30) -> float | None:
    while time.monotonic() - since < limit:
        m = metrics(port)
        if m["num_requests_running"] == 0 and m["num_requests_waiting"] == 0:
            return time.monotonic() - since
        time.sleep(0.05)
    return None


def run_case(port: int, name: str) -> dict:
    before = metrics(port)
    sock = send(port, name != "plain_cut", MAX_TOKENS)
    if name == "control":
        # Keep-alive leaves the socket open, so the stream's end is the [DONE] frame, not EOF.
        read_until(sock, b"[DONE]", 1, 30)
    elif name == "stream_cut":
        read_until(sock, b"data:", 5, 30)
    else:
        time.sleep(1.0)
    cut_at = time.monotonic()
    sock.close()
    probe = probe_ttfb(port)
    idle = wait_idle(port, cut_at)
    after = metrics(port)
    success = {
        reason: after["success"].get(reason, 0) - before["success"].get(reason, 0)
        for reason in set(after["success"]) | set(before["success"])
    }
    return {
        "case": name,
        "probe_ttfb_s": round(probe, 3),
        "idle_after_cut_s": None if idle is None else round(idle, 3),
        "released": probe < RELEASED_BELOW_SECONDS,
        "generated_tokens_incl_probe": after["generation_tokens_total"] - before["generation_tokens_total"],
        "success_delta": {k: v for k, v in sorted(success.items()) if v},
    }


def main() -> int:
    port = int(sys.argv[1])
    reps = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    control_ok = True
    for _ in range(reps):
        for name in ("control", "stream_cut", "plain_cut"):
            row = run_case(port, name)
            print(json.dumps(row), flush=True)
            if name == "control" and not row["released"]:
                control_ok = False
            time.sleep(0.5)
    if not control_ok:
        print("FAIL: the control did not release its slot, so the probe does not measure the engine", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
