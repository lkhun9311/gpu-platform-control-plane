"""Open-loop sender for the llm-d-router #1598 pilot.

Requests leave at absolute wall-clock times computed before the first one, so a slow response never delays a later send.
Connections are opened before the first send, so a burst is not serialized by TCP setup.
Every time is epoch seconds from time.time(), the clock the EPP's and Envoy's logs use, so the three can be joined.
"""

import gc
import http.client
import json
import queue
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


def one(pool, req, sched_abs, extra_headers=None, body=None):
    """Send one request and return its row; a network error or timeout is an outcome recorded on the row, not raised."""
    row = {"rid": req["rid"], "population": req["population"], "prefix": req["prefix"], "max_tokens": req["max_tokens"],
           "prompt_len": len(req["prompt"]), "sched_abs": sched_abs, "sent_abs": None, "status": None, "endpoint": None,
           "first_event_t": None, "first_text_t": None, "last_text_t": None, "done": False, "usage": None, "error": None}
    if body is None:
        body = body_of(req)
    headers = {"Content-Type": "application/json", "x-request-id": req["rid"]}
    headers.update(extra_headers or {})
    c, healthy = pool.get(), False
    try:
        row["sent_abs"] = time.time()
        c.request("POST", "/v1/completions", body, headers)
        r = c.getresponse()
        row["status"] = r.status
        row["endpoint"] = r.getheader("x-kit-upstream-host")
        if r.status != 200:
            row["error"] = f"http {r.status}: {r.read()[:200]!r}"
            healthy = True
            return row
        while True:
            # HTTPResponse.readline decodes chunked transfer and returns b"" at the body's end; the raw socket would block
            # until the timeout on a kept-alive connection.
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
            for ch in ev.get("choices") or []:
                if ch.get("text"):
                    if row["first_text_t"] is None:
                        row["first_text_t"] = now
                    row["last_text_t"] = now
            u = ev.get("usage")
            if u:
                row["usage"] = {"prompt_tokens": u.get("prompt_tokens"), "completion_tokens": u.get("completion_tokens"),
                                "cached_tokens": (u.get("prompt_tokens_details") or {}).get("cached_tokens", 0) or 0}
        r.read()
        healthy = row["done"]
    except Exception as e:  # noqa: BLE001 - every failure is a recorded outcome
        row["error"] = f"{type(e).__name__}: {e}"
    finally:
        row["end_abs"] = time.time()
        pool.put(c, healthy)
    return row


def run(host, port, reqs, origin_abs, timeout, workers=256, stagger=0.0):
    """Send `reqs` at origin_abs + offset (or, with `stagger`, at origin_abs + i * stagger) and return their rows in order.

    Dispatch lag, the send time minus the scheduled time, is on each row.
    """
    # Bodies are serialized before the first send: a W942 prompt is 7,936 ids, and encoding it on the send path, under the
    # GIL beside threads parsing streams, put 14 to 34 ms stalls into the dispatch lag in the offline run.
    bodies = [body_of(r) for r in reqs]
    # A full cyclic collection over the process's millions of prompt ids can pause every thread for tens of ms, which lands
    # in the dispatch lag; objects made so far are frozen out of collection and collection is off until the cell's sends end.
    gc.collect()
    gc.freeze()
    gc.disable()
    try:
        return _run(host, port, reqs, bodies, origin_abs, timeout, workers, stagger)
    finally:
        gc.enable()
        gc.unfreeze()


def _run(host, port, reqs, bodies, origin_abs, timeout, workers, stagger):
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
    plan = sorted(((origin_abs + (i * stagger if stagger else r["offset"])), i, r) for i, r in enumerate(reqs))
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
    for i, r in enumerate(reqs):
        if rows[i] is None:
            rows[i] = {"rid": r["rid"], "population": r["population"], "prefix": r["prefix"], "max_tokens": r["max_tokens"],
                       "sched_abs": None, "sent_abs": None, "status": None, "endpoint": None, "done": False, "usage": None,
                       "first_event_t": None, "first_text_t": None, "last_text_t": None, "error": "never dispatched"}
        if rows[i].get("sent_abs") is not None and rows[i].get("sched_abs") is not None:
            rows[i]["lag_s"] = rows[i]["sent_abs"] - rows[i]["sched_abs"]
    return rows
