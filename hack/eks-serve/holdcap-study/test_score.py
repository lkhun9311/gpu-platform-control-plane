"""Tests score.py on a synthetic run built to meet every line, and on altered copies of it.

    python3 hack/eks-serve/holdcap-study/test_score.py

The passing fixture is what makes the failures mean something: a scorer that rejected everything would fail every
altered copy too.
"""

import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score  # noqa: E402

ORIGIN = 1_000_000_000_000_000
N_PREMIUM, N_CONTENDER = 300, 30


def write_jsonl(path, rows):
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def prom(path, preemptions=0.0):
    with open(path, "w") as f:
        f.write("# HELP x\n")
        f.write('vllm:num_preemptions_total{model_name="m"} %s\n' % preemptions)
        f.write('vllm:num_requests_running{model_name="m"} 0\n')
        f.write('vllm:num_requests_waiting{model_name="m"} 0\n')


def gateway_prom(path):
    with open(path, "w") as f:
        f.write('gpuaas_gateway_admission_mode_active{mode="off"} 1\n')
        f.write('gpuaas_gateway_backend_admission_mode{mode="gateway",name="e",namespace="serve-a"} 1\n')


class Run:
    """A run directory every check passes on; tests bend one thing each."""

    def __init__(self, root):
        self.root = root
        self.traces = os.path.join(root, "traces")
        self.run = os.path.join(root, "run")
        os.makedirs(self.traces)
        os.makedirs(os.path.join(self.run, "cells"))
        self.identity = {"argo": {"gateway": "abc"}, "node": "aws:///ap-northeast-2c/i-1"}
        with open(os.path.join(self.run, "identity-start.json"), "w") as f:
            json.dump(self.identity, f)
        t0 = 0
        for seed in score.SEEDS:
            trace = []
            for i in range(N_PREMIUM + N_CONTENDER):
                tenant = score.CONTENDER if i % 11 == 10 else score.PREMIUM
                trace.append({"index": i, "offsetMs": 100 * i, "tenant": tenant})
            path = os.path.join(self.traces, "trace-off-%d.jsonl" % (seed - 850))
            write_jsonl(path, trace)
            with open(path, "rb") as f:
                checksum = hashlib.sha256(f.read()).hexdigest()
            for arm in score.registered_order(seed):
                t0 += 1
                self.cell(seed, arm, trace, checksum, t0)

    def dir(self, seed, arm):
        return os.path.join(self.run, "cells", score.cell_name(seed, arm))

    def cell(self, seed, arm, trace, checksum, order):
        d = self.dir(seed, arm)
        os.makedirs(d)
        origin = ORIGIN + order * 10**12
        rows = []
        for t in trace:
            premium = t["tenant"] == score.PREMIUM
            n = score.OUTPUT_TOKENS[t["tenant"]]
            ttft_ms = (40 if arm == "HoldCap" else 100) if premium else 2000
            sched = origin + t["offsetMs"] * 10**6
            rows.append({
                "index": t["index"], "tenant": t["tenant"], "scheduledOffsetMs": t["offsetMs"],
                "study": score.STUDY, "arm": arm, "traceChecksum": checksum,
                "replayOriginUnixNanos": origin, "sendUnixNanos": sched + 1_000_000,
                "firstTokenUnixNanos": sched + ttft_ms * 10**6, "returnedUnixNanos": sched + 5 * 10**9,
                "contentGapsMicros": [30_000] * (n - 1), "outputTokens": n, "httpStatus": 200,
                "streamTerminated": True, "enginePriority": score.PRIORITY[arm][t["tenant"]],
            })
        write_jsonl(os.path.join(d, "raw.jsonl"), rows)
        with open(os.path.join(d, "raw.jsonl.sender.json"), "w") as f:
            json.dump({"study": score.STUDY, "arm": arm, "connMode": "pooled", "maxIdleConnsPerHost": 600,
                       "timeoutMs": 30000, "priorities": None}, f)
        start = origin
        end = max(r["returnedUnixNanos"] for r in rows)
        samples = [{"t": t, "statusMode": arm, "backendMode": score.BACKEND_MODE[arm], "processMode": "off",
                    "engineUID": "e-%d-%s" % (seed, arm), "engineRestarts": 0, "gatewayUID": "g", "gatewayRestarts": 0}
                   for t in range(start, end + 1, 5 * 10**9)]
        write_jsonl(os.path.join(d, "samples.jsonl"), samples)
        for side in ("before", "after"):
            prom(os.path.join(d, "metrics-engine-%s.prom" % side))
            gateway_prom(os.path.join(d, "metrics-gateway-%s.prom" % side))
        with open(os.path.join(d, "identity-after.json"), "w") as f:
            json.dump(self.identity, f)
        args = "non-default args: {'model': 'q'%s}" % (", " + score.CAP_ARG if arm == "HoldCap" else "")
        with open(os.path.join(d, "cell.json"), "w") as f:
            json.dump({"cell": score.cell_name(seed, arm), "outcome": "complete", "startedUnixNanos": origin,
                       "enginePodUID": "e-%d-%s" % (seed, arm), "engineNonDefaultArgs": args}, f)

    def rows(self, seed, arm):
        with open(os.path.join(self.dir(seed, arm), "raw.jsonl")) as f:
            return [json.loads(line) for line in f]

    def set_rows(self, seed, arm, rows):
        write_jsonl(os.path.join(self.dir(seed, arm), "raw.jsonl"), rows)

    def edit_rows(self, seed, arm, fn):
        self.set_rows(seed, arm, [fn(r) or r for r in self.rows(seed, arm)])

    def score(self):
        return score.score(self.run, self.traces)


class ScoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.r = Run(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def assertVerdict(self, want, needle):
        verdict, lines = self.r.score()
        self.assertEqual(verdict, want, lines)
        self.assertTrue(any(needle in line for line in lines), "%r not in %s" % (needle, lines))

    def test_the_fixture_passes(self):
        verdict, lines = self.r.score()
        self.assertEqual(verdict, "observed on these traces", lines)

    # Completeness: each makes a block unscorable.
    def test_a_deleted_row(self):
        self.r.set_rows(851, "Off", self.r.rows(851, "Off")[:-1])
        self.assertVerdict("inconclusive", "rows for")

    def test_a_duplicated_row(self):
        rows = self.r.rows(851, "Off")
        self.r.set_rows(851, "Off", rows[:-1] + [rows[0]])
        self.assertVerdict("inconclusive", "appears twice")

    def test_an_extra_row(self):
        rows = self.r.rows(851, "Off")
        self.r.set_rows(851, "Off", rows + [dict(rows[0], index=99999)])
        self.assertVerdict("inconclusive", "rows for")

    def test_a_row_moved_in_time(self):
        self.r.edit_rows(852, "HoldCap", lambda r: r.update(scheduledOffsetMs=r["scheduledOffsetMs"] + 1) if r["index"] == 5 else None)
        self.assertVerdict("inconclusive", "no matching row")

    def test_a_missing_cell(self):
        shutil.rmtree(self.r.dir(853, "HoldCap"))
        self.assertVerdict("inconclusive", "missing")

    def test_a_cell_outside_the_registration(self):
        shutil.copytree(self.r.dir(851, "Off"), os.path.join(self.r.run, "cells", "851-Off-retry"))
        self.assertVerdict("inconclusive", "outside the registration")

    def test_a_wrong_arm_label(self):
        self.r.edit_rows(851, "Off", lambda r: r.update(arm="HoldCap"))
        self.assertVerdict("inconclusive", "is stamped")

    def test_a_wrong_study_label(self):
        self.r.edit_rows(852, "Off", lambda r: r.update(study="admission-diagnostic-2026-10-10"))
        self.assertVerdict("inconclusive", "is stamped")

    def test_a_client_priority(self):
        self.r.edit_rows(852, "Off", lambda r: r.update(priority=0))
        self.assertVerdict("inconclusive", "client priority")

    def test_a_sampling_gap(self):
        path = os.path.join(self.r.dir(851, "HoldCap"), "samples.jsonl")
        with open(path) as f:
            samples = [json.loads(line) for line in f]
        write_jsonl(path, samples[:3] + samples[7:])
        self.assertVerdict("inconclusive", "gap between samples")

    def test_missing_metrics(self):
        os.remove(os.path.join(self.r.dir(851, "Off"), "metrics-engine-after.prom"))
        self.assertVerdict("inconclusive", "metrics-engine-after.prom")

    def test_malformed_metrics(self):
        with open(os.path.join(self.r.dir(851, "Off"), "metrics-gateway-before.prom"), "w") as f:
            f.write("this is not prometheus\n")
        self.assertVerdict("inconclusive", "unparsable")

    def test_a_cut_cell(self):
        path = os.path.join(self.r.dir(853, "Off"), "cell.json")
        with open(path) as f:
            meta = json.load(f)
        meta["outcome"] = "deadline"
        with open(path, "w") as f:
            json.dump(meta, f)
        self.assertVerdict("inconclusive", "outcome 'deadline'")

    # The re-run: its rows carry its own study, named by the run's study-id.txt.
    def restamp(self, study):
        for seed in score.SEEDS:
            for arm in score.ARMS:
                self.r.edit_rows(seed, arm, lambda r: r.update(study=study))
                path = os.path.join(self.r.dir(seed, arm), "raw.jsonl.sender.json")
                with open(path) as f:
                    s = json.load(f)
                s["study"] = study
                with open(path, "w") as f:
                    json.dump(s, f)

    def test_the_re_run_scores_under_its_own_study(self):
        self.restamp(score.STUDIES[1])
        with open(os.path.join(self.r.run, "study-id.txt"), "w") as f:
            f.write(score.STUDIES[1] + "\n")
        verdict, lines = self.r.score()
        self.assertEqual(verdict, "observed on these traces", lines)

    def test_re_run_rows_without_its_study_id_file_are_refused(self):
        # Mutation that turns this red: stamp-check rows against any registered run rather than the one named.
        self.restamp(score.STUDIES[1])
        self.assertVerdict("inconclusive", "is stamped")

    def test_a_study_id_file_naming_another_study(self):
        with open(os.path.join(self.r.run, "study-id.txt"), "w") as f:
            f.write("admission-diagnostic-2026-10-10\n")
        self.assertVerdict("inconclusive", "not a registered run")

    # Validity: each makes a block invalid.
    def test_a_wrong_priority_header(self):
        self.r.edit_rows(851, "Off", lambda r: r.update(enginePriority="1"))
        self.assertVerdict("inconclusive", "engine priority")

    def test_a_status_sample_in_the_wrong_mode(self):
        path = os.path.join(self.r.dir(852, "HoldCap"), "samples.jsonl")
        with open(path) as f:
            samples = [json.loads(line) for line in f]
        samples[2]["statusMode"] = "Off"
        write_jsonl(path, samples)
        self.assertVerdict("inconclusive", "a sample shows")

    def test_the_cap_missing_under_holdcap(self):
        path = os.path.join(self.r.dir(851, "HoldCap"), "cell.json")
        with open(path) as f:
            meta = json.load(f)
        meta["engineNonDefaultArgs"] = "non-default args: {'model': 'q'}"
        with open(path, "w") as f:
            json.dump(meta, f)
        self.assertVerdict("inconclusive", "cap is absent")

    def test_a_late_dispatch(self):
        self.r.edit_rows(853, "Off", lambda r: r.update(sendUnixNanos=r["sendUnixNanos"] + 60_000_000) if r["index"] == 3 else None)
        self.assertVerdict("inconclusive", "50 ms late")

    def test_a_changed_identity(self):
        with open(os.path.join(self.r.dir(853, "Off"), "identity-after.json"), "w") as f:
            json.dump({"argo": {"gateway": "def"}}, f)
        self.assertVerdict("inconclusive", "identity changed")

    def test_an_off_baseline_below_completion(self):
        self.r.edit_rows(852, "Off", lambda r: r.update(httpStatus=0, errorKind="timeout") if r["tenant"] == score.CONTENDER and r["index"] < 100 else None)
        self.assertVerdict("inconclusive", "Off contender completion")

    def test_the_wrong_order(self):
        for arm in score.ARMS:
            path = os.path.join(self.r.dir(851, arm), "cell.json")
            with open(path) as f:
                meta = json.load(f)
            meta["startedUnixNanos"] = -meta["startedUnixNanos"] if arm == "HoldCap" else meta["startedUnixNanos"]
            with open(path, "w") as f:
                json.dump(meta, f)
        self.assertVerdict("inconclusive", "registered")

    # Direct harms: counted even when the block is otherwise invalid.
    def test_a_preemption(self):
        prom(os.path.join(self.r.dir(852, "HoldCap"), "metrics-engine-after.prom"), preemptions=1)
        self.assertVerdict("not met", "preemption")

    def test_a_refusal_in_an_otherwise_invalid_block(self):
        self.r.edit_rows(853, "Off", lambda r: r.update(sendUnixNanos=r["sendUnixNanos"] + 60_000_000) if r["index"] == 3 else None)
        self.r.edit_rows(853, "HoldCap", lambda r: r.update(httpStatus=429, outputTokens=0) if r["index"] == 10 else None)
        self.assertVerdict("not met", "refusal")

    # Acceptance: each line breached in turn.
    def test_line_1_premium_ttft(self):
        self.r.edit_rows(851, "HoldCap", lambda r: r.update(firstTokenUnixNanos=r["firstTokenUnixNanos"] + 60_000_000) if r["tenant"] == score.PREMIUM else None)
        self.assertVerdict("not met", "line 1")

    def test_line_1_counts_a_premium_failure_at_infinity(self):
        # Four premium failures in 300 put the nearest-rank p99 on +inf; dropping them would have passed.
        self.r.edit_rows(851, "HoldCap", lambda r: r.update(httpStatus=0, errorKind="timeout") if r["tenant"] == score.PREMIUM and r["index"] < 5 else None)
        self.assertVerdict("not met", "line 1")

    def test_line_2_contender_completion(self):
        self.r.edit_rows(852, "HoldCap", lambda r: r.update(httpStatus=0, errorKind="timeout") if r["tenant"] == score.CONTENDER and r["index"] < 100 else None)
        self.assertVerdict("not met", "line 2")

    def test_line_3_contender_p95(self):
        self.r.edit_rows(853, "HoldCap", lambda r: r.update(contentGapsMicros=[1_600_000] * 15) if r["tenant"] == score.CONTENDER else None)
        self.assertVerdict("not met", "line 3")

    def test_line_5_premium_gap(self):
        self.r.edit_rows(851, "HoldCap", lambda r: r.update(contentGapsMicros=[40_000] * 63) if r["tenant"] == score.PREMIUM else None)
        self.assertVerdict("not met", "line 5")

    def test_every_premium_request_failing_is_not_met_rather_than_a_crash(self):
        # No premium success leaves no gaps to rank; that must read as a failed line, not an exception.
        self.r.edit_rows(852, "HoldCap", lambda r: r.update(httpStatus=0, errorKind="timeout") if r["tenant"] == score.PREMIUM else None)
        self.assertVerdict("not met", "line 1")

    def test_a_short_stream_is_not_a_success(self):
        self.r.edit_rows(851, "HoldCap", lambda r: r.update(contentGapsMicros=[30_000] * 62) if r["tenant"] == score.PREMIUM and r["index"] < 5 else None)
        self.assertVerdict("not met", "line 1")


if __name__ == "__main__":
    unittest.main()
