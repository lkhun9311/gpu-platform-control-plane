"""Offline tests for the llm-d-router #1598 pilot kit: every analysis and verdict rule on synthetic rows, the workloads'
determinism, and the log readers on lines in the pinned EPP's and Envoy's formats."""

import json
import math
import os
import sys
import tempfile
import unittest

# mutate.py points KIT_DIR at a mutated copy of the kit; otherwise the tests read the committed one.
KIT = os.environ.get("KIT_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kit")
sys.path.insert(0, KIT)

import analysis as A  # noqa: E402
import logs  # noqa: E402
import verdict  # noqa: E402
import workloads as W  # noqa: E402

INF = float("inf")


def row(rid="r", status=200, done=True, mt=4, pt=100, ct=None, cached=0, sched=0.0, sent=0.0, first=0.1, last=0.4,
        endpoint="e0", prefix=None, pop="eval", usage=True, error=None):
    return {"rid": rid, "status": status, "done": done, "max_tokens": mt, "population": pop, "prefix": prefix,
            "usage": ({"prompt_tokens": pt, "completion_tokens": mt if ct is None else ct, "cached_tokens": cached} if usage else None),
            "sched_abs": sched, "sent_abs": sent, "first_event_t": first, "first_text_t": first, "last_text_t": last,
            "endpoint": endpoint, "error": error}


class Completion(unittest.TestCase):
    def test_completed_needs_every_part(self):
        self.assertTrue(A.completed(row()))
        self.assertFalse(A.completed(row(status=500)))
        self.assertFalse(A.completed(row(done=False)))
        self.assertFalse(A.completed(row(usage=False)))
        self.assertFalse(A.completed(row(ct=3)))

    def test_ttft_infinite_without_text_or_200(self):
        self.assertAlmostEqual(A.ttft(row(sched=1.0, first=1.25)), 0.25)
        self.assertTrue(math.isinf(A.ttft(row(first=None))))
        self.assertTrue(math.isinf(A.ttft(row(status=503))))

    def test_tpot_undefined_below_two_tokens(self):
        self.assertIsNone(A.client_tpot(row(mt=1)))
        self.assertAlmostEqual(A.client_tpot(row(mt=4, first=1.0, last=1.3)), 0.1)


class Percentiles(unittest.TestCase):
    def test_nearest_rank(self):
        v = list(range(1, 101))
        self.assertEqual(A.nearest_rank(v, 50), 50)
        self.assertEqual(A.nearest_rank(v, 99), 99)
        self.assertEqual(A.nearest_rank([1, 2, INF], 99), INF)
        self.assertIsNone(A.nearest_rank([], 50))

    def test_ratio_outcomes(self):
        self.assertEqual(A.ratio_outcome(0.85, 1.0, 0.9), "meets")
        self.assertEqual(A.ratio_outcome(0.95, 1.0, 0.9), "fails")
        self.assertEqual(A.ratio_outcome(INF, INF, 0.9), "both_infinite")
        self.assertEqual(A.ratio_outcome(1.0, INF, 0.9), "categorical_improvement")
        self.assertEqual(A.ratio_outcome(INF, 1.0, 0.9), "categorical_regression")
        self.assertEqual(A.ratio_outcome(None, 1.0, 0.9), "empty")

    def test_two_of_three(self):
        g = {"meets"}
        self.assertEqual(A.two_of_three(["meets", "meets", "fails"], g), "yes")
        self.assertEqual(A.two_of_three(["meets", "fails", "fails"], g), "no")
        self.assertEqual(A.two_of_three(["meets", None, "meets"], g), "yes (two runs)")
        self.assertEqual(A.two_of_three(["meets", None, "fails"], g), "inconclusive")
        self.assertEqual(A.two_of_three([None, None, "meets"], g), "inconclusive")
        self.assertEqual(A.two_of_three(["both_infinite", "both_infinite", "meets"], g), "no")


