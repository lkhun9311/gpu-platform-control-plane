"""Checks a step log from step_logging_scheduler.py against the engine's own iteration log.

    python3 check_step_log.py STEP_LOG ENGINE_LOG [OUTPUT_TOKENS_BY_ID_JSON]
    python3 check_step_log.py --self-test

It refuses rather than reports when the log cannot be trusted, because every later number is built on it:
  - a record after an overflow, or an overflow at all
  - a scheduled step without its done record, or step indices that skip
  - a step count or a per-step token total that differs from the engine's Iteration( lines
  - a request whose scheduled tokens do not sum to prompt + output - 1 (given the client's output counts)
  - a step whose instrument cost exceeds 1% of that step's measured occupancy (t0 to t3)
  - a log that does not end with a flush record
It prints the instrument's cost as the share of occupancy, median and worst, so the overhead is a number in the
archive and not a claim.
"""

import json
import re
import statistics
import sys

ITER = re.compile(r"Iteration\((\d+)\): (\d+) context requests, (\d+) context tokens, (\d+) generation requests, "
                  r"(\d+) generation tokens, iteration elapsed time: ([0-9.]+) ms")
MAX_SELF_SHARE = 0.01


class Refusal(Exception):
    pass


def load(step_lines, engine_lines):
    recs = [json.loads(l) for l in step_lines if l.strip()]
    # The plugin writes only when the engine drains and ends every write with a flush record, so a log that does
    # not end on one was cut off mid-write or never drained.
    if not recs or recs[-1]["ev"] != "flush":
        raise Refusal("the step log does not end with a flush record, so it may be cut short")
    over = [r for r in recs if r["ev"] == "overflow"]
    if over:
        raise Refusal(f"the instrument's buffer overflowed after {over[0]['dropped_after']} records, so the log is short")
    sched = [r for r in recs if r["ev"] == "sched"]
    done = {r["step"]: r for r in recs if r["ev"] == "done"}
    adds = [r for r in recs if r["ev"] == "add"]
    if [r["step"] for r in sched] != list(range(1, len(sched) + 1)):
        raise Refusal("the scheduled steps' indices are not 1..n in order")
    missing = [r["step"] for r in sched if r["step"] not in done]
    if missing:
        raise Refusal(f"{len(missing)} scheduled step(s) have no done record, first {missing[0]}")
    iters = [tuple(float(x) for x in m.groups()) for m in map(ITER.search, engine_lines) if m]
    return sched, done, adds, iters


def check(step_lines, engine_lines, outputs=None):
    sched, done, adds, iters = load(step_lines, engine_lines)
    lines = []
    if len(iters) != len(sched):
        raise Refusal(f"the instrument recorded {len(sched)} steps and the engine logged {len(iters)}")
    for s, it in zip(sched, iters):
        if sum(s["tokens"].values()) != int(it[2] + it[4]):
            raise Refusal(f"step {s['step']}: the instrument scheduled {sum(s['tokens'].values())} tokens and the "
                          f"engine logged {int(it[2] + it[4])}")
    lines.append(f"steps: {len(sched)} recorded, {len(iters)} logged by the engine, tokens equal at every step")
    shares = []
    for s in sched:
        d = done[s["step"]]
        occupancy = d["t3"] - s["t0"]
        cost = s["self"] + d["self"]
        shares.append(cost / occupancy if occupancy > 0 else float("inf"))
    worst = max(shares)
    lines.append(f"instrument cost per step: median {statistics.median(shares):.5%}, worst {worst:.5%} of occupancy")
    if worst > MAX_SELF_SHARE:
        raise Refusal(f"a step's instrument cost was {worst:.3%} of its occupancy, above {MAX_SELF_SHARE:.0%}")
    if outputs is not None:
        prompt = {a["id"]: a["prompt"] for a in adds}
        scheduled = {}
        for s in sched:
            for rid, n in s["tokens"].items():
                scheduled[rid] = scheduled.get(rid, 0) + n
        for rid, n in scheduled.items():
            out = next((v for k, v in outputs.items() if rid.startswith("chatcmpl-" + k + "-")), None)
            if out is None:
                raise Refusal(f"engine request {rid} matches no client request id")
            if n != prompt[rid] + out - 1:
                raise Refusal(f"{rid}: {n} tokens scheduled, but prompt {prompt[rid]} + output {out} - 1 = "
                              f"{prompt[rid] + out - 1}")
        lines.append(f"requests: {len(scheduled)} joined to client ids, every one scheduled prompt + output - 1 tokens")
    return lines


def self_test():
    def step_log(extra_self=0):
        return [
            json.dumps({"ev": "add", "id": "chatcmpl-a-1-xx", "mono": 0, "wall": 0, "prompt": 4, "self": 10}),
            json.dumps({"ev": "sched", "step": 1, "t0": 0, "t1": 100, "wall1": 0, "tokens": {"chatcmpl-a-1-xx": 4},
                        "computed": {"chatcmpl-a-1-xx": 0}, "self": 50 + extra_self}),
            json.dumps({"ev": "done", "step": 1, "t2": 1_000_000, "t3": 1_000_100, "self": 50}),
            json.dumps({"ev": "sched", "step": 2, "t0": 1_000_200, "t1": 1_000_300, "wall1": 0,
                        "tokens": {"chatcmpl-a-1-xx": 1}, "computed": {"chatcmpl-a-1-xx": 4}, "self": 50}),
            json.dumps({"ev": "done", "step": 2, "t2": 2_000_000, "t3": 2_000_100, "self": 50}),
            json.dumps({"ev": "flush", "mono": 2_000_200, "records": 5}),
        ]
    engine = ["Iteration(1): 1 context requests, 4 context tokens, 0 generation requests, 0 generation tokens, iteration elapsed time: 0.9 ms",
              "Iteration(2): 0 context requests, 0 context tokens, 1 generation requests, 1 generation tokens, iteration elapsed time: 0.9 ms"]
    lines = check(step_log(), engine, {"a-1": 2})
    print("ok: a consistent log passes --", "; ".join(lines))
    for what, sl, el, outs, words in [
        ("an engine step the instrument missed", step_log()[:3] + step_log()[5:], engine, None, "recorded 1 steps"),
        ("a token total that differs", step_log(), [engine[0].replace("4 context tokens", "5 context tokens"), engine[1]], None, "logged 5"),
        ("a request whose tokens do not reconcile", step_log(), engine, {"a-1": 3}, "prompt 4 + output 3"),
        ("an instrument cost above 1%", step_log(extra_self=20_000), engine, None, "above 1%"),
        ("an overflow", step_log()[:-1] + [json.dumps({"ev": "overflow", "mono": 0, "dropped_after": 9}), step_log()[-1]], engine, None, "overflowed"),
        ("a step without its done record", step_log()[:2] + step_log()[3:], engine, None, "no done record"),
        ("a log cut off before its flush", step_log()[:-1], engine, None, "does not end with a flush"),
    ]:
        try:
            check(sl, el, outs)
            raise AssertionError(f"{what} was accepted")
        except Refusal as e:
            assert words in str(e), (what, e)
            print(f"ok: refuses {what} -- {e}")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) in (3, 4):
            outs = json.load(open(sys.argv[3])) if len(sys.argv) == 4 else None
            print("\n".join(check(open(sys.argv[1]).read().splitlines(), open(sys.argv[2]).read().splitlines(), outs)))
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
