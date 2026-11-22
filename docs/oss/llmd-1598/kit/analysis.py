"""The rules that turn a cell's raw records into numbers, for the llm-d-router #1598 pilot.

Every rule here is one the design registers (docs/superpowers/specs/2026-11-21-llmd-1598-real-gpu-ab-design.md).
They are pure functions over plain dicts so the offline tests can feed them faults and see each one caught.
A row is one request as the sender saw it; see sender.py for its fields.
"""

import math

INF = float("inf")
ROUTER_BLOCK = 64


def completed(row):
    """A request counts as completed only with a 200, a terminal [DONE], a usage record and every requested token."""
    u = row.get("usage")
    return (row.get("status") == 200 and row.get("done") is True and isinstance(u, dict)
            and u.get("completion_tokens") == row.get("max_tokens"))


def ttft(row):
    """Seconds from the scheduled send to the first token's event; a request that did not complete is infinite.

    The first non-empty text event marks the first token, except when a completed request's tokens all decoded to no text
    (a partial UTF-8 sequence), where the first event carrying a choice does.
    A request that failed after its first token is a failure too, so its TTFT is infinite, as the design registers.
    """
    if not completed(row):
        return INF
    t = row.get("first_text_t")
    if t is None:
        t = row.get("first_token_t")
    if t is None:
        return INF
    return t - row["sched_abs"]


def client_tpot(row):
    """Client TPOT over usage tokens; undefined below two output tokens, where the denominator is zero."""
    u = row.get("usage") or {}
    n = u.get("completion_tokens")
    if not completed(row) or n is None or n < 2 or row.get("last_text_t") is None:
        return None
    return (row["last_text_t"] - row["first_text_t"]) / (n - 1)


def nearest_rank(values, p):
    """Nearest-rank percentile; infinities sort last, so a failed request can make the percentile infinite."""
    if not values:
        return None
    v = sorted(values)
    k = max(1, math.ceil(p / 100.0 * len(v)))
    return v[k - 1]


def ratio_outcome(cand, base, threshold):
    """Compare a candidate percentile with a baseline against `cand <= threshold * base`, with the registered infinite cases.

    Both infinite shows no difference, a finite candidate against an infinite baseline is a categorical improvement whose
    percentage is undefined, and the reverse a categorical regression.
    """
    if cand is None or base is None:
        return "empty"
    if math.isinf(cand) and math.isinf(base):
        return "both_infinite"
    if math.isinf(base):
        return "categorical_improvement"
    if math.isinf(cand):
        return "categorical_regression"
    if base == 0:
        return "meets" if cand == 0 else "fails"
    return "meets" if cand <= threshold * base else "fails"


def two_of_three(outcomes, good):
    """The descriptive 2-of-3 rule; with a seed missing, the remaining two decide only if they agree."""
    present = [o for o in outcomes if o is not None]
    if len(present) == 3:
        return "yes" if sum(o in good for o in present) >= 2 else "no"
    if len(present) == 2:
        a, b = (o in good for o in present)
        return ("yes (two runs)" if a else "no (two runs)") if a == b else "inconclusive"
    return "inconclusive"


def slo_from_cold(cold_ttfts_s):
    """SLO = 3 x the p50 cold TTFT, rounded up to the next 10 ms, in seconds."""
    p50 = nearest_rank(cold_ttfts_s, 50)
    if p50 is None or math.isinf(p50):
        return None
    ms = math.ceil(round(3 * p50 * 1000, 6) / 10.0) * 10
    return ms / 1000.0


def passes_slo(rows, slo):
    """The ramp's pass rule: at least 95% of offered requests completed within the SLO, and every one completed."""
    if not rows:
        return False
    ok = sum(1 for r in rows if completed(r) and ttft(r) <= slo)
    return ok >= 0.95 * len(rows) and all(completed(r) for r in rows)


def bracket(results):
    """r from a ramp of (rate, passed): the highest passing rate below a failing one, or a censored bound.

    Returns (rate, kind) with kind 'bracketed', 'at_least' (nothing failed) or 'below' (nothing passed).
    """
    results = sorted(results)
    if not results:
        return None, "empty"
    passed = [r for r, ok in results if ok]
    failed = [r for r, ok in results if not ok]
    if not passed:
        return min(failed), "below"
    if not failed:
        return max(passed), "at_least"
    first_fail = min(failed)
    below = [r for r in passed if r < first_fail]
    if not below:
        return first_fail, "below"
    return max(below), "bracketed"


