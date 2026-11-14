"""S2, engine half: does the engine stop a request when its client connection closes?

Issues #578 (simulator) and #580 (vLLM v0.27.1 on CPU). The gateway half is #572: on `client_gone` or `idle_timeout` the
gateway records the cut and closes the upstream connection without a clean end, so from the engine's side the gateway
is a client that went away.

The engine runs one sequence at a time, so a one-token probe can only be answered from a free slot.
Every row is either valid, with the conditions its case depends on checked, or invalid with the reason; a run with an
invalid row, a control that does not release, or a busy control that does release exits non-zero.

Cases:
  control           streams and reads up to [DONE]; the probe after it is the baseline for a free slot.
  busy_control      keeps a stream alive and probes while it runs; the probe must wait, or it can overtake a request
                    and then says nothing about a cut.
  stream_cut        streams, reads five SSE events and closes.
  plain_cut         sends a non-streamed request and closes --cut-after seconds in.
  prefill_baseline  sends the long prompt uncut and records its prompt tokens and time to first event.
  prefill_cut       sends the long prompt and closes once the engine runs it and before any response byte arrived.
  queued_cut        queues a request behind a holder that is drained and timed on its own thread, closes the queued
                    one while it waits, and requires the queue to clear before the holder finishes.

Release is judged on the probe's time to first event in excess of the idle baseline measured at the start of the run,
and it also needs the engine to reach idle afterwards.
Counters are read only once two consecutive scrapes agree.

Standard library only. Usage: python3 -I abort.py --port PORT [--reps N] [--cases a,b] [...]
"""

from __future__ import annotations

import argparse
import http.client
import json
import re
import socket
import sys
import threading
import time

HOST = "127.0.0.1"
CASES = ("control", "busy_control", "stream_cut", "plain_cut", "prefill_baseline", "prefill_cut", "queued_cut")
GAUGES = ("num_requests_running", "num_requests_waiting")
COUNTERS = ("generation_tokens_total",)


class Invalid(Exception):
    """A row whose case did not happen as named; it is recorded, never scored."""


def metrics(port: int) -> dict:
    conn = http.client.HTTPConnection(HOST, port, timeout=10)
    conn.request("GET", "/metrics")
    resp = conn.getresponse()
    text = resp.read().decode()
    if resp.status != 200:
        raise Invalid("metrics returned HTTP %d" % resp.status)
    out: dict = {}
    for name in GAUGES + COUNTERS:
        # The name must be followed by `{` so that `num_requests_waiting_by_reason` does not match.
        series = re.findall(r"^vllm:%s\{([^}]*)\} ([0-9.e+]+)$" % name, text, re.M)
        if len(series) > 1:
            # Reading the first of several engines would call a busy engine idle.
            raise Invalid("%d series for vllm:%s; one engine is assumed" % (len(series), name))
        if not series:
            if name in GAUGES:
                # A gauge is published from the start, so a missing one means the scrape is not this engine's.
                raise Invalid("vllm:%s missing from metrics" % name)
            # A counter appears only after its first observation, and an absent counter has counted nothing.
            out[name] = 0.0
        else:
            out[name] = float(series[0][1])
    # vLLM puts `engine` before `finished_reason` and the simulator does not, so the label is found anywhere.
    out["success"] = {}
    for labels, value in re.findall(r"^vllm:request_success_total\{([^}]*)\} ([0-9.e+]+)$", text, re.M):
        reason = re.search(r'finished_reason="([^"]+)"', labels)
        if reason:
            if reason.group(1) in out["success"]:
                raise Invalid("several series for finished_reason=%s; one engine is assumed" % reason.group(1))
            out["success"][reason.group(1)] = float(value)
    return out


def stable_metrics(port: int, limit: float = 10) -> dict:
    """Metrics once two scrapes 0.2 s apart agree, so a late update is not left between two rows."""
    deadline = time.monotonic() + limit
    last = metrics(port)
    while time.monotonic() < deadline:
        time.sleep(0.2)
        now = metrics(port)
        if now == last:
            return now
        last = now
    raise Invalid("metrics did not settle within %.0f s" % limit)


