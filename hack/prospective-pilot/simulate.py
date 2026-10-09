"""A scheduler replay on the pilot's archives, to screen gateway admission rules before any purchase.

    python3 simulate.py validate DIR [DIR ...]   fit the step model and reproduce each archived arm's premium p99
    python3 simulate.py screen DIR [DIR ...]      replay every off cell's arrivals under each candidate rule

It models vLLM v0.27.1's V1 scheduler as the pilot's step logs show it working (design page, "Where the premium tail's
1.5 s goes"): each step has a 512-token budget and at most 64 running requests; running requests are scheduled first,
a prefilling one taking as many of its remaining prompt tokens as the budget leaves and a decoding one taking one;
waiting requests then take what is left, in priority order and then by arrival. A request's first token is sampled at
the end of the step that completes its prompt. A step's duration comes from a linear model fitted on the archived
steps.

Its outputs screen candidates; they are not measurements, and a candidate it favours still has to be measured.
"""

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pilot_report as pr  # noqa: E402

BUDGET = 512
MAX_SEQS = 64
CAP = {pr.PREMIUM: 64, pr.CONTENDER: 16}
PRIORITY = {pr.PREMIUM: 0, pr.CONTENDER: 1}
TIMEOUT_NS = 30_000_000_000


# ---------------------------------------------------------------- the archive


def load_cell(stage_dir, arm, rep):
    """The cell's requests, its steps and the engine IDs, from the archive."""
    tag = "%s-%d" % (arm, rep)
    rows = pr.jsonl(os.path.join(stage_dir, "raw-%s.jsonl" % tag))
    gw = pr.gateway_records(os.path.join(stage_dir, "gateway-record-%s.jsonl" % tag))
    steps = pr.jsonl(os.path.join(stage_dir, "step-log-%s.jsonl" % tag))
    adds = {s["id"]: s for s in steps if s.get("ev") == "add"}
    by_client = {}
    for e in adds:
        if e.startswith("chatcmpl-") and "fence-" not in e and "calib-" not in e:
            by_client[e[len("chatcmpl-"):].rsplit("-", 1)[0]] = adds[e]
    reqs = []
    for r in rows:
        d = (gw.get(r["requestId"]) or {}).get("done") or {}
        a = by_client.get(r["requestId"])
        reqs.append({
            "id": r["requestId"], "tenant": r["tenant"],
            "sched": r["replayOriginUnixNanos"] + r["scheduledOffsetMs"] * 1_000_000,
            "gw_arrived": d.get("arrivedUnixNanos"),
            "engine_add": a["arrival_wall"] if a else None,
            "prompt": a["prompt"] if a else r.get("exactInputTokens"),
            "first_content": d.get("firstContentUnixNanos"),
            "admitted": d.get("decision") == "admit",
        })
    return reqs, steps, adds


def step_features(step, adds):
    """[1, prefill tokens, running requests, context in thousands, prefill-attention work in millions]."""
    pf = ctx = att = 0
    for e, n in step["tokens"].items():
        p = adds[e]["prompt"] if e in adds else 0
        c = step["computed"].get(e, 0)
        f = min(n, max(p - c, 0))
        pf += f
        ctx += c + n
        att += f * (c + f / 2)
    return [1.0, pf, len(step["tokens"]), ctx / 1000.0, att / 1e6]


def fit_step_model(cells):
    """Least squares of the step period (one step's t0 to the next's) on step_features, over busy steps."""
    X, y = [], []
    for _, steps, adds in cells:
        sched = [s for s in steps if s.get("ev") == "sched"]
        for a, b in zip(sched, sched[1:]):
            period = (b["t0"] - a["t0"]) / 1e6
            if period > 500:  # the engine went idle between them; that gap is not a step
                continue
            X.append(step_features(a, adds))
            y.append(period)
    k = len(X[0])
    xtx = [[sum(r[i] * r[j] for r in X) for j in range(k)] for i in range(k)]
    xty = [sum(r[i] * v for r, v in zip(X, y)) for i in range(k)]
    return solve(xtx, xty), len(y)


