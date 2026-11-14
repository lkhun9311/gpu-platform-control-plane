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
        self.assertAlmostEqual(s["format_error_rate"], 1 / 3)
        self.assertLess(s["macro_f1"], 1.0)
        self.assertEqual(s["rows"], 3)

    def test_mismatched_lengths_and_unknown_gold_are_refused(self):
        with self.assertRaises(ValueError):
            ev.macro_f1(["card_arrival"], [], NAMES)
        with self.assertRaises(ValueError):
            ev.macro_f1(["nope"], ["nope"], NAMES)


if __name__ == "__main__":
    unittest.main()