def send(port: int, stream: bool, max_tokens: int, prompt: str = "hi") -> socket.socket:
    # A raw socket, so closing it is a real disconnect and not a pooled connection kept alive by a client library.
    body = {"model": "m", "messages": [{"role": "user", "content": prompt}], "max_tokens": max_tokens,
            "ignore_eos": True, "stream": stream}
    if stream:
        body["stream_options"] = {"include_usage": True}
    data = json.dumps(body).encode()
    sock = socket.create_connection((HOST, port))
    sock.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: engine\r\nContent-Type: application/json\r\n"
                 b"Content-Length: %d\r\n\r\n" % len(data) + data)
    return sock


class Stream:
    """Reads one HTTP response from a raw socket and splits its SSE events."""

    def __init__(self, sock: socket.socket, started: float):
        self.sock, self.started = sock, started
        self.raw, self.buf = b"", b""
        self.status: int | None = None
        self.chunked = False
        self.first_event_at: float | None = None
        self.events: list[dict] = []
        self.done = False

    def _decode(self) -> None:
        if self.status is None:
            end = self.raw.find(b"\r\n\r\n")
            if end < 0:
                return
            head, self.raw = self.raw[:end].decode("latin-1"), self.raw[end + 4:]
            lines = head.split("\r\n")
            self.status = int(lines[0].split()[1])
            self.chunked = any(l.lower().replace(" ", "") == "transfer-encoding:chunked" for l in lines[1:])
        if not self.chunked:
            self.buf, self.raw = self.buf + self.raw, b""
            return
        # A chunk boundary can fall inside an event's JSON, so the body is reassembled before events are split.
        while True:
            eol = self.raw.find(b"\r\n")
            if eol < 0:
                return
            size = int(self.raw[:eol].split(b";")[0], 16)
            if len(self.raw) < eol + 2 + size + 2:
                return
            self.buf += self.raw[eol + 2:eol + 2 + size]
            self.raw = self.raw[eol + 2 + size + 2:]
            if size == 0:
                return

    def _pump(self, timeout: float) -> None:
        self.sock.settimeout(timeout)
        chunk = self.sock.recv(65536)
        if not chunk:
            raise Invalid("connection closed before the response ended")
        self.raw += chunk
        self._decode()
        while True:
            # SSE events end with a blank line; frames are counted as events, not as `data:` substrings.
            cut = self.buf.find(b"\n\n")
            if cut < 0:
                break
            raw, self.buf = self.buf[:cut], self.buf[cut + 2:]
            for line in raw.split(b"\n"):
                line = line.strip()
                if not line.startswith(b"data:"):
                    continue
                payload = line[5:].strip()
                if self.first_event_at is None:
                    self.first_event_at = time.monotonic()
                if payload == b"[DONE]":
                    self.done = True
                    continue
                event = json.loads(payload)
                if "error" in event:
                    raise Invalid("engine sent an SSE error: %s" % str(event["error"])[:200])
                self.events.append(event)

    def read_events(self, count: int, timeout: float) -> None:
        while len(self.events) < count and not self.done:
            self._pump(timeout)

    def read_to_done(self, timeout: float) -> None:
        while not self.done:
            self._pump(timeout)
        if self.status != 200:
            raise Invalid("stream answered HTTP %s" % self.status)


def probe(port: int, limit: float) -> float:
    """Time to the probe's first SSE event; the probe has to finish with one token and no error."""
    started = time.monotonic()
    s = Stream(send(port, True, 1), started)
    s.read_to_done(limit)
    s.sock.close()
    finishes = [c.get("finish_reason") for e in s.events for c in e.get("choices", []) if c.get("finish_reason")]
    if finishes != ["length"]:
        raise Invalid("probe finished with %s, not one length" % finishes)
    return s.first_event_at - started


def wait_for(port: int, done, limit: float) -> float | None:
    since = time.monotonic()
    while time.monotonic() - since < limit:
        if done(metrics(port)):
            return time.monotonic() - since
        time.sleep(0.02)
    return None


def idle(m: dict) -> bool:
    return m["num_requests_running"] == 0 and m["num_requests_waiting"] == 0


def baseline_probe(port: int, limit: float) -> float:
    if wait_for(port, idle, limit) is None:
        raise Invalid("engine not idle before the baseline")
    return max(probe(port, limit) for _ in range(3))


