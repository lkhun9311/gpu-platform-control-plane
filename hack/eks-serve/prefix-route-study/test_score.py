"""The scorer on a synthetic study built to meet every line, and on altered copies that must each fail, naming why.

    python3 -m unittest hack/eks-serve/prefix-route-study/test_score.py
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score  # noqa: E402

N = 200
ORIGIN = 1_800_000_000_000_000_000
A, B = score.BACKENDS
# Two lines as vLLM 0.27.1 wrote them in the paid run 2,
# hack/prefix-route/2026-10-28-run2/prefix-route-study/cells/control-944-LeastQueue/engine-a.log.
REAL_ARGS_LINE = (
    "(APIServer pid=1) INFO 10-28 06:05:59 [api_utils.py:273] non-default args: {'model_tag': 'Qwen/Qwen2.5-3B-Instruct', "
    "'model': 'Qwen/Qwen2.5-3B-Instruct', 'dtype': 'half', 'revision': 'aa8e72537993ba99e69dfaafa59ed015b17504d1', "
    "'tokenizer_revision': 'aa8e72537993ba99e69dfaafa59ed015b17504d1', 'max_model_len': 16384, "
    "'served_model_name': ['Qwen/Qwen2.5-3B-Instruct'], 'gpu_memory_utilization': 0.9, 'enable_prefix_caching': True, "
    "'max_num_batched_tokens': 512, 'max_num_seqs': 64, 'scheduling_policy': 'priority', 'async_scheduling': False}\n")
REAL_VERSION_LINE = "(APIServer pid=1) INFO 10-28 06:05:59 [api_utils.py:345]  ▄▄ ▄█ █     █     █ ▀▄▀ █  version 0.27.1\n"


def trace_rows(block: str) -> list[dict]:
    control = block == score.CONTROL_BLOCK
    return [{"index": i, "offsetMs": i * 100, "tenant": score.TENANT, "promptLenChars": 41000, "maxOutputTokens": 64,
             "minOutputTokens": 64, "prefixGroup": 1 + i % 20, "prefixChars": 40000, "prefixControl": control,
             "promptSeed": int(block.rsplit("-", 1)[1])} for i in range(N)]


def backend_for(arm: str, row: dict) -> str:
    if arm == "PrefixAffinity":
        return A if row["prefixGroup"] % 2 else B
    return A if row["index"] % 2 == 0 else B


def ttft_for(arm: str, block: str, i: int) -> float:
    base = 100 if arm == "PrefixAffinity" and block != score.CONTROL_BLOCK else 300
    return base + i % 10


def hit_ratio(arm: str, block: str) -> float:
    if block == score.CONTROL_BLOCK:
        return 0.002
    return 0.8 if arm == "PrefixAffinity" else 0.5


def prom_engine(success: int, queries: int, hits: int, capacity: int = 393232, caching: str = "True") -> str:
    return (f'vllm:prefix_cache_queries_total{{engine="0",model_name="m"}} {queries}\n'
            f'vllm:prefix_cache_hits_total{{engine="0",model_name="m"}} {hits}\n'
            f'vllm:request_success_total{{engine="0",finished_reason="length",model_name="m"}} {success}\n'
            f'vllm:cache_config_info{{block_size="16",enable_prefix_caching="{caching}",engine="0",'
            f'kv_cache_size_tokens="{capacity}",num_gpu_blocks="24577"}} 1.0\n')


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)


IDENTITY = {"argo": {"gpu-platform-gateway": "abc"}, "images": {"gateway": "g@sha256:1", "operator": "o@sha256:2"},
            "gatewayArgs": [["/gateway"]], "gpuNodes": ["i-1", "i-2"]}


def build(root: str) -> dict[str, str]:
    write(os.path.join(root, "study-id.txt"), score.STUDY + "\n")
    write(os.path.join(root, "identity-start.json"), json.dumps(IDENTITY))
    frozen = {}
    for block in score.BLOCKS:
        trace = trace_rows(block)
        text = "".join(json.dumps(r) + "\n" for r in trace)
        write(os.path.join(root, "traces", f"{block}.jsonl"), text)
        checksum = hashlib.sha256(text.encode()).hexdigest()
        frozen[block] = checksum
        for arm in score.ARMS:
            d = os.path.join(root, "cells", f"{block}-{arm}")
            rows = []
            for t in trace:
                ttft = ttft_for(arm, block, t["index"])
                at = ORIGIN + t["offsetMs"] * 1_000_000
                rows.append({"index": t["index"], "arm": arm, "study": score.STUDY, "tenant": t["tenant"],
                             "scheduledOffsetMs": t["offsetMs"], "sendUnixNanos": at + 1_000_000,
                             "replayOriginUnixNanos": ORIGIN, "firstTokenUnixNanos": at + int(ttft * 1e6),
                             "returnedUnixNanos": at + int(ttft * 1e6) + 400_000_000,
                             "httpStatus": 200, "streamTerminated": True, "outputTokens": 64, "engineOutputTokens": 64,
                             "contentGapsMicros": [1000] * 63, "traceChecksum": checksum, "routingPolicy": arm,
                             "routedBackend": backend_for(arm, t)})
            write(os.path.join(d, "raw.jsonl"), "".join(json.dumps(r) + "\n" for r in rows))
            write(os.path.join(d, "raw.jsonl.sender.json"), json.dumps(
                {"study": score.STUDY, "arm": arm, "connMode": "pooled", "maxIdleConnsPerHost": 600, "timeoutMs": 30000}))
            write(os.path.join(d, "identity-after.json"), json.dumps(IDENTITY))
            ids = {"engineAUID": "ua", "engineBUID": "ub", "gatewayUID": "ug", "engineARestarts": "0",
                   "engineBRestarts": "0", "gatewayRestarts": "0"}
            write(os.path.join(d, "cell.json"), json.dumps(dict(ids, cell=f"{block}-{arm}", outcome="complete")))
            write(os.path.join(d, "samples.jsonl"), "".join(
                json.dumps(dict(ids, t=ORIGIN + k * 5_000_000_000, engineALoad=1, engineBLoad=1)) + "\n" for k in range(5)))
            h = hit_ratio(arm, block)
            for b, f in score.ENGINE_FILE.items():
                served = sum(1 for r in rows if r["routedBackend"] == b)
                write(os.path.join(d, f"metrics-engine-{f}-before.prom"), prom_engine(2, 100, 0))
                write(os.path.join(d, f"metrics-engine-{f}-after.prom"),
                      prom_engine(2 + served, 100 + served * 1000, int(served * 1000 * h)))
                write(os.path.join(d, f"engine-{f}-args.txt"), REAL_ARGS_LINE)
                write(os.path.join(d, f"engine-{f}.log"), REAL_VERSION_LINE + REAL_ARGS_LINE)
            write(os.path.join(d, "metrics-gateway-before.prom"), "")
            write(os.path.join(d, "metrics-gateway-after.prom"),
                  f'gpuaas_gateway_routing_decisions_total{{policy="{arm}"}} {N}\n')
    return frozen


class ScorerTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="prefix-route-score-")
        self.frozen = build(self.root)
        self._real = score.frozen_checksums
        score.frozen_checksums = lambda: dict(self.frozen)

    def tearDown(self):
        score.frozen_checksums = self._real
        shutil.rmtree(self.root)

    def run_scorer(self, *extra: str) -> tuple[int, str]:
        out = io.StringIO()
        with redirect_stdout(out):
            rc = score.main(["score.py", self.root, *extra])
        return rc, out.getvalue()

    def cell(self, block="shared-941", arm="PrefixAffinity") -> str:
        return os.path.join(self.root, "cells", f"{block}-{arm}")

    def rows(self, block="shared-941", arm="PrefixAffinity") -> list[dict]:
        with open(os.path.join(self.cell(block, arm), "raw.jsonl")) as handle:
            return [json.loads(line) for line in handle]

    def put_rows(self, rows, block="shared-941", arm="PrefixAffinity"):
        write(os.path.join(self.cell(block, arm), "raw.jsonl"), "".join(json.dumps(r) + "\n" for r in rows))

    def expect(self, fragment: str, rc_want: int = 1):
        rc, out = self.run_scorer()
        self.assertEqual(rc, rc_want, out)
        self.assertIn(fragment, out.splitlines()[0], out)

    def test_meets_every_line(self):
        rc, out = self.run_scorer()
        self.assertEqual(rc, 0, out)
        self.assertEqual(out.splitlines()[0], "verdict: observed on these traces")

    # Review of 981f6031: the flag is accepted from any caller, so a paid run scored with it once passed with exit 0
    # while a treatment engine ran max_num_seqs 1.
    def test_unpinned_pass_is_not_the_registered_verdict(self):
        rc, out = self.run_scorer("--engine-unpinned")
        self.assertEqual(rc, 1, out)
        self.assertEqual(out.splitlines()[0], "verdict: rehearsal only, not a result: the traces met every line, "
                         "but the engine pin was not checked")
        self.assertIn("engine pin: NOT CHECKED", out)

    def test_missing_row(self):
        self.put_rows(self.rows()[1:])
        self.expect("inconclusive: cell shared-941-PrefixAffinity: 199 rows")

    def test_duplicated_row(self):
        rows = self.rows()
        self.put_rows(rows + rows[:1])
        self.expect("appears twice")

    def test_extra_row(self):
        rows = self.rows()
        extra = dict(rows[0], index=N)
        self.put_rows(rows + [extra])
        self.expect("201 rows")

    def test_wrong_arm_stamp(self):
        rows = self.rows()
        rows[5]["arm"] = "RoundRobin"
        self.put_rows(rows)
        self.expect("is stamped")

    def test_wrong_policy_header(self):
        rows = self.rows()
        rows[5]["routingPolicy"] = "RoundRobin"
        self.put_rows(rows)
        self.expect("was routed under")

    def test_unknown_backend(self):
        rows = self.rows()
        rows[5]["routedBackend"] = "prefix-route/qwen-c"
        self.put_rows(rows)
        self.expect("names backend")

    def test_sample_gap(self):
        path = os.path.join(self.cell(), "samples.jsonl")
        with open(path) as handle:
            samples = [json.loads(line) for line in handle]
        # Samples 5 s apart: dropping three leaves a 20 s gap, past the 15 s line; dropping two would leave exactly 15 s.
        del samples[1:4]
        write(path, "".join(json.dumps(s) + "\n" for s in samples))
        self.expect("gap over 15 s")

    def test_metrics_missing_a_series(self):
        path = os.path.join(self.cell(), "metrics-engine-a-after.prom")
        with open(path) as handle:
            text = handle.read()
        write(path, "\n".join(l for l in text.splitlines() if not l.startswith(score.HITS)) + "\n")
        self.expect(f"lacks {score.HITS}")

    def test_engine_count_off_by_one(self):
        rows = self.rows()
        moved = next(r for r in rows if r["routedBackend"] == A)
        moved["routedBackend"] = B
        self.put_rows(rows)
        self.expect("finished")

    def test_fallback(self):
        write(os.path.join(self.cell(), "metrics-gateway-after.prom"),
              'gpuaas_gateway_routing_decisions_total{policy="PrefixAffinity"} 200\n'
              'gpuaas_gateway_backend_fallbacks_total{tenant="premium-1",model="m"} 1\n')
        self.expect("fallback")

    def test_caching_off_in_args(self):
        write(os.path.join(self.cell(), "engine-b-args.txt"),
              REAL_ARGS_LINE.replace("'enable_prefix_caching': True", "'enable_prefix_caching': False"))
        self.expect("differs in ['enable_prefix_caching']")

    def test_caching_off_in_args_when_unpinned(self):
        # The rehearsal skips the pin, and prefix caching must still be checked there.
        write(os.path.join(self.cell(), "engine-b-args.txt"),
              REAL_ARGS_LINE.replace("'enable_prefix_caching': True", "'enable_prefix_caching': False"))
        rc, out = self.run_scorer("--engine-unpinned")
        self.assertEqual(rc, 1, out)
        self.assertIn("did not report prefix caching on", out.splitlines()[0], out)
        self.assertIn("engine pin: NOT CHECKED", out)

    # Audit finding 10: changing the treatment cell's engine to another model and max_num_seqs 1 scored exit 0,
    # "observed on these traces", because only prefix caching was read from the args.
    def test_another_model_in_one_cell(self):
        write(os.path.join(self.cell(), "engine-a-args.txt"),
              REAL_ARGS_LINE.replace("'model': 'Qwen/Qwen2.5-3B-Instruct'", "'model': 'Qwen/Qwen2.5-0.5B-Instruct'"))
        self.expect("differs in ['model']")

    def test_max_num_seqs_one_in_one_cell(self):
        write(os.path.join(self.cell(), "engine-b-args.txt"), REAL_ARGS_LINE.replace("'max_num_seqs': 64", "'max_num_seqs': 1"))
        self.expect("differs in ['max_num_seqs']")

    def test_an_added_argument(self):
        write(os.path.join(self.cell(), "engine-a-args.txt"), REAL_ARGS_LINE.replace("}\n", ", 'enforce_eager': True}\n"))
        self.expect("differs in ['enforce_eager']")

    def test_another_engine_version(self):
        write(os.path.join(self.cell(), "engine-a.log"), REAL_VERSION_LINE.replace("0.27.1", "0.28.0") + REAL_ARGS_LINE)
        self.expect("reports vLLM 0.28.0, not 0.27.1")

    def test_no_engine_version(self):
        write(os.path.join(self.cell(), "engine-b.log"), REAL_ARGS_LINE)
        self.expect("reports vLLM no version")

    def test_args_that_are_not_vllms_line(self):
        write(os.path.join(self.cell(), "engine-a-args.txt"), "non-default args: {'model': \n")
        self.expect("are not one 'non-default args: ' line")

    def test_the_paid_run_meets_the_engine_pin(self):
        # Every engine args file the paid run 2 committed must parse to the registered engine, or the pin would
        # void the published result rather than guard it.
        cells = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "prefix-route",
                             "2026-10-28-run2", "prefix-route-study", "cells")
        seen = 0
        for cell in sorted(os.listdir(cells)):
            for f in ("a", "b"):
                with open(os.path.join(cells, cell, f"engine-{f}-args.txt")) as handle:
                    self.assertEqual(score.engine_args(handle.read()), score.REGISTERED_ENGINE_ARGS, cell)
                with open(os.path.join(cells, cell, f"engine-{f}.log")) as handle:
                    self.assertEqual(score.VERSION_RE.search(handle.read()).group(1), score.REGISTERED_ENGINE_VERSION)
                seen += 1
        self.assertEqual(seen, 24)

    def test_capacity_outside_tolerance(self):
        path = os.path.join(self.cell(), "metrics-engine-a-after.prom")
        with open(path) as handle:
            text = handle.read()
        write(path, text.replace('kv_cache_size_tokens="393232"', 'kv_cache_size_tokens="370000"'))
        self.expect("not within 5%")

    def test_pod_replaced_mid_cell(self):
        path = os.path.join(self.cell(), "samples.jsonl")
        with open(path) as handle:
            samples = [json.loads(line) for line in handle]
        samples[3]["engineAUID"] = "other"
        write(path, "".join(json.dumps(s) + "\n" for s in samples))
        self.expect("engineAUID")

    def test_dispatch_lag(self):
        rows = self.rows()
        rows[7]["sendUnixNanos"] += 60_000_000
        self.put_rows(rows)
        self.expect("dispatched")

    def test_round_robin_below_completion(self):
        rows = self.rows(arm="RoundRobin")
        for r in rows[:3]:
            r["engineOutputTokens"] = 63
        self.put_rows(rows, arm="RoundRobin")
        self.expect("completed 0.9850")

    def test_control_shows_a_gain(self):
        d = self.cell(score.CONTROL_BLOCK, "PrefixAffinity")
        for f in ("a", "b"):
            path = os.path.join(d, f"metrics-engine-{f}-after.prom")
            with open(path) as handle:
                text = handle.read()
            lines = []
            for line in text.splitlines():
                if line.startswith(score.HITS):
                    name, value = line.rsplit(" ", 1)
                    line = f"{name} {int(float(value)) + 5000}"
                lines.append(line)
            write(path, "\n".join(lines) + "\n")
        self.expect("not attributable to prefix affinity")

    def test_hit_ratio_not_raised(self):
        d = self.cell("shared-942", "LeastQueue")
        for f in ("a", "b"):
            path = os.path.join(d, f"metrics-engine-{f}-after.prom")
            with open(path) as handle:
                text = handle.read()
            out = []
            for line in text.splitlines():
                if line.startswith(score.HITS):
                    name, _ = line.rsplit(" ", 1)
                    line = f"{name} 100000"
                out.append(line)
            write(path, "\n".join(out) + "\n")
        rc, out = self.run_scorer()
        self.assertEqual(rc, 1)
        self.assertIn("not met: rule 3", out.splitlines()[0])
        self.assertIn("not raised in shared-942", out)

    def test_ttft_not_lowered(self):
        rows = self.rows("shared-943", "PrefixAffinity")
        for r in rows:
            r["firstTokenUnixNanos"] += 1_000_000_000
        self.put_rows(rows, "shared-943", "PrefixAffinity")
        rc, out = self.run_scorer()
        self.assertEqual(rc, 1)
        self.assertIn("rule 4 p50", out.splitlines()[0])
        self.assertIn("rule 4 p99", out.splitlines()[0])

    def test_hot_backend_by_share(self):
        rows = self.rows()
        # Move every request to qwen-a, and the engines' counts with it, so only the share line can fail.
        for r in rows:
            r["routedBackend"] = A
        self.put_rows(rows)
        d = self.cell()
        write(os.path.join(d, "metrics-engine-a-after.prom"), prom_engine(2 + N, 100 + N * 1000, int(N * 800)))
        write(os.path.join(d, "metrics-engine-b-after.prom"), prom_engine(2, 100, 0))
        rc, out = self.run_scorer()
        self.assertEqual(rc, 1, out)
        self.assertIn("rule 5", out.splitlines()[0])
        self.assertIn("share 1.000 >", out)

    def test_hot_backend_by_tail(self):
        rows = self.rows()
        worst = [r for r in rows if r["routedBackend"] == A][:3]
        for r in worst:
            r["firstTokenUnixNanos"] += 5_000_000_000
        self.put_rows(rows)
        rc, out = self.run_scorer()
        self.assertEqual(rc, 1, out)
        self.assertIn("worse-backend p99", out)

    def test_wrong_trace(self):
        self.frozen["shared-941"] = "0" * 64
        self.expect("not the frozen")

    def test_missing_cell(self):
        shutil.rmtree(self.cell("control-944", "LeastQueue"))
        self.expect("was never run")

    def test_stopped_study(self):
        write(os.path.join(self.root, "STOPPED"), "cell x: no fresh engine\n")
        self.expect("inconclusive: cell x: no fresh engine")

    # The archived counterexample: 64 tokens in 63 content events is a complete request.
    def test_content_events_do_not_decide_success(self):
        rows = self.rows(arm="RoundRobin")
        for r in rows[:5]:
            r["outputTokens"] = 63
            r["contentGapsMicros"] = r["contentGapsMicros"][:62]
        self.put_rows(rows, arm="RoundRobin")
        rc, out = self.run_scorer()
        self.assertEqual(rc, 0, out)

    # A gain the control reproduces is not prefix affinity's, however small the control's own gain is.
    def test_control_matching_a_small_shared_gain(self):
        for block in score.BLOCKS:
            for arm in score.ARMS:
                d = self.cell(block, arm)
                h = 0.502 if arm == "PrefixAffinity" else 0.5
                rows = self.rows(block, arm)
                for b, f in score.ENGINE_FILE.items():
                    served = sum(1 for r in rows if r["routedBackend"] == b)
                    write(os.path.join(d, f"metrics-engine-{f}-after.prom"),
                          prom_engine(2 + served, 100 + served * 1000, int(served * 1000 * h)))
        self.expect("not attributable to prefix affinity")

    # An infinite tail on the treatment's backend is a worse tail, not an incomparable one.
    def test_infinite_treatment_tail(self):
        rows = self.rows()
        for r in [r for r in rows if r["routedBackend"] == A][:3]:
            r["engineOutputTokens"] = 10
        self.put_rows(rows)
        rc, out = self.run_scorer()
        self.assertEqual(rc, 1, out)
        self.assertIn("worse-backend p99 inf", out.splitlines()[0])

    def test_round_robin_backend_tail_must_be_finite(self):
        rows = self.rows(arm="RoundRobin")
        for r in rows:
            r["engineOutputTokens"] = 64
        b_rows = [r for r in rows if r["routedBackend"] == B]
        for r in b_rows[:2]:
            r["engineOutputTokens"] = 10
        self.put_rows(rows, arm="RoundRobin")
        self.expect("so rule 5 has no reference")

    # A failure a complete shared block shows is not hidden by a stop later in the study.
    def test_failure_survives_a_stop(self):
        rows = self.rows("shared-941", "PrefixAffinity")
        for r in rows:
            r["firstTokenUnixNanos"] += 1_000_000_000
        self.put_rows(rows, "shared-941", "PrefixAffinity")
        shutil.rmtree(self.cell("control-944", "PrefixAffinity"))
        write(os.path.join(self.root, "STOPPED"), "cell control-944-PrefixAffinity: no fresh engine\n")
        rc, out = self.run_scorer()
        self.assertEqual(rc, 1, out)
        self.assertTrue(out.splitlines()[0].startswith("verdict: not met: rule 4 p50"), out)
        self.assertIn("incomplete", out.splitlines()[0])

    def test_product_identity_changed(self):
        changed = dict(IDENTITY, images={"gateway": "g@sha256:9", "operator": "o@sha256:2"})
        write(os.path.join(self.cell("shared-942", "LeastQueue"), "identity-after.json"), json.dumps(changed))
        self.expect("images changed")

    def test_sender_timeout(self):
        path = os.path.join(self.cell(), "raw.jsonl.sender.json")
        write(path, json.dumps({"study": score.STUDY, "arm": "PrefixAffinity", "connMode": "pooled",
                                "maxIdleConnsPerHost": 600, "timeoutMs": 60000}))
        self.expect("the sender is not the registered one")

    # Two samples at the start say nothing about the rest of the replay (codex review).
    def test_samples_stop_early(self):
        path = os.path.join(self.cell(), "samples.jsonl")
        with open(path) as handle:
            samples = [json.loads(line) for line in handle]
        write(path, "".join(json.dumps(s) + "\n" for s in samples[:2]))
        self.expect("do not cover the replay")

    # A gateway steady across cells with a changed routing size is still not the registered treatment (codex review).
    def test_gateway_with_arguments(self):
        changed = dict(IDENTITY, gatewayArgs=[["/gateway", "--routing-prefix-capacity-chunks=1"]])
        write(os.path.join(self.root, "identity-start.json"), json.dumps(changed))
        for block in score.BLOCKS:
            for arm in score.ARMS:
                write(os.path.join(self.cell(block, arm), "identity-after.json"), json.dumps(changed))
        self.expect("not the registered")

    def test_usage(self):
        with redirect_stdout(io.StringIO()):
            self.assertEqual(score.main(["score.py"]), 2)


if __name__ == "__main__":
    unittest.main()