def ledger(rows, deltas):
    """Reconcile what the client saw on each engine with that engine's own counter deltas.

    `rows` are every population routed in the cell (evaluation, warm-up, preloads, calibration) with their `endpoint`.
    `deltas` maps endpoint -> {prompt, generation, cached, success}.
    With no failed or cut-off request on an engine the identity must be exact; otherwise the engine must show at least the
    completed rows' sums, and the excess is recorded as work for requests that did not complete.
    """
    out, ok = {}, True
    eps = set(deltas) | {r["endpoint"] for r in rows if r.get("endpoint")}
    for ep in sorted(eps):
        mine = [r for r in rows if r.get("endpoint") == ep]
        done = [r for r in mine if completed(r)]
        sums = dict(prompt=sum(r["usage"]["prompt_tokens"] for r in done),
                    generation=sum(r["usage"]["completion_tokens"] for r in done),
                    cached=sum(r["usage"]["cached_tokens"] for r in done),
                    success=len(done))
        d = deltas.get(ep)
        if d is None:
            out[ep] = {"ok": False, "why": "no counter delta for an engine that served rows"}
            ok = False
            continue
        exact = len(done) == len(mine)
        if exact:
            good = all(d[k] == sums[k] for k in sums)
        else:
            good = all(d[k] >= sums[k] for k in sums)
        out[ep] = {"ok": good, "exact": exact, "client": sums, "engine": dict(d),
                   "excess": {k: d[k] - sums[k] for k in sums}, "incomplete_rows": len(mine) - len(done)}
        ok = ok and good
    return ok, out


STAGES = ("offered", "dispatched", "received", "scheduled", "forwarded", "completed")


def stage(row, envoy, epp):
    """The last lifecycle stage a request reached, from the sender's row, Envoy's log and the EPP's decision."""
    rid = row["rid"]
    if completed(row):
        return "completed"
    if row.get("endpoint"):
        return "forwarded"
    if rid in epp:
        return "scheduled"
    if rid in envoy:
        return "received"
    if row.get("sent_abs") is not None:
        return "dispatched"
    return "offered"


def unexplained(row, envoy, epp, epp_logged):
    """Evidence a request's own stage requires and that is missing; an empty list means the row is explained.

    A request rejected before scheduling has no decision, legitimately; only a forwarded request must have one, and
    only when the EPP logged decisions at all.
    """
    st = stage(row, envoy, epp)
    missing = []
    if STAGES.index(st) >= STAGES.index("forwarded"):
        if row["rid"] not in envoy:
            missing.append("envoy")
        if epp_logged and row["rid"] not in epp:
            missing.append("epp")
    if st == "dispatched" and row.get("error") is None:
        missing.append("terminal outcome")
    return missing


def join_valid(rows, envoy, epp, epp_logged, limit=0.005):
    bad = [r["rid"] for r in rows if unexplained(r, envoy, epp, epp_logged)]
    return len(bad) <= limit * max(1, len(rows)), bad


def is_eval(r):
    return r.get("population") == "eval"


def recover_endpoints(rows, envoy):
    """Fill in the upstream from Envoy's access record for a request that reached an engine but ended before its response
    headers, so the ledger counts it as that engine's incomplete request rather than as no request at all."""
    for r in rows:
        up = (envoy.get(r["rid"]) or {}).get("upstream")
        if not r.get("endpoint") and up and up != "-":
            r["endpoint"] = up
            r["endpoint_from"] = "envoy"
    return rows


def envoy_first_byte_t(rec):
    """When the upstream's first response byte reached Envoy: its forward time plus the upstream TTFB, or None."""
    f = envoy_forward_t(rec)
    try:
        return None if f is None else f + float(rec["ttfb_us"]) / 1e6
    except (KeyError, TypeError, ValueError):
        return None


def preload_visible_until(p, envoy):
    """The last moment a preload can be relied on as in-flight load: the earlier of Envoy's upstream first byte and the
    client's first event, whichever are recorded."""
    ts = [t for t in (envoy_first_byte_t(envoy.get(p["rid"]) or {}), p.get("first_event_t")) if t is not None]
    return min(ts) if ts else None