def long_prompt(words: int) -> str:
    # A prompt seen before is a prefix-cache hit whose prefill is nearly free; a nonce in front makes it a miss.
    return "%d %s" % (time.time_ns(), " ".join(["hello"] * words))


def finish_with_probe(port: int, row: dict, a: argparse.Namespace, limit: float) -> None:
    ttfb = probe(port, limit)
    settled = wait_for(port, idle, limit)
    row["probe_ttfb_s"] = round(ttfb, 3)
    row["probe_excess_s"] = round(ttfb - a.baseline, 3)
    row["idle_after_probe_s"] = None if settled is None else round(settled, 3)
    row["released"] = settled is not None and ttfb - a.baseline < a.release_threshold


def run_case(port: int, name: str, a: argparse.Namespace) -> dict:
    limit = a.max_tokens * a.token_seconds * 4 + 60
    if wait_for(port, idle, limit) is None:
        raise Invalid("engine not idle before the case")
    before = stable_metrics(port)
    row: dict = {"case": name}

    if name == "control":
        started = time.monotonic()
        s = Stream(send(port, True, a.max_tokens), started)
        s.read_to_done(limit)
        s.sock.close()
        row["request_duration_s"] = round(time.monotonic() - started, 3)
        finish_with_probe(port, row, a, limit)

    elif name == "busy_control":
        s = Stream(send(port, True, a.max_tokens), time.monotonic())
        s.read_events(5, limit)
        # Drained on a thread so the target never stalls on a full socket while the probe waits.
        drained = threading.Thread(target=s.read_to_done, args=(limit,), daemon=True)
        drained.start()
        finish_with_probe(port, row, a, limit)
        drained.join(limit)
        s.sock.close()

    elif name in ("stream_cut", "plain_cut"):
        s = Stream(send(port, name == "stream_cut", a.max_tokens), time.monotonic())
        if name == "stream_cut":
            s.read_events(5, limit)
            row["events_before_cut"] = len(s.events)
        else:
            time.sleep(a.cut_after)
        s.sock.close()
        finish_with_probe(port, row, a, limit)

    elif name == "prefill_baseline":
        started = time.monotonic()
        s = Stream(send(port, True, 1, prompt=long_prompt(a.long_prompt_words)), started)
        s.read_to_done(limit)
        s.sock.close()
        usage = [e["usage"] for e in s.events if e.get("usage")]
        row["prompt_tokens"] = usage[-1]["prompt_tokens"] if usage else None
        row["first_event_s"] = round(s.first_event_at - started, 3)
        a.prefill_first_event = s.first_event_at - started
        settled = wait_for(port, idle, limit)
        row["released"] = settled is not None

    elif name == "prefill_cut":
        # vLLM publishes num_requests_running after a step, so the gauge turns 1 only once the prefill step is done
        # and cannot mark "in prefill"; the cut is timed as a fraction of the uncut first event measured this rep.
        if a.prefill_first_event is None:
            raise Invalid("no prefill_baseline earlier in this rep to time the cut from")
        started = time.monotonic()
        sock = send(port, True, a.max_tokens, prompt=long_prompt(a.long_prompt_words))
        time.sleep(a.prefill_first_event * a.cut_fraction)
        # vLLM may send the headers before any output, so the test is for an SSE event, not for any byte.
        sock.setblocking(False)
        try:
            early = sock.recv(65536, socket.MSG_PEEK)
        except BlockingIOError:
            early = b""
        if b"data:" in early:
            raise Invalid("an SSE event arrived before the cut, so the cut was not before the first token")
        sock.close()
        row["cut_after_send_s"] = round(time.monotonic() - started, 3)
        row["uncut_first_event_s"] = round(a.prefill_first_event, 3)
        finish_with_probe(port, row, a, limit)
        # A probe that waits past the idle baseline shows the engine was running this prefill when the cut came;
        # without that wait the cut may have landed before the engine took the request at all.
        if row["probe_excess_s"] <= a.busy_excess:
            raise Invalid("the probe did not wait (excess %.3f s), so the cut may have come before the engine took "
                          "the request" % row["probe_excess_s"])

    elif name == "queued_cut":
        holder = Stream(send(port, True, a.max_tokens), time.monotonic())
        holder.read_events(1, limit)
        holder_done: dict = {}

        def drain() -> None:
            holder.read_to_done(limit)
            holder_done["at"] = time.monotonic()

        drained = threading.Thread(target=drain, daemon=True)
        drained.start()
        queued = send(port, True, a.max_tokens)
        if wait_for(port, lambda m: m["num_requests_waiting"] >= 1, 30) is None:
            raise Invalid("the second request never waited")
        cut_at = time.monotonic()
        queued.close()
        cleared = wait_for(port, lambda m: m["num_requests_waiting"] == 0, limit)
        cleared_at = time.monotonic()
        running_then = metrics(port)["num_requests_running"]
        drained.join(limit)
        holder.sock.close()
        if cleared is None or "at" not in holder_done:
            raise Invalid("the queue or the holder did not finish")
        # The case needs the cut to land while the holder still runs; otherwise nothing was queued behind it.
        if holder_done["at"] <= cut_at:
            raise Invalid("the holder finished before the cut, so the request was not cut while queued")
        row["waiting_cleared_after_cut_s"] = round(cleared, 3)
        row["holder_done_after_cut_s"] = round(holder_done["at"] - cut_at, 3)
        row["running_when_cleared"] = running_then
        finish_with_probe(port, row, a, limit)
        # The waiting gauge also falls when a request starts running, which needs the holder gone first, so only a
        # queue that clears while the holder still runs is a removal; the probe only shows the engine came back.
        row["released"] = row["released"] and holder_done["at"] > cleared_at and running_then == 1

    after = stable_metrics(port)
    row["generation_counter_delta"] = after["generation_tokens_total"] - before["generation_tokens_total"]
    row["success_counter_delta"] = {
        r: after["success"].get(r, 0) - before["success"].get(r, 0)
        for r in sorted(set(after["success"]) | set(before["success"]))
        if after["success"].get(r, 0) - before["success"].get(r, 0)
    }
    return row


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--cases", default="control,busy_control,stream_cut,plain_cut")
    p.add_argument("--max-tokens", type=int, default=50)
    p.add_argument("--token-seconds", type=float, default=0.1, help="rough time per token, only for timeouts")
    p.add_argument("--release-threshold", type=float, default=1.0,
                   help="a probe slower than the idle baseline by this much waited on the cut request")
    p.add_argument("--cut-after", type=float, default=1.0)
    p.add_argument("--long-prompt-words", type=int, default=1500)
    p.add_argument("--cut-fraction", type=float, default=0.4,
                   help="prefill_cut closes at this fraction of the uncut long prompt's first event")
    p.add_argument("--busy-excess", type=float, default=0.05,
                   help="probe excess above which the engine counts as having been busy with the cut request")
    a = p.parse_args()
    a.prefill_first_event = None
    cases = [c for c in a.cases.split(",") if c]
    unknown = set(cases) - set(CASES)
    if unknown:
        p.error("unknown cases: %s" % ", ".join(sorted(unknown)))
    limit = a.max_tokens * a.token_seconds * 4 + 60
    a.baseline = baseline_probe(a.port, limit)
    print(json.dumps({"case": "idle_probe_baseline", "probe_ttfb_s": round(a.baseline, 3),
                      "args": {k: v for k, v in vars(a).items() if k != "baseline"}}), flush=True)
    failures = []
    for rep in range(a.reps):
        for name in cases:
            try:
                row = run_case(a.port, name, a)
                row["valid"] = True
            except Invalid as e:
                row = {"case": name, "valid": False, "invalid_reason": str(e)}
                failures.append("%s rep %d invalid: %s" % (name, rep, e))
            row["rep"] = rep
            print(json.dumps(row), flush=True)
            if row.get("valid") and name == "control" and not row["released"]:
                failures.append("control rep %d did not release" % rep)
            if row.get("valid") and name == "busy_control" and row["released"]:
                failures.append("busy_control rep %d released, so the probe can overtake a running request" % rep)
            time.sleep(0.5)
    for f in failures:
        print("FAIL: " + f, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
