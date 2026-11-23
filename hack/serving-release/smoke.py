#!/usr/bin/env python3
"""Streams chat completions through the gateway and judges one serving release.

A release passes only if every request answers 200, every data chunk names the expected model, the stream ends
with [DONE], and the first content chunk arrives inside the TTFT bound.
Every response is written raw to --raw, so a verdict can be re-read from what the gateway actually sent.
The verdict is the last stdout line, as JSON, and the exit status is 0 for a pass and 1 for a fail.

Usage: smoke.py --url URL --key KEY --model NAME --ttft-bound-ms N --requests N --raw FILE
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

# A route the gateway has not cached yet answers 404 for a moment after a model is renamed, and that is not the
# release's fault, so only that answer is retried, and only for this long.
ROUTE_SETTLE_S = 30


def one(url, key, model, timeout_s, raw):
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": "hi"}], "stream": True}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.monotonic()
    result = {"status": None, "ttft_ms": None, "models": [], "chunks": 0, "done": False, "error": None}
    try:
        resp = urllib.request.urlopen(req, timeout=timeout_s)
    except urllib.error.HTTPError as e:
        result["status"] = e.code
        raw.write(f"--- HTTP {e.code}\n{e.read().decode(errors='replace')}\n")
        return result
    except (urllib.error.URLError, OSError) as e:
        result["error"] = str(e)
        raw.write(f"--- transport error {e}\n")
        return result
    result["status"] = resp.status
    raw.write(f"--- HTTP {resp.status}\n")
    # The socket timeout bounds each read, not the response, so a stream that keeps sending and never ends would
    # hold the smoke, and with it the restore, until the job's own timeout.
    deadline = t0 + timeout_s
    with resp:
        try:
            for line in resp:
                if time.monotonic() > deadline:
                    result["error"] = f"stream still open after {timeout_s:.0f} s"
                    raw.write(f"\n--- {result['error']}\n")
                    break
                text = line.decode(errors="replace")
                raw.write(text)
                if not text.startswith("data: "):
                    continue
                payload = text[len("data: "):].strip()
                if payload == "[DONE]":
                    result["done"] = True
                    continue
                # Anything after [DONE] means the stream did not end there.
                result["done"] = False
                result["chunks"] += 1
                try:
                    chunk = json.loads(payload)
                except ValueError:
                    result["models"].append(None)
                    continue
                result["models"].append(chunk.get("model"))
                if result["ttft_ms"] is None and any(c.get("delta", {}).get("content") for c in chunk.get("choices", [])):
                    result["ttft_ms"] = round((time.monotonic() - t0) * 1000, 1)
        except (OSError, ValueError) as e:
            result["error"] = str(e)
            raw.write(f"\n--- stream error {e}\n")
    return result


def judge(r, model, bound_ms):
    reasons = []
    if r["status"] != 200:
        reasons.append(f"status {r['status']}")
    if r["error"]:
        reasons.append(f"error {r['error']}")
    if r["status"] == 200:
        if r["chunks"] == 0:
            reasons.append("no data chunks")
        wrong = sorted({str(m) for m in r["models"] if m != model})
        if wrong:
            reasons.append(f"chunks named model {wrong}, want {model}")
        if not r["done"]:
            reasons.append("stream did not end with [DONE]")
        if r["ttft_ms"] is None:
            reasons.append("no content chunk, so no TTFT")
        elif r["ttft_ms"] > bound_ms:
            reasons.append(f"TTFT {r['ttft_ms']} ms over the {bound_ms} ms bound")
    return reasons


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--ttft-bound-ms", type=float, required=True)
    ap.add_argument("--requests", type=int, default=3)
    ap.add_argument("--raw", required=True)
    a = ap.parse_args()
    if a.requests < 1:
        print(json.dumps({"pass": False, "reasons": ["--requests must be at least 1"]}))
        return 1
    results = []
    with open(a.raw, "a", encoding="utf-8") as raw:
        settle_until = time.monotonic() + ROUTE_SETTLE_S
        while len(results) < a.requests:
            r = one(a.url, a.key, a.model, a.ttft_bound_ms / 1000 + 15, raw)
            if r["status"] == 404 and not results and time.monotonic() < settle_until:
                time.sleep(2)
                continue
            r["reasons"] = judge(r, a.model, a.ttft_bound_ms)
            results.append(r)
            raw.flush()
    failed = [r for r in results if r["reasons"]]
    verdict = {"pass": not failed, "model": a.model, "ttft_bound_ms": a.ttft_bound_ms,
               "requests": [{k: r[k] for k in ("status", "ttft_ms", "chunks", "done", "reasons")} for r in results]}
    print(json.dumps(verdict))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
