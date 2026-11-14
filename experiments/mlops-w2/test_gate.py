"""Tests for gate.py: each refusal fixture breaks only the rule it targets, and positive fixtures keep the gate honest.

Standard library only. Intervals use 1,000 resamples here for speed; the registered 10,000 is the gate's default.
"""

import copy
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import evaluate as ev  # noqa: E402
import gate  # noqa: E402

NAMES = [f"l{i}" for i in range(77)]
GOLD = {f"test-{i:04d}": NAMES[i // 40] for i in range(77 * 40)}
REG = gate.Registered(test_manifest_sha256="t" * 64, label_map_sha256=gate.label_map_digest(NAMES), gold=GOLD, names=NAMES)
MODEL = {"base_revision": "b1", "adapter_sha256": "a1", "tokenizer_revision": "k1", "inference_manifest_sha256": "i1",
         "label_map_sha256": REG.label_map_sha256}
R = 1000


def artifact(wrong_every: int, *, malformed: int = 0, swap: tuple[str, str] | None = None, model=None) -> gate.Artifact:
    """An artifact that answers every wrong_every-th row with the next label, the first `malformed` rows as format
    errors, and optionally swaps two labels everywhere."""
    rows = []
    # Malformed rows are spread one per label (each label's first row, label by label), so they never collapse a label.
    spread = sorted(range(len(GOLD)), key=lambda i: (i % 40, i))[:malformed]
    for i, (rid, g) in enumerate(sorted(GOLD.items())):
        label, outcome = g, "ok"
        if wrong_every and i % wrong_every == 0:
            label = NAMES[(NAMES.index(g) + 1) % 77]
        if swap and g in swap:
            label = swap[1] if g == swap[0] else swap[0]
        if i in spread:
            label, outcome = None, ev.FORMAT_ERROR
        rows.append({"id": rid, "gold": g, "raw": "", "finish": "stop", "outcome": outcome, "label": label})
    manifest = {"model": dict(model or MODEL), "test_manifest_sha256": REG.test_manifest_sha256,
                "label_map_sha256": REG.label_map_sha256, "predictions_sha256": gate.predictions_digest(rows),
                "test_evaluation_index": 1, "plan_test_budget": 3}
    return gate.Artifact(manifest, rows)


def controls():
    return {"tfidf": artifact(10), "pretrained": artifact(3)}  # 90% and about 67%


def decide(cand, **kw):
    kw.setdefault("promote", dict(MODEL))
    return gate.decide(cand, kw.pop("controls", controls()), REG, resamples=R, **kw)


def has(decision, reason):
    return any(r.startswith(reason) for r in decision.reasons)


class Positive(unittest.TestCase):
    # Without this, a gate that refuses everything would pass every refusal test below.
    def test_a_good_candidate_is_offline_qualified(self):
        d = decide(artifact(50))
        self.assertEqual(d.decision, gate.OFFLINE_QUALIFIED, d.reasons)
        self.assertIn("no champion: the rule against it was not applied", d.notes)

    def test_a_candidate_equal_to_its_champion_is_not_refused_as_worse(self):
        d = decide(artifact(50), champion=artifact(50), reference=artifact(50))
        self.assertEqual(d.decision, gate.OFFLINE_QUALIFIED, d.reasons)
        self.assertEqual(d.numbers["minus_champion"], [0.0, 0.0])


class WellFormed(unittest.TestCase):
    # 1% of 3,080 is 30.8 rows: 30 passes, 31 is refused. Mutation that turns this red: >= instead of >, or a rate sum.
    def test_the_boundary_is_thirty_rows(self):
        self.assertEqual(decide(artifact(50, malformed=30)).decision, gate.OFFLINE_QUALIFIED)
        d = decide(artifact(50, malformed=31))
        self.assertEqual(d.decision, gate.REFUSE)
        self.assertTrue(has(d, gate.MALFORMED), d.reasons)

    # The 30-row case from the design: answered badly in form or wrongly in content, the gate sees the same accuracy.
    def test_format_errors_and_wrong_labels_cost_the_same(self):
        malformed = decide(artifact(0, malformed=30))
        wrong = artifact(0)
        for row in wrong.rows[:30]:
            row["label"] = NAMES[(NAMES.index(row["gold"]) + 1) % 77]
        wrong.manifest["predictions_sha256"] = gate.predictions_digest(wrong.rows)
        self.assertEqual(malformed.numbers["candidate"]["accuracy"], decide(wrong).numbers["candidate"]["accuracy"])


class LabelMap(unittest.TestCase):
    # Two labels swapped and everything else perfect beat the champion on average; v1 promoted exactly this.
    # Mutation that turns this red: drop the per-label floor and the label map rule.
    def test_two_swapped_labels_are_refused(self):
        swapped = dict(MODEL, label_map_sha256=gate.label_map_digest(NAMES[:2][::-1] + NAMES[2:]))
        d = decide(artifact(0, swap=("l0", "l1"), model=swapped), promote=swapped, champion=artifact(10))
        self.assertEqual(d.decision, gate.REFUSE)
        self.assertTrue(has(d, gate.LABEL_MAP), d.reasons)
        self.assertTrue(has(d, gate.COLLAPSED), d.reasons)
        self.assertGreater(d.numbers["candidate"]["accuracy"], 0.97)

    # The floor alone, with the label map intact: a model that never answers one intent is refused.
    def test_a_collapsed_label_is_refused_even_with_the_right_map(self):
        d = decide(artifact(0, swap=("l0", "l1")))
        self.assertTrue(has(d, gate.COLLAPSED), d.reasons)
        self.assertFalse(has(d, gate.LABEL_MAP), d.reasons)


class Controls(unittest.TestCase):
    # Mutation that turns this red: skip the control comparison, or compare with >= 0 against a tie.
    def test_a_candidate_that_does_not_beat_tfidf_is_refused(self):
        d = decide(artifact(10))
        self.assertTrue(has(d, "does_not_beat_tfidf"), d.reasons)

    def test_a_missing_control_refuses(self):
        d = decide(artifact(50), controls={"tfidf": artifact(10)})
        self.assertTrue(has(d, "does_not_beat_pretrained"), d.reasons)


class ChampionAndReference(unittest.TestCase):
    def test_a_clearly_worse_candidate_is_refused(self):
        d = decide(artifact(12), champion=artifact(0))  # about 91.7% against a perfect champion
        self.assertTrue(has(d, "worse_than_champion"), d.reasons)

    # Mutation that turns this red: call a straddling interval worse, or call it fine.
    def test_a_straddling_interval_is_insufficient_evidence(self):
        d = decide(artifact(40), champion=artifact(50))  # 2.5% vs 2% wrong; the interval measured [-0.011, 0.0016]
        lo, hi = d.numbers["minus_champion"]
        self.assertLess(lo, gate.NONINFERIORITY_MARGIN)
        self.assertGreater(hi, gate.NONINFERIORITY_MARGIN)
        self.assertEqual(d.decision, gate.INSUFFICIENT, d.reasons)

    def test_the_fixed_reference_is_judged_like_the_champion(self):
        d = decide(artifact(12), champion=artifact(12), reference=artifact(0))
        self.assertTrue(has(d, "worse_than_reference"), d.reasons)


class Integrity(unittest.TestCase):
    def test_rows_in_another_order_give_the_same_decision(self):
        a = artifact(50)
        b = copy.deepcopy(a)
        b.rows.reverse()
        self.assertEqual(decide(a).numbers, decide(b).numbers)

    # Mutation that turns this red: stop checking the predictions digest.
    def test_a_predictions_file_that_does_not_match_its_manifest_is_refused(self):
        a = artifact(50)
        a.rows[0]["label"] = "l5"
        self.assertTrue(has(decide(a), gate.INTEGRITY))

    def test_a_missing_or_repeated_row_is_refused(self):
        a = artifact(50)
        a.rows.pop()
        a.manifest["predictions_sha256"] = gate.predictions_digest(a.rows)
        self.assertTrue(has(decide(a), gate.INTEGRITY))
        b = artifact(50)
        b.rows[1] = dict(b.rows[0])
        b.manifest["predictions_sha256"] = gate.predictions_digest(b.rows)
        self.assertTrue(has(decide(b), gate.INTEGRITY))

    def test_a_non_finite_or_missing_number_is_refused(self):
        for value in (math.nan, math.inf, None, "1"):
            a = artifact(50)
            a.manifest["test_evaluation_index"] = value
            with self.subTest(value=value):
                self.assertTrue(has(decide(a), gate.INTEGRITY))

    def test_another_test_set_is_not_comparable(self):
        a = artifact(50)
        a.manifest["test_manifest_sha256"] = "x" * 64
        self.assertTrue(has(decide(a), gate.NOT_COMPARABLE))

    # Mutation that turns this red: compare only the adapter, or skip the binding.
    def test_an_evaluation_of_another_artifact_is_refused(self):
        for key in ("adapter_sha256", "base_revision", "tokenizer_revision", "inference_manifest_sha256"):
            with self.subTest(key=key):
                d = decide(artifact(50), promote=dict(MODEL, **{key: "other"}))
                self.assertTrue(has(d, gate.NOT_BOUND), d.reasons)

    def test_a_test_evaluation_beyond_the_plan_is_refused(self):
        a = artifact(50)
        a.manifest["test_evaluation_index"] = 4
        self.assertTrue(has(decide(a), gate.TEST_BUDGET))


if __name__ == "__main__":
    unittest.main()
