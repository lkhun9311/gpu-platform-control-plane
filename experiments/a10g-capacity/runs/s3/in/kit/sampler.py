"""Scrapes the engine's /metrics on the contract's interval and appends one JSON line per scrape.

    sampler.py CONTRACT METRICS_URL OUT_JSONL
    sampler.py --drained CONTRACT METRICS_URL TIMEOUT_S

Each line has the scrape's wall time `t`, the waiting and running counts, and the KV usage gauge with the name it was read under.
A gauge the scrape did not carry is null, and a failed scrape is a line with `error`, so a gap is visible rather than read as 0.
It runs until it is terminated.
"""

import json
import signal
import sys
import time
import urllib.request


def parse(text, names):
    """Sums each named gauge over its label sets; a name with no sample is absent from the result."""
    out = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        head, _, value = line.rpartition(" ")
        name = head.split("{", 1)[0]
        if name in names:
            try:
                out[name] = out.get(name, 0.0) + float(value)
            except ValueError:
                continue
    return out


def sample(text, m):
    got = parse(text, {m["waiting_metric"], m["running_metric"], *m["kv_metrics"]})
    kv_name = next((n for n in m["kv_metrics"] if n in got), None)
    return {
        "waiting": got.get(m["waiting_metric"]),
        "running": got.get(m["running_metric"]),
        "kv": got.get(kv_name) if kv_name else None,
        "kv_name": kv_name,
    }


def drained(argv):
    """Exit 0 once a scrape reads zero running and zero waiting, 1 if none does within the timeout."""
    with open(argv[2]) as f:
        m = json.load(f)["metrics"]
    deadline = time.time() + float(argv[4])
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(argv[3], timeout=2) as r:
                s = sample(r.read().decode(), m)
            if s["waiting"] == 0 and s["running"] == 0:
                return 0
        except Exception:  # noqa: BLE001 -- an unreadable scrape is not a drained engine
            pass
        time.sleep(0.5)
    return 1


def main(argv):
    if argv[1] == "--drained":
        return drained(argv)
    with open(argv[1]) as f:
        m = json.load(f)["metrics"]
    url, out = argv[2], argv[3]
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    interval = m["scrape_interval_s"]
    with open(out, "a", buffering=1) as f:
        nxt = time.time()
        while not stop:
            t = time.time()
            try:
                with urllib.request.urlopen(url, timeout=interval) as r:
                    rec = {"t": t, **sample(r.read().decode(), m)}
            except Exception as e:  # noqa: BLE001 -- every failure is a recorded gap, never a stop
                rec = {"t": t, "error": f"{type(e).__name__}: {e}"}
            f.write(json.dumps(rec) + "\n")
            nxt += interval
            time.sleep(max(nxt - time.time(), 0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
