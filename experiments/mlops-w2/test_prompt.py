"""Tests for prompt.py. Standard library only."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import evaluate as ev  # noqa: E402
import prompt  # noqa: E402

NAMES = [f"intent_{i}" for i in range(77)]


class Prompt(unittest.TestCase):
    def test_the_labels_are_listed_in_id_order_and_the_message_is_the_user_turn(self):
        system, user = prompt.messages("where is my card?", NAMES)
        lines = system["content"].splitlines()
        self.assertEqual(lines[2:79], NAMES)
        self.assertEqual(user, {"role": "user", "content": "where is my card?"})

    # The training target must be exactly what the evaluator accepts, or a perfectly trained model scores zero.
    def test_the_training_target_parses_as_its_own_label(self):
        for name in NAMES:
            self.assertEqual(ev.parse_answer(prompt.answer(name), NAMES), name)

    # Mutation that turns this red: leave the label order or the generation settings out of the hash.
    def test_the_hash_changes_with_the_label_order_and_the_settings(self):
        base = prompt.template_hash(NAMES)
        self.assertNotEqual(base, prompt.template_hash(list(reversed(NAMES))))
        saved = dict(prompt.GENERATION)
        try:
            prompt.GENERATION["max_new_tokens"] = 64
            self.assertNotEqual(base, prompt.template_hash(NAMES))
        finally:
            prompt.GENERATION.clear()
            prompt.GENERATION.update(saved)


if __name__ == "__main__":
    unittest.main()
