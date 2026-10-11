"""Tests pilot_evidence.py on hand-built step logs and raw rows.

    python3 hack/prospective-pilot/test_pilot_evidence.py
"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pilot_evidence as pe  # noqa: E402


def write(path, recs):
    with open(path, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")


def step_log(adds, terminal=None):
    recs, seq = [], 0
    for rid, prio in adds:
        seq += 1
        recs.append({"ev": "add", "id": rid, "priority": prio, "seq": seq})
    recs.append({"ev": "flush", "first_seq": 1, "last_seq": seq})
    t = {"ev": "terminal", "seq_written": seq, "seq_produced": seq, "buffered": 0, "last_step": 3}
    t.update(terminal or {})
    recs.append(t)
    return recs


class PilotEvidenceTest(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp()
        self.step, self.raw = os.path.join(d, "step.jsonl"), os.path.join(d, "raw.jsonl")
        write(self.raw, [{"requestId": "pp-A-off-1-%d" % i, "tenant": t} for i, t in
                         [(1, "premium-1"), (10, "standard-noisy"), (2, "premium-1")]])

    def test_the_registered_priorities_pass(self):
        write(self.step, step_log([("chatcmpl-pp-A-off-1-1", 0), ("chatcmpl-pp-A-off-1-10", 1),
                                   ("chatcmpl-pp-A-off-1-2", 0), ("chatcmpl-fence-off-1", 0)]))
        self.assertEqual(pe.priority(self.step, self.raw), (True, ""))

    # Mutation that turns this red: compare priority only for premium requests.
    def test_a_standard_request_at_priority_zero_is_a_violation(self):
        # An unbound priority defaults to 0 for both tiers, so this is the failure a premium-only check misses.
        write(self.step, step_log([("chatcmpl-pp-A-off-1-1", 0), ("chatcmpl-pp-A-off-1-10", 0)]))
        ok, why = pe.priority(self.step, self.raw)
        self.assertIs(ok, False)
        self.assertIn("standard-noisy", why)

    # Mutation that turns this red: match a client ID wherever it appears as a substring.
    def test_index_one_does_not_match_inside_index_ten(self):
        self.assertEqual(pe.match_client("chatcmpl-pp-A-off-1-10", ["pp-A-off-1-1", "pp-A-off-1-10"]), "pp-A-off-1-10")
        self.assertEqual(pe.match_client("chatcmpl-pp-A-off-1-1-abc", ["pp-A-off-1-1", "pp-A-off-1-10"]), "pp-A-off-1-1")

    def test_a_scheduled_request_no_client_sent_is_a_violation(self):
        write(self.step, step_log([("chatcmpl-somebody-else-1", 1)]))
        ok, _ = pe.priority(self.step, self.raw)
        self.assertIs(ok, False)

    # A terminal record declaring 99 records over a log holding none is incomplete (v26 review, B21).
    # Mutation that turns this red: skip the produced-count comparison when there are no sequenced records.
    def test_a_terminal_record_over_an_empty_log_is_incomplete(self):
        write(self.step, [{"ev": "terminal", "seq_written": 99, "seq_produced": 99, "buffered": 0, "last_step": 0}])
        ok, _ = pe.terminal(self.step)
        self.assertIs(ok, False)

    # A request the scheduler ran with no add record ran at a priority nobody witnessed (v26 review, B9).
    # Mutation that turns this red: read priorities from the add records alone.
    def test_a_scheduled_request_without_its_add_cannot_be_witnessed(self):
        recs = step_log([("chatcmpl-pp-A-off-1-1", 0)])
        recs.insert(1, {"ev": "sched", "step": 1, "t0": 1, "tokens": {"chatcmpl-pp-A-off-1-2": 68}, "computed": {}, "seq": 2})
        recs[2]["last_seq"] = 2
        recs[-1].update({"seq_written": 2, "seq_produced": 2})
        write(self.step, recs)
        ok, why = pe.priority(self.step, self.raw)
        self.assertIsNone(ok, why)
        self.assertIn("no add record", why)

    # Mutation that turns this red: check priority before checking the log's completeness.
    def test_an_incomplete_log_cannot_witness_priority(self):
        write(self.step, step_log([("chatcmpl-pp-A-off-1-1", 0)], {"seq_produced": 5, "buffered": 4}))
        ok, why = pe.priority(self.step, self.raw)
        self.assertIsNone(ok)
        self.assertIn("cannot witness", why)

    def test_a_gap_in_the_sequence_is_incomplete(self):
        recs = step_log([("chatcmpl-pp-A-off-1-1", 0), ("chatcmpl-pp-A-off-1-2", 0)])
        recs[1]["seq"] = 3
        write(self.step, recs)
        ok, _ = pe.terminal(self.step)
        self.assertIs(ok, False)

    def test_no_terminal_record_is_unknown_not_incomplete(self):
        write(self.step, step_log([("chatcmpl-pp-A-off-1-1", 0)])[:-1])
        self.assertEqual(pe.main(["x", "terminal", self.step]), 2)

    def test_an_overflow_is_incomplete(self):
        recs = step_log([("chatcmpl-pp-A-off-1-1", 0)])
        recs.insert(1, {"ev": "overflow", "seq": 2})
        recs[-1].update({"seq_written": 2, "seq_produced": 2})
        write(self.step, recs)
        ok, why = pe.terminal(self.step)
        self.assertIs(ok, False)
        self.assertIn("overflow", why)


if __name__ == "__main__":
    unittest.main()
