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


class OrderTest(unittest.TestCase):
    # A contender arriving at 15 ms, before the first one's token is delivered at 18 ms, is decided with the state at
    # 15 ms: refuse-one-prefill refuses it (review of f2e0c8a, its example).
    def test_an_arrival_is_decided_with_the_state_at_its_own_instant(self):
        out = sim.simulate([req("c1", pr.CONTENDER, 0, 512), req("c2", pr.CONTENDER, 15, 512)], FLAT,
                           sim.RULES["refuse-one-prefill"], 0, 8 * MS)
        by = {r["id"]: r for r in out}
        self.assertTrue(by["c2"].get("refused"))

    # And one arriving at 20 ms, after the token was delivered at 18 ms, is forwarded (review of e51e8e6, its example).
    def test_a_delivered_token_frees_the_rule_before_a_later_arrival(self):
        out = sim.simulate([req("c1", pr.CONTENDER, 0, 512), req("c2", pr.CONTENDER, 20, 512)], FLAT,
                           sim.RULES["refuse-one-prefill"], 0, 8 * MS)
        by = {r["id"]: r for r in out}
        self.assertNotIn("refused", by["c2"])
        self.assertEqual(by["c2"]["forwarded"], 20 * MS)

    # A premium request that never gets a token counts in the p99 as a failure, not as a dropped sample.
    def test_a_premium_failure_is_in_the_p99(self):
        reqs = [{"tenant": pr.PREMIUM, "ttft_ms": 10.0}] * 50 + [{"tenant": pr.PREMIUM, "expired": True}] * 2
        self.assertEqual(sim.summarize(reqs)["premium_p99_ms"], float("inf"))


class HoldTimeoutTest(unittest.TestCase):
    # A contender held past the longest hold, counted from its arrival, is refused as the gateway refuses it.
    # Mutation that turns it red: drop the hold deadline, leaving only the 30-second request timeout.
    def test_a_contender_held_past_the_longest_hold_is_refused(self):
        old = sim.HOLD_NS
        sim.HOLD_NS = 50 * MS
        try:
            out = sim.simulate([req("c1", pr.CONTENDER, 0, 7695), req("c2", pr.CONTENDER, 1, 7695)], FLAT,
                               sim.RULES["hold-one-prefill"], 0, 0)
        finally:
            sim.HOLD_NS = old
        by = {r["id"]: r for r in out}
        self.assertTrue(by["c2"].get("hold_timeout"))
        self.assertNotIn("forwarded", by["c2"])


class CancelTest(unittest.TestCase):
    # A contender that expires in prefill frees the rule for the one held behind it, which then runs and completes
    # instead of waiting to its own deadline (review of 7caa759).
    def test_a_cancellation_frees_a_held_contender(self):
        old = sim.TIMEOUT_NS
        sim.TIMEOUT_NS = 100 * MS
        try:
            out = sim.simulate([req("c1", pr.CONTENDER, 0, 7695 * 4), req("c2", pr.CONTENDER, 90, 512)], FLAT,
                               sim.RULES["hold-one-prefill"], 0, 0)
        finally:
            sim.TIMEOUT_NS = old
        by = {r["id"]: r for r in out}
        self.assertTrue(by["c1"].get("expired"))
        self.assertIn("forwarded", by["c2"])
        self.assertLessEqual(by["c2"]["forwarded"], 120 * MS)


