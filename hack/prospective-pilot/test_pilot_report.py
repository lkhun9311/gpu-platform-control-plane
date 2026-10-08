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


if __name__ == "__main__":
    unittest.main()
