"""Unit tests of the A10G capacity kit's analysis: each contract rule, its passing case and its must-fail case.

    python3 -m unittest -q test_kit

A10G_KIT points at the kit directory to test (default ../kit), so mutate.py can run these tests on a broken copy.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.environ.get("A10G_KIT", os.path.join(HERE, "..", "kit"))
sys.path.insert(0, HERE)
import fixtures  # noqa: E402

spec = importlib.util.spec_from_file_location("analysis", os.path.join(KIT, "analysis.py"))
A = importlib.util.module_from_spec(spec)
spec.loader.exec_module(A)
CONTRACT = os.path.join(HERE, "..", "kit", "contract.json")
C = A.load_contract(CONTRACT)


class Fixtures(unittest.TestCase):
    """Every fixture gives the exit status its manifest records, through the same command line the kit runs."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="a10g-fixtures-")
        cls.manifest = fixtures.build(cls.tmp)

    def test_each_fixture_gives_its_verdict(self):
        for f in self.manifest:
            target = {"rung": f"{f['name']}/rung-01", "cycle": f"{f['name']}/cycle", "report": f["name"]}[f["cmd"]]
            p = subprocess.run([sys.executable, "-I", os.path.join(KIT, "analysis.py"), f["cmd"], CONTRACT, os.path.join(self.tmp, target)],
                               capture_output=True, text=True)
            with self.subTest(fixture=f["name"]):
                self.assertEqual(p.returncode, f["want_exit"], f"{f['why']}\n{p.stdout[-600:]}\n{p.stderr[-600:]}")

    def test_every_rule_has_a_must_fail_fixture(self):
        why = " ".join(f["why"] for f in self.manifest if f["want_exit"] != 0)
        for rule in ("S1", "S2", "S3", "recovery rule", "ledger mismatch", "too few samples", "X3", "X5"):
            self.assertIn(rule, why)


class Ledger(unittest.TestCase):
    def test_http_and_stream_are_separate_axes(self):
        r = fixtures.row(0, "x", 0, outcome="timeout")
        self.assertEqual(A.classify(r, C, 128), ("failed", "200", "timeout"))
        self.assertEqual(A.classify(fixtures.row(0, "x", 0, outcome="429"), C, 128), ("rejected", "429", "not-read"))
        self.assertEqual(A.classify(fixtures.row(0, "x", 0, outcome="transport"), C, 128), ("failed", "none", "transport"))
        self.assertEqual(A.classify(fixtures.row(0, "x", 0, completion=127), C, 128), ("failed", "200", "contract"))
        self.assertEqual(A.classify(fixtures.row(0, "x", 0, finish="stop"), C, 128), ("failed", "200", "contract"))
        self.assertEqual(A.classify(fixtures.row(0, "x", 0, prompt=511), C, 128), ("failed", "200", "contract"))
        self.assertEqual(A.classify(fixtures.row(0, "x", 0), C, 128), ("completed", "200", "done"))

    def test_identities_and_cross_table(self):
        rows = [fixtures.row(i, "x", i, outcome=o) for i, o in enumerate(["done", "done", "timeout", "429", "unsent", "transport"])]
        led = A.ledger(rows, C, 128)
        self.assertEqual((led["planned"], led["unsent"], led["sent"]), (6, 1, 5))
        self.assertEqual((led["completed"], led["rejected"], led["failed"]), (2, 1, 2))
        self.assertEqual(led["cross"], {"200/done": 2, "200/timeout": 1, "429/not-read": 1, "none/transport": 1})

    def test_a_row_without_disposition_is_refused(self):
        r = fixtures.row(0, "x", 0)
        del r["disposition"]
        with self.assertRaises(A.Refused):
            A.ledger([r], C, 128)


class Quantiles(unittest.TestCase):
    def test_nearest_rank(self):
        v = list(range(1, 101))
        self.assertEqual(A.quantile(v, 0.99), 99)
        self.assertEqual(A.quantile(v, 0.5), 50)
        self.assertEqual(A.quantile([7], 0.99), 7)

    def test_p99_needs_the_minimum(self):
        self.assertIsNone(A.quantiles(list(range(99)), 100)["p99"])
        self.assertEqual(A.quantiles(list(range(100)), 100)["p99"], 98)


def v(rate, stable, rung):
    return {"rate_rps": rate, "stable": stable, "rung": rung}


class Saturation(unittest.TestCase):
    def test_highest_stable_below_the_first_unstable(self):
        s = A.saturation([v(3, True, 1), v(4, True, 2), v(5, False, 3)], C)
        self.assertEqual((s["status"], s["r_sat"], s["first_unstable"]), ("saturated", 4, 5))

    def test_first_rung_unstable(self):
        s = A.saturation([v(3, False, 1)], C)
        self.assertEqual((s["status"], s["r_sat"]), ("saturation below the ladder", None))
        self.assertFalse(A.cycle_plan(s, C)["run"])

    def test_every_rung_stable(self):
        ladder = C["pilot"]["rungs_rps"]
        s = A.saturation([v(r, True, i + 1) for i, r in enumerate(ladder)], C)
        self.assertEqual(s["r_sat"], ladder[-1])
        self.assertIn("at or above", s["status"])
        self.assertFalse(A.cycle_plan(s, C)["overload_is_overload"])

    def test_budget_exhausted(self):
        s = A.saturation([v(3, True, 1), v(4, True, 2)], C)
        self.assertEqual((s["status"], s["r_sat"]), ("pilot budget exhausted", 4))

    def test_refusals(self):
        with self.assertRaises(A.Refused):
            A.saturation([v(4, True, 1)], C)
        with self.assertRaises(A.Refused):
            A.saturation([v(3, False, 1), v(4, False, 2)], C)
        with self.assertRaises(A.Refused):
            A.saturation([], C)

    def test_cycle_rates(self):
        p = A.cycle_plan({"status": "saturated", "r_sat": 12, "first_unstable": 14}, C)
        self.assertEqual((p["r_low"], p["r_over"]), (3.0, 18.0))
        self.assertEqual(p["segments"], "baseline:3:150,saturation:12:150,overload:18:90,recovery:3:240")
        p = A.cycle_plan({"status": "saturated", "r_sat": 4, "first_unstable": 5}, C)
        self.assertEqual(p["r_low"], 1.5)
        p = A.cycle_plan({"status": "saturated", "r_sat": 2.9, "first_unstable": 3}, C)
        self.assertFalse(p["run"])