class SloAndRamp(unittest.TestCase):
    def test_slo_rounds_up_to_10ms(self):
        self.assertAlmostEqual(A.slo_from_cold([0.0601] * 20), 0.19)
        self.assertAlmostEqual(A.slo_from_cold([0.07] * 20), 0.21)
        self.assertIsNone(A.slo_from_cold([INF] * 20))

    def test_pass_needs_95pct_and_every_completion(self):
        ok = [row(rid=str(i), sched=0, first=0.1) for i in range(100)]
        self.assertTrue(A.passes_slo(ok, 0.2))
        slow = ok[:94] + [row(rid=f"s{i}", sched=0, first=0.5) for i in range(6)]
        self.assertFalse(A.passes_slo(slow, 0.2))
        five = ok[:95] + [row(rid=f"s{i}", sched=0, first=0.5) for i in range(5)]
        self.assertTrue(A.passes_slo(five, 0.2))
        self.assertFalse(A.passes_slo(ok[:99] + [row(rid="f", done=False)], 0.2))
        self.assertFalse(A.passes_slo([], 0.2))

    def test_bracket(self):
        self.assertEqual(A.bracket([(10, True), (15, True), (22.5, False)]), (15, "bracketed"))
        self.assertEqual(A.bracket([(10, True), (15, True)]), (15, "at_least"))
        self.assertEqual(A.bracket([(10, False)]), (10, "below"))
        self.assertEqual(A.bracket([(10, True), (15, False), (22.5, True)]), (10, "bracketed"))


class Ledger(unittest.TestCase):
    def d(self, prompt, gen, cached, success):
        return {"prompt": prompt, "generation": gen, "cached": cached, "success": success, "preemptions": 0}

    def test_exact_when_all_completed(self):
        rows = [row(rid="a", pt=100, mt=4, cached=16), row(rid="b", pt=50, mt=2, cached=0)]
        ok, out = A.ledger(rows, {"e0": self.d(150, 6, 16, 2)})
        self.assertTrue(ok, out)

    def test_off_by_one_fails(self):
        rows = [row(rid="a", pt=100, mt=4)]
        self.assertFalse(A.ledger(rows, {"e0": self.d(100, 5, 0, 1)})[0])
        self.assertFalse(A.ledger(rows, {"e0": self.d(101, 4, 0, 1)})[0])
        self.assertFalse(A.ledger(rows, {"e0": self.d(100, 4, 1, 1)})[0])
        self.assertFalse(A.ledger(rows, {"e0": self.d(100, 4, 0, 2)})[0])

    def test_incomplete_allows_excess_not_shortfall(self):
        rows = [row(rid="a", pt=100, mt=4), row(rid="b", done=False, usage=False)]
        ok, out = A.ledger(rows, {"e0": self.d(200, 7, 0, 1)})
        self.assertTrue(ok, out)
        self.assertEqual(out["e0"]["excess"]["prompt"], 100)
        self.assertFalse(A.ledger(rows, {"e0": self.d(99, 7, 0, 1)})[0])

    def test_missing_engine_delta_fails(self):
        self.assertFalse(A.ledger([row(endpoint="e9")], {"e0": self.d(0, 0, 0, 0)})[0])

    def test_unrouted_rows_are_not_counted(self):
        rows = [row(rid="a", pt=100, mt=4), row(rid="x", endpoint=None, done=False, usage=False)]
        self.assertTrue(A.ledger(rows, {"e0": self.d(100, 4, 0, 1)})[0])


class Joins(unittest.TestCase):
    def test_forwarded_needs_envoy_and_decision(self):
        r = row(rid="a")
        self.assertEqual(A.unexplained(r, {"a": {}}, {"a"}, True), [])
        self.assertEqual(A.unexplained(r, {}, {"a"}, True), ["envoy"])
        self.assertEqual(A.unexplained(r, {"a": {}}, set(), True), ["epp"])
        self.assertEqual(A.unexplained(r, {"a": {}}, set(), False), [])

    def test_rejected_before_scheduling_is_explained(self):
        r = row(rid="a", status=503, endpoint=None, done=False, usage=False, error="http 503")
        self.assertEqual(A.stage(r, {"a": {}}, set()), "received")
        self.assertEqual(A.unexplained(r, {"a": {}}, set(), True), [])

    def test_dispatched_with_no_outcome_is_unexplained(self):
        r = row(rid="a", status=None, endpoint=None, done=False, usage=False)
        self.assertEqual(A.unexplained(r, {}, set(), True), ["terminal outcome"])

    def test_join_limit(self):
        rows = [row(rid=str(i)) for i in range(400)]
        env = {str(i): {} for i in range(400)}
        epp = {str(i) for i in range(400)}
        self.assertTrue(A.join_valid(rows, env, epp, True)[0])
        del env["0"], env["1"]
        self.assertTrue(A.join_valid(rows, env, epp, True)[0])
        del env["2"]
        self.assertFalse(A.join_valid(rows, env, epp, True)[0])


