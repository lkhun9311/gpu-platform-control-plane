"""S2, engine half: does the engine stop a request when its client connection closes?

Issues #578 (simulator) and #580 (vLLM on CPU). The gateway half is #572: on `client_gone` or `idle_timeout` the
gateway records the cut and closes the upstream connection without a clean end, so from the engine's side the
gateway is a client that went away.

The engine runs one sequence at a time. Each case sends one request of --max-tokens tokens with `ignore_eos`:

  control       streams and reads up to the [DONE] frame;
  stream_cut    streams, reads five frames and closes the socket;
  plain_cut     sends a non-streamed request and closes the socket --cut-after seconds in;
  prefill_cut   streams a long prompt and closes the socket --cut-after-prefill seconds in, before any token;
  queued_cut    starts a holder request, queues a second one behind it, closes the second while it waits,
                then lets the holder finish.

After the cut a one-token streamed probe is sent, and with one slot its time to first byte is the release signal.
For queued_cut the release signal is the waiting gauge returning to 0 while the holder still runs.
A verdict is printed per case, and the run exits non-zero when the control does not release, because then the
probe measures the harness, not the engine.

Standard library only. Usage: python3 -I abort.py --port PORT [--reps N] [--cases a,b] [...]
"""

from __future__ import annotations

import argparse
import http.client
import json
import re
import socket
import sys
import time

HOST = "127.0.0.1"
CASES = ("control", "stream_cut", "plain_cut", "prefill_cut", "queued_cut")


def metrics(port: int) -> dict:
    conn = http.client.HTTPConnection(HOST, port, timeout=10)
    conn.request("GET", "/metrics")
    text = conn.getresponse().read().decode()
    out = {}
    for name in ("num_requests_running", "num_requests_waiting", "generation_tokens_total"):
        # The name must be followed by `{` so that `num_requests_waiting_by_reason` does not match.
        found = re.search(r"^vllm:%s\{[^}]*\} ([0-9.e+]+)$" % name, text, re.M)
        # A counter appears only after its first observation, and an absent counter has counted nothing.
        out[name] = float(found.group(1)) if found else 0.0
    # vLLM puts `engine` before `finished_reason` and the simulator does not, so the label is found anywhere.
    out["success"] = {}
    for labels, value in re.findall(r"^vllm:request_success_total\{([^}]*)\} ([0-9.e+]+)$", text, re.M):
        reason = re.search(r'finished_reason="([^"]+)"', labels)
        if reason:
            out["success"][reason.group(1)] = out["success"].get(reason.group(1), 0.0) + float(value)
    return out


def send(port: int, stream: bool, max_tokens: int, prompt: str = "hi") -> socket.socket:
    # A raw socket, so closing it is a real disconnect and not a pooled connection kept alive by a client library.
    body = json.dumps({"model": "m", "messages": [{"role": "user", "content": prompt}],
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


def probe_ttfb(port: int, timeout: float) -> float:
    started = time.monotonic()
    sock = send(port, True, 1)
    read_until(sock, b"data:", 1, timeout)
    ttfb = time.monotonic() - started
    sock.close()
    return ttfb


def wait_for(port: int, since: float, done, limit: float) -> float | None:
    while time.monotonic() - since < limit:
        if done(metrics(port)):
            return time.monotonic() - since
        time.sleep(0.05)
    return None


def idle(m: dict) -> bool:
    return m["num_requests_running"] == 0 and m["num_requests_waiting"] == 0


def run_case(port: int, name: str, a: argparse.Namespace) -> dict:
    limit = a.max_tokens * a.token_seconds * 4 + 60
    before = metrics(port)
    row: dict = {"case": name}
    if name == "queued_cut":
        holder = send(port, True, a.max_tokens)
        read_until(holder, b"data:", 1, limit)
        queued = send(port, True, a.max_tokens)
        queued_seen = wait_for(port, time.monotonic(), lambda m: m["num_requests_waiting"] >= 1, 30)
        if queued_seen is None:
            raise RuntimeError("the second request never waited, so the case does not test a queued cut")
        cut_at = time.monotonic()
        queued.close()
        waiting_cleared = wait_for(port, cut_at, lambda m: m["num_requests_waiting"] == 0, limit)
        read_until(holder, b"[DONE]", 1, limit)
        holder.close()
        row["waiting_cleared_after_cut_s"] = None if waiting_cleared is None else round(waiting_cleared, 3)
        # The holder ends near when the queued request would have started, so the slot verdict comes from the
        # waiting gauge clearing well before the holder could have released it.
        row["released"] = waiting_cleared is not None and waiting_cleared < a.release_threshold
        wait_for(port, time.monotonic(), idle, limit)
        row["probe_ttfb_s"] = round(probe_ttfb(port, limit), 3)
    else:
        if name == "prefill_cut":
            # A prompt seen before is a prefix-cache hit whose prefill is nearly free, and the cut then lands
            # after the first tokens; the nonce in front makes every rep's prompt a miss.
            nonce = "%d-%d" % (time.time_ns(), id(row))
            sock = send(port, True, a.max_tokens, prompt=nonce + " " + " ".join(["hello"] * a.long_prompt_words))
            time.sleep(a.cut_after_prefill)
        else:
            sock = send(port, name != "plain_cut", a.max_tokens)
            if name == "control":
                # Keep-alive leaves the socket open, so the stream's end is the [DONE] frame, not EOF.
                read_until(sock, b"[DONE]", 1, limit)
            elif name == "stream_cut":
                read_until(sock, b"data:", 5, limit)
            else:
                time.sleep(a.cut_after)
        cut_at = time.monotonic()
        sock.close()
        probe = probe_ttfb(port, limit)
        settled = wait_for(port, cut_at, idle, limit)
        row["probe_ttfb_s"] = round(probe, 3)
        row["idle_after_cut_s"] = None if settled is None else round(settled, 3)
        row["released"] = probe < a.release_threshold
    after = metrics(port)
    row["generated_tokens_incl_probe"] = after["generation_tokens_total"] - before["generation_tokens_total"]
    row["success_delta"] = {
        reason: after["success"].get(reason, 0) - before["success"].get(reason, 0)
        for reason in sorted(set(after["success"]) | set(before["success"]))
        if after["success"].get(reason, 0) - before["success"].get(reason, 0)
    }
    return row


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--cases", default="control,stream_cut,plain_cut")
    p.add_argument("--max-tokens", type=int, default=50)
    p.add_argument("--token-seconds", type=float, default=0.1, help="rough time per token, only for timeouts")
    p.add_argument("--release-threshold", type=float, default=1.0,
                   help="a probe slower than this waited on the cut request")
    p.add_argument("--cut-after", type=float, default=1.0)
    p.add_argument("--cut-after-prefill", type=float, default=0.3)
    p.add_argument("--long-prompt-words", type=int, default=1500)
    a = p.parse_args()
    cases = [c for c in a.cases.split(",") if c]
    unknown = set(cases) - set(CASES)
    if unknown:
        p.error("unknown cases: %s" % ", ".join(sorted(unknown)))
    control_ok = True
    for _ in range(a.reps):
        for name in cases:
            row = run_case(a.port, name, a)
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
