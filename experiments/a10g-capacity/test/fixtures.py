"""Synthetic stage directories for the analysis: one that passes each rule and one that must fail it.

    fixtures.py OUT_DIR     writes every fixture under OUT_DIR and prints the manifest of expected verdicts

A fixture is the same files `capacityrun stage` writes (meta.json and raw.jsonl), with rows built here, so the analysis
is tested on the shape it reads on the instance.
"""

import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT = os.path.join(HERE, "..", "kit", "contract.json")
MS = 1_000_000


def load_contract():
    with open(CONTRACT) as f:
        return json.load(f)


def row(index, tenant, offset_ms, ttft_ms=60.0, e2e_ms=1500.0, outcome="done", lag_ms=0.5, prompt=512, completion=128, finish="length"):
    """One raw row in bench.RawRow's JSON shape; outcome picks the HTTP status and stream result."""
    r = {"index": index, "tenant": tenant, "scheduledOffsetMs": offset_ms, "study": "fixture", "arm": "a10g"}
    send = offset_ms * MS + int(lag_ms * MS)
    clock = {"originUnixNanos": 1_700_000_000 * 10**9, "intendedNanos": offset_ms * MS, "sendNanos": send}
    if outcome == "unsent":
        r.update(disposition="unsent", errorKind="unsent", httpStatus=0)
        r["clock"] = {"originUnixNanos": clock["originUnixNanos"]}
        return r
    if outcome == "done":
        clock.update(firstContentNanos=send + int(ttft_ms * MS), doneNanos=send + int(e2e_ms * MS))
        r.update(disposition="completed", httpStatus=200, streamTerminated=True, engineInputTokens=prompt,
                 engineOutputTokens=completion, finishReason=finish)
    elif outcome == "timeout":
        r.update(disposition="timeout", httpStatus=200, errorKind="timeout")
    elif outcome == "429":
        r.update(disposition="rejected", httpStatus=429, errorKind="rejected")
    elif outcome == "transport":
        r.update(disposition="transport", httpStatus=0, errorKind="transport")
    r["clock"] = clock
    return r


