#!/usr/bin/env python3
"""Checks analyze.py on a synthetic run: per-attempt scoring of a re-queued request, nearest-rank percentiles, stream
completion, and refusal of repeated ids.

Run: python3 hack/llmd-2881/test_analyze.py
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import analyze  # noqa: E402

CFG = "concurrencyMode: tokens\nmaxTokenConcurrency: 1024\nheadroom: 0\nfailOpen: false\n"


def line(t, rid, body, **kw):
    # The EPP logs compact JSON, and parse_epp prefilters on the compact form of the id field.
    return json.dumps({"timestamp": f"2026-11-19T12:00:{t:09.6f}Z", "x-request-id": rid, "body": body, **kw},
                      separators=(",", ":")) + "\n"


def endpoint(pod):
    return {"TargetEndpoints": [{"Endpoint": {"Name": pod}}]}


def make_run(root, epp_lines, client, tokens):
    run = Path(root) / "20261119T000000Z-tokens-synthetic-s1"
    run.mkdir()
    (run / "epp-config.yaml").write_text(CFG)
    (run / "pins.txt").write_text("--max-num-seqs=4\n")
    (run / "metrics-before.txt").write_text("")
    (run / "metrics-after.txt").write_text("")
    (run / "epp.log").write_text("".join(epp_lines))
    (run / "requests.jsonl").write_text("".join(json.dumps(c) + "\n" for c in client))
    (run / "tokens.jsonl").write_text("".join(json.dumps(t) + "\n" for t in tokens))
    return run


def client_row(rid, status, t_sent, t_done, **kw):
    row = {"id": rid, "status": status, "max_tokens": 16, "sent_unix_ns": int(t_sent * 1e9),
           "done_unix_ns": int(t_done * 1e9), "e2e_ms": (t_done - t_sent) * 1e3, "ttft_ms": 100.0, "chunks": 20}
    row.update(kw)
    return row


class RequeueScoring(unittest.TestCase):
    def test_two_attempts_are_both_kept(self):
        # Request 1 is released, emptied by the filter, re-queued, released again and served.
        # Request 2 is released, emptied, and fails with 503.
        a, b = "syn-s1-00000", "syn-s1-00001"
        lines = [
            line(1.0, a, "EPP received request"),
            line(1.001, a, "Flow control outcome", outcome="Dispatched"),
            line(1.002, a, "Filter eliminated all endpoints", plugin="conc/concurrency-detector"),
            line(1.003, a, "Request re-queued after saturation"),
            line(1.5, a, "Flow control outcome", outcome="Dispatched"),
            line(1.501, a, "Completed running picker plugin successfully", result=endpoint("pod-a")),
            line(1.502, a, "Completed running PreRequest plugin successfully", plugin="inflight-load-producer"),
            line(2.0, a, "HandleResponseBody is triggered", endOfStream=True),
            line(1.0, b, "EPP received request"),
            line(1.1, b, "Flow control outcome", outcome="Dispatched"),
            line(1.102, b, "Filter eliminated all endpoints", plugin="conc/concurrency-detector"),
            line(1.103, b, "Failed to process request", error="ServiceUnavailable - no endpoints available"),
        ]
        client = [
            client_row(a, 200, 1.0, 2.0, done=True, content_chunks=16, usage_completion_tokens=16),
            client_row(b, 503, 1.0, 1.104, dropped_reason="rejected-no-endpoints", done=False),
        ]
        tokens = [{"id": a, "prompt_tokens": 10, "max_tokens": 16}, {"id": b, "prompt_tokens": 10, "max_tokens": 16}]
        with tempfile.TemporaryDirectory(dir=Path.home() / ".cache") as root:
            s = analyze.analyze(make_run(root, lines, client, tokens))
        self.assertEqual(s["attempts_per_request"], {"1": 1, "2": 1})
        self.assertEqual(s["release_then_reject_attempts"], 2)
        # The re-queued request recovered, so only the 503 counts at request level.
        self.assertEqual(s["release_then_reject"], 1)
        self.assertEqual(s["requeued_attempts"], 1)
        self.assertEqual(s["client_200_without_route_lines"], 0)
        self.assertEqual(s["client_503_not_counted"], 0)
        self.assertEqual(s["successful_completions"], 1)
        self.assertEqual(s["routed"], 1)
        # The span runs from the first send (1.0 s) to the last completion (2.0 s).
        self.assertEqual(s["generated_tok_s"], 16.0)

    def test_unscored_lines_open_no_attempt(self):
        # The full log carries lines such as "LLM request assembled" before admission.
        a = "syn-s1-00000"
        lines = [
            line(1.0, a, "EPP received request"),
            line(1.0005, a, "LLM request assembled"),
            line(1.001, a, "Flow control outcome", outcome="Dispatched"),
            line(1.002, a, "Completed running picker plugin successfully", result=endpoint("pod-a")),
            line(1.003, a, "Completed running PreRequest plugin successfully", plugin="inflight-load-producer"),
            line(2.0, a, "HandleResponseBody is triggered", endOfStream=True),
        ]
        with tempfile.TemporaryDirectory(dir=Path.home() / ".cache") as root:
            s = analyze.analyze(make_run(root, lines, [client_row(a, 200, 1.0, 2.0)], []))
        self.assertEqual(s["attempts_per_request"], {"1": 1})

    def test_rejection_before_a_different_terminal_failure_keeps_its_fit_label(self):
        # Concurrency rejection, re-queue, then a final no-endpoints failure from another filter.
        a = "syn-s1-00000"
        lines = [
            line(1.0, a, "EPP received request"),
            line(1.001, a, "Flow control outcome", outcome="Dispatched"),
            line(1.002, a, "Filter eliminated all endpoints", plugin="conc/concurrency-detector"),
            line(1.003, a, "Request re-queued after saturation"),
            line(1.5, a, "Flow control outcome", outcome="Dispatched"),
            line(1.502, a, "Filter eliminated all endpoints", plugin="other/filter"),
            line(1.503, a, "Failed to process request", error="ServiceUnavailable - no endpoints available"),
        ]
        client = [client_row(a, 503, 1.0, 1.504, dropped_reason="rejected-no-endpoints")]
        with tempfile.TemporaryDirectory(dir=Path.home() / ".cache") as root:
            s = analyze.analyze(make_run(root, lines, client, [{"id": a, "prompt_tokens": 10, "max_tokens": 16}]))
        self.assertEqual(s["release_then_reject"], 1)
        self.assertEqual(s["rtr_fit_at_release_gone_at_reject"] + s["rtr_no_fit_even_at_release"], 1)
        self.assertIsNotNone(s["rtr_release_to_reject_ms_p50"])

    def test_completed_stream_without_text_is_counted_not_fatal(self):
        a = "syn-s1-00000"
        lines = [
            line(1.0, a, "EPP received request"),
            line(1.001, a, "Flow control outcome", outcome="Dispatched"),
            line(1.002, a, "Completed running picker plugin successfully", result=endpoint("pod-a")),
            line(1.003, a, "Completed running PreRequest plugin successfully", plugin="inflight-load-producer"),
            line(2.0, a, "HandleResponseBody is triggered", endOfStream=True),
        ]
        row = client_row(a, 200, 1.0, 2.0, done=True, usage_completion_tokens=0)
        del row["ttft_ms"]
        with tempfile.TemporaryDirectory(dir=Path.home() / ".cache") as root:
            s = analyze.analyze(make_run(root, lines, [row], []))
        self.assertEqual(s["successes_without_text"], 1)
        self.assertIsNone(s["ttft_ms_p50"])

    def test_repeated_receive_is_refused(self):
        a = "syn-s1-00000"
        lines = [line(1.0, a, "EPP received request"), line(1.1, a, "EPP received request")]
        with tempfile.TemporaryDirectory(dir=Path.home() / ".cache") as root:
            run = make_run(root, lines, [client_row(a, 200, 1.0, 2.0)], [])
            with self.assertRaises(SystemExit):
                analyze.analyze(run)


class StreamCompletion(unittest.TestCase):
    def test_truncated_and_error_streams_are_not_successes(self):
        self.assertTrue(analyze.stream_ok({"status": 200, "done": True}))
        self.assertFalse(analyze.stream_ok({"status": 200, "done": False}))
        self.assertFalse(analyze.stream_ok({"status": 200, "done": True, "stream_error": "{}"}))
        self.assertFalse(analyze.stream_ok({"status": 200, "done": True, "bad_events": 1}))
        # Records written before the completion fields existed can only be held to status and client error.
        self.assertTrue(analyze.stream_ok({"status": 200}))


class NearestRank(unittest.TestCase):
    def test_matches_the_definition(self):
        xs = list(range(1, 101))
        self.assertEqual(analyze.pct(xs, 50), 50)
        self.assertEqual(analyze.pct(xs, 99), 99)
        self.assertEqual(analyze.pct(xs, 100), 100)
        self.assertEqual(analyze.pct([5, 1, 3, 2], 50), 2)
        self.assertEqual(analyze.pct([5, 1, 3, 2], 99), 5)
        self.assertIsNone(analyze.pct([], 50))


if __name__ == "__main__":
    unittest.main()
