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
  - a write that was still running when the next request arrived
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
    # Each write runs on a background thread after a drain; it must have ended before the next request reached the
    # scheduler, or the write overlapped measured work.
    for i, r in enumerate(recs):
        if r["ev"] == "flush":
            if "end" not in r:
                raise Refusal("a flush record carries no end stamp, so whether it overlapped a request is unknown")
            if r.get("handoff_ns") is None:
                raise Refusal("a flush record carries no handoff cost, so the instrument's cost for that step is unknown")
            nxt = next((x for x in recs[i + 1:] if x["ev"] == "add"), None)
            if nxt is not None and r["end"] >= nxt["mono"]:
                raise Refusal(f"a write ended at {r['end']} ns, after request {nxt['id']} arrived at {nxt['mono']} ns")
    over = [r for r in recs if r["ev"] == "overflow"]
    if over:
        raise Refusal(f"the instrument's buffer overflowed after {over[0]['dropped_after']} records, so the log is short")
    sched = [r for r in recs if r["ev"] == "sched"]
    dones = [r for r in recs if r["ev"] == "done"]
    done = {r["step"]: r for r in dones}
    if len(done) != len(dones):
        raise Refusal("a step has more than one done record")
    adds = [r for r in recs if r["ev"] == "add"]
    # The cost of handing a batch to the writer, charged to the step after which it was handed over.
    launch = {}
    for r in recs:
        if r["ev"] == "flush":
            launch[r["step"]] = launch.get(r["step"], 0) + r["handoff_ns"]
    # Clock anchors: a wall reading bracketed by two monotonic ones, in order; and vLLM's arrival stamp, taken in
    # the frontend before the request was sent, must precede the scheduler's own reading of the wall clock.
    for r in adds + sched:
        a = r.get("anchor")
        if not a or not a[0] <= a[2]:
            raise Refusal(f"a {r['ev']} record has no ordered monotonic bracket around its wall reading")
    for r in adds:
        if r["arrival_wall"] > r["anchor"][1]:
            raise Refusal(f"request {r['id']} arrived at the frontend after it reached the scheduler")
    if [r["step"] for r in sched] != list(range(1, len(sched) + 1)):
        raise Refusal("the scheduled steps' indices are not 1..n in order")
    missing = [r["step"] for r in sched if r["step"] not in done]
    if missing:
        raise Refusal(f"{len(missing)} scheduled step(s) have no done record, first {missing[0]}")
    # A step's four boundaries in order, and no step starting before the previous one's update ended.
    prev_t3 = None
    for r in sched:
        d = done[r["step"]]
        if not r["t0"] <= r["t1"] <= d["t2"] <= d["t3"]:
            raise Refusal(f"step {r['step']}: its boundaries are out of order")
        if prev_t3 is not None and r["t0"] < prev_t3:
            raise Refusal(f"step {r['step']} started before step {r['step'] - 1}'s update ended")
        prev_t3 = d["t3"]
    # Each request's computed tokens continue where its previous step left them.
    progress = {}
    for r in sched:
        for rid, n in r["tokens"].items():
            c = r["computed"].get(rid, -1)
            if c != progress.get(rid, c if rid not in progress else -2) or c < 0:
                raise Refusal(f"step {r['step']}: request {rid} reports {c} computed tokens, not the "
                              f"{progress.get(rid, 0)} its earlier steps scheduled")
            progress[rid] = c + n
    iters = [tuple(float(x) for x in m.groups()) for m in map(ITER.search, engine_lines) if m]
    return sched, done, adds, iters, launch


def check(step_lines, engine_lines, outputs=None):
    sched, done, adds, iters, launch = load(step_lines, engine_lines)
    lines = []
    if len(iters) != len(sched):
        raise Refusal(f"the instrument recorded {len(sched)} steps and the engine logged {len(iters)}")
    for s, it in zip(sched, iters):
        if sum(s["tokens"].values()) != int(it[2] + it[4]):
            raise Refusal(f"step {s['step']}: the instrument scheduled {sum(s['tokens'].values())} tokens and the "
                          f"engine logged {int(it[2] + it[4])}")
    lines.append(f"steps: {len(sched)} recorded, {len(iters)} logged by the engine, tokens equal at every step")
    shares = []
    prev_t3 = None
    for s in sched:
        d = done[s["step"]]
        occupancy = d["t3"] - s["t0"]
        # Admissions recorded between the previous step's update and this step's scheduling delay this step, so
        # their cost is this step's too (a review built 20 ms of admission cost that the bound had ignored).
        admitted = sum(a["self"] for a in adds if (prev_t3 is None or a["mono"] >= prev_t3) and a["mono"] <= s["t0"])
        cost = s["self"] + d["self"] + launch.get(s["step"], 0) + admitted
        prev_t3 = d["t3"]
        shares.append(cost / occupancy if occupancy > 0 else float("inf"))
    worst = max(shares)
    lines.append(f"instrument cost per step: median {statistics.median(shares):.5%}, worst {worst:.5%} of occupancy")
    widths = [r["anchor"][2] - r["anchor"][0] for r in adds + sched]
    lines.append(f"clock anchors: {len(widths)}, bracket median {statistics.median(widths)} ns, worst {max(widths)} ns")
    if worst > MAX_SELF_SHARE:
        raise Refusal(f"a step's instrument cost was {worst:.3%} of its occupancy, above {MAX_SELF_SHARE:.0%}")
    if outputs is not None:
        prompt = {a["id"]: a["prompt"] for a in adds}
        scheduled = {}
        for s in sched:
            for rid, n in s["tokens"].items():
                scheduled[rid] = scheduled.get(rid, 0) + n
        # One to one: every engine request joins exactly one client id and every client id exactly one engine
        # request, or a log holding only a prefix of the workload would pass on what it happened to keep.
        joined = {}
        for rid in scheduled:
            ks = [k for k in outputs if rid.startswith("chatcmpl-" + k + "-")]
            if len(ks) != 1:
                raise Refusal(f"engine request {rid} matches {len(ks)} client request ids, not one")
            if ks[0] in joined:
                raise Refusal(f"client request {ks[0]} matches two engine requests, {joined[ks[0]]} and {rid}")
            joined[ks[0]] = rid
        absent = sorted(set(outputs) - set(joined))
        if absent:
            raise Refusal(f"{len(absent)} client request(s) appear in no engine record, first {absent[0]}")
        for rid, n in scheduled.items():
            out = next(v for k, v in outputs.items() if rid.startswith("chatcmpl-" + k + "-"))
            if n != prompt[rid] + out - 1:
                raise Refusal(f"{rid}: {n} tokens scheduled, but prompt {prompt[rid]} + output {out} - 1 = "
                              f"{prompt[rid] + out - 1}")
        lines.append(f"requests: {len(scheduled)} joined to client ids, every one scheduled prompt + output - 1 tokens")
    return lines