def envoy_forward_t(rec):
    """When Envoy sent a request upstream: its start plus the downstream-receive-to-upstream-send duration, or None."""
    try:
        return float(rec["start"]) + float(rec["route_us"]) / 1e6
    except (KeyError, TypeError, ValueError):
        return None


def credit(rows, epp_match, decision_t=None, measured=is_eval):
    """Classify router credit on the chosen endpoint against what the engine served from cache.

    `epp_match` maps rid -> {endpoint: matched 64-token router blocks}; `decision_t` maps rid -> the EPP's pick time.
    A credit is in-flight when the endpoint's earliest earlier request with that prefix had not produced its first token
    when this one was scheduled, since the approximate producer inserts its entries optimistically at PreRequest; otherwise
    it is a completed credit.
    Every routed row is prefix history (warm-up included), and only rows `measured` accepts are classified.
    """
    decision_t = decision_t or {}

    def when(r):
        return decision_t.get(r["rid"], r["sent_abs"])

    order = sorted((r for r in rows if r.get("endpoint") and r.get("sent_abs") is not None), key=when)
    res = {"credited": 0, "in_flight": 0, "completed": 0, "completed_no_reuse": 0, "rows": []}
    for r in order:
        blocks = (epp_match.get(r["rid"]) or {}).get(r["endpoint"], 0)
        if blocks < 1 or not completed(r) or not measured(r):
            continue
        res["credited"] += 1
        earlier = [e for e in order if e is not r and e.get("endpoint") == r["endpoint"]
                   and e.get("prefix") is not None and e.get("prefix") == r.get("prefix") and when(e) < when(r)]
        first = earlier[0] if earlier else None
        settled = first is not None and first.get("first_text_t") is not None and first["first_text_t"] <= when(r)
        kind = "completed" if settled else "in_flight"
        res[kind] += 1
        cached = r["usage"]["cached_tokens"]
        if kind == "completed" and cached == 0:
            res["completed_no_reuse"] += 1
        res["rows"].append({"rid": r["rid"], "endpoint": r["endpoint"], "router_tokens": blocks * ROUTER_BLOCK,
                            "cached_tokens": cached, "kind": kind})
    res["no_reuse_share"] = (res["completed_no_reuse"] / res["completed"]) if res["completed"] else None
    return res


def reuse(rows, measured=is_eval):
    """Separate first fills from lost reuse: a request whose prefix had already been served on its engine, by a request
    whose first token arrived before this one was sent, and which still got no cached tokens.
    Every completed row is prefix history (warm-up included); only rows `measured` accepts are counted."""
    order = sorted((r for r in rows if completed(r) and r.get("prefix") is not None), key=lambda r: r["sent_abs"])
    fills = lost = n = 0
    for r in order:
        if not measured(r):
            continue
        n += 1
        prior = [e for e in order if e is not r and e["endpoint"] == r["endpoint"] and e["prefix"] == r["prefix"]
                 and e.get("first_text_t") is not None and e["first_text_t"] <= r["sent_abs"]]
        if not prior:
            fills += 1
        elif r["usage"]["cached_tokens"] == 0:
            lost += 1
    return {"measured": n, "first_fills": fills, "lost_reuse": lost, "lost_share": (lost / n) if n else None}


def reused_fraction(rows):
    done = [r for r in rows if completed(r)]
    p = sum(r["usage"]["prompt_tokens"] for r in done)
    return (sum(r["usage"]["cached_tokens"] for r in done) / p) if p else None


def largest_share(rows):
    counts = {}
    for r in rows:
        if r.get("endpoint"):
            counts[r["endpoint"]] = counts.get(r["endpoint"], 0) + 1
    return max(counts.values()) if counts else 0, counts