class Credit(unittest.TestCase):
    def test_in_flight_and_completed(self):
        a = row(rid="a", prefix="P", sent=0.0, first=0.5, cached=0)
        b = row(rid="b", prefix="P", sent=0.2, first=0.6, cached=0)
        c = row(rid="c", prefix="P", sent=1.0, first=1.1, cached=512)
        d = row(rid="d", prefix="P", sent=2.0, first=2.1, cached=0)
        m = {x: {"e0": 8} for x in "bcd"}
        res = A.credit([a, b, c, d], m)
        self.assertEqual((res["credited"], res["in_flight"], res["completed"], res["completed_no_reuse"]), (3, 1, 2, 1))
        self.assertAlmostEqual(res["no_reuse_share"], 0.5)

    def test_credit_on_another_endpoint_is_not_credit(self):
        b = row(rid="b", prefix="P", endpoint="e1")
        self.assertEqual(A.credit([b], {"b": {"e0": 8}})["credited"], 0)

    def test_reuse_first_fill_and_lost(self):
        a = row(rid="a", prefix="P", sent=0.0, first=0.2)
        b = row(rid="b", prefix="P", sent=0.1, first=0.3)
        c = row(rid="c", prefix="P", sent=1.0, first=1.1, cached=256)
        d = row(rid="d", prefix="P", sent=2.0, first=2.1, cached=0)
        e = row(rid="e", prefix="P", sent=3.0, first=3.1, endpoint="e1")
        r = A.reuse([a, b, c, d, e])
        self.assertEqual((r["first_fills"], r["lost_reuse"], r["measured"]), (3, 1, 5))

    def test_reused_fraction(self):
        self.assertAlmostEqual(A.reused_fraction([row(pt=100, cached=50), row(pt=100, cached=0)]), 0.25)


class Bursts(unittest.TestCase):
    def test_largest_share(self):
        rows = [row(rid=str(i), endpoint="e0" if i < 5 else "e1") for i in range(8)]
        self.assertEqual(A.largest_share(rows)[0], 5)

    def test_burst_valid(self):
        pre = [row(rid=f"p{i}", endpoint=f"e{i + 1}", first=1.0) for i in range(3)]
        burst = [row(rid=str(i), sent=0.5) for i in range(4)]
        ok, why, basis = A.burst_valid(burst, pre, {str(i): 0.6 for i in range(4)})
        self.assertTrue(ok, why)
        self.assertEqual(basis, "epp")
        self.assertFalse(A.burst_valid(burst, pre, {str(i): 1.2 for i in range(4)})[0])
        same = [row(rid=f"p{i}", endpoint="e1", first=1.0) for i in range(3)]
        self.assertFalse(A.burst_valid(burst, same, {})[0])
        self.assertEqual(A.burst_valid(burst, pre, {})[2], "send")
        late = [row(rid=str(i), sent=1.5) for i in range(4)]
        self.assertFalse(A.burst_valid(late, pre, {})[0])


class Samples(unittest.TestCase):
    def samples(self, engines, hz, start, end, skip=None):
        out, t = [], start
        while t < end:
            for e in engines:
                if not (skip and skip[0] <= t < skip[1] and e == engines[0]):
                    out.append({"t": t, "engine": e, "running": 1 if e == engines[0] else 0, "waiting": 0, "kv": 0})
            t += 1.0 / hz
        return out

    def test_rate_and_gaps(self):
        e = ["e0", "e1"]
        self.assertTrue(A.sampler_ok(self.samples(e, 4, 0, 10), e, 0, 10)[0])
        self.assertFalse(A.sampler_ok(self.samples(e, 2, 0, 10), e, 0, 10)[0])
        self.assertFalse(A.sampler_ok(self.samples(e, 4, 0, 10, skip=(3, 4.6)), e, 0, 10)[0])
        # At 5 Hz a 1.5 s gap leaves the average above 3.5 a second, so only the gap rule can catch it.
        gapped = self.samples(e, 5, 0, 10, skip=(3, 4.5))
        self.assertGreaterEqual(sum(1 for s in gapped if s["engine"] == "e0") / 10, 3.5)
        self.assertFalse(A.sampler_ok(gapped, e, 0, 10)[0])

    def test_imbalance(self):
        e = ["e0", "e1"]
        cv, n = A.imbalance(self.samples(e, 4, 0, 4), e)
        self.assertAlmostEqual(cv, 1.0)
        self.assertEqual(n, 4)

    def test_hist_quantile(self):
        text = "\n".join([
            'llm_d_epp_scheduler_e2e_duration_seconds_bucket{le="0.0005"} 90',
            'llm_d_epp_scheduler_e2e_duration_seconds_bucket{le="0.001"} 98',
            'llm_d_epp_scheduler_e2e_duration_seconds_bucket{le="0.002"} 100',
            'llm_d_epp_scheduler_e2e_duration_seconds_bucket{le="+Inf"} 100'])
        self.assertEqual(A.hist_quantile(text, "scheduler_e2e_duration_seconds", 0.99), 0.002)
        self.assertEqual(A.hist_quantile(text, "scheduler_e2e_duration_seconds", 0.9), 0.0005)
        self.assertIsNone(A.hist_quantile("", "scheduler_e2e_duration_seconds", 0.99))


