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
    ("analysis.py", 'if row.get("status") != 200 or row.get("first_text_t") is None:', 'if row.get("first_text_t") is None:',
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
    ("analysis.py", "    if None in registered or None in decided or None in sends:", "    if None in sends:",
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
]


def main():
    survivors, stale = [], []
    for i, (fname, old, new, what) in enumerate(MUTANTS):
        tmp = tempfile.mkdtemp(prefix="llmd1598-mut-")
        kit = os.path.join(tmp, "kit")
        shutil.copytree(KIT, kit)
        path = os.path.join(kit, fname)
        with open(path) as f:
            src = f.read()
        if src.count(old) != 1:
            stale.append(what)
            print(f"STALE   {i:2d} {fname}: {what} (the original text occurs {src.count(old)} times)")
            shutil.rmtree(tmp)
            continue
        with open(path, "w") as f:
            f.write(src.replace(old, new))
        r = subprocess.run([sys.executable, "-m", "unittest", "-q", "test_kit"], cwd=HERE, env=dict(os.environ, KIT_DIR=kit),
                           capture_output=True, text=True)
        caught = r.returncode != 0
        print(f"{'caught ' if caught else 'SURVIVED'} {i:2d} {fname}: {what}")
        if not caught:
            survivors.append(what)
        shutil.rmtree(tmp)
    print(f"{len(MUTANTS) - len(survivors) - len(stale)} of {len(MUTANTS)} caught, {len(survivors)} survived, {len(stale)} stale")
    return 1 if survivors or stale else 0


if __name__ == "__main__":
    sys.exit(main())
