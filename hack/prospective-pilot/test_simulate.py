"""Tests the scheduler replay's engine on hand-built requests.

    python3 hack/prospective-pilot/test_simulate.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pilot_report as pr  # noqa: E402
import simulate as sim  # noqa: E402

# Every step takes 10 ms whatever it holds, so step counts read directly as time.
FLAT = [10.0, 0.0, 0.0, 0.0, 0.0]
MS = 1_000_000


def req(rid, tenant, at_ms, prompt):
    return {"id": rid, "tenant": tenant, "sched": at_ms * MS, "gw_arrived": at_ms * MS, "prompt": prompt, "admitted": True}


class EngineTest(unittest.TestCase):
    # The pilot's finding, as the model must reproduce it: running requests are scheduled first, so a premium request
    # arriving while a contender's 7,695-token prefill runs in 512-token chunks waits for it, priority or not.
    # Mutation that turns it red: schedule waiting requests before running ones.
    def test_a_premium_arrival_waits_for_a_running_prefill(self):
        out = sim.simulate([req("c", pr.CONTENDER, 0, 7695), req("p", pr.PREMIUM, 15, 68)], FLAT, sim.RULES["off"], 0, 0)
        by = {r["id"]: r for r in out}
        # The contender's prefill takes ceil(7695/512) = 16 steps, 0 to 160 ms. Steps 2 to 15 are full, so the premium
        # request arriving at 15 ms gets nothing until step 16, whose last chunk is 7,695 - 15 x 512 = 15 tokens and
        # leaves it 497: its first token comes at 160 ms, 145 ms after it arrived, not one step later.
        self.assertEqual(by["c"]["first_token"], 160 * MS)
        self.assertEqual(by["p"]["first_token"], 160 * MS)

    # Without a running prefill, priority decides among waiting requests.
    def test_priority_orders_the_waiting_queue(self):
        out = sim.simulate([req("c", pr.CONTENDER, 0, 400), req("p", pr.PREMIUM, 0, 400)], FLAT, sim.RULES["off"], 0, 0)
        by = {r["id"]: r for r in out}
        self.assertLess(by["p"]["first_token"], by["c"]["first_token"])

    # The hold rule forwards a contender only once the previous one's first token is back.
    def test_hold_one_prefill_serializes_prefills(self):
        out = sim.simulate([req("c1", pr.CONTENDER, 0, 1024), req("c2", pr.CONTENDER, 0, 1024)], FLAT,
                           sim.RULES["hold-one-prefill"], 0, 0)
        by = {r["id"]: r for r in out}
        self.assertGreaterEqual(by["c2"]["forwarded"], by["c1"]["first_token"])


class ReviewTest(unittest.TestCase):
    # A request still in flight to the engine does not block one already there (review of d75156c, finding 3).
    def test_a_future_arrival_does_not_block_a_ready_request(self):
        eng = sim.Engine(FLAT)
        eng.now = 0
        c, p = req("c", pr.CONTENDER, 0, 100), req("p", pr.PREMIUM, 0, 100)
        eng.add(c, 0)
        eng.add(p, 5 * MS)
        self.assertIsNotNone(eng.step())
        self.assertIn(c, eng.running)

    # The gateway sees a first token only when it is delivered, so the hold rule waits for that (finding 4).
    def test_the_hold_rule_waits_for_the_delivered_first_token(self):
        out = sim.simulate([req("c1", pr.CONTENDER, 0, 1024), req("c2", pr.CONTENDER, 0, 1024)], FLAT,
                           sim.RULES["hold-one-prefill"], 0, 50 * MS)
        by = {r["id"]: r for r in out}
        self.assertGreaterEqual(by["c2"]["forwarded"], by["c1"]["first_token"] + 50 * MS)

    # A request past its deadline stops taking engine tokens (finding 1).
    def test_an_expired_request_is_cancelled_in_the_engine(self):
        old = sim.TIMEOUT_NS
        sim.TIMEOUT_NS = 100 * MS
        try:
            out = sim.simulate([req("c", pr.CONTENDER, 0, 7695)], FLAT, sim.RULES["off"], 0, 0)
        finally:
            sim.TIMEOUT_NS = old
        self.assertTrue(out[0].get("expired"))
        self.assertNotIn("first_token", out[0])


if __name__ == "__main__":
    unittest.main()
