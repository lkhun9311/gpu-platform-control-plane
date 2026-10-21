"""Tests for analyze.py: the gloo profile pinned to its recorded output, and each nccl criterion shown able to fail.

The nccl fixtures are the archived gloo run's completing arms with their records rewritten to say what a GPU run
would, so every criterion has one fixture that falsifies only its own field.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ARCHIVE = ROOT / "hack" / "multi-pod-ddp-20261014T231122Z"
GOLDEN = HERE / "testdata" / "gloo-20261014T231122Z.txt"
APPROVED = "a" * 64
UUIDS = {0: "GPU-00000000-0000-0000-0000-000000000000", 1: "GPU-11111111-1111-1111-1111-111111111111"}

sys.path.insert(0, str(HERE))
import analyze  # noqa: E402


def score(*argv: str) -> tuple[int, str]:
    out = io.StringIO()
    saved = sys.argv
    sys.argv = ["analyze.py", *argv]
    try:
        with redirect_stdout(out):
            code = analyze.main()
    finally:
        sys.argv = saved
    return code, out.getvalue()


def rewrite_logs(arm_dir: Path, edit) -> None:
    """Applies edit(record) to every JSON record of every Pod log in an arm, keeping the other lines."""
    for log in arm_dir.glob("log-*.txt"):
        lines = []
        for line in log.read_text().splitlines():
            if line.startswith("{"):
                record = json.loads(line)
                edit(record)
                line = json.dumps(record, sort_keys=True)
            lines.append(line)
        log.write_text("\n".join(lines) + "\n")


def nodes_document(labels: dict[str, dict]) -> dict:
    return {"items": [{"metadata": {"name": name, "labels": lab}} for name, lab in labels.items()]}


class Fixture:
    """A copy of the archive's pass and no-sync arms, rewritten into an nccl run."""

    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for arm in ("pass", "no-sync"):
            shutil.copytree(ARCHIVE / arm, self.root / arm)
            rewrite_logs(self.root / arm, self.gpu_record)
            nodes = {p["node"] for p in map(json.loads, (self.root / arm / "pods.jsonl").read_text().splitlines())}
            (self.root / arm / "nodes.json").write_text(json.dumps(nodes_document(
                {n: {"eks.amazonaws.com/nodegroup": "gpu"} for n in nodes})))
        provenance = (ARCHIVE / "provenance.txt").read_text().replace(
            "arms=pass no-sync bad-address one-rank-fails", "arms=pass no-sync")
        (self.root / "provenance.txt").write_text(provenance + "profile=nccl\n")

    @staticmethod
    def gpu_record(record: dict) -> None:
        if record.get("event") == "rendezvous_start":
            record.update(backend_requested="nccl", device_type="cuda", tensor_device_type="cuda",
                          gpu_uuid=UUIDS[record["rank"]], device_name="NVIDIA A10G")
        if record.get("event") == "rendezvous":
            record.update(backend="nccl", script_sha256=APPROVED)

    def edit(self, arm: str, rank: int, which: str, **fields) -> None:
        def apply(record: dict) -> None:
            if record.get("event") == which and record.get("rank") == rank:
                for key, value in fields.items():
                    if value is None:
                        record.pop(key, None)
                    else:
                        record[key] = value
        rewrite_logs(self.root / arm, apply)

    def score(self, *flags: str) -> tuple[int, str]:
        return score(*flags, str(self.root))

    def nccl(self) -> tuple[int, str]:
        return self.score("--profile", "nccl", "--script-sha256", APPROVED)

    def close(self) -> None:
        self.tmp.cleanup()


class GlooUnchanged(unittest.TestCase):
    def test_the_archived_run_scores_exactly_as_recorded(self):
        code, out = score(str(ARCHIVE))
        self.assertEqual(code, 0)
        self.assertEqual(out, GOLDEN.read_text())


class NcclProfile(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()

    def tearDown(self):
        self.fx.close()

    def assertFailsWith(self, needle: str):
        code, out = self.fx.nccl()
        self.assertEqual(code, 1, out)
        bad = [line for line in out.splitlines() if line.strip().startswith("BAD")]
        self.assertTrue(any(needle in line for line in bad), out)

    def test_a_complete_gpu_run_passes(self):
        code, out = self.fx.nccl()
        self.assertEqual(code, 0, out)
        self.assertIn("backend nccl", out)

    def test_a_gloo_backend_fails(self):
        self.fx.edit("pass", 1, "rendezvous", backend="gloo")
        self.assertFailsWith("backend")

    def test_a_cpu_tensor_fails(self):
        self.fx.edit("no-sync", 0, "rendezvous_start", tensor_device_type="cpu")
        self.assertFailsWith("tensor")

    def test_a_missing_device_type_fails(self):
        self.fx.edit("pass", 0, "rendezvous_start", device_type=None)
        self.assertFailsWith("tensor")

    def test_a_missing_gpu_uuid_fails(self):
        self.fx.edit("pass", 1, "rendezvous_start", gpu_uuid=None)
        self.assertFailsWith("GPU UUID")

    def test_one_gpu_shared_by_both_ranks_fails(self):
        self.fx.edit("pass", 1, "rendezvous_start", gpu_uuid=UUIDS[0])
        self.assertFailsWith("GPU UUID")

    def test_a_node_outside_the_gpu_group_fails(self):
        arm = self.fx.root / "pass"
        doc = json.loads((arm / "nodes.json").read_text())
        doc["items"][0]["metadata"]["labels"]["eks.amazonaws.com/nodegroup"] = "gpu_single"
        (arm / "nodes.json").write_text(json.dumps(doc))
        self.assertFailsWith("node group")

    def test_missing_node_objects_fail(self):
        os.remove(self.fx.root / "no-sync" / "nodes.json")
        self.assertFailsWith("node group")

    def test_an_unapproved_script_fails(self):
        self.fx.edit("pass", 0, "rendezvous", script_sha256="b" * 64)
        self.assertFailsWith("script")

    def test_a_missing_rendezvous_record_fails(self):
        self.fx.edit("pass", 1, "rendezvous", event="renamed")
        code, out = self.fx.nccl()
        self.assertEqual(code, 1, out)


class ProfileSelection(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()

    def tearDown(self):
        self.fx.close()

    def test_an_nccl_run_scored_without_the_profile_is_void(self):
        code, out = self.fx.score()
        self.assertEqual(code, 1)
        self.assertIn("VOID", out)
        self.assertIn("profile", out)

    def test_the_nccl_profile_on_a_run_that_did_not_ask_for_it_is_void(self):
        code, out = score("--profile", "nccl", "--script-sha256", APPROVED, str(ARCHIVE))
        self.assertEqual(code, 1)
        self.assertIn("VOID", out)

    def test_the_nccl_profile_without_an_approved_hash_is_refused(self):
        code, _ = self.fx.score("--profile", "nccl")
        self.assertEqual(code, 2)

    def test_an_unknown_profile_is_refused(self):
        code, _ = self.fx.score("--profile", "cuda", "--script-sha256", APPROVED)
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