def burst_valid(burst_rows, preload_rows, epp_picked, epp_prereq, envoy, max_span=None, with_preloads=True):
    """K's burst is valid only if the scorer saw all three engines loaded for the whole burst: the three preloads went to
    three distinct engines, all three were registered (PreRequest) before any burst request left the client, and every
    burst request was decided before any preload stopped counting as load.
    The EPP frees a preload's in-flight tokens on its response, which reaches Envoy before the client, so the bound is the
    earlier of Envoy's upstream first byte and the client's first event; the client's alone was not conservative.
    K-equal sends no preloads (`with_preloads` False), so only the release conditions below apply to it; the first version
    held it to the preload conditions too, which no K-equal burst could ever meet.

    At -v=5 the EPP's PreRequest and pick times are used.
    Without them each is bounded from Envoy's record (the upstream send follows PreRequest and the pick), which can only
    make the check stricter: a preload's forward time is no earlier than its registration, and a burst request's forward
    time is no earlier than its decision.
    A burst with any time missing is invalid, never assumed valid.
    """
    if with_preloads:
        eps = [p.get("endpoint") for p in preload_rows]
        if len(preload_rows) != 3 or None in eps or len(set(eps)) != 3:
            return False, "preloads not on three distinct engines", None
        firsts = [preload_visible_until(p, envoy) for p in preload_rows]
        if any(f is None for f in firsts):
            return False, "a preload produced no event", None
    elif preload_rows:
        return False, "a burst registered with no preloads has preload rows", None
    rids = [r["rid"] for r in burst_rows + preload_rows]
    basis = "epp" if all(x in epp_picked for x in rids) and all(p["rid"] in epp_prereq for p in preload_rows) else "envoy"
    if basis == "epp":
        registered = [epp_prereq[p["rid"]] for p in preload_rows]
        decided = [epp_picked[r["rid"]] for r in burst_rows]
    else:
        registered = [envoy_forward_t(envoy.get(p["rid"]) or {}) for p in preload_rows]
        decided = [envoy_forward_t(envoy.get(r["rid"]) or {}) for r in burst_rows]
    sends = [r.get("sent_abs") for r in burst_rows]
    if not burst_rows or None in registered or None in decided or None in sends:
        return False, "a registration, decision or send time is missing", basis
    if with_preloads:
        if max(registered) >= min(sends):
            return False, "a preload was registered after the burst began", basis
        if max(decided) >= min(firsts):
            return False, "a burst request was decided after a preload's first response byte", basis
    # A request is primed to its last byte before the release, so a decision before that byte left the client means the
    # router picked on a partial body, and the release did not hold the burst back.
    if any(d < r.get("send_begin_abs", r["sent_abs"]) for d, r in zip(decided, burst_rows)):
        return False, "a burst request was decided before its release", basis
    if max_span is not None and max(sends) - min(sends) > max_span:
        return False, "the release was spread over more than the registered span", basis
    return True, "ok", basis


def early_decisions(burst_rows, epp_picked, envoy):
    """How many of a primed burst's requests were decided (EPP pick, else Envoy's forward) before their last byte's write
    began, or have no decision or send time at all; anything but zero means the priming did not hold the burst back.
    The write's start, not its end, is the bound: Envoy can forward during the write, before the client reads its clock."""
    n = 0
    for r in burst_rows:
        d = epp_picked.get(r["rid"]) if r["rid"] in epp_picked else envoy_forward_t(envoy.get(r["rid"]) or {})
        if d is None or r.get("sent_abs") is None or d < r.get("send_begin_abs", r["sent_abs"]):
            n += 1
    return n


def release_ok(spans, early, limit, share=0.9):
    """The primed release worked: no request decided before its release in any burst, and at least `share` of the bursts
    went out within `limit` (None: a staggered cell, spread by design).
    One slow burst is an invalid burst, as the design treats any unmet burst condition; most of them failing is the
    apparatus not doing what it says."""
    if not spans or any(e for e in early):
        return False
    if limit is None:
        return True
    return sum(1 for x in spans if x is not None and x <= limit) >= share * len(spans)


def fluid_reference(n_preloads, preload_tokens, burst, prompt_tokens, engines=4):
    """The static fluid-allocation reference: the idle engine's share of a burst if the burst's tokens were poured until
    every engine held the same in-flight tokens (21.51 of 64 with K's three 4,000-token preloads, 16 with none).

    It is descriptive only.
    A discrete race-free allocator gives a different number (sequential_reference below gives 22), completions during a
    burst change the load it assumes, and neither agreement with it nor excess over it shows whether picks saw each other.
    """
    total = n_preloads * preload_tokens + burst * prompt_tokens
    share = total / engines / prompt_tokens
    return min(float(burst), max(burst / engines, share))