class Workloads(unittest.TestCase):
    def test_steady_is_deterministic_and_arm_independent(self):
        a = W.steady("A", 1, 10, "x")
        b = W.steady("A", 1, 10, "y")
        self.assertEqual(W.schedule_hash(a), W.schedule_hash(b))
        self.assertNotEqual(W.schedule_hash(a), W.schedule_hash(W.steady("A", 2, 10, "x")))
        self.assertTrue(all(r["population"] == ("warmup" if r["offset"] < 5 else "eval") for r in a))
        self.assertTrue(all(len(r["prompt"]) == 544 and 1 <= r["max_tokens"] <= 32 for r in a))
        self.assertEqual({r["prefix"] for r in a}, {"A0", "A1"})

    def test_b_has_48_prefixes(self):
        b = W.steady("B", 1, 30, "x")
        self.assertEqual(len({tuple(r["prompt"][:256]) for r in b}), len({r["prefix"] for r in b}))
        self.assertLessEqual(len({r["prefix"] for r in b}), 48)

    def test_w942_composition_fixed_across_rates(self):
        x, y = W.w942(942, 1.75, "a"), W.w942(942, 4.4, "a")
        self.assertEqual([r["prompt"] for r in x], [r["prompt"] for r in y])
        self.assertAlmostEqual(y[-1]["offset"] * 4.4, x[-1]["offset"] * 1.75, places=6)
        # The scaled trace's mean rate is the grid rate itself.
        for trace, rate in ((x, 1.75), (y, 4.4)):
            self.assertAlmostEqual(len(trace) / trace[-1]["offset"], rate, places=6)
        self.assertEqual(x[0]["offset"], x[1]["offset"])
        firsts = {}
        for r in x[:50]:
            firsts.setdefault(r["prefix"], 0)
            firsts[r["prefix"]] += 1
        self.assertEqual(len(firsts), 48)
        self.assertTrue(all(len(r["prompt"]) == 7936 and r["max_tokens"] == 64 for r in x))

    def test_k_prompts_distinct_first_router_blocks(self):
        bursts = W.k_bursts(1, "k")
        heads = [tuple(r["prompt"][:64]) for b in bursts for r in b]
        self.assertEqual(len(heads), len(set(heads)))
        self.assertTrue(all(len(p["prompt"]) == 4000 and p["max_tokens"] == 1 for p in W.preloads(1, "k", 0)))

    def test_ramp_ladder(self):
        import pilot
        # Four cells, x2 apart from the thread's 10/s, so the ladder spans 8x.
        self.assertEqual(pilot.RAMP_AB, [10, 20, 40, 80])
        self.assertEqual(pilot.ENGINE_CFG, {"AK": (4096, 4096), "B": (2048, 400), "W": (8192, None)})

    def test_tokens_in_range(self):
        for r in W.steady("A", 1, 10, "x")[:20]:
            self.assertTrue(all(W.TOKEN_LO <= t < W.TOKEN_HI for t in r["prompt"]))