def write_stage(path, segments, rows, reconciled=True, output_tokens=128, planned_override=None):
    """Writes meta.json and raw.jsonl; segments are (name, rate, start_ms, end_ms)."""
    os.makedirs(path)
    segs = []
    for name, rate, a, b in segments:
        segs.append({"name": name, "rateRps": rate, "durationS": (b - a) / 1000, "startMs": a, "endMs": b,
                     "planned": sum(1 for r in rows if r["tenant"] == name)})
    meta = {"contract": "fixture", "segments": segs, "rows": planned_override if planned_override is not None else len(rows),
            "outputTokens": output_tokens, "reconciled": reconciled}
    if not reconciled:
        meta["unreconciled"] = "1 request(s) scheduled but not recorded (7)"
    with open(os.path.join(path, "meta.json"), "w") as f:
        json.dump(meta, f)
    with open(os.path.join(path, "raw.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def arrivals(rate, start_ms, end_ms, rng):
    t, out = float(start_ms), []
    while True:
        t += rng.expovariate(rate) * 1000
        if t >= end_ms:
            return out
        out.append(int(t))


def rung(path, rate, ttft=lambda i, off: 60.0, outcome=lambda i, off: "done", seed=1, rung_s=60, lag=lambda i: 0.5):
    rng = random.Random(seed)
    offs = arrivals(rate, 0, rung_s * 1000, rng)
    rows = [row(i, "rung", o, ttft_ms=ttft(i, o), outcome=outcome(i, o), lag_ms=lag(i)) for i, o in enumerate(offs)]
    write_stage(path, [("rung", rate, 0, rung_s * 1000)], rows)
    return rows


def cycle(path, recover_after_s=40.0, baseline_rate=2.5, sat=10, over=15, seed=3, tokens=lambda i: (512, 128), fail_every=0):
    """A cycle whose recovery-stage TTFT stays high until recover_after_s after the overload ends."""
    rng = random.Random(seed)
    spans = [("baseline", baseline_rate, 0, 150_000), ("saturation", sat, 150_000, 300_000),
             ("overload", over, 300_000, 390_000), ("recovery", baseline_rate, 390_000, 630_000)]
    rows = []
    for name, rate, a, b in spans:
        for off in arrivals(rate, a, b, rng):
            ttft = 60.0 + rng.random() * 20
            if name == "overload":
                ttft = 3000.0
            if name == "recovery" and off < 390_000 + recover_after_s * 1000:
                ttft = 2000.0
            p, c = tokens(len(rows))
            # A failed request in every recovery window, with fast TTFT on the rest, is not recovery.
            failed = name == "recovery" and fail_every and len(rows) % fail_every == 0
            rows.append(row(len(rows), name, off, ttft_ms=ttft, prompt=p, completion=c, outcome="timeout" if failed else "done"))
    write_stage(path, spans, rows)
    return rows


def build(out):
    """Every fixture, with the analysis command and the exit status it must give."""
    m = []

    def add(name, cmd, want, why):
        m.append({"name": name, "cmd": cmd, "want_exit": want, "why": why})

    rung(f"{out}/stable/rung-01", 5)
    add("stable", "rung", 0, "every rule holds")
    rung(f"{out}/s1-completion/rung-01", 5, outcome=lambda i, off: "timeout" if i % 50 == 0 else "done")
    add("s1-completion", "rung", 10, "saturation rule S1: 2% of sent requests timed out")
    rung(f"{out}/s2-p99/rung-01", 5, ttft=lambda i, off: 2500.0 if i % 40 == 0 else 60.0)
    add("s2-p99", "rung", 10, "saturation rule S2: p99 TTFT above 2,000 ms")
    rung(f"{out}/s3-growth/rung-01", 5, ttft=lambda i, off: 20.0 + max(off - 26_700, 0) / 30)
    add("s3-growth", "rung", 10, "saturation rule S3: TTFT grows across the window while p99 stays under 2,000 ms")
    rung(f"{out}/few-samples/rung-01", 1.5)
    add("few-samples", "rung", 10, "too few samples: fewer than 100 completed, so no p99 and no stability")
    rung(f"{out}/ledger-missing-row/rung-01", 5)
    path = f"{out}/ledger-missing-row/rung-01/raw.jsonl"
    with open(path) as f:
        lines = f.readlines()
    with open(path, "w") as f:
        f.writelines(lines[:7] + lines[8:])
    add("ledger-missing-row", "rung", 2, "ledger mismatch: a planned row is missing from the recording")
    rows = rung(f"{out}/ledger-unreconciled/rung-01", 5)
    os.remove(f"{out}/ledger-unreconciled/rung-01/meta.json")
    os.remove(f"{out}/ledger-unreconciled/rung-01/raw.jsonl")
    os.rmdir(f"{out}/ledger-unreconciled/rung-01")
    write_stage(f"{out}/ledger-unreconciled/rung-01", [("rung", 5, 0, 60_000)], rows, reconciled=False)
    add("ledger-unreconciled", "rung", 2, "ledger mismatch: the replay's own reconciliation failed")
    write_stage(f"{out}/ledger-planned/rung-01", [("rung", 5, 0, 60_000)], rows, planned_override=len(rows) + 3)
    add("ledger-planned", "rung", 2, "ledger mismatch: the trace planned more rows than were recorded")

    rung(f"{out}/lagged/pilot/rung-01", 5, lag=lambda i: 150.0 if i % 25 == 0 else 0.5)
    add("lagged", "report", 3, "exclusion X5: 4% of sent requests left more than 100 ms late")
    rung(f"{out}/on-time/pilot/rung-01", 5, lag=lambda i: 150.0 if i == 3 else 0.5)
    add("on-time", "report", 0, "exclusion X5 not met: one late request of about 300 is under 1%")
    cycle(f"{out}/recovers/cycle", recover_after_s=40)
    add("recovers", "cycle", 0, "recovery at 40 s")
    cycle(f"{out}/never-recovers/cycle", recover_after_s=10_000)
    add("never-recovers", "cycle", 10, "recovery rule: never three recovered windows inside 180 s")
    cycle(f"{out}/recovers-late/cycle", recover_after_s=185)
    add("recovers-late", "cycle", 10, "recovery rule: recovery would start at 200 s, past the last countable window")
    cycle(f"{out}/recovery-with-failures/cycle", recover_after_s=0, fail_every=12)
    add("recovery-with-failures", "cycle", 10, "recovery rule: fast windows that still lose requests are not recovered")
    cycle(f"{out}/baseline-thin/cycle", baseline_rate=0.5)
    add("baseline-thin", "cycle", 2, "too few samples: the baseline cannot be the recovery reference")
    cycle(f"{out}/token-contract/cycle", tokens=lambda i: (512, 127) if i == 30 else (512, 128))
    add("token-contract", "report", 3, "exclusion X3: a [DONE] stream with 127 completion tokens")
    return m


if __name__ == "__main__":
    out = sys.argv[1]
    manifest = build(out)
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(json.dumps(manifest, indent=2))
