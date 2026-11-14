"""Tests for evaluate.py. Standard library only."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import evaluate as ev  # noqa: E402

NAMES = ["card_arrival", "card_linking", "exchange_rate"]


class Parser(unittest.TestCase):
    def test_a_well_formed_answer_names_its_label(self):
        self.assertEqual(ev.parse_answer(' {"label": "card_linking"}\n', NAMES), "card_linking")

    # Mutation that turns this red: accept the label from any JSON object that has one, or from prose around it.
    def test_anything_but_one_object_with_only_a_known_label_is_a_format_error(self):
        for answer in (
            'The label is {"label": "card_linking"}',
            '{"label": "card_linking", "why": "x"}',
            '{"label": "Card_Linking"}',
            '{"label": "unknown_label"}',
            '["card_linking"]',
            '{"label": 1}',
            "card_linking",
            "",
        ):
            with self.subTest(answer=answer):
                self.assertEqual(ev.parse_answer(answer, NAMES), ev.FORMAT_ERROR)

    # Mutation that turns this red: drop the repeated-key hook; json.loads keeps the last value of a repeated key.
    def test_a_repeated_key_is_a_format_error(self):
        self.assertEqual(ev.parse_answer('{"label": "exchange_rate", "label": "card_linking"}', NAMES), ev.FORMAT_ERROR)

    # Mutation that turns this red: parse a length-stopped answer like any other.
    def test_a_truncated_generation_is_truncated_even_when_it_parses(self):
        self.assertEqual(ev.parse_answer('{"label": "card_linking"}', NAMES, truncated=True), ev.TRUNCATED)


class Metrics(unittest.TestCase):
    def test_macro_f1_is_the_unweighted_mean_over_every_label(self):
        gold = ["card_arrival"] * 2 + ["card_linking"] * 2 + ["exchange_rate"] * 2
        pred = ["card_arrival", "card_linking", "card_linking", "card_linking", "exchange_rate", "exchange_rate"]
        # card_arrival: tp1 fn1 -> 2/3; card_linking: tp2 fp1 -> 4/5; exchange_rate: 1.
        self.assertAlmostEqual(ev.macro_f1(gold, pred, NAMES), (2 / 3 + 4 / 5 + 1) / 3)

    # Mutation that turns this red: leave format errors out of the rows scored.
    def test_a_format_error_counts_as_a_wrong_prediction(self):
        gold = ["card_arrival", "card_linking", "exchange_rate"]
        with_error = ["card_arrival", ev.FORMAT_ERROR, "exchange_rate"]
        s = ev.summarise(gold, with_error, NAMES)
        self.assertAlmostEqual(s["accuracy"], 2 / 3)
        self.assertEqual(s["format_error_rows"], 1)
        self.assertEqual(s["not_ok_rows"], 1)
        self.assertLess(s["macro_f1"], 1.0)
        self.assertEqual(s["rows"], 3)
        self.assertEqual(s["per_label_recall"]["card_linking"], 0.0)

    # The design's reason for accuracy: a row answered badly in form must cost what a row answered wrongly costs.
    # Mutation that turns this red: make macro-F1 the primary metric again, or skip format errors in accuracy.
    def test_a_format_error_costs_exactly_what_a_wrong_label_costs(self):
        names = [f"l{i}" for i in range(77)]
        gold = [n for n in names for _ in range(40)]
        wrong, malformed = list(gold), list(gold)
        for i in range(30):
            wrong[i], malformed[i] = "l1", ev.FORMAT_ERROR
        self.assertEqual(ev.summarise(gold, wrong, names)["accuracy"], ev.summarise(gold, malformed, names)["accuracy"])
        # Under macro-F1 the malformed answers would have scored better, which is why it is not the primary metric.
        self.assertGreater(ev.macro_f1(gold, malformed, names), ev.macro_f1(gold, wrong, names))

    def test_mismatched_lengths_and_unknown_gold_are_refused(self):
        with self.assertRaises(ValueError):
            ev.macro_f1(["card_arrival"], [], NAMES)
        with self.assertRaises(ValueError):
            ev.macro_f1(["nope"], ["nope"], NAMES)


class PairedInterval(unittest.TestCase):
    names = [f"l{i}" for i in range(77)]
    gold = {f"r{i:04d}": f"l{i // 40}" for i in range(77 * 40)}

    def test_identical_predictions_give_exactly_zero(self):
        lo, hi = ev.paired_accuracy_interval(self.gold, self.gold, dict(self.gold), resamples=500)
        self.assertEqual((lo, hi), (0.0, 0.0))

    # Mutation that turns this red: pair rows by position instead of by id.
    def test_rows_are_paired_by_id_not_by_order(self):
        a = {rid: ("l0" if i % 9 == 0 else g) for i, (rid, g) in enumerate(self.gold.items())}
        b = {rid: ("l0" if i % 13 == 0 else g) for i, (rid, g) in enumerate(self.gold.items())}
        reordered = dict(reversed(list(b.items())))
        self.assertEqual(ev.paired_accuracy_interval(self.gold, a, b, resamples=500),
                         ev.paired_accuracy_interval(self.gold, a, reordered, resamples=500))

    def test_a_clearly_better_model_has_an_interval_above_zero(self):
        worse = {rid: ("l0" if i % 5 == 0 and g != "l0" else g) for i, (rid, g) in enumerate(self.gold.items())}
        lo, hi = ev.paired_accuracy_interval(self.gold, self.gold, worse, resamples=500)
        self.assertGreater(lo, 0.0)
        self.assertLess(lo, hi)

    def test_models_scored_on_different_rows_are_refused(self):
        other = dict(self.gold)
        other.pop("r0000")
        with self.assertRaises(ValueError):
            ev.paired_accuracy_interval(self.gold, self.gold, other, resamples=10)


if __name__ == "__main__":
    unittest.main()
