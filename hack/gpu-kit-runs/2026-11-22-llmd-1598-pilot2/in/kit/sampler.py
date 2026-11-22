"""Engine metrics for the llm-d-router #1598 pilot: counter snapshots for the ledger, and the 4 Hz load sampler."""

import http.client
import json
import re
import threading
import time

LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)')
# Counter names as vLLM 0.34.0 exposes them; the ledger compares their deltas with the client's usage sums.
COUNTERS = {"prompt": "vllm:prompt_tokens_total", "generation": "vllm:generation_tokens_total",
            "cached": "vllm:prompt_tokens_cached_total", "success": "vllm:request_success_total",
            "preemptions": "vllm:num_preemptions_total"}


def parse(text):
    """Sum every series of each metric name; labels are dropped because each engine is scraped on its own."""
    out = {}
    for ln in text.splitlines():
        if not ln or ln.startswith("#"):
            continue
        m = LINE.match(ln)
        if not m:
            continue
        try:
            v = float(m.group(3))
        except ValueError:
            continue
        out[m.group(1)] = out.get(m.group(1), 0.0) + v
    return out


def labels(text, name):
    for ln in text.splitlines():
        if ln.startswith(name + "{"):
            return dict(re.findall(r'(\w+)="([^"]*)"', ln))
    return {}


def scrape(hostport, timeout=2.0):
    host, port = hostport.split(":")
    c = http.client.HTTPConnection(host, int(port), timeout=timeout)
    try:
        c.request("GET", "/metrics")
        r = c.getresponse()
        return r.read().decode()
    finally:
        c.close()


def counters(text):
    p = parse(text)
    return {k: int(round(p.get(v, 0.0))) for k, v in COUNTERS.items()}


def delta(before, after):
    return {k: after[k] - before[k] for k in before}


class Sampler:
    """Scrape every engine's load gauges at `hz` into a JSON-lines file until stopped."""

    def __init__(self, engines, path, hz=4.0):
        self.engines, self.path, self.period = engines, path, 1.0 / hz
        self.stop_ev = threading.Event()
        self.t = threading.Thread(target=self._run, daemon=True)

    def _one(self, out, i, e):
        try:
            p = parse(scrape(e, timeout=self.period))
            out[i] = {"t": time.time(), "engine": e, "running": p.get("vllm:num_requests_running", 0.0),
                      "waiting": p.get("vllm:num_requests_waiting", 0.0), "kv": p.get("vllm:kv_cache_usage_perc", 0.0)}
        except Exception as ex:  # noqa: BLE001 - a missed scrape is a gap the check reports
            out[i] = {"t": time.time(), "engine": e, "error": str(ex)}

    def _run(self):
        with open(self.path, "a") as f:
            nxt = time.time()
            while not self.stop_ev.is_set():
                # One thread per engine so a slow engine does not delay the others' samples; lines are written by this thread only.
                out = [None] * len(self.engines)
                ts = [threading.Thread(target=self._one, args=(out, i, e)) for i, e in enumerate(self.engines)]
                for t in ts:
                    t.start()
                for t in ts:
                    t.join()
                for d in out:
                    f.write(json.dumps(d) + "\n")
                f.flush()
                nxt += self.period
                d = nxt - time.time()
                if d > 0:
                    self.stop_ev.wait(d)
                else:
                    nxt = time.time()

    def start(self):
        self.t.start()
        return self

    def stop(self):
        self.stop_ev.set()
        self.t.join(5)


def read_samples(path):
    out = []
    with open(path) as f:
        for ln in f:
            d = json.loads(ln)
            if "error" not in d:
                out.append(d)
    return out
