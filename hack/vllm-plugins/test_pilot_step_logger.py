"""Tests pilot_step_logger.py without vLLM, against a stand-in for vLLM's synchronous Scheduler.

    python3 hack/vllm-plugins/test_pilot_step_logger.py

The stand-in implements only what the logger calls: add_request, schedule, update_from_output, has_requests and the
requests map. What it cannot test is vLLM's own behaviour (request ids, priority, the real step loop); the CPU
rehearsal with the real engine is what checks that (design page, "Rehearsals before purchase").
"""

import json
import os
import sys
import tempfile
import time
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


class _FakeScheduler:
    """vLLM's Scheduler as far as the logger touches it: one request at a time, one token per step."""

    def __init__(self, *args, **kwargs):
        self.requests = {}

    def add_request(self, request):
        self.requests[request.request_id] = request

    def schedule(self, *args, **kwargs):
        tokens = {}
        for rid, r in self.requests.items():
            if r.remaining > 0:
                tokens[rid] = 1
                r.num_computed_tokens += 1
        return types.SimpleNamespace(num_scheduled_tokens=tokens, total_num_scheduled_tokens=sum(tokens.values()))

    def update_from_output(self, scheduler_output, model_runner_output):
        for rid in list(scheduler_output.num_scheduled_tokens):
            r = self.requests[rid]
            r.remaining -= 1
            if r.remaining == 0:
                del self.requests[rid]

    def has_requests(self):
        return bool(self.requests)


def _install_fake_vllm():
    for name in ("vllm", "vllm.v1", "vllm.v1.core", "vllm.v1.core.sched"):
        sys.modules.setdefault(name, types.ModuleType(name))
    mod = types.ModuleType("vllm.v1.core.sched.scheduler")
    mod.Scheduler = _FakeScheduler
    sys.modules["vllm.v1.core.sched.scheduler"] = mod


_install_fake_vllm()
sys.path.insert(0, HERE)
import pilot_step_logger as psl  # noqa: E402


def _request(rid, tokens, priority):
    return types.SimpleNamespace(request_id=rid, arrival_time=time.time(), num_prompt_tokens=tokens,
                                 priority=priority, num_computed_tokens=0, remaining=tokens)


def _step(s):
    out = s.schedule()
    s.update_from_output(out, None)
    return out


def _records(path):
    with open(path) as f:
        return [json.loads(line) for line in f]


def _wait_for(path, pred, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path):
            recs = _records(path)
            if pred(recs):
                return recs
        time.sleep(0.05)
    raise AssertionError("timed out waiting on %s" % path)


class PilotStepLoggerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "step.jsonl")
        os.environ["STEP_LOG_PATH"] = self.path
        psl.SENTINEL_POLL_S = 0.05

    def _run_two_requests(self):
        s = psl.PilotStepLoggingScheduler()
        s.add_request(_request("premium-1", 2, 0))
        s.add_request(_request("standard-1", 3, 1))
        while s.has_requests():
            _step(s)
        return s

    # Mutation that turns this red: drop "seq" from _keep, or the first/last range from the flush record.
    def test_every_record_is_numbered_and_every_flush_names_its_range(self):
        s = self._run_two_requests()
        recs = _wait_for(self.path, lambda r: any(x["ev"] == "flush" for x in r))
        data = [r for r in recs if r["ev"] not in ("flush", "terminal")]
        self.assertEqual([r["seq"] for r in data], list(range(1, len(data) + 1)))
        flush = [r for r in recs if r["ev"] == "flush"][0]
        self.assertEqual((flush["first_seq"], flush["last_seq"]), (1, len(data)))
        self.assertEqual(s._seq_written, len(data))

    # Mutation that turns this red: drop "priority" from the add record.
    def test_add_records_carry_the_priority_the_scheduler_received(self):
        self._run_two_requests()
        recs = _wait_for(self.path, lambda r: any(x["ev"] == "flush" for x in r))
        prio = {r["id"]: r["priority"] for r in recs if r["ev"] == "add"}
        self.assertEqual(prio, {"premium-1": 0, "standard-1": 1})

    # Mutation that turns this red: stop polling the sentinel in the writer's idle loop.
    def test_the_sentinel_yields_a_complete_terminal_record_after_every_written_batch(self):
        s = self._run_two_requests()
        _wait_for(self.path, lambda r: any(x["ev"] == "flush" for x in r))
        open(s._sentinel_path, "w").close()
        recs = _wait_for(self.path, lambda r: any(x["ev"] == "terminal" for x in r))
        term = [r for r in recs if r["ev"] == "terminal"][-1]
        self.assertEqual(term["seq_written"], term["seq_produced"])
        self.assertEqual(term["buffered"], 0)
        self.assertEqual(term["last_step"], s._step_index)
        self.assertEqual(recs[-1]["ev"], "terminal", "the terminal record precedes a batch it claims to follow")

    # Mutation that turns this red: report seq_written as seq_produced.
    def test_a_terminal_record_says_so_when_records_are_still_buffered(self):
        s = psl.PilotStepLoggingScheduler()
        s.add_request(_request("standard-1", 3, 1))
        _step(s)  # one step, the request still running, so nothing is flushed
        open(s._sentinel_path, "w").close()
        recs = _wait_for(self.path, lambda r: any(x["ev"] == "terminal" for x in r))
        term = [r for r in recs if r["ev"] == "terminal"][-1]
        self.assertLess(term["seq_written"], term["seq_produced"])
        self.assertGreater(term["buffered"], 0)

    def test_a_rewritten_sentinel_yields_a_second_terminal_record(self):
        s = self._run_two_requests()
        _wait_for(self.path, lambda r: any(x["ev"] == "flush" for x in r))
        open(s._sentinel_path, "w").close()
        _wait_for(self.path, lambda r: sum(x["ev"] == "terminal" for x in r) == 1)
        time.sleep(0.02)
        with open(s._sentinel_path, "w") as f:
            f.write("again")
        os.utime(s._sentinel_path, ns=(time.time_ns(), time.time_ns()))
        _wait_for(self.path, lambda r: sum(x["ev"] == "terminal" for x in r) == 2)


if __name__ == "__main__":
    unittest.main()