def sequential_reference(n_preloads, preload_tokens, burst, prompt_tokens, engines=4):
    """Request counts per engine from a sequential least-in-flight-tokens allocator with no completions, idle engine first:
    the discrete counterpart of fluid_reference, reported beside it ([22, 14, 14, 14] for K)."""
    load = [0] + [preload_tokens] * n_preloads + [0] * (engines - 1 - n_preloads)
    counts = [0] * engines
    for _ in range(burst):
        i = min(range(engines), key=lambda k: (load[k], k))
        load[i] += prompt_tokens
        counts[i] += 1
    return counts


# Burst invalidity reasons that say the apparatus did not do what it says, the same whichever router ran; any other
# reason (preload placement, timing the router produced, failed requests) is the arm's own outcome and counts against it.
APPARATUS_REASONS = ("the release was spread over more than the registered span",
                     "a burst request was decided before its release",
                     "a registration, decision or send time is missing")
# The registered minimum share of a seed's bursts usable in both arms of a paired K comparison (9 of 12).
MIN_PAIRED_COVERAGE = 0.75
# K's burst performance guardrail: the candidate's burst TTFT p95 and median burst makespan at most this times the baseline's.
K_GUARDRAIL = 1.10


def paired_bursts(base, cand, min_coverage=MIN_PAIRED_COVERAGE):
    """C2 on identical burst IDs: `base` and `cand` map burst id -> {"valid", "why", "largest", "completed"}.

    A burst excluded for an apparatus reason in either arm leaves both; a burst invalid for any other reason, or with a
    failed request, stays in as a failure of the arm it happened in.
    The registered C2 ratio (candidate mean largest share <= 0.75 x baseline's) is read only over bursts valid in both.
    """
    ids = sorted(set(base) | set(cand))
    excluded, both, failures = [], [], {"base": 0, "cand": 0}
    for b in ids:
        x, y = base.get(b), cand.get(b)
        if x is None or y is None:
            excluded.append((b, "missing in one arm"))
            continue
        why = [w for w in (x["why"], y["why"]) if w in APPARATUS_REASONS]
        if why:
            excluded.append((b, why[0]))
            continue
        bad = False
        for arm, z in (("base", x), ("cand", y)):
            if not z["valid"] or not z.get("completed", True):
                failures[arm] += 1
                bad = True
        if not bad:
            both.append(b)
    usable = len(ids) - len(excluded)
    coverage = usable / len(ids) if ids else 0.0
    res = {"bursts": len(ids), "excluded": excluded, "treatment_failures": failures, "paired_valid": both,
           "coverage": coverage, "covered": coverage >= min_coverage}
    if both and res["covered"]:
        mb = sum(base[b]["largest"] for b in both) / len(both)
        mc = sum(cand[b]["largest"] for b in both) / len(both)
        res.update(base_mean=mb, cand_mean=mc, contrast=mc - mb,
                   c2=("meets" if mc <= 0.75 * mb else "fails") if failures["cand"] <= failures["base"] else "fails")
    else:
        res["c2"] = "unavailable"
    return res


def burst_perf(burst_rows):
    """One burst's service: TTFTs (infinite for a failed request) and makespan, release to the last response's end, which
    includes whatever the router spent per request, a reservation included."""
    tt = [ttft(r) for r in burst_rows]
    starts = [r.get("send_begin_abs", r.get("sent_abs")) for r in burst_rows]
    ends = [r.get("end_abs") for r in burst_rows]
    if None in starts or None in ends or not burst_rows or not all(completed(r) for r in burst_rows):
        return {"ttft": tt, "makespan": INF}
    return {"ttft": tt, "makespan": max(ends) - min(starts)}