class SpacingTest(unittest.TestCase):
    # Two contenders arriving together under a 100 ms spacing: the second goes exactly 100 ms after the first, with no
    # signal from the engine. Mutation that turns it red: forward at the decision point instead of the spacing's end.
    def test_the_static_control_forwards_at_its_spacing(self):
        out = sim.simulate([req("c1", pr.CONTENDER, 0, 7695), req("c2", pr.CONTENDER, 0, 7695)], FLAT,
                           sim.hold_spacing(100 * MS), 0, 0)
        by = {r["id"]: r for r in out}
        self.assertEqual(by["c1"]["forwarded"], 0)
        self.assertEqual(by["c2"]["forwarded"], 100 * MS)

    # The engine goes idle while the second contender waits out its spacing, and the next arrival is 10 s away: the
    # replay must wake at the spacing's end, not jump to that arrival (review of 3cb7e05).
    # Mutation that turns it red: leave the spacing's release time out of the idle engine's next event.
    def test_an_idle_engine_wakes_at_the_spacing_end(self):
        out = sim.simulate([req("c1", pr.CONTENDER, 0, 512), req("c2", pr.CONTENDER, 0, 512),
                            req("p", pr.PREMIUM, 10_000, 68)], FLAT, sim.hold_spacing(1000 * MS), 0, 0)
        by = {r["id"]: r for r in out}
        self.assertEqual(by["c2"]["forwarded"], 1000 * MS)
        self.assertEqual(by["c2"]["first_token"], 1010 * MS)

    # A spacing that ends at 24.99 s of waiting, inside a step that ends at 25.04 s: the gateway's timer would have
    # forwarded it before its 25 s, so it is forwarded, not refused (v26 review, finding 1).
    # Mutation that turns it red: judge the hold deadline before asking the rule, or restore the sweep that refuses
    # every held contender past 25 s at the step boundary.
    def test_a_spacing_ending_inside_the_hold_is_not_refused(self):
        steps_80 = [80.0, 0.0, 0.0, 0.0, 0.0]
        out = sim.simulate([req("c1", pr.CONTENDER, 0, 200_000), req("c2", pr.CONTENDER, 0, 512)], steps_80,
                           sim.hold_spacing(24_990 * MS), 0, 0)
        by = {r["id"]: r for r in out}
        self.assertFalse(by["c2"].get("refused"), by["c2"])
        self.assertEqual(by["c2"]["forwarded"], 24_990 * MS)



class OwnerLimitsTest(unittest.TestCase):
    # Each of the owner's four contender limits refuses on its own; the boundaries are inclusive as the owner froze them.
    # Mutation that turns it red: drop any one line of owner_limits, or make a boundary strict.
    def test_each_limit_refuses_on_its_own(self):
        off = {"contender_completion_p50_ms": 4000}
        ok = {"contender_completed": 95, "contender_offered": 100, "contender_completion_p50_ms": 6000,
              "contender_completion_p95_ms": 25_000, "contender_hold_timeouts": 0}
        self.assertIsNone(sim.owner_limits(ok, off))
        for key, value, line in (("contender_completed", 94, "completion below 95%"),
                                 ("contender_completion_p50_ms", 6001, "completion p50 above 1.5x off's"),
                                 ("contender_completion_p95_ms", 25_001, "completion p95 above 25 s"),
                                 ("contender_hold_timeouts", 1, "a hold refusal")):
            self.assertEqual(sim.owner_limits(dict(ok, **{key: value}), off), line)