def self_test():
    def step_log(extra_self=0):
        return [
            json.dumps({"ev": "add", "id": "chatcmpl-a-1-xx", "mono": 0, "anchor": [0, 100, 2], "arrival_wall": 90, "prompt": 4, "self": 10}),
            json.dumps({"ev": "sched", "step": 1, "t0": 0, "t1": 100, "anchor": [100, 200, 102], "tokens": {"chatcmpl-a-1-xx": 4},
                        "computed": {"chatcmpl-a-1-xx": 0}, "self": 50 + extra_self}),
            json.dumps({"ev": "done", "step": 1, "t2": 1_000_000, "t3": 1_000_100, "self": 50}),
            json.dumps({"ev": "sched", "step": 2, "t0": 1_000_200, "t1": 1_000_300, "anchor": [1_000_300, 1_000_400, 1_000_302],
                        "tokens": {"chatcmpl-a-1-xx": 1}, "computed": {"chatcmpl-a-1-xx": 4}, "self": 50}),
            json.dumps({"ev": "done", "step": 2, "t2": 2_000_000, "t3": 2_000_100, "self": 50}),
            json.dumps({"ev": "flush", "mono": 2_000_200, "end": 2_000_300, "records": 5, "step": 2, "handoff_ns": 20}),
        ]
    engine = ["Iteration(1): 1 context requests, 4 context tokens, 0 generation requests, 0 generation tokens, iteration elapsed time: 0.9 ms",
              "Iteration(2): 0 context requests, 0 context tokens, 1 generation requests, 1 generation tokens, iteration elapsed time: 0.9 ms"]
    lines = check(step_log(), engine, {"a-1": 2})
    print("ok: a consistent log passes --", "; ".join(lines))
    for what, sl, el, outs, words in [
        ("an engine step the instrument missed", step_log()[:3] + step_log()[5:], engine, None, "recorded 1 steps"),
        ("a token total that differs", step_log(), [engine[0].replace("4 context tokens", "5 context tokens"), engine[1]], None, "logged 5"),
        ("a request whose tokens do not reconcile", step_log(), engine, {"a-1": 3}, "prompt 4 + output 3"),
        ("a client request missing from the step log", step_log(), engine, {"a-1": 2, "a-2": 2}, "appear in no engine record"),
        ("an instrument cost above 1%", step_log(extra_self=20_000), engine, None, "above 1%"),
        ("an overflow", step_log()[:-1] + [json.dumps({"ev": "overflow", "mono": 0, "dropped_after": 9}), step_log()[-1]], engine, None, "overflowed"),
        ("a step without its done record", step_log()[:2] + step_log()[3:], engine, None, "no done record"),
        ("a log cut off before its flush", step_log()[:-1], engine, None, "does not end with a flush"),
        ("a duplicated done record", step_log()[:3] + [step_log()[2]] + step_log()[3:], engine, None, "more than one done"),
        ("boundaries out of order", [step_log()[0], step_log()[1].replace('"t1": 100', '"t1": 2000000')] + step_log()[2:],
         engine, None, "out of order"),
        ("computed tokens that do not continue", step_log()[:3] + [step_log()[3].replace('{"chatcmpl-a-1-xx": 4}', '{"chatcmpl-a-1-xx": 3}')]
         + step_log()[4:], engine, None, "computed tokens"),
        ("a flush with no end stamp", step_log()[:-1] + [json.dumps({"ev": "flush", "mono": 2_000_200, "records": 5,
         "step": 2, "handoff_ns": 20})], engine, None, "no end stamp"),
        ("a flush with no handoff cost", step_log()[:-1] + [json.dumps({"ev": "flush", "mono": 2_000_200, "end": 2_000_300,
         "records": 5, "step": 2})], engine, None, "no handoff cost"),
        ("an admission cost above 1% of the step it delayed", [step_log()[0].replace('"self": 10', '"self": 20000')] + step_log()[1:],
         engine, None, "above 1%"),
        ("an arrival after the scheduler saw it", [step_log()[0].replace('"arrival_wall": 90', '"arrival_wall": 150')] + step_log()[1:],
         engine, None, "arrived at the frontend after"),
        ("a write still running when the next request arrived",
         [json.dumps({"ev": "flush", "mono": 0, "end": 5, "records": 0, "step": 0, "handoff_ns": 1})]
         + [step_log()[0].replace('"mono": 0', '"mono": 3')] + step_log()[1:], engine, None, "after request")
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