def solve(a, b):
    """Gaussian elimination with partial pivoting."""
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c and m[c][c]:
                f = m[r][c] / m[c][c]
                m[r] = [x - f * y for x, y in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


# ---------------------------------------------------------------- the engine


class Engine:
    """The scheduler, stepped by the simulation; times in nanoseconds."""

    def __init__(self, coef):
        self.coef = coef
        self.waiting = []   # [priority, arrival, req]
        self.running = []   # req, in the order it started running
        self.now = None

    def add(self, req, t):
        req["computed"], req["out"] = 0, 0
        self.waiting.append([PRIORITY[req["tenant"]], t, req])

    def step(self):
        """Run one step from self.now; returns the requests whose first token it sampled and those it finished."""
        budget, tokens = BUDGET, {}
        for r in self.running:
            if budget == 0:
                break
            n = min(r["prompt"] - r["computed"], budget) if r["computed"] < r["prompt"] else 1
            tokens[id(r)] = (r, n)
            budget -= n
        self.waiting.sort(key=lambda w: (w[0], w[1]))
        while self.waiting and budget > 0 and len(self.running) < MAX_SEQS and self.waiting[0][1] <= self.now:
            _, _, r = self.waiting.pop(0)
            n = min(r["prompt"], budget)
            self.running.append(r)
            tokens[id(r)] = (r, n)
            budget -= n
        if not tokens:
            return None
        pf = ctx = att = 0
        for r, n in tokens.values():
            f = min(n, max(r["prompt"] - r["computed"], 0))
            pf += f
            ctx += r["computed"] + n
            att += f * (r["computed"] + f / 2)
        x = [1.0, pf, len(tokens), ctx / 1000.0, att / 1e6]
        dur = max(1.0, sum(c * v for c, v in zip(self.coef, x))) * 1e6
        end = self.now + dur
        first, done = [], []
        for r, n in tokens.values():
            if r["computed"] < r["prompt"]:
                r["computed"] += n
                if r["computed"] >= r["prompt"]:
                    r["out"] = 1
                    r["first_token"] = end
                    first.append(r)
            else:
                r["out"] += 1
            if r["out"] >= CAP[r["tenant"]]:
                r["finished"] = end
                done.append(r)
        self.running = [r for r in self.running if "finished" not in r]
        self.now = end
        return first, done


# ---------------------------------------------------------------- the gateway's rules


def simulate(reqs, coef, rule, forward_ns, deliver_ns):
    """Replay the requests' gateway arrivals under rule; every request gets first_token, finished, or refused/expired.

    rule(gateway, req) is asked at each step boundary for every held contender, and returns "forward", "hold" or
    "refuse"; gateway is what a gateway can see: its forwarded contenders, and which have produced a first token.
    """
    reqs = [dict(r) for r in reqs if r["gw_arrived"] is not None]
    reqs.sort(key=lambda r: r["gw_arrived"])
    eng = Engine(coef)
    eng.now = reqs[0]["gw_arrived"]
    gw = {"in_prefill": set(), "outstanding": set(), "premium_waiting": set()}
    held, i = [], 0
    while True:
        while i < len(reqs) and reqs[i]["gw_arrived"] <= eng.now:
            r = reqs[i]
            i += 1
            if r["tenant"] == pr.PREMIUM:
                eng.add(r, r["gw_arrived"] + forward_ns)
                gw["premium_waiting"].add(id(r))
            else:
                held.append(r)
        keep = []
        for r in held:
            if eng.now - r["sched"] > TIMEOUT_NS:
                r["expired"] = True
                continue
            d = rule(gw, r)
            if d == "forward":
                eng.add(r, eng.now + forward_ns)
                gw["in_prefill"].add(id(r))
                gw["outstanding"].add(id(r))
                r["forwarded"] = eng.now
            elif d == "refuse":
                r["refused"] = True
            else:
                keep.append(r)
        held = keep
        out = eng.step()
        if out is None:
            nxt = [reqs[i]["gw_arrived"]] if i < len(reqs) else []
            nxt += [w[1] for w in eng.waiting]
            if not nxt and not held:
                break
            eng.now = max(eng.now + 1_000_000, min(nxt)) if nxt else eng.now + 10_000_000
            continue
        first, done = out
        for r in first:
            gw["in_prefill"].discard(id(r))
            gw["premium_waiting"].discard(id(r))
        for r in done:
            gw["outstanding"].discard(id(r))
    for r in reqs:
        if "first_token" in r:
            r["ttft_ms"] = (r["first_token"] + deliver_ns - r["sched"]) / 1e6
    return reqs


def summarize(reqs):
    prem = sorted(r["ttft_ms"] for r in reqs if r["tenant"] == pr.PREMIUM and "ttft_ms" in r)
    cont = [r for r in reqs if r["tenant"] == pr.CONTENDER]
    completed = [r for r in cont if "finished" in r and r["finished"] - r["sched"] <= TIMEOUT_NS]
    delays = sorted((r["forwarded"] - r["gw_arrived"]) / 1e6 for r in cont if "forwarded" in r)
    return {"premium_p99_ms": pr.nearest_rank(prem, 0.99), "premium_p50_ms": pr.nearest_rank(prem, 0.5),
            "contender_completed": len(completed), "contender_offered": len(cont),
            "contender_hold_p50_ms": pr.nearest_rank(delays, 0.5), "contender_hold_max_ms": delays[-1] if delays else None}


RULES = {
    "off": lambda gw, r: "forward",
    "recorded": lambda gw, r: "forward" if r["admitted"] else "refuse",
    # At most one contender whose first token has not come back: the prefill the tail waits on.
    "hold-one-prefill": lambda gw, r: "forward" if not gw["in_prefill"] else "hold",
    "refuse-one-prefill": lambda gw, r: "forward" if not gw["in_prefill"] else "refuse",
    # At most one contender outstanding at all, until it finishes.
    "hold-one-stream": lambda gw, r: "forward" if not gw["outstanding"] else "hold",
    # No contender is forwarded while a premium request is waiting for its first token.
    "hold-premium-clear": lambda gw, r: "forward" if not gw["in_prefill"] and not gw["premium_waiting"] else "hold",
}


# ---------------------------------------------------------------- commands


def stage_dirs(argv):
    for d in argv:
        for arm, rep in pr.cells(d):
            yield d, arm, rep


def offsets(cells):
    """The median gateway-arrival-to-engine-add delay, in nanoseconds."""
    fwd = []
    for reqs, _, _ in cells:
        for r in reqs:
            if r["gw_arrived"] and r["engine_add"]:
                fwd.append(r["engine_add"] - r["gw_arrived"])
    fwd.sort()
    return fwd[len(fwd) // 2]


def main(argv):
    if len(argv) < 3 or argv[1] not in ("validate", "screen"):
        print(__doc__)
        return 64
    loaded = {(d, a, r): load_cell(d, a, r) for d, a, r in stage_dirs(argv[2:])}
    coef, n = fit_step_model(list(loaded.values()))
    fwd = offsets(list(loaded.values()))
    deliver = 8_000_000
    print(json.dumps({"step_model_ms": [round(c, 4) for c in coef], "fitted_steps": n, "forward_ms": fwd / 1e6}))
    if argv[1] == "validate":
        for (d, arm, rep), (reqs, _, _) in sorted(loaded.items()):
            measured = sorted((r["first_content"] - r["sched"]) / 1e6 for r in reqs if r["tenant"] == pr.PREMIUM and r["first_content"])
            sim = summarize(simulate(reqs, coef, RULES["recorded"] if arm in ("prospective", "static-cap") else RULES["off"], fwd, deliver))
            print("%s %-12s %d measured p99 %7.1f  simulated p99 %7.1f  (p50 %6.1f / %6.1f)" % (
                os.path.basename(os.path.dirname(d)), arm, rep, pr.nearest_rank(measured, 0.99), sim["premium_p99_ms"],
                pr.nearest_rank(measured, 0.5), sim["premium_p50_ms"]))
        return 0
    for (d, arm, rep), (reqs, _, _) in sorted(loaded.items()):
        if arm != "off":
            continue
        for name, rule in RULES.items():
            if name == "recorded":
                continue
            s = summarize(simulate(reqs, coef, rule, fwd, deliver))
            print("%s off-%d %-20s premium p99 %7.1f  p50 %6.1f  contenders %d/%d  hold p50 %s max %s" % (
                os.path.basename(os.path.dirname(d)), rep, name, s["premium_p99_ms"], s["premium_p50_ms"],
                s["contender_completed"], s["contender_offered"],
                None if s["contender_hold_p50_ms"] is None else round(s["contender_hold_p50_ms"]),
                None if s["contender_hold_max_ms"] is None else round(s["contender_hold_max_ms"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