def k_guardrail(base_perf, cand_perf, limit=K_GUARDRAIL):
    """Whether the candidate served the paired bursts no worse than `limit` x the baseline: pooled burst TTFT p95 and the
    median burst makespan; it must hold before a smaller largest share is read as spreading the burst better."""
    if not base_perf or not cand_perf:
        return {"holds": False, "why": "no paired bursts"}
    tb = nearest_rank([t for p in base_perf for t in p["ttft"]], 95)
    tc = nearest_rank([t for p in cand_perf for t in p["ttft"]], 95)
    mb = sorted(p["makespan"] for p in base_perf)[(len(base_perf) - 1) // 2]
    mc = sorted(p["makespan"] for p in cand_perf)[(len(cand_perf) - 1) // 2]
    ok_t = ratio_outcome(tc, tb, limit) in ("meets", "categorical_improvement")
    ok_m = ratio_outcome(mc, mb, limit) in ("meets", "categorical_improvement")
    return {"holds": ok_t and ok_m, "ttft_p95": [tb, tc], "makespan_median": [mb, mc]}


# K-stagger's feasibility rules, frozen before the second pilot: a burst's release gaps are acceptable when the smallest
# is at least half the spacing and the median within 10% of it; the probe is usable in the main run only if at least 90% of
# its bursts have acceptable gaps, at least 75% are valid, and at least 95% of consecutive requests had the predecessor
# forwarded by Envoy before the next one's last byte was written.
STAGGER_GAP_SHARE, STAGGER_VALID_SHARE, STAGGER_PREDECESSOR_SHARE = 0.9, 0.75, 0.95


def stagger_gaps_ok(burst_rows, stagger):
    starts = sorted(r.get("send_begin_abs", r.get("sent_abs")) for r in burst_rows if r.get("sent_abs") is not None)
    if len(starts) != len(burst_rows) or len(starts) < 2:
        return False
    gaps = sorted(b - a for a, b in zip(starts, starts[1:]))
    med = gaps[(len(gaps) - 1) // 2]
    return gaps[0] >= 0.5 * stagger and 0.9 * stagger <= med <= 1.1 * stagger


def predecessor_forwarded(burst_rows, envoy):
    """Consecutive pairs (by release) in which the earlier request was forwarded by Envoy before the later one's last byte
    began to be written, and how many pairs there were."""
    order = sorted(burst_rows, key=lambda r: r.get("send_begin_abs", r.get("sent_abs") or INF))
    ok = 0
    for a, b in zip(order, order[1:]):
        f = envoy_forward_t(envoy.get(a["rid"]) or {})
        t = b.get("send_begin_abs", b.get("sent_abs"))
        if f is not None and t is not None and f < t:
            ok += 1
    return ok, max(0, len(order) - 1)


def stagger_usable(gaps_ok, valid, pred_ok, pred_pairs):
    """K-stagger's frozen feasibility rule over a cell's bursts; usable means it can run as a dynamic spacing intervention,
    not that it measures a race."""
    n = len(gaps_ok)
    if not n or not pred_pairs:
        return False
    return (sum(gaps_ok) >= STAGGER_GAP_SHARE * n and sum(valid) >= STAGGER_VALID_SHARE * n
            and pred_ok >= STAGGER_PREDECESSOR_SHARE * pred_pairs)


def percentile_ci(values, p=99, conf=0.95):
    """A nearest-rank percentile, its row count and rank, how many rows lie above it, and an iid-reference interval.

    The interval is the pair of order statistics [x_(l), x_(u)] with P(l <= B <= u - 1) >= conf for B ~ Binomial(n, p/100).
    It would be a 95% interval only if the rows were independent draws, and requests in one cell are not: in the pilot,
    14 of the 18 rows at or above A1's p99 fell in the same second.
    So it is labelled an iid reference and is never read as the precision of a p99; the seeds are the independent unit.
    """
    v = sorted(values)
    n = len(v)
    if n == 0:
        return None
    q = p / 100.0
    k = max(1, math.ceil(q * n))
    # Binomial(n, q) cumulative probabilities from log-space terms, exact enough for n in the tens of thousands.
    logs = [math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1)
            + (i * math.log(q) if i else 0.0) + ((n - i) * math.log1p(-q) if n - i else 0.0) for i in range(n + 1)]
    cdf, acc = [], 0.0
    for lg in logs:
        acc += math.exp(lg)
        cdf.append(acc)
    alpha = (1 - conf) / 2
    # l: the largest rank with P(B <= l - 1) <= alpha; u: the smallest rank with P(B <= u - 1) >= 1 - alpha.
    lo = max((r for r in range(1, n + 1) if cdf[r - 1] <= alpha), default=None)
    up = next((r for r in range(1, n + 1) if cdf[r - 1] >= 1 - alpha), None)
    return {"value": v[k - 1], "n": n, "rank": k, "beyond": n - k,
            "iid_reference_interval": [v[lo - 1] if lo else None, v[up - 1] if up else None]}


def grid_anchor(ramps):
    """The rate the main grid is scaled from: the lowest knee among the arms ramped, so the grid holds the baseline's knee.

    `ramps` maps an arm to (r, kind) from bracket().
    The pilot's A3-only rule would have put A at 0.6 to 1.5 x A3's knee, while A1 put both of A's prefixes on two of the
    four engines and was at its own knee at 72/s; every grid rate would then have been past A1's and A2's knees, C3 would
    have compared two overloaded arms, and C4 would have been censored below for both.
    A censored arm decides only when the order is still known: an arm that passed everything up to at least the other's
    bracketed knee cannot hold the minimum, and an arm that failed its lowest rate, or two censored arms, give no anchor.
    """
    if not ramps:
        return None, "no ramp"
    brk = {a: r for a, (r, kind) in ramps.items() if kind == "bracketed"}
    if not brk:
        return None, "no arm's knee was bracketed"
    low = min(brk.values())
    for a, (r, kind) in ramps.items():
        if kind == "at_least" and r < low:
            return None, f"{a} passed only up to {r}, below the lowest bracketed knee {low}"
        if kind not in ("bracketed", "at_least"):
            return None, f"{a}: {kind}, so its knee is below every rate it ran"
    return low, "ok"


def balanced_replays(spare_by_seed, units):
    """W942's descriptive replays, frozen before the main run: `units` in priority order, each (label, {seed: seconds}) for
    one more A1 and A2 trace at one rate; a unit is taken only if every seed's session still has the time for it, so every
    seed and both arms always hold the same replay set, and the first unit that does not fit everywhere ends the plan.
    Replays repeat one trace: they are reported per seed and per replay, never as independent samples."""
    left, plan = dict(spare_by_seed), []
    for label, cost in units:
        if set(cost) != set(left) or any(left[k] < cost[k] for k in left):
            break
        for k in left:
            left[k] -= cost[k]
        plan.append(label)
    return plan


GRID = (0.6, 0.9, 1.2, 1.5)


def grid_rates(anchor):
    return [round(m * anchor, 2) for m in GRID]


def imbalance(samples, engines):
    """Mean over 1 s windows of the coefficient of variation of outstanding requests (running + waiting) across engines."""
    by_win = {}
    for s in samples:
        w = int(s["t"])
        by_win.setdefault(w, {}).setdefault(s["engine"], []).append(s["running"] + s["waiting"])
    cvs = []
    for w, per in sorted(by_win.items()):
        if set(per) != set(engines):
            continue
        means = [sum(v) / len(v) for v in (per[e] for e in engines)]
        m = sum(means) / len(means)
        if m == 0:
            continue
        sd = math.sqrt(sum((x - m) ** 2 for x in means) / len(means))
        cvs.append(sd / m)
    return (sum(cvs) / len(cvs)) if cvs else None, len(cvs)


def hist_quantile(prom_text, name_suffix, q):
    """Quantile of a Prometheus histogram as the upper bound of the first bucket holding q of the count.

    The EPP's scheduler histogram has coarse buckets (0.5, 1, 2, 5 ms ...), so this is a bound, not an interpolation.
    """
    buckets = []
    for ln in prom_text.splitlines():
        if ln.startswith("#") or "_bucket{" not in ln:
            continue
        name = ln.split("{", 1)[0]
        if not name.endswith(name_suffix + "_bucket"):
            continue
        le = ln.split('le="', 1)[1].split('"', 1)[0]
        buckets.append((INF if le == "+Inf" else float(le), float(ln.rsplit(" ", 1)[1])))
    if not buckets:
        return None
    buckets.sort()
    total = buckets[-1][1]
    if total == 0:
        return None
    for le, cum in buckets:
        if cum >= q * total:
            return le
    return INF


def sampler_ok(samples, engines, start, end, rate_hz=4.0):
    """The 4 Hz sampler held its rate for every engine (at least 3.5 a second on average, no gap over 1 s)."""
    if end <= start:
        return False, "empty window"
    for e in engines:
        ts = sorted(s["t"] for s in samples if s["engine"] == e and start <= s["t"] <= end)
        if len(ts) / (end - start) < rate_hz * 0.875:
            return False, f"{e}: {len(ts)} samples in {end - start:.1f} s"
        gaps = [b - a for a, b in zip([start] + ts, ts + [end])]
        if max(gaps) > 1.0:
            return False, f"{e}: a gap of {max(gaps):.2f} s"
    return True, "ok"
