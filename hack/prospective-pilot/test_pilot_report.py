"""Tests pilot_report.py on hand-built cells.

    python3 hack/prospective-pilot/test_pilot_report.py
"""

import hashlib
import json
import math
import os
import sys
import tempfile
import unittest
from unittest import mock

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
             "httpStatus": 200, "engineOutputTokens": 64, "outputTokens": 64, "streamTerminated": True, "exactInputTokens": 68},
            {"requestId": "pp-A-off-1-1", "tenant": "standard-noisy", "scheduledOffsetMs": 1, "replayOriginUnixNanos": ORIGIN,
             "sendUnixNanos": ORIGIN + 1_100_000, "returnedUnixNanos": ORIGIN + 40_000_000,
             "httpStatus": 200, "engineOutputTokens": 16, "outputTokens": 16, "streamTerminated": True, "exactInputTokens": 100},
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
                          "returnedUnixNanos": ORIGIN + 50_000_000, "httpStatus": 200, "engineOutputTokens": 64, "outputTokens": 64,
                          "streamTerminated": True, "exactInputTokens": 68})
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

    # Every registered gate is evaluated and none is dropped: the first published list left out the P/O screen.
    # Mutation that turns it red: drop the P/O gate from gates().
    def test_every_registered_gate_is_evaluated(self):
        full_stage(os.path.join(self.d, "A"), "A")
        full_stage(os.path.join(self.d, "B"), "B")
        names = [g["gate"] for g in pr.gates(os.path.join(self.d, "A"), os.path.join(self.d, "B"), 13)]
        for want in ("A contention", "A loss", "A engagement", "A P/O", "A release timing", "A restart",
                     "A dispatch fidelity", "A capture", "B loss", "B width", "B margin", "B informative bound", "B re-stamp"):
            self.assertTrue(any(n.startswith(want) for n in names), want)
        # A gate the evidence cannot evaluate says so rather than passing.
        restart = [g for g in pr.gates(os.path.join(self.d, "A"), os.path.join(self.d, "B"), 13) if g["gate"].startswith("A restart")][0]
        self.assertIsNone(restart["would_fire"])

    # Each premium inter-token gap is pooled as recorded, so one long gap among short ones sets the p99.
    def test_premium_inter_token_gaps_are_pooled_one_by_one(self):
        cell = Cell(self.d)
        cell.rows[0]["contentGapsMicros"] = [10_000] * 62 + [160_000]
        cell.save()
        rep = pr.stage_report(self.d)
        g = rep["arms"]["off"]["premium_inter_token_gap_ms"]
        self.assertEqual(g["n"], 63)
        self.assertEqual(g["max"], 160.0)

    # A stream that ended without [DONE] is not a success (v25 review, finding 1).
    def test_an_unterminated_stream_is_not_a_success(self):
        row = {"httpStatus": 200, "engineOutputTokens": 64, "streamTerminated": False}
        self.assertFalse(pr.full_output(row, 64))

    # A premium success with fewer gaps than frames less one is missing evidence, not fast gaps.
    def test_short_gap_evidence_is_a_problem_not_a_fast_gap(self):
        cell = Cell(self.d)
        cell.rows[0]["contentGapsMicros"] = [10_000] * 10
        c = cell.save()
        self.assertTrue(any("fewer inter-token gaps" in p for p in c["problems"]), c["problems"])
        self.assertEqual(c["premium_gap_evidence"]["short"], 1)

    # The shared window ends at the last scheduled instant, not the arm's last premium return. In the fixture the last
    # request is scheduled at 1 ms and the contender's prefill step starts at 1 ms, so it falls outside the shared
    # window, while the arm's own window, to the premium's return at 50 ms, counts it (v25 review, finding 3).
    # Mutation that turns it red: end the shared window at the last premium return.
    def test_retained_work_has_a_window_shared_by_every_arm(self):
        c = Cell(self.d).save()
        self.assertEqual(c["work"]["p_shared_window"], 0.0)
        self.assertEqual(c["work"]["p"], 1.0)

    # Finding 8.
    def test_an_infinite_comparator_bound_keeps_its_infinity(self):
        self.assertEqual(pr.crossed_log_ratio(20.0, math.inf), -math.inf)
        self.assertEqual(pr.crossed_log_ratio(math.inf, 20.0), math.inf)
        self.assertIsNone(pr.crossed_log_ratio(math.inf, math.inf))


