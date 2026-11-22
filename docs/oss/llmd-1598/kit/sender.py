"""Open-loop sender for the llm-d-router #1598 pilot.

Requests leave at absolute wall-clock times computed before the first one, so a slow response never delays a later send.
Connections are opened before the first send, so a burst is not serialized by TCP setup.
Every time is epoch seconds from time.time(), the clock the EPP's and Envoy's logs use, so the three can be joined.
"""

import gc
import http.client
import json
import queue
import sys
import threading
import time

MODEL = "Qwen/Qwen2.5-3B-Instruct"


class Pool:
    """Keep-alive connections to one host, opened up front."""

    def __init__(self, host, port, n, timeout):
        self.host, self.port, self.timeout = host, port, timeout
        self.q = queue.Queue()
        for _ in range(n):
            c = http.client.HTTPConnection(host, port, timeout=timeout)
            c.connect()
            self.q.put(c)

    def get(self):
        try:
            return self.q.get_nowait()
        except queue.Empty:
            c = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
            c.connect()
            return c

    def put(self, c, healthy):
        if healthy:
            self.q.put(c)
        else:
            c.close()

    def close(self):
        while not self.q.empty():
            self.q.get_nowait().close()


def body_of(req):
    return json.dumps({"model": MODEL, "prompt": req["prompt"], "max_tokens": req["max_tokens"], "min_tokens": req["max_tokens"],
                       "ignore_eos": True, "stream": True, "stream_options": {"include_usage": True}}).encode()


def new_row(req, sched_abs):
    return {"rid": req["rid"], "population": req["population"], "prefix": req["prefix"], "max_tokens": req["max_tokens"],
            "prompt_len": len(req["prompt"]), "sched_abs": sched_abs, "sent_abs": None, "status": None, "endpoint": None,
            "first_event_t": None, "first_token_t": None, "first_text_t": None, "last_text_t": None, "done": False, "usage": None,
            "error": None}


def one(pool, req, sched_abs, extra_headers=None, body=None):
    """Send one request and return its row; a network error or timeout is an outcome recorded on the row, not raised."""
    row = new_row(req, sched_abs)
    if body is None:
        body = body_of(req)
    headers = {"Content-Type": "application/json", "x-request-id": req["rid"]}
    headers.update(extra_headers or {})
    c, healthy = pool.get(), False
    try:
        row["sent_abs"] = time.time()
        c.request("POST", "/v1/completions", body, headers)
        healthy = read_response(c, row, row["sent_abs"] + pool.timeout)
    except Exception as e:  # noqa: BLE001 - every failure is a recorded outcome
        row["error"] = f"{type(e).__name__}: {e}"
    finally:
        row["end_abs"] = time.time()
        pool.put(c, healthy)
    return row


class Deadline(Exception):
    pass


def read_response(c, row, deadline):
    """Read one streamed response into `row` by `deadline`; returns whether the connection can be reused.

    The connection's own timeout bounds each blocking read, not the request: a stream that keeps producing tokens would
    outlive it, so the remaining time to the whole-request deadline is set before every read, and a request still
    streaming at the deadline is cut off and recorded as a timeout, as the design's whole-request timeouts say.
    """
    def arm():
        left = deadline - time.time()
        if left <= 0:
            raise Deadline("whole-request deadline")
        c.sock.settimeout(left)

    arm()
    r = c.getresponse()
    row["status"] = r.status
    row["endpoint"] = r.getheader("x-kit-upstream-host")
    if r.status != 200:
        row["error"] = f"http {r.status}: {r.read()[:200]!r}"
        return True
    while True:
        # HTTPResponse.readline decodes chunked transfer and returns b"" at the body's end; the raw socket would block
        # until the timeout on a kept-alive connection.
        arm()
        line = r.readline()
        if not line:
            break
        if not line.startswith(b"data:"):
            continue
        now = time.time()
        data = line[5:].strip()
        if row["first_event_t"] is None:
            row["first_event_t"] = now
        if data == b"[DONE]":
            row["done"] = True
            continue
        try:
            ev = json.loads(data)
        except ValueError:
            row["error"] = "unparsable event"
            continue
        choices = ev.get("choices") or []
        # A token can decode to no text (a partial UTF-8 sequence from a random prompt): its event still marks the token,
        # and the pilot had nine completed evaluation rows whose only text was empty and whose TTFT therefore read infinite.
        if choices and row["first_token_t"] is None:
            row["first_token_t"] = now
        for ch in choices:
            if ch.get("text"):
                if row["first_text_t"] is None:
                    row["first_text_t"] = now
                row["last_text_t"] = now
        u = ev.get("usage")
        if u:
            row["usage"] = {"prompt_tokens": u.get("prompt_tokens"), "completion_tokens": u.get("completion_tokens"),
                            "cached_tokens": (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0) or 0}
    r.read()
    return row["done"]


