"""S2, engine half: does the engine stop a request when its client connection closes?

Issues #578 (simulator) and #580 (vLLM v0.27.1 on CPU). The gateway half is #572: on `client_gone` or `idle_timeout` the
gateway records the cut and closes the upstream connection without a clean end, so from the engine's side the gateway
is a client that went away.

The engine runs one sequence at a time, so a one-token probe can only be answered from a free slot.
Every row is either valid, with the conditions its case depends on checked, or invalid with the reason; a run with an
invalid row, a control that does not release, or a busy control that does release exits non-zero.

Cases:
  control           streams to [DONE] with the full token count; its probe shows a free slot answers fast.
  busy_control      probes while a stream still runs; the probe must wait, or it could overtake a request and then
                    says nothing about a cut.
  stream_cut        streams, closes after five events while the stream is still open.
  plain_cut         sends a non-streamed request and closes --cut-after seconds in, once the engine runs it and before
                    any response arrived.
  prefill_baseline  sends the long prompt uncut and records its prompt tokens and time to first SSE event.
  prefill_cut       sends the long prompt and closes before its first SSE event, at --cut-fraction of the uncut time;
                    valid only if the probe then waits past the idle baseline, which shows the engine was working on it.
                    The rows show a cut before the first event the client saw, not which engine phase was running.
  queued_cut        queues a request behind a holder that is drained on its own thread, closes the queued one while
                    it waits, and counts as released only if the holder still sent events after the queue cleared.

Release is judged on the probe's time to first SSE event in excess of the idle baseline measured at the start of the
run, and it also needs the engine to reach idle afterwards.
Counters are read once five scrapes over one second agree.

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
    try:
        conn.request("GET", "/metrics")
        resp = conn.getresponse()
        text = resp.read().decode()
    except OSError as e:
        raise Invalid("metrics scrape failed: %s" % e)
    finally:
        conn.close()
    if resp.status != 200:
        raise Invalid("metrics returned HTTP %d" % resp.status)
    out: dict = {"present": []}
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
            # The simulator publishes a counter only after its first observation; the row records that it was absent.
            out[name] = 0.0
        else:
            out[name] = float(series[0][1])
            out["present"].append(name)
    # vLLM puts `engine` before `finished_reason` and the simulator does not, so the label is found anywhere.
    out["success"] = {}
    for labels, value in re.findall(r"^vllm:request_success_total\{([^}]*)\} ([0-9.e+]+)$", text, re.M):
        reason = re.search(r'finished_reason="([^"]+)"', labels)
        if reason:
            if reason.group(1) in out["success"]:
                raise Invalid("several series for finished_reason=%s; one engine is assumed" % reason.group(1))
            out["success"][reason.group(1)] = float(value)
    return out


def stable_metrics(port: int, limit: float = 15) -> dict:
    """Metrics once five scrapes over one second agree, so a late update is not left between two rows."""
    deadline = time.monotonic() + limit
    window = [metrics(port)]
    while time.monotonic() < deadline:
        time.sleep(0.25)
        window = (window + [metrics(port)])[-5:]
        if len(window) == 5 and all(m == window[0] for m in window):
            return window[0]
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
    """Reads one HTTP response from a raw socket, undoes chunked encoding and assembles SSE events."""

    def __init__(self, sock: socket.socket, started: float):
        self.sock, self.started = sock, started
        self.raw, self.buf = b"", b""
        self.status: int | None = None
        self.chunked = False
        self.first_event_at: float | None = None
        self.events: list[dict] = []
        self.event_times: list[float] = []
        self.done = False
        self.closed = False

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
        else:
            # A chunk boundary can fall inside an event, so the body is reassembled before events are split.
            while True:
                eol = self.raw.find(b"\r\n")
                if eol < 0:
                    break
                size = int(self.raw[:eol].split(b";")[0], 16)
                if len(self.raw) < eol + 2 + size + 2:
                    break
                self.buf += self.raw[eol + 2:eol + 2 + size]
                self.raw = self.raw[eol + 2 + size + 2:]
                if size == 0:
                    break
        self._events()

    def _events(self) -> None:
        # SSE allows CRLF, CR or LF line ends and several data lines per event, joined by a newline.
        text = self.buf.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        while True:
            cut = text.find(b"\n\n")
            if cut < 0:
                break
            raw, text = text[:cut], text[cut + 2:]
            data = [l[5:].lstrip(b" ") for l in raw.split(b"\n") if l.startswith(b"data:")]
            if not data:
                continue
            payload = b"\n".join(data)
            now = time.monotonic()
            if self.first_event_at is None:
                self.first_event_at = now
            if payload.strip() == b"[DONE]":
                self.done = True
                continue
            try:
                event = json.loads(payload)
            except ValueError:
                raise Invalid("an SSE event is not JSON: %r" % payload[:100])
            if "error" in event:
                raise Invalid("engine sent an SSE error: %s" % str(event["error"])[:200])
            self.events.append(event)
            self.event_times.append(now)
        self.buf = text

    def _pump(self, timeout: float) -> None:
        self.sock.settimeout(timeout)
        try:
            chunk = self.sock.recv(65536)
        except socket.timeout:
            raise Invalid("no response data within %.0f s" % timeout)
        if not chunk:
            self.closed = True
            raise Invalid("connection closed before the response ended")
        self.raw += chunk
        self._decode()

    def poll(self) -> None:
        """Decodes whatever has arrived without waiting."""
        self.sock.setblocking(False)
        try:
            while True:
                chunk = self.sock.recv(65536)
                if not chunk:
                    self.closed = True
                    break
                self.raw += chunk
        except BlockingIOError:
            pass
        finally:
            self.sock.setblocking(True)
        self._decode()

    def read_events(self, count: int, timeout: float) -> None:
        while len(self.events) < count and not self.done:
            self._pump(timeout)

    def read_to_done(self, timeout: float) -> None:
        while not self.done:
            self._pump(timeout)
        if self.status != 200:
            raise Invalid("stream answered HTTP %s" % self.status)

    def usage(self) -> dict:
        found = [e["usage"] for e in self.events if e.get("usage")]
        return found[-1] if found else {}

    def finishes(self) -> list:
        return [c.get("finish_reason") for e in self.events for c in e.get("choices", []) if c.get("finish_reason")]


class Drain:
    """Reads a stream to [DONE] on a thread and hands its failure back to the caller."""

    def __init__(self, s: Stream, timeout: float):
        self.s, self.error, self.done_at = s, None, None
        self.thread = threading.Thread(target=self._run, args=(timeout,), daemon=True)
        self.thread.start()

    def _run(self, timeout: float) -> None:
        try:
            self.s.read_to_done(timeout)
            self.done_at = time.monotonic()
        except Exception as e:  # noqa: BLE001 - every failure has to reach the main thread
            self.error = e

    def join(self, timeout: float) -> None:
        self.thread.join(timeout)
        if self.thread.is_alive():
            raise Invalid("the drained stream did not finish")
        if self.error is not None:
            raise Invalid("the drained stream failed: %s" % self.error)


def check_complete(s: Stream, tokens: int, what: str) -> None:
    if s.finishes() != ["length"] or s.usage().get("completion_tokens") != tokens:
        raise Invalid("%s ended with %s and %s tokens, not one length with %d" %
                      (what, s.finishes(), s.usage().get("completion_tokens"), tokens))


def probe(port: int, limit: float) -> float:
    """Time to the probe's first SSE event; the probe has to finish with exactly one generated token."""
    started = time.monotonic()
    s = Stream(send(port, True, 1), started)
    try:
        s.read_to_done(limit)
    finally:
        s.sock.close()
    check_complete(s, 1, "the probe")
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
        try:
            s.read_to_done(limit)
        finally:
            s.sock.close()
        check_complete(s, a.max_tokens, "the control")
        row["request_duration_s"] = round(time.monotonic() - started, 3)
        finish_with_probe(port, row, a, limit)

    elif name == "busy_control":
        s = Stream(send(port, True, a.max_tokens), time.monotonic())
        try:
            s.read_events(5, limit)
            if s.done:
                raise Invalid("the busy stream finished before the probe")
            # Drained on a thread so the target never stalls on a full socket while the probe waits.
            drain = Drain(s, limit)
            finish_with_probe(port, row, a, limit)
            drain.join(limit)
        finally:
            s.sock.close()
        check_complete(s, a.max_tokens, "the busy stream")

    elif name == "stream_cut":
        s = Stream(send(port, True, a.max_tokens), time.monotonic())
        try:
            s.read_events(5, limit)
            s.poll()
        finally:
            s.sock.close()
        if s.status != 200 or len(s.events) < 5 or s.done:
            raise Invalid("the stream was not open with five events at the cut (status %s, %d events, done %s)" %
                          (s.status, len(s.events), s.done))
        row["events_before_cut"] = len(s.events)
        finish_with_probe(port, row, a, limit)

    elif name == "plain_cut":
        s = Stream(send(port, False, a.max_tokens), time.monotonic())
        try:
            time.sleep(a.cut_after)
            running = metrics(port)["num_requests_running"]
            s.poll()
        finally:
            s.sock.close()
        # A non-streamed answer arrives whole at the end, so any byte back means it finished before the cut.
        if running != 1 or s.status is not None or s.closed:
            raise Invalid("the request was not running unanswered at the cut (running %s, status %s, closed %s)" %
                          (running, s.status, s.closed))
        finish_with_probe(port, row, a, limit)

    elif name == "prefill_baseline":
        started = time.monotonic()
        s = Stream(send(port, True, 1, prompt=long_prompt(a.long_prompt_words)), started)
        try:
            s.read_to_done(limit)
        finally:
            s.sock.close()
        check_complete(s, 1, "the long prompt")
        row["prompt_tokens"] = s.usage().get("prompt_tokens")
        row["first_event_s"] = round(s.first_event_at - started, 3)
        a.prefill_first_event = s.first_event_at - started
        settled = wait_for(port, idle, limit)
        row["released"] = settled is not None

    elif name == "prefill_cut":
        # vLLM publishes num_requests_running after a step, so the gauge cannot mark a request before its first
        # output; the cut is timed as a fraction of the uncut first event measured earlier in this rep.
        if a.prefill_first_event is None:
            raise Invalid("no prefill_baseline earlier in this rep to time the cut from")
        started = time.monotonic()
        s = Stream(send(port, True, a.max_tokens, prompt=long_prompt(a.long_prompt_words)), started)
        try:
            time.sleep(a.prefill_first_event * a.cut_fraction)
            s.poll()
        finally:
            s.sock.close()
        if s.events or s.done or s.closed or (s.status is not None and s.status != 200):
            raise Invalid("the response had an event, ended or failed before the cut (status %s, %d events)" %
                          (s.status, len(s.events)))
        row["cut_after_send_s"] = round(time.monotonic() - started, 3)
        row["uncut_first_event_s"] = round(a.prefill_first_event, 3)
        finish_with_probe(port, row, a, limit)
        # A probe that waits past the idle baseline shows the engine was working on this request when the cut came;
        # without that wait the cut may have landed before the engine took the request at all.
        if row["probe_excess_s"] <= a.busy_excess:
            raise Invalid("the probe did not wait (excess %.3f s), so the cut may have come before the engine took "
                          "the request" % row["probe_excess_s"])

    elif name == "queued_cut":
        holder = Stream(send(port, True, a.max_tokens), time.monotonic())
        queued = None
        try:
            holder.read_events(1, limit)
            drain = Drain(holder, limit)
            queued = send(port, True, a.max_tokens)
            if wait_for(port, lambda m: m["num_requests_waiting"] >= 1, 30) is None:
                raise Invalid("the second request never waited")
            events_at_cut = len(holder.events)
            cut_at = time.monotonic()
            queued.close()
            cleared = wait_for(port, lambda m: m["num_requests_waiting"] == 0, limit)
            cleared_at = time.monotonic()
            drain.join(limit)
        finally:
            holder.sock.close()
            if queued is not None:
                queued.close()
        check_complete(holder, a.max_tokens, "the holder")
        if cleared is None:
            raise Invalid("the queue never cleared")
        if drain.done_at <= cut_at or holder.done and holder.event_times and holder.event_times[-1] < cut_at:
            raise Invalid("the holder finished before the cut, so the request was not cut while queued")
        # The waiting gauge also falls when a request starts running, which needs the holder gone first; holder
        # events that arrive after the queue cleared show the holder was still running then.
        events_after_clear = sum(1 for t in holder.event_times if t > cleared_at)
        row["waiting_cleared_after_cut_s"] = round(cleared, 3)
        row["holder_events_at_cut"] = events_at_cut
        row["holder_events_after_clear"] = events_after_clear
        row["holder_done_after_cut_s"] = round(drain.done_at - cut_at, 3)
        finish_with_probe(port, row, a, limit)
        row["released"] = row["released"] and events_after_clear >= a.holder_events_after_clear

    after = stable_metrics(port)
    row["generation_counter_delta"] = after["generation_tokens_total"] - before["generation_tokens_total"]
    row["success_counter_delta"] = {
        r: after["success"].get(r, 0) - before["success"].get(r, 0)
        for r in sorted(set(after["success"]) | set(before["success"]))
        if after["success"].get(r, 0) - before["success"].get(r, 0)
    }
    row["counters_absent_before"] = [c for c in COUNTERS if c not in before["present"]]
    row["success_series_after"] = sorted(after["success"])
    return row


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--cases", default="control,busy_control,stream_cut,plain_cut")
    p.add_argument("--max-tokens", type=int, default=50)
    p.add_argument("--token-seconds", type=float, default=0.1, help="rough time per token, only for timeouts")
    p.add_argument("--release-threshold", type=float, default=2.0,
                   help="a probe slower than the idle baseline by this much waited on the cut request")
    p.add_argument("--cut-after", type=float, default=1.0)
    p.add_argument("--long-prompt-words", type=int, default=1500)
    p.add_argument("--cut-fraction", type=float, default=0.4,
                   help="prefill_cut closes at this fraction of the uncut long prompt's first event")
    p.add_argument("--busy-excess", type=float, default=0.1,
                   help="probe excess above which the engine counts as having been busy with the cut request")
    p.add_argument("--holder-events-after-clear", type=int, default=5,
                   help="holder events needed after the queue cleared for a queued cut to count as a removal")
    a = p.parse_args()
    a.prefill_first_event = None
    cases = [c for c in a.cases.split(",") if c]
    unknown = set(cases) - set(CASES)
    if unknown:
        p.error("unknown cases: %s" % ", ".join(sorted(unknown)))
    limit = a.max_tokens * a.token_seconds * 4 + 60
    a.baseline = baseline_probe(a.port, limit)
    print(json.dumps({"case": "idle_probe_baseline", "probe_ttfb_s": round(a.baseline, 3),
                      "args": {k: v for k, v in vars(a).items() if k not in ("baseline", "prefill_first_event")}}),
          flush=True)
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