def diag_block(d, rep, hold_ttft_ns=20_000_000, prom=True, blocks=(1, 2, 3)):
    """Every diagnostic cell of the given blocks, R1 once; hold-cap's premium first content at hold_ttft_ns after
    arrival, every other arm's at 20 ms. Contenders carry their first token and fifteen gaps, so they can be timed."""
    cells = [("R1", 1, 20_000_000)] if 1 in blocks else []
    cells += [(arm, b, hold_ttft_ns if arm == "hold-cap" else 20_000_000)
              for b in blocks for arm in ("off", "hold", "cap", "hold-cap")]
    for arm, b, ttft in cells:
        c = Cell(d, arm, b)
        c.rows[0]["contentGapsMicros"] = [10_000] * 63
        c.rows[1]["firstTokenUnixNanos"] = ORIGIN + 30_000_000
        c.rows[1]["contentGapsMicros"] = [500] * 15
        for g in c.gw:
            if g["ev"] == "done" and g["requestId"] == "pp-A-off-1-0":
                g["firstContentUnixNanos"] = g["arrivedUnixNanos"] + ttft
        c.save()
        if prom:
            for phase in ("before", "after"):
                with open(os.path.join(d, "engine-metrics-%s-%d-%s.prom" % (arm, b, phase)), "w") as f:
                    f.write('vllm:num_preemptions_total{engine="0"} 0.0\n')


class DiagnosticTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    # Every line holds in all three blocks: hold-cap's premium tail at half of off's.
    # Mutation that turns it red: require two blocks instead of three, or drop a line.
    def test_a_candidate_meeting_every_limit_in_three_blocks_is_observed(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        v = pr.diagnostic(self.d)
        self.assertTrue(v["verdict"].startswith("observed on these traces"), v["verdict"])

    def test_a_tail_no_better_than_off_is_not_met(self):
        diag_block(self.d, 1)
        v = pr.diagnostic(self.d)
        self.assertTrue(v["verdict"].startswith("not met: block 1: premium p99"), v["verdict"])

    # A missing block is inconclusive, never a pass (v25 review, finding 6).
    def test_a_missing_block_is_inconclusive(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000, blocks=(1, 2))
        v = pr.diagnostic(self.d)
        self.assertTrue(v["verdict"].startswith("inconclusive: block 3 is incomplete"), v["verdict"])

    # An unread preemption counter makes the block unscorable: inconclusive, neither a pass nor a measured failure
    # (v24 review, finding 9; review of 46de41a).
    def test_a_missing_preemption_read_is_inconclusive_not_a_failure(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000, prom=False)
        v = pr.diagnostic(self.d)
        self.assertTrue(v["verdict"].startswith("inconclusive"), v["verdict"])

    # A hold-timeout refusal observed in a block whose off cell never ran is still a failure (review of 46de41a).
    def test_an_observed_failure_survives_a_missing_companion(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        os.remove(os.path.join(self.d, "raw-off-2.jsonl"))
        path = os.path.join(self.d, "gateway-record-hold-cap-2.jsonl")
        recs = pr.jsonl(path)
        for r in recs:
            if r["ev"] == "done" and r["requestId"] == "pp-A-off-1-1":
                r["reason"] = "serial_prefill_hold_timeout"
        write(path, recs)
        v = pr.diagnostic(self.d)
        self.assertEqual(v["verdict"], "not met: block 2: hold-timeout refusals")

    # A premium success with no gap evidence at all makes the block inconclusive, not scored on the others.
    def test_absent_gap_evidence_is_inconclusive(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        path = os.path.join(self.d, "raw-hold-cap-1.jsonl")
        rows = pr.jsonl(path)
        rows[0].pop("contentGapsMicros")
        write(path, rows)
        v = pr.diagnostic(self.d)
        self.assertTrue(v["verdict"].startswith("inconclusive") and "without gap evidence" in v["verdict"], v["verdict"])

    # A cell the matrix refused is not scored as passing, whatever its files hold (final review, finding 1).
    def test_a_refused_cell_is_not_scored_as_passing(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        with open(os.path.join(self.d, "cell-refused-hold-cap-3.txt"), "w") as f:
            f.write("REFUSED hold-cap rep 3 after its capture: a request reached the scheduler at priority 99\n")
        v = pr.diagnostic(self.d)
        self.assertTrue(v["verdict"].startswith("inconclusive") and "hold-cap eligible" in v["verdict"], v["verdict"])

    # An invalid block leaves its comparisons unscored rather than failed: a 60 ms dispatch lag on hold-cap's premium
    # request breaks the ceiling, and must not read as the treatment failing (final review, finding 2).
    def test_an_invalid_block_does_not_fail_the_treatment(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        path = os.path.join(self.d, "gateway-record-hold-cap-2.jsonl")
        recs = pr.jsonl(path)
        for r in recs:
            if r["requestId"] == "pp-A-off-1-0":
                r["arrivedUnixNanos"] += 60_000_000
        write(path, recs)
        v = pr.diagnostic(self.d)
        self.assertTrue(v["verdict"].startswith("inconclusive"), v["verdict"])

    # Completion is timed at the last content, not the replay's return: a contender whose last token came at 31 ms
    # and whose return waited 31 s for [DONE] still completed (final review, finding 3).
    def test_completion_is_timed_at_the_last_content(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        path = os.path.join(self.d, "raw-hold-cap-1.jsonl")
        rows = pr.jsonl(path)
        rows[1]["returnedUnixNanos"] = ORIGIN + 31_000_000_000
        write(path, rows)
        done, offered, lat, _, _ = pr.contender_outcomes(self.d, "hold-cap-1")
        self.assertEqual((done, offered), (1, 1))
        self.assertLess(lat[0], 100)

    # A contender whose gaps are fewer than its frames cannot be timed at its last content: summing what is there would
    # end it early, so it is untimed, as a premium success with short gaps is (v26 review, finding 2).
    # Mutation that turns it red: drop the length check on the contender's gaps.
    def test_a_contender_with_short_gaps_is_untimed(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        path = os.path.join(self.d, "raw-hold-cap-1.jsonl")
        rows = pr.jsonl(path)
        rows[1]["contentGapsMicros"] = rows[1]["contentGapsMicros"][:3]
        write(path, rows)
        done, offered, _, _, untimed = pr.contender_outcomes(self.d, "hold-cap-1")
        self.assertEqual((done, offered, untimed), (0, 1, 1))

    # A contender success with no first-token stamp is untimed, not a failure (v26 review, A12).
    # Mutation that turns it red: require the first-token stamp before counting a success as untimed.
    def test_a_contender_without_its_first_token_is_untimed(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        path = os.path.join(self.d, "raw-hold-cap-1.jsonl")
        rows = pr.jsonl(path)
        rows[1].pop("firstTokenUnixNanos")
        write(path, rows)
        done, offered, lat, _, untimed = pr.contender_outcomes(self.d, "hold-cap-1")
        self.assertEqual((done, offered, untimed, lat), (0, 1, 1, []))

    # The truncated gaps are bounded upward: fifteen gaps add fifteen microseconds to the end (v26 review, A15).
    # Mutation that turns it red: sum the gaps alone.
    def test_truncated_gaps_are_bounded_upward(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        _, _, lat, _, _ = pr.contender_outcomes(self.d, "hold-cap-1")
        # First token 29 ms after the scheduled instant (offset 1 ms), fifteen gaps of 500 µs, plus 15 µs.
        self.assertAlmostEqual(lat[0], 29.0 + 7.5 + 0.015, places=6)

    # A step with no clock anchor makes the cell ineligible rather than placing its work at time zero (v26 review, B8).
    # Mutation that turns it red: default a missing anchor to [0, 0, 0] again.
    def test_a_step_without_its_anchor_is_ineligible(self):
        c = Cell(self.d)
        del c.steps[2]["anchor"]
        rep = c.save()
        self.assertFalse(rep["eligible"])
        self.assertTrue(any("clock anchor" in p for p in rep["problems"]), rep["problems"])

    # Six cells are not the diagnostic: R1, hold and cap missing make it inconclusive (final review, finding 4).
    def test_the_pairs_alone_are_not_the_diagnostic(self):
        diag_block(self.d, 1, hold_ttft_ns=10_000_000)
        for c in ["R1-1"] + ["%s-%d" % (a, b) for b in (1, 2, 3) for a in ("hold", "cap")]:
            os.remove(os.path.join(self.d, "raw-%s.jsonl" % c))
        v = pr.diagnostic(self.d)
        self.assertTrue(v["verdict"].startswith("inconclusive: cells not acquired: R1-1"), v["verdict"])

    # The diagnostic scores uncertainty at its own L of 13 ms: a 6 ms lag is trusted there and not at the pilot's 5.
    def test_the_diagnostic_scores_uncertainty_at_13_ms(self):
        cell = Cell(self.d)
        for g in cell.gw:
            if g["requestId"] == "pp-A-off-1-0":
                g["arrivedUnixNanos"] += 6_000_000
        cell.save()
        self.assertEqual(pr.cell_report(self.d, "off", 1)["premium"]["uncertain"], 1)
        self.assertEqual(pr.cell_report(self.d, "off", 1, L=pr.DIAG_L_MS)["premium"]["uncertain"], 0)


# Every fixture cell replays this two-request trace; the tests freeze its hash in place of the real seeds' checksums.
FIXTURE_TRACE = [{"index": 0, "offsetMs": 0, "tenant": "premium-1"}, {"index": 1, "offsetMs": 1, "tenant": "standard-noisy"}]
FIXTURE_HASH = hashlib.sha256("".join(json.dumps(r) + "\n" for r in FIXTURE_TRACE).encode()).hexdigest()


def frontier_block(d, ttft=None, extra_decode=(), skip=()):
    """Every v26 cell: manifests carrying the frozen study, seed and checksum, a trace of the cell's two rows, and each
    contender decision under its arm's mode. ttft maps an arm to its premium first content after arrival, 20 ms by
    default; extra_decode lists arms whose contenders get one more decode step in the shared window."""
    ttft = ttft or {}
    for c in pr.FRONTIER_CELLS:
        if c in skip:
            continue
        arm, b = c.rsplit("-", 1)[0], int(c.rsplit("-", 1)[1])
        cell = Cell(d, arm, b)
        cell.rows[0]["contentGapsMicros"] = [10_000] * 63
        cell.rows[1]["firstTokenUnixNanos"] = ORIGIN + 30_000_000
        cell.rows[1]["contentGapsMicros"] = [500] * 15
        reason = {"hold-cap": "serial_prefill_free", "off": "admission_off", "R1": "admission_off"}.get(arm, "fixed_spacing_free")
        # The steps placed before the block's last scheduled instant, so their work falls in the shared window.
        for r in cell.steps:
            if r.get("anchor"):
                r["anchor"] = [0, ORIGIN - 100_000_000, 0]
        for g in cell.gw:
            if g["ev"] == "done":
                g["decision"], g["reason"] = "admit", reason
                if g["requestId"] == "pp-A-off-1-0":
                    g["firstContentUnixNanos"] = g["arrivedUnixNanos"] + ttft.get(arm, 20_000_000)
        if arm in extra_decode:
            # One more contender decode before the fence, with the engine's own log agreeing.
            a = [0, ORIGIN - 100_000_000, 0]
            cell.steps.insert(5, {"ev": "sched", "step": 4, "t0": 65_000_000, "anchor": a, "tokens": {"chatcmpl-pp-A-off-1-1": 1},
                                  "computed": {"chatcmpl-pp-A-off-1-1": 102}})
            seq = 0
            for r in cell.steps:
                if r["ev"] != "terminal":
                    seq += 1
                    r["seq"] = seq
            cell.steps[-3]["step"], cell.steps[-2]["step"] = 4, 5
            cell.steps[-1].update({"seq_written": seq, "seq_produced": seq})
            cell.iters = [100, 69, 1, 1, 1]
        seed = pr.FRONTIER_SEEDS[b]
        want = pr.FRONTIER_CHECKSUMS[seed][1 if arm == "R1" else 0]
        for i, r in enumerate(cell.rows):
            r.update({"index": i, "study": pr.FRONTIER_STUDY, "arm": arm, "traceChecksum": want})
        cell.save()
        with open(os.path.join(d, "manifest-%s.yaml" % c), "w") as f:
            f.write('arm: "%s"\nseed: %d\nstudy: %s\ntraceChecksum: %s\n' % (arm, seed, pr.FRONTIER_STUDY, want))
        write(os.path.join(d, "trace-%s.jsonl" % c), FIXTURE_TRACE)
        for phase in ("before", "after"):
            with open(os.path.join(d, "engine-metrics-%s-%s.prom" % (c, phase)), "w") as f:
                f.write('vllm:num_preemptions_total{engine="0"} 0.0\n')


class FrontierTest(unittest.TestCase):
    # v26's scorer on built cells (docs/superpowers/specs/2026-10-10-v26-adversarial-review.md).
    def setUp(self):
        self.d = tempfile.mkdtemp()
        patch = mock.patch.dict(pr.FRONTIER_CHECKSUMS, {s: (FIXTURE_HASH, FIXTURE_HASH) for s in pr.FRONTIER_CHECKSUMS})
        patch.start()
        self.addCleanup(patch.stop)

    def v(self):
        return pr.frontier(self.d)["verdict"]

    # Hold-cap at 10 ms against 20 ms everywhere else: it beats every fixed arm and off by more than 15%.
    # Mutation that turns it red: compare against the widest fixed arm only, or drop the off comparison.
    def test_hold_cap_beating_every_fixed_arm(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        self.assertEqual(self.v(), "observed on these traces: hold-cap beat every admissible fixed spacing")

    # Hold-cap admissible but no better than off: not met, whatever the fixed arms did (A5).
    # Mutation that turns it red: drop the premium-against-off line.
    def test_hold_cap_no_better_than_off_is_not_met(self):
        frontier_block(self.d, ttft={a: 30_000_000 for a in pr.FRONTIER_FIXED})
        self.assertEqual(self.v(), "not met: hold-cap did not cut the premium tail 15% below off's")

    # One fixed arm at 5 ms beats hold-cap at 10 ms, and it is named (A6).
    def test_a_fixed_arm_beating_hold_cap_is_named(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000, "fixed-1.70": 5_000_000})
        self.assertEqual(self.v(), "observed on these traces: fixed-1.70 beat hold-cap")

    # Within 15% either way is "not established", never a fixed-arm win (A5 of the earlier draft, finding 5).
    def test_a_near_tie_is_not_established(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000, "fixed-1.62": 11_000_000, "fixed-1.66": 11_000_000,
                                     "fixed-1.70": 11_000_000, "fixed-1.74": 11_000_000})
        self.assertEqual(self.v(), "not established: neither hold-cap nor fixed-1.62 was 15% below the other")

    # A hold refusal makes an arm inadmissible; with every fixed arm refused, hold-cap alone met the limits.
    # Mutation that turns it red: ignore the fixed-spacing hold-timeout reason.
    def test_no_admissible_fixed_arm(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        for arm in pr.FRONTIER_FIXED:
            path = os.path.join(self.d, "gateway-record-%s-2.jsonl" % arm)
            recs = pr.jsonl(path)
            for r in recs:
                if r["ev"] == "done" and r["requestId"] == "pp-A-off-1-1":
                    r["reason"] = "fixed_spacing_hold_timeout"
            write(path, recs)
        self.assertEqual(self.v(), "observed on these traces: hold-cap met the limits and no fixed spacing in the grid did")

    # Hold-cap's own refusal is verdict 2, naming the line (A19).
    def test_hold_cap_not_admissible_names_its_line(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        path = os.path.join(self.d, "gateway-record-hold-cap-3.jsonl")
        recs = pr.jsonl(path)
        for r in recs:
            if r["ev"] == "done" and r["requestId"] == "pp-A-off-1-1":
                r["reason"] = "serial_prefill_hold_timeout"
        write(path, recs)
        self.assertEqual(self.v(), "not met: hold-cap was not admissible: block 3: hold refusals")

    # A failed premium request in hold-cap is an outcome, not invalidity: here it is the cell's only premium stream,
    # so hold-cap served none and fails the gap safeguard (A4, B4). The infinite-tail ordering is pinned in the replay's
    # tests and by the crossed ratio's own (test_an_infinite_comparator_bound_keeps_its_infinity).
    # Mutation that turns it red: count a treatment's premium failure as invalid evidence.
    def test_a_failed_premium_in_hold_cap_is_an_outcome(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        path = os.path.join(self.d, "raw-hold-cap-2.jsonl")
        rows = pr.jsonl(path)
        rows[0].update({"httpStatus": 0, "errorKind": "timeout", "outputTokens": 3, "engineOutputTokens": 3, "streamTerminated": False})
        rows[0].pop("contentGapsMicros")
        write(path, rows)
        self.assertEqual(self.v(), "not met: hold-cap was not admissible: block 2: premium inter-token gap p99 against off's")

    # A cell whose manifest names another seed's trace is not the registered cell (B6, B7).
    def test_a_cell_with_another_trace_is_inconclusive(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        with open(os.path.join(self.d, "manifest-fixed-1.66-2.yaml"), "a") as f:
            f.write("traceChecksum: 0000\n")
        v = self.v()
        self.assertTrue(v.startswith("inconclusive: evidence not trusted: fixed-1.66-2 is the registered cell"), v)

    # A missing cell and an extra one are both inconclusive (C23 on the scorer's side).
    def test_missing_or_extra_cells_are_inconclusive(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000}, skip=("fixed-1.74-3",))
        self.assertTrue(self.v().startswith("inconclusive: cells not acquired: fixed-1.74-3"), self.v())
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        write(os.path.join(self.d, "raw-R1-2.jsonl"), [{"requestId": "x"}])
        self.assertTrue(self.v().startswith("inconclusive: cells the plan did not buy: R1-2"), self.v())

    # A gateway that did not run the arm's mode is not the registered apparatus.
    # Mutation that turns it red: drop the mode-reason line.
    def test_a_cell_whose_gateway_ran_another_mode_is_inconclusive(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        path = os.path.join(self.d, "gateway-record-fixed-1.62-1.jsonl")
        recs = pr.jsonl(path)
        for r in recs:
            if r["ev"] == "done":
                r["reason"] = "admission_off"
        write(path, recs)
        self.assertIn("fixed-1.62-1 contender decisions by its admission mode", self.v())

    # A truncated record makes its cell untrusted rather than crashing the scorer (B11).
    def test_a_truncated_record_is_inconclusive_not_a_crash(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        with open(os.path.join(self.d, "raw-off-2.jsonl"), "a") as f:
            f.write('{"requestId": "pp-A-off-1-9", "tena')
        self.assertIn("off-2 records readable", self.v())

    # A win needs the winner to have kept the loser's work: hold-cap's tail is better, but every fixed arm decoded
    # more of the contender's tokens in the shared window, so hold-cap does not win (A2).
    # Mutation that turns it red: drop the work comparability from a win.
    def test_a_win_by_less_work_is_not_a_win(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000}, extra_decode=pr.FRONTIER_FIXED)
        self.assertEqual(self.v(), "not established: neither hold-cap nor fixed-1.62 was 15% below the other")

    # Rows from another run beside the right manifest and trace are not the registered cell (review of fde74bb).
    # Mutation that turns it red: compare row counts only.
    def test_rows_naming_another_study_are_not_the_registered_cell(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        path = os.path.join(self.d, "raw-hold-cap-2.jsonl")
        rows = pr.jsonl(path)
        rows[1]["study"] = "admission-diagnostic-2026-10-10"
        write(path, rows)
        self.assertIn("hold-cap-2 is the registered cell", self.v())

    # A row without an integer index is not the registered cell, and does not crash the report (review of 087cc3b).
    # Mutation that turns it red: sort the indices without checking them.
    def test_a_row_without_its_index_is_not_the_registered_cell(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        path = os.path.join(self.d, "raw-off-1.jsonl")
        rows = pr.jsonl(path)
        rows[0].pop("index")
        write(path, rows)
        self.assertIn("off-1 is the registered cell", self.v())

    # A trace that does not hash to the frozen checksum is not the registered trace, whatever its manifest says.
    # Mutation that turns it red: trust the manifest's checksum without hashing the trace.
    def test_a_trace_with_another_hash_is_not_the_registered_cell(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        write(os.path.join(self.d, "trace-off-3.jsonl"), FIXTURE_TRACE[::-1])
        self.assertIn("off-3 is the registered cell", self.v())

    # A truncated trace makes its cell untrusted rather than crashing the report (review of fde74bb).
    def test_a_truncated_trace_is_inconclusive_not_a_crash(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        with open(os.path.join(self.d, "trace-fixed-1.62-1.jsonl"), "a") as f:
            f.write('{"index": 2, "off')
        v = self.v()
        # Its hash no longer matches, so provenance refuses it before anything parses it; either refusal names the cell.
        self.assertTrue(v.startswith("inconclusive: evidence not trusted: fixed-1.62-1"), v)

    # A fixed arm's admission without its decision time leaves the spacing line unscorable, not vacuously holding.
    # Mutation that turns it red: drop admissions without a decision time from the timing.
    def test_an_admission_without_its_time_is_unscorable(self):
        frontier_block(self.d, ttft={"hold-cap": 10_000_000})
        path = os.path.join(self.d, "gateway-record-fixed-1.70-2.jsonl")
        recs = pr.jsonl(path)
        for r in recs:
            if r["ev"] == "done" and r["requestId"] == "pp-A-off-1-1":
                r.pop("decidedUnixNanos")
        write(path, recs)
        self.assertIn("fixed-1.70-2 admissions after the spacing", self.v())

    # The scorer's frozen checksums and the session library's are one table (a key assembled in two places).
    def test_the_checksums_agree_with_the_session_library(self):
        mock.patch.stopall()
        lib = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "prospective-pilot.sh")).read()
        for seed, (whole, r1) in pr.FRONTIER_CHECKSUMS.items():
            self.assertIn("%d:R1) echo %s" % (seed, r1), lib)
            self.assertIn("%d:*) echo %s" % (seed, whole), lib)


def lencal_block(d, ttft=None, a2c=None, skip=()):
    """Every v27 calibration cell, as frontier_block builds v26's: ttft maps an arm to its premium first content after
    arrival (20 ms by default); a2c maps a length to hold-cap's contender decision-to-first-content in ms."""
    ttft, a2c = ttft or {}, a2c or {}
    for c in pr.LENCAL_CELLS:
        if c in skip:
            continue
        arm = c.rsplit("-", 1)[0]
        length = None if arm == "R1" else arm.rsplit("-", 1)[1]
        cell = Cell(d, arm, 1)
        cell.rows[0]["contentGapsMicros"] = [10_000] * 63
        cell.rows[1]["firstTokenUnixNanos"] = ORIGIN + 30_000_000
        cell.rows[1]["contentGapsMicros"] = [500] * 15
        want = pr.LENCAL_CHECKSUMS["R1" if arm == "R1" else length]
        for i, r in enumerate(cell.rows):
            r.update({"index": i, "study": pr.LENCAL_STUDY, "arm": arm, "traceChecksum": want})
        for r in cell.steps:
            if r.get("anchor"):
                r["anchor"] = [0, ORIGIN - 100_000_000, 0]
        reason = "serial_prefill_free" if arm.startswith("hold-cap") else "admission_off"
        for g in cell.gw:
            if g["ev"] == "done":
                g["decision"], g["reason"] = "admit", reason
                if g["requestId"] == "pp-A-off-1-0":
                    g["firstContentUnixNanos"] = g["arrivedUnixNanos"] + ttft.get(arm, 20_000_000)
                elif arm.startswith("hold-cap"):
                    g["firstContentUnixNanos"] = g["decidedUnixNanos"] + int(a2c.get(length, 1600) * 1_000_000)
        cell.save()
        with open(os.path.join(d, "manifest-%s-1.yaml" % arm), "w") as f:
            f.write('arm: "%s"\nseed: %d\nstudy: %s\ntraceChecksum: %s\n' % (arm, pr.LENCAL_SEED, pr.LENCAL_STUDY, want))
        write(os.path.join(d, "trace-%s-1.jsonl" % arm), FIXTURE_TRACE)
        for phase in ("before", "after"):
            with open(os.path.join(d, "engine-metrics-%s-1-%s.prom" % (arm, phase)), "w") as f:
                f.write('vllm:num_preemptions_total{engine="0"} 0.0\n')


class CalibrationTest(unittest.TestCase):
    # v27's calibration gate on built cells.
    def setUp(self):
        self.d = tempfile.mkdtemp()
        patch = mock.patch.dict(pr.LENCAL_CHECKSUMS, {k: FIXTURE_HASH for k in pr.LENCAL_CHECKSUMS})
        patch.start()
        self.addCleanup(patch.stop)
        self.protective = {"hold-cap-short": 10_000_000, "hold-cap-ref": 10_000_000, "hold-cap-long": 10_000_000}

    def v(self):
        return pr.calibration(self.d)

    # Protective and admissible everywhere, and the long length's prefill past 1,740 ms and 5% above the reference's:
    # feasible, with the size-aware spacings frozen from the medians.
    # Mutation that turns it red: drop the 1.05 x reference condition, or scale the spacings by the long length.
    def test_feasible_with_its_spacings(self):
        lencal_block(self.d, ttft=self.protective, a2c={"short": 1300, "ref": 1600, "long": 1800})
        v = self.v()
        self.assertEqual(v["verdict"], "feasible: hold-cap admissible and protective at every length, and the long length outlasts 1,740 ms")
        self.assertEqual(v["size_aware_spacings_ms"], {"short": round(1740 * 1300.002 / 1600.002, 1),
                                                       "ref": 1740.0, "long": round(1740 * 1800.002 / 1600.002, 1)})

    # The long length's prefill under 1,740 ms tests nothing about a fixed spacing tuned there.
    def test_a_long_prefill_short_of_the_spacing_is_no_challenge(self):
        lencal_block(self.d, ttft=self.protective, a2c={"short": 1300, "ref": 1600, "long": 1700})
        self.assertTrue(self.v()["verdict"].startswith("challenge not achieved"), self.v()["verdict"])

    # Past 1,740 ms but within 5% of the reference's is no challenge either.
    # Mutation that turns it red: require only the 1,740 ms bound.
    def test_a_long_prefill_within_five_percent_of_the_reference_is_no_challenge(self):
        lencal_block(self.d, ttft=self.protective, a2c={"short": 1300, "ref": 1720, "long": 1760})
        self.assertTrue(self.v()["verdict"].startswith("challenge not achieved"), self.v()["verdict"])

    # Hold-cap no better than off at one length is not a feasible test of protection.
    # Mutation that turns it red: drop the premium-against-off line.
    def test_hold_cap_not_protective_at_a_length(self):
        lencal_block(self.d, ttft={"hold-cap-short": 20_000_000, "hold-cap-ref": 10_000_000, "hold-cap-long": 10_000_000},
                     a2c={"short": 1300, "ref": 1600, "long": 1800})
        self.assertEqual(self.v()["verdict"], "not feasible: hold-cap did not protect the premium tail at short")

    # A hold refusal at the long length makes hold-cap inadmissible there: the first-ranked risk, measured.
    def test_hold_cap_inadmissible_at_the_long_length(self):
        lencal_block(self.d, ttft=self.protective, a2c={"short": 1300, "ref": 1600, "long": 1800})
        path = os.path.join(self.d, "gateway-record-hold-cap-long-1.jsonl")
        recs = pr.jsonl(path)
        for r in recs:
            if r["ev"] == "done" and r["requestId"] == "pp-A-off-1-1":
                r["reason"] = "serial_prefill_hold_timeout"
        write(path, recs)
        self.assertEqual(self.v()["verdict"], "not feasible: hold-cap was not admissible at long: hold refusals")

    # An admissibility failure at the long length outranks a protection failure at the short one (review of 25f989a).
    # Mutation that turns it red: take the first failing length in length order.
    def test_admissibility_outranks_protection_across_lengths(self):
        lencal_block(self.d, ttft={"hold-cap-short": 20_000_000, "hold-cap-ref": 10_000_000, "hold-cap-long": 10_000_000},
                     a2c={"short": 1300, "ref": 1600, "long": 1800})
        path = os.path.join(self.d, "gateway-record-hold-cap-long-1.jsonl")
        recs = pr.jsonl(path)
        for r in recs:
            if r["ev"] == "done" and r["requestId"] == "pp-A-off-1-1":
                r["reason"] = "serial_prefill_hold_timeout"
        write(path, recs)
        self.assertEqual(self.v()["verdict"], "not feasible: hold-cap was not admissible at long: hold refusals")

    # A contender success without its gateway first content cannot be timed: inconclusive, not a crash or a median
    # over the rest (review of 25f989a).
    # Mutation that turns it red: drop untimed contenders from the median silently.
    def test_a_contender_without_gateway_timing_is_inconclusive(self):
        lencal_block(self.d, ttft=self.protective, a2c={"short": 1300, "ref": 1600, "long": 1800})
        path = os.path.join(self.d, "gateway-record-hold-cap-ref-1.jsonl")
        recs = pr.jsonl(path)
        for r in recs:
            if r["ev"] == "done" and r["requestId"] == "pp-A-off-1-1":
                r.pop("firstContentUnixNanos")
        write(path, recs)
        self.assertIn("hold-cap at ref: contender successes without gateway timing", self.v()["verdict"])

    def test_a_missing_cell_is_inconclusive(self):
        lencal_block(self.d, ttft=self.protective, skip=("off-long-1",))
        self.assertTrue(self.v()["verdict"].startswith("inconclusive: cells not acquired: off-long-1"), self.v()["verdict"])

    def test_the_checksums_agree_with_the_session_library(self):
        mock.patch.stopall()
        lib = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "prospective-pilot.sh")).read()
        for key, want in pr.LENCAL_CHECKSUMS.items():
            pat = "871:R1) echo %s" % want if key == "R1" else "871:*-%s) echo %s" % (key, want)
            self.assertIn(pat, lib)


if __name__ == "__main__":
    unittest.main()