# A ceiling on threads for one cell: a schedule that needs more is refused, never served by fewer workers than it needs.
MAX_WORKERS = 8192


def workers_for(reqs, timeout):
    """Threads an open-loop schedule needs: the most requests scheduled inside any span of `timeout` + 5 s.

    A request holds its worker for at most about its timeout, so no more than this many can be outstanding at once.
    The pilot's fixed 256 would have capped an overloaded cell (180/s for 20 s is 3,600 outstanding): the sends would have
    waited for a free worker, so the offered schedule would not have been the one sent.
    """
    offs = sorted(r["offset"] for r in reqs)
    span, best, j = timeout + 5.0, 0, 0
    for i, t in enumerate(offs):
        while offs[j] < t - span:
            j += 1
        best = max(best, i - j + 1)
    return best


def run(host, port, reqs, timeout, delay=0.5, workers=None):
    """Send `reqs` at origin + offset, the origin `delay` seconds after every connection and worker is ready, and return
    their rows in order.

    Dispatch lag, the send time minus the scheduled time, is on each row.
    """
    if workers is None:
        workers = workers_for(reqs, timeout)
    if workers > MAX_WORKERS:
        raise ValueError(f"the schedule needs {workers} workers, over the sender's {MAX_WORKERS}")
    # Bodies are serialized before the first send: a W942 prompt is 7,936 ids, and encoding it on the send path, under the
    # GIL beside threads parsing streams, put 14 to 34 ms stalls into the dispatch lag in the offline run.
    bodies = [body_of(r) for r in reqs]
    # A full cyclic collection over the process's millions of prompt ids can pause every thread for tens of ms, which lands
    # in the dispatch lag; objects made so far are frozen out of collection and collection is off until the cell's sends end.
    gc.collect()
    gc.freeze()
    gc.disable()
    try:
        return _run(host, port, reqs, bodies, delay, timeout, workers)
    finally:
        gc.enable()
        gc.unfreeze()


def _run(host, port, reqs, bodies, delay, timeout, workers):
    # Small stacks: thousands of workers mostly sit blocked on a socket.
    old_stack = threading.stack_size(256 * 1024)
    try:
        pool = Pool(host, port, min(len(reqs), workers), timeout)
        rows = [None] * len(reqs)
        jobs = queue.Queue()

        def worker():
            while True:
                item = jobs.get()
                if item is None:
                    return
                i, req, at = item
                rows[i] = one(pool, req, at, body=bodies[i])

        threads = [threading.Thread(target=worker, daemon=True) for _ in range(min(len(reqs), workers))]
        for t in threads:
            t.start()
    finally:
        threading.stack_size(old_stack)
    # The origin is set only now: opening thousands of connections can take longer than a fixed head start.
    origin_abs = time.time() + delay
    plan = sorted((origin_abs + r["offset"], i, r) for i, r in enumerate(reqs))
    for at, i, r in plan:
        d = at - time.time()
        if d > 0:
            time.sleep(d)
        jobs.put((i, r, at))
    for _ in threads:
        jobs.put(None)
    for t in threads:
        t.join(timeout + 30)
    pool.close()
    return finish_rows(reqs, rows)


def finish_rows(reqs, rows):
    for i, r in enumerate(reqs):
        if rows[i] is None:
            rows[i] = {"rid": r["rid"], "population": r["population"], "prefix": r["prefix"], "max_tokens": r["max_tokens"],
                       "sched_abs": None, "sent_abs": None, "status": None, "endpoint": None, "done": False, "usage": None,
                       "first_event_t": None, "first_token_t": None, "first_text_t": None, "last_text_t": None,
                       "error": "never dispatched"}
        if rows[i].get("sent_abs") is not None and rows[i].get("sched_abs") is not None:
            rows[i]["lag_s"] = rows[i]["sent_abs"] - rows[i]["sched_abs"]
    return rows