class Recovery(unittest.TestCase):
    def test_recovery_time_is_the_first_of_three_windows(self):
        tmp = tempfile.mkdtemp()
        fixtures.cycle(f"{tmp}/cycle", recover_after_s=40)
        meta, rows = A.read_stage(f"{tmp}/cycle")
        segs = {s["name"]: s for s in meta["segments"]}
        base = A.stage_summary(rows, segs["baseline"], 15_000, C, 128)
        rec = A.recovery(rows, base, segs["recovery"], C, 128)
        self.assertTrue(rec["recovered"])
        self.assertEqual(rec["recovery_s"], 40)
        self.assertEqual(len(rec["windows"]), 12)

    def test_an_insufficient_window_is_not_recovered(self):
        tmp = tempfile.mkdtemp()
        fixtures.cycle(f"{tmp}/cycle", recover_after_s=0, baseline_rate=0.95)
        meta, rows = A.read_stage(f"{tmp}/cycle")
        segs = {s["name"]: s for s in meta["segments"]}
        base = A.stage_summary(rows, segs["baseline"], 15_000, C, 128)
        rec = A.recovery(rows, base, segs["recovery"], C, 128)
        thin = [w for w in rec["windows"] if w["sent"] < 15]
        # At 0.95 req/s a 20 s window expects 19 requests, so this seed's draw has thin windows to check.
        self.assertTrue(thin, "the fixture's draw has no thin window")
        self.assertTrue(all(w["state"] == "insufficient" for w in thin))


class Reporting(unittest.TestCase):
    def test_tpot(self):
        r = fixtures.row(0, "x", 0, ttft_ms=100.0, e2e_ms=1371.0)
        self.assertAlmostEqual(A.tpot_ms(r), (1371.0 - 1 - 100.0) / 127)

    def test_gpu_samples_are_parsed_and_assigned(self):
        tmp = tempfile.mkdtemp()
        with open(f"{tmp}/g.csv", "w") as f:
            f.write("timestamp, utilization.gpu [%], memory.used [MiB], memory.total [MiB]\n")
            f.write("2026/11/24 03:00:00.500, 87 %, 21000 MiB, 23028 MiB\n")
            f.write("2026/11/24 03:00:09.500, 12 %, 21010 MiB, 23028 MiB\n")
        g = A.read_gpu_samples(f"{tmp}/g.csv")
        self.assertEqual(len(g), 2)
        origin = g[0]["t"] - 0.5
        p = A.gpu_peaks(g, origin, {"startMs": 0, "endMs": 5000})
        self.assertEqual((p["samples"], p["util_pct"], p["mem_mib"]), (1, 87.0, 21000.0))
        self.assertEqual(A.gpu_peaks(g, origin, {"startMs": 20000, "endMs": 30000})["util_pct"], "not recorded")

    def test_overload_is_named_only_when_saturation_was_found(self):
        tmp = tempfile.mkdtemp()
        fixtures.cycle(f"{tmp}/cycle")
        os.makedirs(f"{tmp}/pilot")
        for flag, word in ((False, "not established as overload"), (True, "  overload: planned")):
            with open(f"{tmp}/pilot/cycle-plan.json", "w") as f:
                json.dump({"overload_is_overload": flag, "status": "x"}, f)
            text = A.render(A.report(C, tmp))
            self.assertIn(word, text)
            if not flag:
                self.assertNotIn("  overload:", text)


class Contract(unittest.TestCase):
    def test_document_and_json_agree_on_every_threshold(self):
        with open(os.path.join(HERE, "..", "CONTRACT.md")) as f:
            md = f.read()
        rows = re.findall(r"^\| `([a-z_]+\.[a-z_0-9]+)` \| ([^|]+) \|$", md, re.M)
        self.assertGreater(len(rows), 30)
        for key, value in rows:
            group, name = key.split(".")
            with self.subTest(key=key):
                self.assertEqual(float(value), float(C[group][name]))

    def test_rehearsal_scale_keeps_every_count(self):
        s = A.scaled(C, 0.1)
        for a, b in ((C["pilot"]["rungs_rps"][0] * C["pilot"]["rung_s"], s["pilot"]["rungs_rps"][0] * s["pilot"]["rung_s"]),
                     (C["cycle"]["low_min_rps"] * C["recovery"]["window_s"], s["cycle"]["low_min_rps"] * s["recovery"]["window_s"])):
            self.assertAlmostEqual(a, b, places=6)
        self.assertEqual(s["metrics"]["min_samples_p99"], C["metrics"]["min_samples_p99"])
        self.assertIsInstance(s["workload"]["request_timeout_s"], int)

    def test_seeds_follow_the_ladder(self):
        p = C["pilot"]
        self.assertEqual(p["rung_seeds"], [6730 + k for k in range(1, len(p["rungs_rps"]) + 1)])


if __name__ == "__main__":
    unittest.main()