class Logs(unittest.TestCase):
    def test_epp_time(self):
        self.assertAlmostEqual(logs.epp_time("2026-11-21T07:29:44.53972063Z") % 100, 1795246184.53972063 % 100, places=6)

    def test_read_epp(self):
        lines = [
            {"timestamp": "2026-11-21T07:29:44.5Z", "body": "Prefix cache match", "x-request-id": "r1",
             "matchedBlocks": {"default/vllm-0": 8}, "totalBlocks": 9},
            {"timestamp": "2026-11-21T07:29:44.6Z", "body": "Calculated score", "x-request-id": "r1",
             "plugin": "token-load-scorer/token-load-scorer", "endpoint": {"name": "vllm-0", "namespace": "default"}, "score": 0.9},
            {"timestamp": "2026-11-21T07:29:44.7Z", "body": "Completed running picker plugin successfully", "x-request-id": "r1"},
            {"timestamp": "2026-11-21T07:29:44.8Z", "body": "Running PreRequest plugin", "x-request-id": "r1"},
        ]
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("\n".join(json.dumps(x) for x in lines) + "\nnot json\n{broken\n")
        e = logs.read_epp(f.name, {"default/vllm-0": "127.0.0.1:8000"})
        self.assertEqual(e["match"]["r1"], {"127.0.0.1:8000": 8})
        self.assertEqual(e["scores"]["r1"]["token-load-scorer/token-load-scorer"]["127.0.0.1:8000"], 0.9)
        self.assertLess(e["picked"]["r1"], e["prerequest"]["r1"])
        self.assertEqual(e["unparsable"], 1)

    def test_read_access(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write('{"rid":"a","upstream":"127.0.0.1:8000","ttfb_us":"10"}\n{"rid":"-"}\nbad\n')
        acc, bad = logs.read_access(f.name)
        self.assertEqual(set(acc), {"a"})
        self.assertEqual(bad, 1)


class Verdict(unittest.TestCase):
    """verdict.main on a synthetic OUT: every plan cell, then faults that must change the verdict."""

    ENG = ["127.0.0.1:8000", "127.0.0.1:8001", "127.0.0.1:8002", "127.0.0.1:8003"]

    def make(self, faults=()):
        out = tempfile.mkdtemp()
        # A sequential probe cell rides along in every synthetic run: it has no schedule and so no dispatch lag.
        cells = list(verdict.PLAN) + ["iso-A-cold"]
        state = {"cells": cells, "calibration": {}, "ramps": {}, "timings": {}, "skipped": []}
        if "drop_cell" in faults:
            state["cells"] = cells[1:]
        with open(os.path.join(out, "pilot.json"), "w") as f:
            json.dump(state, f)
        for name in cells:
            cdir = os.path.join(out, "cells", name)
            os.makedirs(cdir)
            kind = "K" if name.startswith("log-K") else ("probe" if name.startswith("iso") else "steady")
            arm = "A3" if kind == "probe" else name.split("-")[2]
            v = 2 if name.endswith("v2") else 5
            rows, bursts, epp_lines, acc = [], [], [], []
            t0 = 1795246000.0
            if kind == "K":
                for b in range(3):
                    # Burst 2's preloads share one engine, so it is invalid, and its 60-on-one share must not be counted.
                    bad = b == 2
                    pre = [row(rid=f"{name}-b{b}-p{j}", endpoint=self.ENG[1 if bad else j + 1], mt=1, pt=4000, sent=t0,
                               first=t0 + 5, pop="preload") for j in range(3)]
                    top = 60 if bad else 40
                    burst = [row(rid=f"{name}-b{b}-{i}", endpoint=self.ENG[0] if i < top else self.ENG[1 + i % 3], mt=2,
                                 pt=544, sent=t0 + 0.1, sched=t0 + 0.1, first=t0 + 1) for i in range(64)]
                    rows += pre + burst
                    bursts.append({"burst": b, "rids": [r["rid"] for r in burst], "preloads": [r["rid"] for r in pre]})
            else:
                rows = [row(rid=f"{name}-{i}", endpoint=self.ENG[i % 4], prefix="A0", pt=544, mt=4, cached=512 if i >= 4 else 0,
                            sent=t0 + i, sched=t0 + i, first=t0 + i + 0.05, last=t0 + i + 0.1) for i in range(40)]
            for r in rows:
                if kind != "probe" and not ("no_lag" in faults and name == "switch-A-A3"):
                    r["lag_s"] = 0.001
                acc.append({"rid": r["rid"], "upstream": r["endpoint"]})
                if v >= 5:
                    ts = "2026-11-21T07:00:00.000000001Z"
                    epp_lines.append({"timestamp": ts, "body": "Completed running picker plugin successfully", "x-request-id": r["rid"]})
                    if not ("no_match" in faults and name == "switch-A-A2" and r["rid"].endswith(("-1", "-2"))):
                        epp_lines.append({"timestamp": ts, "body": "Prefix cache match", "x-request-id": r["rid"],
                                          "matchedBlocks": {f"default/vllm-{self.ENG.index(r['endpoint'])}": 8}})
            if "drop_envoy" in faults and name == "log-A-A1-v5":
                acc = acc[:-5]
            deltas = {}
            for e in self.ENG:
                mine = [r for r in rows if r["endpoint"] == e]
                deltas[e] = {"prompt": sum(r["usage"]["prompt_tokens"] for r in mine),
                             "generation": sum(r["usage"]["completion_tokens"] for r in mine),
                             "cached": sum(r["usage"]["cached_tokens"] for r in mine), "success": len(mine), "preemptions": 0}
            if "ledger" in faults and name == "switch-A-A2":
                deltas[self.ENG[0]]["generation"] += 1
            reset = {e: True for e in self.ENG}
            if "reset" in faults and name == "pressure-B-A1":
                reset[self.ENG[2]] = False
            meta = {"cell": name, "arm": arm, "block": "B" if "B" in name.split("-")[1] else ("K" if kind == "K" else "A"),
                    "kind": kind, "verbosity": v, "engines": self.ENG, "idle_at_start": True, "reset": reset,
                    "window": [t0, t0 + 10], "deltas": deltas, "bursts": bursts}
            with open(os.path.join(cdir, "cell.json"), "w") as f:
                json.dump(meta, f)
            with open(os.path.join(cdir, "rows.jsonl"), "w") as f:
                f.write("".join(json.dumps(r) + "\n" for r in rows))
            with open(os.path.join(cdir, "access.log"), "w") as f:
                f.write("".join(json.dumps(a) + "\n" for a in acc))
            with open(os.path.join(cdir, "epp.log"), "w") as f:
                f.write("".join(json.dumps(a) + "\n" for a in epp_lines))
            hz = 2 if ("sampler" in faults and name == "log-A-A1-v2") else 4
            with open(os.path.join(cdir, "samples.jsonl"), "w") as f:
                t = t0
                while t <= t0 + 10:
                    for e in self.ENG:
                        f.write(json.dumps({"t": t, "engine": e, "running": 1, "waiting": 0, "kv": 0.1}) + "\n")
                    t += 1.0 / hz
            slow = "slow_v5" in faults and name == "log-K-A1-v5"
            with open(os.path.join(cdir, "epp-metrics.prom"), "w") as f:
                f.write(f'llm_d_epp_scheduler_e2e_duration_seconds_bucket{{le="0.001"}} {0 if slow else 100}\n'
                        'llm_d_epp_scheduler_e2e_duration_seconds_bucket{le="0.005"} 100\n'
                        'llm_d_epp_scheduler_e2e_duration_seconds_bucket{le="+Inf"} 100\n')
        return out

    def run_verdict(self, out):
        with open(os.devnull, "w") as devnull:
            old, sys.stdout = sys.stdout, devnull
            try:
                return verdict.main(out)
            finally:
                sys.stdout = old

    def test_holds(self):
        out = self.make()
        self.assertEqual(self.run_verdict(out), 0)
        with open(os.path.join(out, "verdict.json")) as f:
            v = json.load(f)
        self.assertEqual(v["k_effect"]["mean_largest_by_cell"]["log-K-A1-v5"], 40)
        self.assertEqual(v["cells"]["log-K-A1-v5"]["valid_bursts"], 2)
        self.assertTrue(v["k_effect"]["shows"])
        self.assertTrue(v["logging"]["keep_v5"])
        self.assertEqual(v["cells"]["log-A-A1-v5"]["credit_join_share"], 1.0)

    def test_slower_v5_drops_verbose_logging(self):
        out = self.make(("slow_v5",))
        self.assertEqual(self.run_verdict(out), 0)
        with open(os.path.join(out, "verdict.json")) as f:
            v = json.load(f)
        self.assertAlmostEqual(v["logging"]["epp_sched_p99_delta_s"]["K"], 0.004)
        self.assertFalse(v["logging"]["keep_v5"])

    def test_each_fault_fails_the_apparatus(self):
        for fault, cell, check in (("ledger", "switch-A-A2", "ledger"), ("reset", "pressure-B-A1", "reset"),
                                   ("sampler", "log-A-A1-v2", "sampler_4hz"), ("drop_envoy", "log-A-A1-v5", "joins"),
                                   ("no_match", "switch-A-A2", "credit_join"), ("no_lag", "switch-A-A3", "dispatch_lag")):
            out = self.make((fault,))
            self.assertEqual(self.run_verdict(out), 4, fault)
            with open(os.path.join(out, "verdict.json")) as f:
                v = json.load(f)
            self.assertIn(check, v["apparatus_failures"].get(cell, []), fault)

    def test_missing_cell_is_incomplete(self):
        self.assertEqual(self.run_verdict(self.make(("drop_cell",))), 3)


if __name__ == "__main__":
    unittest.main()
