"""Mutation run for the llm-d-router #1598 pilot kit: each mutant breaks one registered rule in a copy of the kit, and the
offline tests must fail on it. A mutant the tests pass is a rule nothing checks.

Prints one line per mutant and exits 1 if any survives or any mutation no longer applies to the source.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.join(HERE, "..", "kit")

MUTANTS = [
    ("analysis.py", 'and u.get("completion_tokens") == row.get("max_tokens"))', ")", "completion stops requiring every requested token"),
    ("analysis.py", "    if not completed(row):\n        return INF\n    t =", "    if False:\n        return INF\n    t =",
     "a non-200 request gets a finite TTFT"),
    ("analysis.py", "if not completed(row) or n is None or n < 2", "if not completed(row) or n is None or n < 1",
     "TPOT is computed for one-token outputs"),
    ("analysis.py", "k = max(1, math.ceil(p / 100.0 * len(v)))", "k = max(1, int(p / 100.0 * len(v)))", "percentile rounds down"),
    ("analysis.py", '        return "both_infinite"', '        return "meets"', "both infinite reads as an improvement"),
    ("analysis.py", '        return "categorical_regression"', '        return "fails"', "finite-against-infinite loses its category"),
    ("analysis.py", '        return ("yes (two runs)" if a else "no (two runs)") if a == b else "inconclusive"',
     '        return "yes (two runs)" if (a or b) else "no (two runs)"', "two disagreeing seeds decide"),
    ("analysis.py", "ms = math.ceil(round(3 * p50 * 1000, 6) / 10.0) * 10", "ms = round(3 * p50 * 1000 / 10.0) * 10",
     "the SLO rounds to nearest instead of up"),
    ("analysis.py", "return ok >= 0.95 * len(rows) and all(completed(r) for r in rows)", "return ok >= 0.95 * len(rows)",
     "a ramp passes with incomplete requests"),
    ("analysis.py", "    below = [r for r in passed if r < first_fail]", "    below = passed", "a pass above the first failure counts"),
    ("analysis.py", "            good = all(d[k] == sums[k] for k in sums)", "            good = all(d[k] >= sums[k] for k in sums)",
     "the ledger is never exact"),
    ("analysis.py", "            good = all(d[k] >= sums[k] for k in sums)\n", "            good = True\n",
     "the ledger accepts a shortfall when a request failed"),
    ("analysis.py", "    if STAGES.index(st) >= STAGES.index(\"forwarded\"):", "    if False:",
     "a forwarded request needs no Envoy line or decision"),
    ("analysis.py", '    if st == "dispatched" and row.get("error") is None:', "    if False:",
     "a sent request with no outcome is explained"),
    ("analysis.py", "    return len(bad) <= limit * max(1, len(rows)), bad", "    return len(bad) <= 0.05 * max(1, len(rows)), bad",
     "the join limit loosens tenfold"),
    ("analysis.py", 'settled = first is not None and first.get("first_text_t") is not None and first["first_text_t"] <= when(r)',
     "settled = first is not None", "in-flight credit counts as completed"),
    ("analysis.py", '        return decision_t.get(r["rid"], r["sent_abs"])', '        return r["sent_abs"]',
     "credit is classified at the client's send time, not the router's decision"),
    ("analysis.py", "        if blocks < 1 or not completed(r) or not measured(r):", "        if blocks < 1 or not completed(r):",
     "warm-up rows are classified as measured credit"),
    ("analysis.py", "        if not measured(r):\n            continue\n        n += 1", "        n += 1",
     "warm-up rows are counted as measured reuse"),
    ("analysis.py", "            r[\"endpoint\"] = up\n", "            pass\n", "the upstream of a cut-off request is not recovered"),
    ("analysis.py", '        return float(rec["start"]) + float(rec["route_us"]) / 1e6', '        return float(rec["start"])',
     "Envoy's forward time drops the routing duration"),
    ("verdict.py", "    analysis.recover_endpoints(rows, envoy)", "    pass", "the verdict skips upstream recovery"),
    ("verdict.py", '        cr = analysis.credit(rows, epp["match"], epp["picked"])', '        cr = analysis.credit(ev, epp["match"], epp["picked"])',
     "credit loses the warm-up history"),
    ("verdict.py", '        res["reuse"] = analysis.reuse(rows)', '        res["reuse"] = analysis.reuse(ev)', "reuse loses the warm-up history"),
    ("analysis.py", "        if blocks < 1 or not completed(r) or not measured(r):", "        if not completed(r) or not measured(r):",
     "uncredited requests are counted"),
    ("analysis.py", '        elif r["usage"]["cached_tokens"] == 0:', "        else:", "every repeat counts as lost reuse"),
    ("analysis.py", "    if len(preload_rows) != 3 or None in eps or len(set(eps)) != 3:", "    if len(preload_rows) != 3:",
     "preloads on one engine pass"),
    ("analysis.py", "    if max(decided) >= min(firsts):", "    if False:", "a burst decided after a preload's first event passes"),
    ("analysis.py", "    if max(registered) >= min(sends):", "    if False:", "a preload registered after the burst began passes"),
    ("analysis.py", "    if not burst_rows or None in registered or None in decided or None in sends:", "    if None in sends:",
     "a burst with a missing time is assumed valid"),
    ("analysis.py", "        cvs.append(sd / m)", "        cvs.append(sd)", "imbalance stops normalising"),
    ("analysis.py", "        if max(gaps) > 1.0:", "        if max(gaps) > 5.0:", "sampler gaps up to 5 s pass"),
    ("analysis.py", "    if len(ts) / (end - start) < rate_hz * 0.875:", "    if len(ts) / (end - start) < rate_hz * 0.25:",
     "a 1 Hz sampler passes"),
    ("analysis.py", "        if cum >= q * total:", "        if cum > q * total:", "the histogram quantile skips its bucket"),
    ("workloads.py", 'pop = "warmup" if t < warm else "eval"', 'pop = "eval"', "warm-up requests are measured"),
    ("workloads.py", "    scale = (len(base) / base_end) / rate", "    scale = 1.0 / rate", "W942's time scale is wrong"),
    ("workloads.py", "        for _ in range(2):", "        for _ in range(1):", "W942 arrivals are not pairs"),
    ("workloads.py", 'rng = random.Random(f"K-{seed}-prompts")\n    return [[_req(f"{tag}-b{b}-{i}", 0.0, _ids(rng, K_PROMPT)',
     'rng = random.Random(f"K-{seed}-prompts")\n    p = _ids(rng, K_PROMPT)\n    return [[_req(f"{tag}-b{b}-{i}", 0.0, list(p)',
     "K bursts reuse one prompt"),
    ("workloads.py", "        h.update(json.dumps([round(r[\"offset\"], 6), r[\"max_tokens\"], r[\"prefix\"], r[\"population\"],",
     "        h.update(json.dumps([r[\"rid\"], round(r[\"offset\"], 6), r[\"max_tokens\"], r[\"prefix\"], r[\"population\"],",
     "the schedule hash depends on the arm's tag"),
    ("logs.py", "    return t + (float(\"0.\" + frac) if frac else 0.0)", "    return t", "EPP timestamps lose their fraction"),
    ("logs.py", '            elif body == "Completed running picker plugin successfully" and rid not in picked:',
     '            elif body == "Running PreRequest plugin" and rid not in picked:', "the pick time is read from PreRequest"),
    ("logs.py", "                match[rid] = {names.get(k, k): v for", "                match[rid] = {k: v for", "matches keep EPP names"),
    ("verdict.py", "    c[\"reset\"] = bool(meta.get(\"reset\")) and all(meta[\"reset\"].values())", "    c[\"reset\"] = True",
     "a failed cache reset passes"),
    ("verdict.py", '    if meta["kind"] != "probe":\n        c["dispatch_lag"]', '    if True:\n        c["dispatch_lag"]',
     "probes are held to a dispatch lag they cannot have"),
    ("verdict.py", "        c[\"dispatch_lag\"] = p99 is not None and p99 <= LAG_P99_S",
     "        c[\"dispatch_lag\"] = p99 is None or p99 <= LAG_P99_S", "a scheduled cell with no lag record passes"),
    ("pilot.py", "RAMP_AB = [10, 20, 40, 80]", "RAMP_AB = [10, 15, 22.5, 33.75]", "the ramp ladder narrows back to x1.5"),
    ("verdict.py", "    c[\"ledger\"] = ok", "    c[\"ledger\"] = True", "the ledger is not a check"),
    ("verdict.py", "    c[\"sampler_4hz\"] = sok", "    c[\"sampler_4hz\"] = True", "the sampler is not a check"),
    ("verdict.py", "    c[\"joins\"] = jok", "    c[\"joins\"] = True", "the joins are not a check"),
    ("verdict.py", "        c[\"credit_join\"] = fwd > 0 and joined >= 0.995 * fwd", "        c[\"credit_join\"] = True",
     "the credit join is not a check"),
    ("verdict.py", "        vs = [v[\"largest\"] for v in valid if v[\"valid\"]]", "        vs = [v[\"largest\"] for v in valid]",
     "invalid bursts count"),
    ("verdict.py", "    elif state.get(\"stopped\") or missing or \"k_effect\" not in v:", "    elif state.get(\"stopped\"):",
     "a missing plan cell reads as complete"),
    ("verdict.py", "        keep = all(d is not None and d <= 0.001 for d in deltas) and share is not None and share <= 4",
     "        keep = True", "the logging rule always keeps -v=5"),
    # The main-run design after the pilot (the spec's third revision).
    ("analysis.py", "    if not completed(row):\n        return INF\n    t =", '    if row.get("status") != 200:\n        return INF\n    t =',
     "a request that failed after its first token gets a finite TTFT"),
    ("analysis.py", '        t = row.get("first_token_t")', "        t = None", "a completed request whose tokens had no text reads infinite"),
    ("analysis.py", "if cdf[r - 1] <= alpha), default=None)", "if cdf[r - 1] <= 2 * alpha), default=None)",
     "the p99 interval loses half its lower tail"),
    ("analysis.py", "    total = n_preloads * preload_tokens + burst * prompt_tokens", "    total = burst * prompt_tokens",
     "the fluid reference forgets the preloads"),
    ("analysis.py", "    low = min(brk.values())", "    low = max(brk.values())", "the grid anchors on the highest knee"),
    ("analysis.py", '        if kind == "at_least" and r < low:', "        if False:",
     "an arm censored below the other's knee is ignored"),
    ("analysis.py", '        if kind not in ("bracketed", "at_least"):', "        if False:",
     "an arm that failed its lowest rate still gives an anchor"),
    ("analysis.py", "GRID = (0.6, 0.9, 1.2, 1.5)", "GRID = (0.6, 0.9, 1.2, 1.8)", "the grid's top rate moves"),
    ("analysis.py", '    if any(d < r.get("send_begin_abs", r["sent_abs"]) for d, r in zip(decided, burst_rows)):', "    if False:",
     "a burst decided before its release is valid"),
    ("analysis.py", "    if max_span is not None and max(sends) - min(sends) > max_span:", "    if False:",
     "a spread release is valid"),
    ("analysis.py", "    elif preload_rows:", "    elif False:", "a no-preload burst with preload rows is valid"),
    ("analysis.py", 'if d is None or r.get("sent_abs") is None or d < r.get("send_begin_abs", r["sent_abs"]):',
     'if d is not None and r.get("sent_abs") is not None and d < r.get("send_begin_abs", r["sent_abs"]):',
     "a burst request with no decision is not early"),
    ("analysis.py", "    return sum(1 for x in spans if x is not None and x <= limit) >= share * len(spans)",
     "    return sum(1 for x in spans if x is not None and x <= limit) >= 0.5 * len(spans)", "half the bursts may be spread"),
    ("analysis.py", "    if not spans or any(e for e in early):", "    if not spans:", "an early decision passes the release check"),
    ("sender.py", "    span, best, j = timeout + 5.0, 0, 0", "    span, best, j = timeout, 0, 0", "the worker count drops the drain"),
    ("sender.py", "    if workers > MAX_WORKERS:", "    if False:", "a schedule over the worker ceiling is not refused"),
    ("sender.py", "        arm()\n        line = r.readline()", "        line = r.readline()", "a streaming request outlives its deadline"),
    ("sender.py", "                c.endheaders(self.bodies[i][:-1])", "                c.endheaders(self.bodies[i])",
     "priming sends the whole body"),
    ("sender.py", '        if choices and row["first_token_t"] is None:', "        if False:", "the first token's event is not recorded"),
    ("sender.py", '                    rows[i]["sent_abs"] = time.time()\n', '                    rows[i]["sent_abs"] = time.time()\n                    time.sleep(0.0002)\n',
     "the release loop pauses between last bytes"),
    ("verdict.py", '        span = W.K_RELEASE_SPAN_S if primed and not meta.get("stagger") else None', "        span = None",
     "the release span is never checked"),
    ("verdict.py", 'with_preloads=meta.get("k_preloads", True))', "with_preloads=True)", "K-equal is held to the preload conditions"),
    ("verdict.py", '        npre = 3 if meta.get("k_preloads", True) else 0', "        npre = 3", "K-equal's fluid reference counts preloads"),
    ("verdict.py", ' or no_k or any(a["anchor"] is None for a in anchors.values()):', " or no_k:",
     "a block with no anchor reads as complete"),
    ("verdict.py", "            ramps.setdefault(arm, tuple(rk))", "            pass", "W942 loses the first pilot's A3 knee"),
    ("workloads.py", "K_BURSTS, K_SIZE, K_PROMPT, K_TIMEOUT = 12, 64, 544, 10.0", "K_BURSTS, K_SIZE, K_PROMPT, K_TIMEOUT = 6, 64, 544, 10.0",
     "K falls back to six bursts"),
    ("workloads.py", "K_STAGGER_S = 0.004", "K_STAGGER_S = 0.02", "K-stagger returns to 20 ms"),
    ("workloads.py", '"peak_prefill_tps": 8869,', '"peak_prefill_tps": 8870,', "the registered peak prefill moves"),
    ("pilot.py", "        return 15 + W.K_BURSTS * (14 + (W.K_SIZE - 1) * stagger)", "        return 15 + W.K_BURSTS * 14",
     "K-stagger's bound drops its gaps"),
    ("pilot.py", "    return 15 + span + timeout", "    return 15 + 120 + timeout", "W942's bound is the old 120 s"),
    ("pilot.py", '"A": [64, 80, 100, 125, 156, 195, 244]', '"A": [64, 80, 100, 125, 156, 195]', "the second pilot's A ladder shortens"),
    ("analysis.py", '        if d is None or r.get("sent_abs") is None or d < r.get("send_begin_abs", r["sent_abs"]):',
     '        if d is None or r.get("sent_abs") is None or d < r["sent_abs"]:', "a decision during the last byte's write counts as early"),
    ("analysis.py", '    if any(d < r.get("send_begin_abs", r["sent_abs"]) for d, r in zip(decided, burst_rows)):',
     '    if any(d < r["sent_abs"] for d, r in zip(decided, burst_rows)):', "burst validity ignores when the write began"),
    ("sender.py", '                    rows[i]["send_begin_abs"] = time.time()\n', "", "the write's start is not recorded"),
    ("verdict.py", '    elif state.get("stopped") or missing or no_k or any(', '    elif state.get("stopped") or missing or any(',
     "a second pilot with no valid K burst reads as complete"),
    # The owner's amendment of 2026-11-22.
    ("analysis.py", "    load = [0] + [preload_tokens] * n_preloads", "    load = [preload_tokens] * n_preloads + [0]",
     "the sequential reference starts on a loaded engine"),
    ("analysis.py", "        why = [w for w in (fault(x), fault(y)) if w]", "        why = []",
     "apparatus-invalid bursts stay in the paired comparison"),
    ("analysis.py", '            if not z["valid"] or not z.get("completed", True):', '            if not z.get("completed", True):',
     "an arm's own invalid burst is not its failure"),
    ("analysis.py", '"covered": coverage >= min_coverage}', '"covered": True}', "paired coverage is not checked"),
    ("analysis.py", '    if failures["cand"] > failures["base"]:\n        res["c2"] = "fails"', '    if False:\n        res["c2"] = "fails"',
     "the candidate's extra failures do not fail C2"),
    ("analysis.py", '"meets" if res["cand_mean"] <= 0.75 * res["base_mean"] else "fails"',
     '"meets" if res["cand_mean"] <= 0.80 * res["base_mean"] else "fails"', "the registered C2 ratio moves"),
    ("analysis.py", "    coverage = len(both) / len(ids) if ids else 0.0", "    coverage = (len(ids) - len(excluded)) / len(ids) if ids else 0.0",
     "coverage counts arm-invalid bursts as usable pairs"),
    ("analysis.py", '        if "apparatus" in z:\n            return z["apparatus"]', '        if False:\n            return z["apparatus"]',
     "the paired comparison reads the apparatus fault from the first invalidity reason"),
    ("analysis.py", '    if entry.get("early"):', "    if False:", "an early decision is no apparatus fault"),
    ("analysis.py", '    if span_limit is not None and entry["release_span_s"] > span_limit:', "    if False:",
     "a spread release is no apparatus fault"),
    ("analysis.py", '    if entry.get("release_span_s") is None:', "    if False:", "a missing release time is no apparatus fault"),
    ("analysis.py", '    done = all(not math.isinf(p["makespan"]) for p in cand_perf)', "    done = True",
     "the guardrail passes a candidate with a failed request"),
    ("verdict.py", '                entry["apparatus"] = analysis.apparatus_fault(entry, span)', "                pass",
     "the verdict records no apparatus fault per burst"),
    ("analysis.py", '"a registration, decision or send time is missing")', '"a preload produced no event")',
     "a missing record becomes an arm's failure rather than an exclusion"),
    ("analysis.py", "MIN_PAIRED_COVERAGE = 0.75", "MIN_PAIRED_COVERAGE = 0.6", "the frozen paired coverage loosens"),
    ("analysis.py", "    if None in starts or None in ends or not burst_rows or not all(completed(r) for r in burst_rows):",
     "    if None in starts or None in ends or not burst_rows:", "a burst with a failed request has a finite makespan"),
    ("analysis.py", '    return {"holds": ok_t and ok_m and done,', '    return {"holds": ok_t and done,', "the guardrail ignores makespan"),
    ("analysis.py", '    return {"holds": ok_t and ok_m and done,', '    return {"holds": ok_m and done,', "the guardrail ignores burst TTFT"),
    ("analysis.py", "K_GUARDRAIL = 1.10", "K_GUARDRAIL = 1.5", "the burst guardrail loosens"),
    ("analysis.py", "    return gaps[0] >= 0.5 * stagger and 0.9 * stagger <= med <= 1.1 * stagger",
     "    return 0.9 * stagger <= med <= 1.1 * stagger", "a single short stagger gap passes"),
    ("analysis.py", "    return gaps[0] >= 0.5 * stagger and 0.9 * stagger <= med <= 1.1 * stagger",
     "    return gaps[0] >= 0.5 * stagger", "bunched stagger gaps pass"),
    ("analysis.py", "        if f is not None and t is not None and f < t:", "        if t is not None:",
     "a predecessor counts as forwarded without Envoy's record"),
    ("analysis.py", "            and pred_ok >= STAGGER_PREDECESSOR_SHARE * pred_pairs)", "            )",
     "K-stagger is usable without predecessor forwarding"),
    ("analysis.py", "sum(valid) >= STAGGER_VALID_SHARE * n", "True", "K-stagger is usable with few valid bursts"),
    ("analysis.py", "    return (sum(gaps_ok) >= STAGGER_GAP_SHARE * n and", "    return (True and", "K-stagger is usable with bad gaps"),
    ("analysis.py", '    ts = [t for t in (envoy_first_byte_t(envoy.get(p["rid"]) or {}), p.get("first_event_t")) if t is not None]',
     '    ts = [t for t in (p.get("first_event_t"),) if t is not None]', "preload visibility uses only the client's first event"),
    ("analysis.py", '        return None if f is None else f + float(rec["ttfb_us"]) / 1e6', "        return f",
     "Envoy's first byte drops the upstream TTFB"),
    ("analysis.py", "        if set(cost) != set(left) or any(left[k] < cost[k] for k in left):",
     "        if set(cost) != set(left) or all(left[k] < cost[k] for k in left):", "a replay unit fits if one seed has room"),
    ("verdict.py", '            res["stagger_usable"] = analysis.stagger_usable([v["gaps_ok"] for v in valid],',
     '            res["stagger_usable"] = analysis.stagger_usable([True for v in valid],', "the verdict skips the stagger gap rule"),
    ("pilot.py", "P2_SEED, P2_W942_SEED = 4, 944", "P2_SEED, P2_W942_SEED = 1, 942", "the second pilot reuses main seeds"),
]


def main():
    survivors, stale = [], []
    for i, (fname, old, new, what) in enumerate(MUTANTS):
        # Removed on every path out of the block, a stale mutant and an exception included.
        with tempfile.TemporaryDirectory(prefix="llmd1598-mut-") as tmp:
            kit = os.path.join(tmp, "kit")
            shutil.copytree(KIT, kit, ignore=shutil.ignore_patterns("__pycache__"))
            path = os.path.join(kit, fname)
            with open(path) as f:
                src = f.read()
            if src.count(old) != 1:
                stale.append(what)
                print(f"STALE   {i:2d} {fname}: {what} (the original text occurs {src.count(old)} times)")
                continue
            with open(path, "w") as f:
                f.write(src.replace(old, new))
            r = subprocess.run([sys.executable, "-m", "unittest", "-q", "test_kit"], cwd=HERE, env=dict(os.environ, KIT_DIR=kit),
                               capture_output=True, text=True)
        caught = r.returncode != 0
        print(f"{'caught ' if caught else 'SURVIVED'} {i:2d} {fname}: {what}")
        if not caught:
            survivors.append(what)
    print(f"{len(MUTANTS) - len(survivors) - len(stale)} of {len(MUTANTS)} caught, {len(survivors)} survived, {len(stale)} stale")
    return 1 if survivors or stale else 0


if __name__ == "__main__":
    sys.exit(main())
