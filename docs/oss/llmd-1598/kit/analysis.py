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
    """Seconds from the scheduled send to the first non-empty text event; a request that never produced text is infinite."""
    if row.get("status") != 200 or row.get("first_text_t") is None:
        return INF
    return row["first_text_t"] - row["sched_abs"]


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


def burst_valid(burst_rows, preload_rows, epp_picked, epp_prereq, envoy):
    """K's burst is valid only if the scorer saw all three engines loaded for the whole burst: the three preloads went to
    three distinct engines, all three were registered (PreRequest) before any burst request left the client, and every
    burst request was decided before any preload produced its first event.

    At -v=5 the EPP's PreRequest and pick times are used.
    Without them each is bounded from Envoy's record (the upstream send follows PreRequest and the pick), which can only
    make the check stricter: a preload's forward time is no earlier than its registration, and a burst request's forward
    time is no earlier than its decision.
    A burst with any time missing is invalid, never assumed valid.
    """
    eps = [p.get("endpoint") for p in preload_rows]
    if len(preload_rows) != 3 or None in eps or len(set(eps)) != 3:
        return False, "preloads not on three distinct engines", None
    firsts = [p.get("first_event_t") for p in preload_rows]
    if any(f is None for f in firsts):
        return False, "a preload produced no event", None
    rids = [r["rid"] for r in burst_rows + preload_rows]
    basis = "epp" if all(x in epp_picked for x in rids) and all(p["rid"] in epp_prereq for p in preload_rows) else "envoy"
    if basis == "epp":
        registered = [epp_prereq[p["rid"]] for p in preload_rows]
        decided = [epp_picked[r["rid"]] for r in burst_rows]
    else:
        registered = [envoy_forward_t(envoy.get(p["rid"]) or {}) for p in preload_rows]
        decided = [envoy_forward_t(envoy.get(r["rid"]) or {}) for r in burst_rows]
    sends = [r.get("sent_abs") for r in burst_rows]
    if None in registered or None in decided or None in sends:
        return False, "a registration, decision or send time is missing", basis
    if max(registered) >= min(sends):
        return False, "a preload was registered after the burst began", basis
    if max(decided) >= min(firsts):
        return False, "a burst request was decided after a preload's first event", basis
    return True, "ok", basis


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