class FrontierVerdictTest(unittest.TestCase):
    # v26's verdicts on point estimates (v26 review: A3, A5, A6, A16, A19 and A2's completion half).
    # Mutations that turn it red: compare infinities with <=, skip the premium-against-off line, test only the fixed arm
    # with the lowest p99, drop the completion comparability, or name a tie's wider spacing.
    def setUp(self):
        self.ok = {"hold-cap": None, "fixed-1.62": None, "fixed-1.66": None}
        self.done = {"hold-cap": 1.0, "fixed-1.62": 1.0, "fixed-1.66": 1.0, "off": 1.0}

    def v(self, p99, fail=None, done=None):
        return sim.frontier_verdict(fail or self.ok, dict(p99, off=p99.get("off", 1500)), done or self.done)

    def test_each_verdict(self):
        self.assertEqual(self.v({}, fail=dict(self.ok, **{"hold-cap": "a hold refusal in t861"})),
                         "not met: hold-cap was not admissible: a hold refusal in t861")
        self.assertEqual(self.v({"hold-cap": 1400, "fixed-1.62": 2000, "fixed-1.66": 2000}),
                         "not met: hold-cap did not cut the premium tail 15% below off's")
        self.assertEqual(self.v({"hold-cap": 400}, fail={"hold-cap": None, "fixed-1.62": "x", "fixed-1.66": "y"}),
                         "observed: hold-cap met the limits and no fixed spacing in the grid did")
        self.assertEqual(self.v({"hold-cap": 400, "fixed-1.62": 1000, "fixed-1.66": 500}),
                         "observed: hold-cap beat every admissible fixed spacing")
        self.assertEqual(self.v({"hold-cap": 400, "fixed-1.62": 460, "fixed-1.66": 1000}),
                         "not established: neither hold-cap nor fixed-1.62 was 15% below the other")
        self.assertEqual(self.v({"hold-cap": 900, "fixed-1.62": 1000, "fixed-1.66": 2000}),
                         "not established: neither hold-cap nor fixed-1.62 was 15% below the other")
        self.assertEqual(self.v({"hold-cap": 1000, "fixed-1.62": 800, "fixed-1.66": 2000}),
                         "observed: fixed-1.62 beat hold-cap")

    def test_two_infinite_tails_do_not_order(self):
        inf = float("inf")
        self.assertEqual(self.v({"hold-cap": inf, "fixed-1.62": inf, "fixed-1.66": inf}),
                         "not met: hold-cap did not cut the premium tail 15% below off's")
        self.assertFalse(sim.beats(inf, inf))
        self.assertTrue(sim.beats(400, inf))

    def test_every_admissible_fixed_arm_is_tested(self):
        # fixed-1.62 has the lowest p99 but lost contender work, so it cannot win; fixed-1.70 is not the lowest and wins.
        ok = dict(self.ok, **{"fixed-1.70": None})
        done = dict(self.done, **{"fixed-1.62": 0.95, "fixed-1.70": 1.0})
        self.assertEqual(sim.frontier_verdict(ok, {"off": 1500, "hold-cap": 1000, "fixed-1.62": 800, "fixed-1.66": 900,
                                                  "fixed-1.70": 840}, done), "observed: fixed-1.70 beat hold-cap")

    def test_a_tie_names_the_narrower_spacing(self):
        self.assertEqual(self.v({"hold-cap": 1000, "fixed-1.62": 800, "fixed-1.66": 800}), "observed: fixed-1.62 beat hold-cap")

    def test_a_win_by_lost_work_is_not_a_win(self):
        done = dict(self.done, **{"hold-cap": 0.96})
        self.assertEqual(self.v({"hold-cap": 400, "fixed-1.62": 1000, "fixed-1.66": 1000}, done=done),
                         "not established: neither hold-cap nor fixed-1.62 was 15% below the other")


class ReplayReviewTest(unittest.TestCase):
    # A premium request whose stream ends past the 30 s timeout is a failure, whatever its first token (v26 review, A9).
    # Mutation that turns it red: drop the completion-in-time condition from the premium p99.
    def test_a_premium_finishing_late_is_a_failure(self):
        r = req("p", pr.PREMIUM, 0, 68)
        r.update({"ttft_ms": 400.0, "first_token": 400 * MS, "finished": 30_005 * MS})
        self.assertEqual(sim.summarize([r])["premium_p99_ms"], float("inf"))
        r["finished"] = 2_000 * MS
        self.assertEqual(sim.summarize([r])["premium_p99_ms"], 400.0)

    # A request without a gateway arrival is refused, not dropped (v26 review, A11).
    def test_a_missing_arrival_is_refused(self):
        r = req("c", pr.CONTENDER, 0, 512)
        r["gw_arrived"] = None
        with self.assertRaises(ValueError):
            sim.simulate([req("p", pr.PREMIUM, 0, 68), r], FLAT, sim.RULES["off"], 0, 0)

    # An idle engine waits for the next event, not a millisecond more: a request forwarded 0.1 ms after arrival on an
    # idle engine with 10 ms steps has its first token at 10.1 ms (v26 review, B24).
    def test_an_idle_engine_does_not_overshoot(self):
        out = sim.simulate([req("p", pr.PREMIUM, 0, 68)], FLAT, sim.RULES["off"], 100_000, 0)
        self.assertEqual(out[0]["first_token"], 10_100_000)


if __name__ == "__main__":
    unittest.main()
