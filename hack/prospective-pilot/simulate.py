"""A scheduler replay on the pilot's archives, to screen gateway admission rules before any purchase.

    python3 simulate.py validate DIR [DIR ...]   fit the step model and reproduce each archived arm's premium p99
    python3 simulate.py screen DIR [DIR ...]      replay every off cell's arrivals under each candidate rule
    python3 simulate.py threshold DIR [DIR ...]   replay them under vLLM's long_prefill_token_threshold instead
    python3 simulate.py combine DIR [DIR ...]     the threshold together with the one-prefill gateway rules
    python3 simulate.py control DIR [DIR ...]     hold-cap against a fixed-spacing static control at several spacings
    python3 simulate.py feasible [--scale K] DIR [DIR ...]
                                                  which spacings, 10 ms apart, meet the owner's contender limits beside
                                                  hold-cap, at K times the fitted step time, and the pooled premium p99
    python3 simulate.py frontier [--scale K] DIR [DIR ...]
                                                  v26's registered decision on the archived traces: each grid arm's
                                                  admissibility, every arm's pooled premium p99, and the verdict
    python3 simulate.py pace DIR [DIR ...] [-- DIR ...]   each cell's measured step time against the model fitted
                                                  before the --, and why a fixed spacing fails when the pace slows

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
# serial-prefill's longest hold (internal/gateway/serialprefill.go), counted from the request's place in the queue,
# which is its gateway arrival here; a contender held past it is refused, as the gateway refuses it.
HOLD_NS = 25_000_000_000


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

    def __init__(self, coef, long_prefill=0, step_scale=1.0):
        self.coef = coef
        # Every step's modelled duration is multiplied by this, to test how much a conclusion leans on the fit.
        self.step_scale = step_scale
        # vLLM's long_prefill_token_threshold: when positive, no prefill takes more than this many tokens in a step,
        # running or newly scheduled (v1/core/sched/scheduler.py, the two places that read it).
        self.long_prefill = long_prefill
        self.waiting = []   # [priority, arrival, req]
        self.running = []   # req, in the order it started running
        self.now = None

    def add(self, req, t):
        req["computed"], req["out"] = 0, 0
        # When it reached the engine, so that a contender's capped prefill can be timed from here to its first token.
        req["engaged"] = t
        self.waiting.append([PRIORITY[req["tenant"]], t, req])

    def _cap(self, n):
        return min(n, self.long_prefill) if self.long_prefill > 0 else n

    def step(self):
        """Run one step from self.now; returns the requests whose first token it sampled and those it finished."""
        budget, tokens = BUDGET, {}
        for r in self.running:
            if budget == 0:
                break
            n = min(self._cap(r["prompt"] - r["computed"]), budget) if r["computed"] < r["prompt"] else 1
            tokens[id(r)] = (r, n)
            budget -= n
        # Only requests that have reached the engine compete; one still in flight must not block those behind it
        # (simulator review, finding 3).
        ready = sorted((w for w in self.waiting if w[1] <= self.now), key=lambda w: (w[0], w[1]))
        while ready and budget > 0 and len(self.running) < MAX_SEQS:
            w = ready.pop(0)
            self.waiting.remove(w)
            _, _, r = w
            n = min(self._cap(r["prompt"]), budget)
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
        dur = max(1.0, sum(c * v for c, v in zip(self.coef, x))) * 1e6 * self.step_scale
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
                # A decode step adds its token to the context, which the step-time model reads (review, finding 2).
                r["computed"] += n
                r["out"] += 1
            if r["out"] >= CAP[r["tenant"]]:
                r["finished"] = end
                done.append(r)
        self.running = [r for r in self.running if "finished" not in r]
        self.now = end
        return first, done


# ---------------------------------------------------------------- the gateway's rules


def simulate(reqs, coef, rule, forward_ns, deliver_ns, long_prefill=0, step_scale=1.0):
    """Replay the requests' gateway arrivals under rule; every request gets first_token, finished, or refused/expired.

    rule(gateway, req) is asked at each step boundary for every held contender, and returns "forward", "hold" or
    "refuse"; gateway is what a gateway can see: its forwarded contenders, and which have produced a first token.
    """
    reqs = [dict(r) for r in reqs if r["gw_arrived"] is not None]
    reqs.sort(key=lambda r: r["gw_arrived"])
    eng = Engine(coef, long_prefill, step_scale)
    eng.now = reqs[0]["gw_arrived"]
    gw = {"in_prefill": set(), "outstanding": set(), "premium_waiting": set()}
    # For time-based rules: the instant being decided at, and when the last contender was forwarded.
    gw["now"], gw["last_forward"] = None, None
    # When a time-based rule will next forward a held contender without any other event; None for the others.
    gw["wake"] = None
    held, i, notices = [], 0, []

    def decide(r, at):
        """The rule's answer for contender r at time at; True when it is settled (forwarded, refused or expired)."""
        if at - r["sched"] > TIMEOUT_NS:
            r["expired"] = True
            return True
        gw["now"] = at
        d = rule(gw, r)
        if isinstance(d, tuple):
            # A rule that knows when it would have forwarded, between two decision points: a fixed spacing.
            d, at = d[0], max(r["gw_arrived"], min(d[1], at))
        # The hold deadline is judged at the instant the rule would have forwarded, not at the step boundary that
        # found it: a spacing that ended inside the 25 s is a forward, not a refusal (v26 review, finding 1).
        if at - r["gw_arrived"] > HOLD_NS:
            r["refused"] = r["hold_timeout"] = True
            return True
        if d == "forward":
            gw["last_forward"] = at
            eng.add(r, at + forward_ns)
            gw["in_prefill"].add(id(r))
            gw["outstanding"].add(id(r))
            r["forwarded"] = at
            return True
        if d == "refuse":
            r["refused"] = True
            return True
        return False

    while True:
        # Arrivals and delivered notices up to now, in the order they happened, each decided with the gateway's state
        # at its own instant; a held contender is reconsidered at the instant a notice changes that state, in arrival
        # order (simulator reviews of e51e8e6 and f2e0c8a).
        events = [(ev[0], 0, ev) for ev in notices if ev[0] <= eng.now]
        while i < len(reqs) and reqs[i]["gw_arrived"] <= eng.now:
            events.append((reqs[i]["gw_arrived"], 1, reqs[i]))
            i += 1
        for t, kind, x in sorted(events, key=lambda e: (e[0], e[1])):
            if kind == 0:
                notices.remove(x)
                for k in x[1]:
                    gw[k].discard(x[2])
                held = [r for r in held if not decide(r, t)]
            elif x["tenant"] == pr.PREMIUM:
                eng.add(x, t + forward_ns)
                gw["premium_waiting"].add(id(x))
            elif held or not decide(x, t):
                held.append(x)
        held = [r for r in held if not (eng.now - r["sched"] > TIMEOUT_NS and r.setdefault("expired", True))]
        # A held contender past its 25 s is refused by decide below, which first asks whether the rule would have
        # forwarded it in time; a sweep here refused it before that question (v26 review, finding 1).
        # Cancel what has passed its 30-second deadline, waiting or running, and release the gateway's state for it,
        # so a late contender stops taking engine tokens (simulator review, finding 1).
        for w in [w for w in eng.waiting if eng.now - w[2]["sched"] > TIMEOUT_NS]:
            eng.waiting.remove(w)
            w[2]["expired"] = True
            for k in ("in_prefill", "outstanding", "premium_waiting"):
                gw[k].discard(id(w[2]))
        for r in [r for r in eng.running if eng.now - r["sched"] > TIMEOUT_NS]:
            eng.running.remove(r)
            r["expired"] = True
            for k in ("in_prefill", "outstanding", "premium_waiting"):
                gw[k].discard(id(r))
        # A cancellation can clear the state a held contender waits on, as a delivered notice can, so the held are
        # reconsidered here too (review of 7caa759).
        held = [r for r in held if not decide(r, eng.now)]
        out = eng.step()
        if out is None:
            nxt = [reqs[i]["gw_arrived"]] if i < len(reqs) else []
            nxt += [w[1] for w in eng.waiting if w[1] > eng.now] + [ev[0] for ev in notices]
            # An idle engine must not jump past a spacing's end to the next arrival, or the held contender is forwarded
            # late with a backdated time, and its prefill runs after that arrival (review of 3cb7e05).
            if held and gw["wake"] is not None and gw["wake"] > eng.now:
                nxt.append(gw["wake"])
            if not nxt and not held:
                break
            eng.now = max(eng.now + 1_000_000, min(nxt)) if nxt else eng.now + 10_000_000
            continue
        first, done = out
        for r in first:
            notices.append((r["first_token"] + deliver_ns, ("in_prefill", "premium_waiting"), id(r)))
        for r in done:
            notices.append((r["finished"] + deliver_ns, ("outstanding",), id(r)))
    for r in reqs:
        if "first_token" in r:
            r["ttft_ms"] = (r["first_token"] + deliver_ns - r["sched"]) / 1e6
        if "finished" in r:
            # Completion is when the client has the last token, not when the engine produced it (v25 review, finding 4).
            r["finished"] += deliver_ns
    return reqs