class Burst:
    """K's burst, sent in two steps: prime() writes every request whole except its body's last byte, and release() writes
    the last bytes (with `stagger`, request i's at i * stagger after the first) and reads the responses in parallel.

    Envoy hands the EPP the body as it streams, and the EPP cannot pick before it has the whole prompt, so a burst released
    this way reaches the scheduler within the time it takes one thread to write 64 single bytes.
    The pilot's thread-per-request send spread its 64 sends over 5.7 to 7.5 ms, a spacing the thread's simulator runs
    showed can change the result (5 ms kept the effect, 20 ms removed it).
    Priming comes before K's preloads are sent, so the preloads' prefill is not spent waiting for 64 connections to open.
    A row's sched_abs is its planned release and its sent_abs when its last byte was written, so its dispatch lag is release
    lateness; primed_abs records when the rest of its body was written.
    """

    def __init__(self, host, port, reqs, timeout):
        self.host, self.port, self.reqs, self.timeout = host, port, reqs, timeout
        self.bodies = [body_of(r) for r in reqs]
        self.rows = [new_row(r, None) for r in reqs]
        self.conns = [None] * len(reqs)

    def prime(self):
        for i, r in enumerate(self.reqs):
            try:
                c = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
                c.putrequest("POST", "/v1/completions", skip_accept_encoding=True)
                for k, v in (("Content-Type", "application/json"), ("Content-Length", str(len(self.bodies[i]))),
                             ("x-request-id", r["rid"])):
                    c.putheader(k, v)
                c.endheaders(self.bodies[i][:-1])
                self.rows[i]["primed_abs"] = time.time()
                self.conns[i] = c
            except Exception as e:  # noqa: BLE001 - a request that could not be primed is an outcome
                self.rows[i]["error"] = f"prime: {type(e).__name__}: {e}"
        return self

    def release(self, stagger=0.0, delay=0.002):
        rows, conns = self.rows, self.conns
        timed = threading.Event()

        def reader(i):
            # The release times are set only after every reader is running; a reader waits for them, then for its response.
            timed.wait()
            try:
                read_response(conns[i], rows[i], rows[i]["sched_abs"] + self.timeout)
            except Exception as e:  # noqa: BLE001 - every failure is a recorded outcome
                rows[i]["error"] = rows[i]["error"] or f"{type(e).__name__}: {e}"
            finally:
                rows[i]["end_abs"] = time.time()
                conns[i].close()

        # Readers wait on their sockets before any release, so a response is timed when it arrives, not when a reader
        # starts: under the 20 ms stagger the last release is 1.26 s after the first, later than the first responses.
        threads = [threading.Thread(target=reader, args=(i,), daemon=True) for i, c in enumerate(conns) if c is not None]
        for t in threads:
            t.start()
        origin = time.time() + delay
        for i, r in enumerate(rows):
            r["sched_abs"] = origin + i * stagger
        timed.set()
        gc.collect()
        gc.freeze()
        gc.disable()
        # A reader woken by an early response would otherwise take the GIL for up to the 5 ms switch interval between
        # two releases; with a long interval this thread keeps it, since writing one byte to a socket never blocks.
        switch = sys.getswitchinterval()
        sys.setswitchinterval(0.5)
        try:
            for i, c in enumerate(conns):
                if c is None:
                    continue
                while time.time() < rows[i]["sched_abs"] - 0.002:
                    time.sleep(0.001)
                while time.time() < rows[i]["sched_abs"]:
                    pass
                try:
                    # The raw socket, not HTTPConnection.send: a reader thread is already inside getresponse here.
                    c.sock.sendall(self.bodies[i][-1:])
                    rows[i]["sent_abs"] = time.time()
                except Exception as e:  # noqa: BLE001
                    rows[i]["error"] = f"release: {type(e).__name__}: {e}"
        finally:
            sys.setswitchinterval(switch)
            gc.enable()
            gc.unfreeze()
        for t in threads:
            t.join(self.timeout + 30)
        return finish_rows(self.reqs, rows)
