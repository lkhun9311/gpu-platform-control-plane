"""Tests pilot_report.py on hand-built cells.

    python3 hack/prospective-pilot/test_pilot_report.py
"""

import json
import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pilot_report as pr  # noqa: E402

ORIGIN = 1_000_000_000_000


def write(path, recs):
    with open(path, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")


class Cell:
    """A one-premium, one-contender cell whose every record can be bent by a test."""

    def __init__(self, d, arm="off", rep=1):
        self.d, self.tag = d, "%s-%d" % (arm, rep)
        self.rows = [
            {"requestId": "pp-A-off-1-0", "tenant": "premium-1", "scheduledOffsetMs": 0, "replayOriginUnixNanos": ORIGIN,
             "sendUnixNanos": ORIGIN + 100_000, "firstTokenUnixNanos": ORIGIN + 30_000_000, "returnedUnixNanos": ORIGIN + 50_000_000,
             "httpStatus": 200, "engineOutputTokens": 64, "exactInputTokens": 68},
            {"requestId": "pp-A-off-1-1", "tenant": "standard-noisy", "scheduledOffsetMs": 1, "replayOriginUnixNanos": ORIGIN,
             "sendUnixNanos": ORIGIN + 1_100_000, "returnedUnixNanos": ORIGIN + 40_000_000,
             "httpStatus": 200, "engineOutputTokens": 16, "exactInputTokens": 100},
        ]
        self.gw = []
        for r in self.rows:
            arr = r["sendUnixNanos"] + 500_000
            self.gw.append({"ev": "arrive", "requestId": r["requestId"], "arrivedUnixNanos": arr})
            self.gw.append({"ev": "done", "requestId": r["requestId"], "arrivedUnixNanos": arr, "recordedUnixNanos": arr + 1000,
                            "decidedUnixNanos": arr + 2000, "handoffUnixNanos": arr + 3000, "firstContentUnixNanos": arr + 20_000_000,
                            "endedUnixNanos": arr + 30_000_000})
        # Steps: contender prefill 100 in one step, premium prefill 68, then contender decodes; the fence last.
        a = [0, ORIGIN, 0]
        self.steps = [{"ev": "add", "id": "chatcmpl-pp-A-off-1-1", "prompt": 100, "seq": 1},
                      {"ev": "add", "id": "chatcmpl-pp-A-off-1-0", "prompt": 68, "seq": 2},
                      {"ev": "sched", "step": 1, "t0": 1_000_000, "anchor": a, "tokens": {"chatcmpl-pp-A-off-1-1": 100}, "computed": {"chatcmpl-pp-A-off-1-1": 0}, "seq": 3},
                      {"ev": "sched", "step": 2, "t0": 2_000_000, "anchor": a, "tokens": {"chatcmpl-pp-A-off-1-0": 68, "chatcmpl-pp-A-off-1-1": 1}, "computed": {"chatcmpl-pp-A-off-1-0": 0, "chatcmpl-pp-A-off-1-1": 100}, "seq": 4},
                      {"ev": "sched", "step": 3, "t0": 60_000_000, "anchor": a, "tokens": {"chatcmpl-pp-A-off-1-1": 1}, "computed": {"chatcmpl-pp-A-off-1-1": 101}, "seq": 5},
                      {"ev": "add", "id": "chatcmpl-fence-off-1", "prompt": 1, "seq": 6},
                      {"ev": "sched", "step": 4, "t0": 70_000_000, "anchor": a, "tokens": {"chatcmpl-fence-off-1": 1}, "computed": {"chatcmpl-fence-off-1": 0}, "seq": 7},
                      {"ev": "terminal", "seq_written": 7, "seq_produced": 7, "buffered": 0}]
        self.iters = [100, 69, 1, 1]

    def save(self):
        write(os.path.join(self.d, "raw-%s.jsonl" % self.tag), self.rows)
        write(os.path.join(self.d, "gateway-record-%s.jsonl" % self.tag), self.gw)
        write(os.path.join(self.d, "step-log-%s.jsonl" % self.tag), self.steps)
        with open(os.path.join(self.d, "engine-log-%s.txt" % self.tag), "w") as f:
            for i, n in enumerate(self.iters):
                f.write("INFO 10-08 13:00:00 [loggers.py:182] Engine 000: Iteration(%d): 1 context requests, %d context tokens, "
                        "0 generation requests, 0 generation tokens, iteration elapsed time: 1.00 ms\n" % (i, n))
        return pr.cell_report(self.d, *self.tag.rsplit("-", 1)[:1], int(self.tag.rsplit("-", 1)[1]))


class PilotReportTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def test_the_repository_nearest_rank_quantile(self):
        self.assertEqual(pr.nearest_rank(list(range(1, 101)), 0.99), 99)
        self.assertEqual(pr.nearest_rank(list(range(1, 102)), 0.99), 100)

    def test_a_complete_cell_is_eligible_with_its_lag_and_work(self):
        c = Cell(self.d).save()
        self.assertTrue(c["eligible"], c["problems"])
        self.assertAlmostEqual(c["lag_ms"]["p50"], 0.6, places=6)
        # The window ends at the premium's return (50 ms); the decode at 60 ms is outside it.
        self.assertEqual(c["work"]["p"], 1.0)
        self.assertAlmostEqual(c["work"]["q"], 1 / 16)

    # Mutation that turns this red: drop the missing-record count.
    def test_a_client_row_without_a_gateway_record_is_ineligible(self):
        cell = Cell(self.d)
        cell.gw = [g for g in cell.gw if g["requestId"] != "pp-A-off-1-1"]
        c = cell.save()
        self.assertFalse(c["eligible"])
        self.assertTrue(any("no gateway record" in p for p in c["problems"]), c["problems"])

    def test_a_refusal_before_the_body_is_ineligible(self):
        cell = Cell(self.d)
        for g in cell.gw:
            if g["requestId"] == "pp-A-off-1-1" and g["ev"] == "done":
                del g["arrivedUnixNanos"]
        c = cell.save()
        self.assertTrue(any("refused before their body" in p for p in c["problems"]), c["problems"])

    # Mutation that turns this red: stop comparing token totals step by step.
    def test_a_skipped_step_misaligns_with_the_engine(self):
        cell = Cell(self.d)
        cell.iters = [100, 69, 2, 1]
        c = cell.save()
        self.assertTrue(any("iteration 2 holds 2" in p for p in c["problems"]), c["problems"])

    def test_a_log_without_the_fence_is_ineligible(self):
        cell = Cell(self.d)
        cell.steps = [s for s in cell.steps if "fence" not in json.dumps(s)]
        c = cell.save()
        self.assertTrue(any("fence never reached" in p for p in c["problems"]), c["problems"])

    # Mutation that turns this red: count every scheduled token of a prefilling request as prefill.
    def test_prefill_and_decode_are_split_at_the_prompt(self):
        cell = Cell(self.d)
        # One step carrying the last 10 prompt tokens and, past the prompt, 2 more: 10 prefill, 2 decode.
        cell.steps[2]["tokens"]["chatcmpl-pp-A-off-1-1"] = 90
        cell.steps[3]["tokens"]["chatcmpl-pp-A-off-1-1"] = 12
        cell.steps[3]["computed"]["chatcmpl-pp-A-off-1-1"] = 90
        cell.iters = [90, 80, 1, 1]
        c = cell.save()
        self.assertEqual(c["work"]["p"], 1.0)
        self.assertAlmostEqual(c["work"]["q"], 2 / 16)

    def test_an_uncertain_premium_tail_has_an_infinite_width(self):
        values = [(10.0, False)] * 98 + [(500.0, True)] * 2
        self.assertEqual(pr.pooled_p99(values, 0.0), 10.0)
        self.assertTrue(math.isinf(pr.pooled_p99(values, math.inf)))
        self.assertTrue(math.isinf(pr.width(10.0, math.inf)))


def add_premium(cell, n, lag_ns=500_000, ttft_ns=20_000_000, start=10):
    """n more premium rows, each arriving lag_ns after its scheduled instant and answered ttft_ns after arrival."""
    for i in range(start, start + n):
        rid = "pp-A-%s-%d" % (cell.tag, i)
        sched = ORIGIN + i * 1_000_000
        cell.rows.append({"requestId": rid, "tenant": "premium-1", "scheduledOffsetMs": i, "replayOriginUnixNanos": ORIGIN,
                          "sendUnixNanos": sched, "firstTokenUnixNanos": sched + lag_ns + ttft_ns + 1000,
                          "returnedUnixNanos": ORIGIN + 50_000_000, "httpStatus": 200, "engineOutputTokens": 64, "exactInputTokens": 68})
        arr = sched + lag_ns
        cell.gw.append({"ev": "arrive", "requestId": rid, "arrivedUnixNanos": arr})
        cell.gw.append({"ev": "done", "requestId": rid, "arrivedUnixNanos": arr, "recordedUnixNanos": arr + 1000, "decidedUnixNanos": arr + 2000,
                        "handoffUnixNanos": arr + 3000, "firstContentUnixNanos": arr + ttft_ns, "endedUnixNanos": arr + ttft_ns})


def full_stage(d, stage, tweak=None):
    """Every registered cell of a stage, with both timing records; tweak(cell) may bend any cell before it is saved."""
    os.makedirs(d, exist_ok=True)
    t = ["cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done"]
    u = ["cell\tarm\trep\thook_start_utc\thook_end_utc\thook_s"]
    n = 0
    for arm in pr.STAGE_ARMS[stage]:
        for rep in range(1, pr.BLOCKS + 1):
            n += 1
            c = Cell(d, arm, rep)
            if tweak:
                tweak(c)
            c.save()
            t.append("%d\t%s\t%d\tcompleted\t2026-10-08T09:%02d:00Z\tb\t%d\t0\t%d" % (n, arm, rep, 25 + n, 400 + n, n))
            u.append("%d\t%s\t%d\ta\tb\t%d" % (n, arm, rep, 10))
    for name, lines in (("cell-timings.tsv", t), ("cell-uploads.tsv", u)):
        with open(os.path.join(d, name), "w") as f:
            f.write("\n".join(lines) + "\n")


class PilotReportReviewTest(unittest.TestCase):
    """The review of 97ae105's eight findings, each pinned."""

    def setUp(self):
        self.d = tempfile.mkdtemp()

    # Finding 1. Mutation that turns it red: take P's scheduled width and S's arrival width instead of each box.
    def test_each_arm_contributes_its_crossed_box(self):
        for arm in ("prospective", "static-cap"):
            c = Cell(self.d, arm, 1)
            add_premium(c, 200, lag_ns=4_000_000, ttft_ns=16_000_000)
            c.save()
        rep = pr.stage_report(self.d)
        box = rep["arms"]["prospective"]["width_box"]
        # Arrival p99 16 ms with nothing uncertain at 4 ms of lag; scheduled p99 20 ms: ln(20/16).
        self.assertAlmostEqual(box, math.log(20 / 16), places=2)
        self.assertEqual(rep["arms"]["prospective"]["width_sched"], 0.0)
        self.assertAlmostEqual(rep["ps_half_width"], math.log(20 / 16), places=2)

    # Finding 2. Mutation that turns it red: read the worst cell's p99.9 instead of the arm's pooled one.
    def test_lag_quantiles_pool_an_arms_blocks(self):
        def tweak(c):
            add_premium(c, 1000)
            if c.tag == "off-2":
                for g in c.gw[-4:]:
                    g["arrivedUnixNanos"] += 100_000_000
        full_stage(os.path.join(self.d, "A"), "A", tweak)
        full_stage(os.path.join(self.d, "B"), "B", lambda c: add_premium(c, 1000))
        f = pr.formulas(os.path.join(self.d, "A"), os.path.join(self.d, "B"))
        self.assertTrue(f["available"], f.get("why"))
        cell_p999 = max(c["lag_ms"]["p999"] for c in pr.stage_report(os.path.join(self.d, "A"))["cells"])
        self.assertGreater(cell_p999, 100)
        self.assertLess(f["p999_lag_ms_max_pooled_arm"], 5)
        self.assertEqual(f["L_ms"], 5.0)
        self.assertEqual(f["arm_time_s"], 400 + 12 + 10)

    # Bring-up is LaunchTime to the first cell's start, 09:00 to 09:26 in the earlier stage and 25 minutes in the
    # other; the tail is the matrix's return to the marker's upload. The larger of each is taken.
    # Mutation that turns it red: take the smaller stage's bring-up, or drop the 1.25.
    def test_the_session_length_and_its_deadlines_follow_the_frozen_formula(self):
        full_stage(os.path.join(self.d, "A"), "A")
        full_stage(os.path.join(self.d, "B"), "B")
        for st, launch, tail in (("A", "2026-10-08T09:00:00+00:00", 120), ("B", "2026-10-08T09:01:00+00:00", 90)):
            ret = int(pr.utc_epoch("2026-10-08T12:00:00Z"))
            with open(os.path.join(self.d, st, "session-timing.tsv"), "w") as f:
                f.write("launch_time_utc\tmatrix_returned_epoch\tmarker_uploaded_utc\n%s\t%d\t2026-10-08T12:%02d:%02d+00:00\n"
                        % (launch, ret, tail // 60, tail % 60))
        f = pr.formulas(os.path.join(self.d, "A"), os.path.join(self.d, "B"))
        # A's first cell starts 09:26 after a 09:00 launch: 1,560 s. B's starts 09:26 after 09:01: 1,500 s.
        self.assertEqual(f["bring_up_s"], 1560)
        self.assertEqual(f["session_tail_s"], 120)
        # The largest complete cell is B's twelfth: 412 s plus a 10 s upload.
        self.assertEqual(f["arm_time_s"], 422)
        self.assertEqual(f["main_session_length_s"], math.ceil((1560 + 12 * 422 + 120) * 1.25))
        self.assertEqual(f["acquisition_deadline_s"], f["hard_stop_s"] - 360)
        self.assertEqual(f["study_deadline_s"], f["hard_stop_s"] + 1200)

    def test_a_missing_session_stamp_makes_the_session_length_unavailable(self):
        full_stage(os.path.join(self.d, "A"), "A")
        full_stage(os.path.join(self.d, "B"), "B")
        f = pr.formulas(os.path.join(self.d, "A"), os.path.join(self.d, "B"))
        self.assertIsNone(f["main_session_length_s"])
        self.assertIn("session-timing.tsv", f["main_session_length_why"])

    # Finding 3. Mutation that turns it red: read the inventory from the raw files that exist.
    def test_a_missing_registered_cell_makes_the_formulas_unavailable(self):
        full_stage(os.path.join(self.d, "A"), "A")
        full_stage(os.path.join(self.d, "B"), "B")
        os.remove(os.path.join(self.d, "B", "raw-static-cap-3.jsonl"))
        f = pr.formulas(os.path.join(self.d, "A"), os.path.join(self.d, "B"))
        self.assertFalse(f["available"])
        self.assertIn("static-cap", f["why"])

    def test_a_missing_upload_row_makes_the_arm_time_unavailable(self):
        full_stage(os.path.join(self.d, "A"), "A")
        full_stage(os.path.join(self.d, "B"), "B")
        path = os.path.join(self.d, "B", "cell-uploads.tsv")
        with open(path) as f:
            lines = f.read().splitlines()
        with open(path, "w") as f:
            f.write("\n".join(lines[:-1]) + "\n")
        f = pr.formulas(os.path.join(self.d, "A"), os.path.join(self.d, "B"))
        self.assertIsNone(f["arm_time_s"])
        self.assertIn("prospective-3", f["arm_time_why"])

    # Finding 4.
    def test_a_premium_success_without_its_flush_stamp_is_ineligible(self):
        cell = Cell(self.d)
        del cell.gw[1]["firstContentUnixNanos"]
        c = cell.save()
        self.assertTrue(any("flushed first-content" in p for p in c["problems"]), c["problems"])

    # Finding 5.
    def test_a_missing_engine_log_is_ineligible(self):
        cell = Cell(self.d)
        cell.save()
        os.remove(os.path.join(self.d, "engine-log-off-1.txt"))
        c = pr.cell_report(self.d, "off", 1)
        self.assertTrue(any("no engine log" in p for p in c["problems"]), c["problems"])

    def test_a_contender_scheduled_without_its_add_record_is_ineligible(self):
        cell = Cell(self.d)
        cell.steps = [s for s in cell.steps if not (s.get("ev") == "add" and "off-1-1" in s["id"])]
        for i, s in enumerate(cell.steps[:-1], 1):
            s["seq"] = i
        cell.steps[-1].update(seq_written=len(cell.steps) - 1, seq_produced=len(cell.steps) - 1)
        c = cell.save()
        self.assertTrue(any("no add record" in p for p in c["problems"]), c["problems"])

    # Finding 6.
    def test_a_premium_row_without_its_return_stamp_is_ineligible(self):
        cell = Cell(self.d)
        del cell.rows[0]["returnedUnixNanos"]
        c = cell.save()
        self.assertTrue(any("no return stamp" in p for p in c["problems"]), c["problems"])
        self.assertIsNone(c["work"]["p"])

    # A request is classified as meeting an upload by its scheduled instant or its scheduled-to-arrival interval.
    # Here the premium is scheduled at the origin and arrives 0.6 ms later, and the contender 1 ms later: an upload
    # from 0.2 to 0.4 ms meets only the first. Mutation that turns it red: classify by the send instead.
    def test_lag_is_reported_apart_for_requests_that_met_an_upload(self):
        cell = Cell(self.d)
        cell.save()
        with open(os.path.join(self.d, "sidecar-uploads.tsv"), "w") as f:
            f.write("cell\ttrigger\tstart_unix_ns\tend_unix_ns\thook_rc\tbytes\n")
            f.write("off-1\tinterval\t%d\t%d\t0\t100\n" % (ORIGIN + 200_000, ORIGIN + 400_000))
            f.write("off-2\tinterval\t%d\t%d\t0\t100\n" % (ORIGIN, ORIGIN + 10_000_000))
        c = pr.cell_report(self.d, "off", 1)
        self.assertEqual(c["sidecar"]["uploads"], 1)
        self.assertEqual(c["sidecar"]["lag_ms_overlapping_an_upload"]["n"], 1)
        self.assertAlmostEqual(c["sidecar"]["lag_ms_overlapping_an_upload"]["max"], 0.6, places=6)

    # Finding 8.
    def test_an_infinite_comparator_bound_keeps_its_infinity(self):
        self.assertEqual(pr.crossed_log_ratio(20.0, math.inf), -math.inf)
        self.assertEqual(pr.crossed_log_ratio(math.inf, 20.0), math.inf)
        self.assertIsNone(pr.crossed_log_ratio(math.inf, math.inf))


if __name__ == "__main__":
    unittest.main()