def summarize(reqs):
    # Every premium request counts: one that expired or never got a token is a failure at +inf, not a dropped sample
    # (simulator review of e51e8e6).
    prem = sorted(r["ttft_ms"] if "ttft_ms" in r and not r.get("expired") else math.inf
                  for r in reqs if r["tenant"] == pr.PREMIUM)
    cont = [r for r in reqs if r["tenant"] == pr.CONTENDER]
    completed = [r for r in cont if "finished" in r and r["finished"] - r["sched"] <= TIMEOUT_NS]
    delays = sorted((r["forwarded"] - r["gw_arrived"]) / 1e6 for r in cont if "forwarded" in r)
    # Completion latency includes every contender: one that expired or was refused counts as never completing.
    lat = sorted([(r["finished"] - r["sched"]) / 1e6 for r in completed] + [math.inf] * (len(cont) - len(completed)))
    last_premium = max((r.get("finished", 0) for r in reqs if r["tenant"] == pr.PREMIUM), default=0)
    return {"premium_p99_ms": pr.nearest_rank(prem, 0.99), "premium_p50_ms": pr.nearest_rank(prem, 0.5),
            "contender_completed": len(completed), "contender_offered": len(cont),
            # Every contender that neither completed in time nor was refused, a late finish included (review of f2e0c8a).
            "contender_expired": len(cont) - len(completed) - sum(1 for r in cont if r.get("refused")),
            "contender_refused": sum(1 for r in cont if r.get("refused")),
            "contender_hold_timeouts": sum(1 for r in cont if r.get("hold_timeout")),
            "contender_completion_p50_ms": pr.nearest_rank(lat, 0.5), "contender_completion_p95_ms": pr.nearest_rank(lat, 0.95),
            "contender_finished_after_last_premium": sum(1 for r in completed if r["finished"] > last_premium),
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


def hold_spacing(spacing_ns):
    """The static control: a contender is forwarded no sooner than spacing_ns after the previous one, held until then,
    with no signal from the engine. It asks whether hold-cap's use of the first-token signal beats fixed pacing."""
    def rule(gw, r):
        last = gw["last_forward"]
        if last is None or gw["now"] - last >= spacing_ns:
            return ("forward", gw["now"] if last is None else max(last + spacing_ns, r["gw_arrived"]))
        gw["wake"] = last + spacing_ns
        return "hold"
    return rule


def owner_limits(x, off):
    """The contender limits the owner froze for the diagnostic, applied to summary x against off's summary; returns the
    first line it fails, or None. A control that breaks them is not a candidate the owner accepted (review of b916a9f)."""
    if x["contender_completed"] < 0.95 * x["contender_offered"]:
        return "completion below 95%"
    if x["contender_completion_p50_ms"] > 1.5 * off["contender_completion_p50_ms"]:
        return "completion p50 above 1.5x off's"
    if x["contender_completion_p95_ms"] > 25_000:
        return "completion p95 above 25 s"
    if x["contender_hold_timeouts"] > 0:
        return "a hold refusal"
    return None


V26_GRID_MS = (1620, 1660, 1700, 1740)


def frontier_verdict(admissible, p99):
    """v26's verdicts 2 to 6 on point estimates: admissible maps each arm to whether it met the owner's limits in every
    block, p99 maps it to its pooled premium p99; the crossed bounds of the real scorer are not modelled here."""
    if not admissible["hold-cap"]:
        return "not met: hold-cap broke the owner's limits"
    fixed = [a for a in admissible if a != "hold-cap" and admissible[a]]
    if not fixed:
        return "observed: hold-cap met the limits and no fixed spacing in the grid did"
    if all(p99["hold-cap"] <= 0.85 * p99[a] for a in fixed):
        return "observed: hold-cap beat every admissible fixed spacing"
    best = min(fixed, key=lambda a: p99[a])
    if p99[best] <= 0.85 * p99["hold-cap"]:
        return "observed: %s beat hold-cap" % best
    return "not established: neither hold-cap nor %s was 15%% below the other" % best


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
    if len(argv) < 3 or argv[1] not in ("validate", "screen", "threshold", "combine", "control", "pace", "feasible", "frontier"):
        print(__doc__)
        return 64
    # A card's pace against the fitted model, as the main study's calibration cell measures it (v26).
    scale = 1.0
    if "--scale" in argv:
        k = argv.index("--scale")
        scale = float(argv[k + 1])
        argv = argv[:k] + argv[k + 2:]
    # Directories after a -- are only measured against the model, never fitted to it: a held-out card.
    held_out = argv[argv.index("--") + 1:] if "--" in argv else []
    fit_dirs = argv[2:argv.index("--")] if "--" in argv else argv[2:]
    loaded = {(d, a, r): load_cell(d, a, r) for d, a, r in stage_dirs(fit_dirs)}
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
    if argv[1] == "pace":
        # How far each cell's engine ran from the model's pace, as total measured step time over total predicted:
        # a fixed spacing tuned at one pace is only as good as the next card's agreement with it.
        for d, arm, rep in [(d, a, r) for d, a, r in stage_dirs(fit_dirs)] + list(stage_dirs(held_out)):
            _, steps, adds = loaded.get((d, arm, rep)) or load_cell(d, arm, rep)
            sched = [s for s in steps if s.get("ev") == "sched"]
            meas = pred = 0.0
            for a, b in zip(sched, sched[1:]):
                period = (b["t0"] - a["t0"]) / 1e6
                if period > 500:
                    continue
                meas += period
                pred += sum(c * v for c, v in zip(coef, step_features(a, adds)))
            # A contender's measured prefill, from reaching the engine to the end of the step that took its last prompt
            # token: what a fixed spacing must outlast, and what hold-cap waits for without being told.
            ends, done = {}, {s["step"]: s["t2"] for s in steps if s.get("ev") == "done"}
            for s in sched:
                for e, n in s["tokens"].items():
                    if e in adds and adds[e]["prompt"] > 1000 and e not in ends and s["computed"].get(e, 0) + n >= adds[e]["prompt"]:
                        ends[e] = done[s["step"]]
            dur = sorted((ends[e] - adds[e]["mono"]) / 1e6 for e in ends)
            # R1 has no contenders, so nothing to time.
            prefill = "p50 %.0f p95 %.0f max %.0f ms" % (pr.nearest_rank(dur, 0.5), pr.nearest_rank(dur, 0.95), dur[-1]) if dur else "none"
            print("%s %s %d | measured/predicted step time %.4f | contender prefill %s%s" % (
                os.path.basename(os.path.dirname(d)), arm, rep, meas / pred, prefill, "" if (d, arm, rep) in loaded else " (held out)"))
        # The mechanism, on the first off cell: a contender's capped prefill against the 1.7 s spacing, and how often
        # two or more overlap, at the fitted pace and 10% slower.
        first = sorted(k for k in loaded if k[1] == "off")[0]
        reqs = loaded[first][0]
        print("\nmechanism on %s off-%d: capped contender prefill, engine arrival to first token" % (os.path.basename(os.path.dirname(first[0])), first[2]))
        for scale in (1.0, 1.1):
            for name, rule in (("hold-cap", RULES["hold-one-prefill"]), ("spacing-1.7s", hold_spacing(1.7e9))):
                out = [r for r in simulate(reqs, coef, rule, fwd, deliver, long_prefill=384, step_scale=scale)
                       if r["tenant"] == pr.CONTENDER and "first_token" in r]
                dur = sorted((r["first_token"] - r["engaged"]) / 1e6 for r in out)
                events = sorted([(r["engaged"], 1) for r in out] + [(r["first_token"], -1) for r in out])
                cur = most = 0
                overlap, last = 0, None
                for t, k in events:
                    if last is not None and cur >= 2:
                        overlap += t - last
                    cur += k
                    most = max(most, cur)
                    last = t
                print("%.1f %s | prefill p50 %.0f p95 %.0f ms | at most %d in prefill at once | share of the span with two or more %.2f" % (
                    scale, name, pr.nearest_rank(dur, 0.5), pr.nearest_rank(dur, 0.95), most, overlap / (events[-1][0] - events[0][0])))
        return 0
    if argv[1] == "frontier":
        # The registered decision, not the widest spacing alone: every grid arm is judged, and hold-cap must beat every
        # admissible one (v26 review, finding 6). Each archived off cell stands in for a block; these are six old
        # traces, not the three new seeds, and the scorer's validity, preemption, work and gap lines are not modelled.
        arms = [("hold-cap", RULES["hold-one-prefill"])] + [("fixed-%.2f" % (t / 1000), hold_spacing(t * 1_000_000)) for t in V26_GRID_MS]
        admissible, pooled = {a: True for a, _ in arms}, {a: [] for a, _ in arms}
        print("step scale %.4f" % scale)
        print("cell arm | premium p99 ratio_to_off | owner's limits")
        for (d, arm, rep), (reqs, _, _) in sorted(loaded.items()):
            if arm != "off":
                continue
            off = summarize(simulate(reqs, coef, RULES["off"], fwd, deliver, step_scale=scale))
            for name, rule in arms:
                out = simulate(reqs, coef, rule, fwd, deliver, long_prefill=384, step_scale=scale)
                pooled[name].extend(out)
                x = summarize(out)
                fail = owner_limits(x, off)
                admissible[name] = admissible[name] and fail is None
                print("%s-off-%d %s | %.3f | %s" % (os.path.basename(os.path.dirname(d))[-6:], rep, name,
                                                   x["premium_p99_ms"] / off["premium_p99_ms"], "met" if fail is None else "fails: " + fail))
        p99 = {a: summarize(pooled[a])["premium_p99_ms"] for a, _ in arms}
        print("\npooled premium p99 ms: " + ", ".join("%s %.0f%s" % (a, p99[a], "" if admissible[a] else " (inadmissible)") for a, _ in arms))
        print("verdict: " + frontier_verdict(admissible, p99))
        return 0
    if argv[1] == "feasible":
        # The control's spacing is a free parameter; the owner's limits are what make one choice admissible. Every
        # spacing from 1.50 to 1.80 s in 10 ms steps, judged by them, beside hold-cap judged the same way.
        print("step scale %.4f" % scale)
        print("cell rule | premium p99 ratio_to_off | contender completion p50 ratio_to_off, p95 ms, hold refusals | owner's limits")
        spacings = list(range(1500, 1801, 10))
        admissible, pooled = set(spacings), {}
        for (d, arm, rep), (reqs, _, _) in sorted(loaded.items()):
            if arm != "off":
                continue
            base = simulate(reqs, coef, RULES["off"], fwd, deliver, step_scale=scale)
            off = summarize(base)
            pooled.setdefault("off", []).append(base)
            rules = [("hold-cap", RULES["hold-one-prefill"], None)] + [
                ("spacing-%.2fs" % (t / 1000), hold_spacing(t * 1_000_000), t) for t in spacings]
            for name, rule, t in rules:
                out = simulate(reqs, coef, rule, fwd, deliver, long_prefill=384, step_scale=scale)
                pooled.setdefault(name, []).append(out)
                x = summarize(out)
                fail = owner_limits(x, off)
                if fail is not None and t is not None:
                    admissible.discard(t)
                print("%s-off-%d %s | %.3f | %.2f %s %d | %s" % (
                    os.path.basename(os.path.dirname(d))[-6:], rep, name, x["premium_p99_ms"] / off["premium_p99_ms"],
                    x["contender_completion_p50_ms"] / off["contender_completion_p50_ms"],
                    "inf" if math.isinf(x["contender_completion_p95_ms"]) else round(x["contender_completion_p95_ms"]),
                    x["contender_hold_timeouts"], "met" if fail is None else "fails: " + fail))
        # The registered rule picks the widest spacing meeting the limits in every cell; the endpoint pools every
        # premium request of the arm across cells, as the main study pools its blocks (v26).
        if not admissible:
            print("\nno spacing meets the owner's limits in every cell")
            return 0
        widest = "spacing-%.2fs" % (max(admissible) / 1000)
        p99 = {n: summarize([r for out in pooled[n] for r in out])["premium_p99_ms"] for n in ("off", "hold-cap", widest)}
        print("\nwidest admissible: %s | pooled premium p99 ms: off %.0f, hold-cap %.0f, %s %.0f | hold-cap over it %.3f" % (
            widest, p99["off"], p99["hold-cap"], widest, p99[widest], p99["hold-cap"] / p99[widest]))
        return 0
    if argv[1] == "control":
        # hold-cap against the static control, fixed spacing with the same 384 cap, at several spacings, with the whole
        # trade, on every off cell: does the first-token signal buy anything over fixed pacing?
        print("cell rule | premium p99 ratio_to_off | contenders completed/offered expired refused | completion p50 p95 ms | hold max ms")
        for (d, arm, rep), (reqs, _, _) in sorted(loaded.items()):
            if arm != "off":
                continue
            base = summarize(simulate(reqs, coef, RULES["off"], fwd, deliver))["premium_p99_ms"]
            rules = [("hold-cap", RULES["hold-one-prefill"])] + [("spacing-%.1fs" % (t / 1e9), hold_spacing(t))
                                                                 for t in (1.0e9, 1.5e9, 1.6e9, 1.7e9, 1.8e9, 1.9e9, 2.0e9, 2.5e9, 3.0e9)]
            for name, rule in rules:
                x = summarize(simulate(reqs, coef, rule, fwd, deliver, long_prefill=384))
                f = lambda v: "inf" if v is None or (isinstance(v, float) and math.isinf(v)) else str(round(v))
                print("%s-off-%d %s | %s %.3f | %d/%d %d %d | %s %s | %s" % (
                    os.path.basename(os.path.dirname(d))[-6:], rep, name, f(x["premium_p99_ms"]), x["premium_p99_ms"] / base,
                    x["contender_completed"], x["contender_offered"], x["contender_expired"], x["contender_refused"],
                    f(x["contender_completion_p50_ms"]), f(x["contender_completion_p95_ms"]), f(x["contender_hold_max_ms"])))
        # A spacing tuned at the fitted step times is then run 10% faster and slower, as a card or a later block may be:
        # feedback follows the engine's pace, a fixed spacing does not, and this is where the two should part.
        print("\ndrift: scale cell rule | premium p99 ratio_to_off at that scale | contenders completed/offered refused | completion p50 p95 ms")
        for scale in (0.9, 1.1):
            for (d, arm, rep), (reqs, _, _) in sorted(loaded.items()):
                if arm != "off":
                    continue
                base = summarize(simulate(reqs, coef, RULES["off"], fwd, deliver, step_scale=scale))["premium_p99_ms"]
                for name, rule in (("hold-cap", RULES["hold-one-prefill"]), ("spacing-1.7s", hold_spacing(1.7e9))):
                    x = summarize(simulate(reqs, coef, rule, fwd, deliver, long_prefill=384, step_scale=scale))
                    f = lambda v: "inf" if v is None or (isinstance(v, float) and math.isinf(v)) else str(round(v))
                    print("%.1f %s-off-%d %s | %.3f | %d/%d %d | %s %s" % (
                        scale, os.path.basename(os.path.dirname(d))[-6:], rep, name, x["premium_p99_ms"] / base,
                        x["contender_completed"], x["contender_offered"], x["contender_refused"],
                        f(x["contender_completion_p50_ms"]), f(x["contender_completion_p95_ms"])))
        return 0
    if argv[1] == "combine":
        # The engine's threshold together with the gateway rules, at the fitted step times and 10% slower, with the
        # whole trade: the contender's completions, expiries, refusals, completion latency and hold (v23 review).
        print("cell rule threshold scale | premium p99 ratio_to_off | contenders completed/offered expired refused | "
              "completion p50 p95 ms | hold p50 max ms | finished after last premium")
        for (d, arm, rep), (reqs, _, _) in sorted(loaded.items()):
            if arm != "off":
                continue
            for scale in (1.0, 1.1):
                base = summarize(simulate(reqs, coef, RULES["off"], fwd, deliver, step_scale=scale))["premium_p99_ms"]
                for rule, t in (("off", 0), ("off", 384), ("hold-one-prefill", 0), ("hold-one-prefill", 384),
                                ("hold-one-prefill", 256), ("refuse-one-prefill", 256)):
                    x = summarize(simulate(reqs, coef, RULES[rule], fwd, deliver, long_prefill=t, step_scale=scale))
                    f = lambda v: "inf" if v is None or (isinstance(v, float) and math.isinf(v)) else str(round(v))
                    print("%s-off-%d %s %d %.1f | %s %.3f | %d/%d %d %d hold-timeouts %d | %s %s | %s %s | %d" % (
                        os.path.basename(os.path.dirname(d))[-6:], rep, rule, t, scale, f(x["premium_p99_ms"]),
                        x["premium_p99_ms"] / base, x["contender_completed"], x["contender_offered"], x["contender_expired"],
                        x["contender_refused"], x["contender_hold_timeouts"], f(x["contender_completion_p50_ms"]), f(x["contender_completion_p95_ms"]),
                        f(x["contender_hold_p50_ms"]), f(x["contender_hold_max_ms"]), x["contender_finished_after_last_premium"]))
        return 0
    if argv[1] == "threshold":
        # The engine-side setting, with no admission rule: every contender forwarded, as off.
        for (d, arm, rep), (reqs, _, _) in sorted(loaded.items()):
            if arm != "off":
                continue
            base = summarize(simulate(reqs, coef, RULES["off"], fwd, deliver))
            for t in (0, 384, 256, 128, 64):
                s_ = summarize(simulate(reqs, coef, RULES["off"], fwd, deliver, long_prefill=t))
                cont = sorted((r["first_token"] - r["sched"]) / 1e6 for r in simulate(reqs, coef, RULES["off"], fwd, deliver, long_prefill=t) if r["tenant"] == pr.CONTENDER and "first_token" in r)
                print("%s off-%d threshold %3d  premium p99 %7.1f (%.3f of off)  p50 %6.1f  contenders %d/%d  contender TTFT p50 %7.1f" % (
                    os.path.basename(os.path.dirname(d)), rep, t, s_["premium_p99_ms"], s_["premium_p99_ms"] / base["premium_p99_ms"],
                    s_["premium_p50_ms"], s_["contender_completed"], s_["contender_offered"], pr.nearest_rank(cont, 0.5)))
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
