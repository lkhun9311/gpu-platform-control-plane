"""Tests for tfidf.py. Needs scikit-learn, so `make w2-control` runs it in a throwaway environment from requirements.txt."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gate  # noqa: E402
import tfidf  # noqa: E402

NAMES = [f"l{i}" for i in range(77)]


def split(words_per_label: dict[int, str], copies: int) -> list[tuple[str, int]]:
    return [(f"{word} {i}", label) for label, word in words_per_label.items() for i in range(copies)]


class Control(unittest.TestCase):
    # The vectorizer must never see dev or test text, or the control is tuned on the rows that judge it.
    # Every fit choose_c makes is watched, so the check is on what selection actually trains on.
    # Mutation that turns this red: fit on train and dev together inside choose_c.
    def test_selection_fits_on_train_only(self):
        train = split({i: f"trainword{i}" for i in range(77)}, 3)
        dev = split({i: f"devonly{i}" for i in range(77)}, 1)
        seen = []
        real_fit = tfidf.fit

        def watched(rows, c):
            seen.extend(text for text, _ in rows)
            return real_fit(rows, c)

        tfidf.fit = watched
        try:
            tfidf.choose_c(train, dev)
        finally:
            tfidf.fit = real_fit
        self.assertTrue(seen, "choose_c fitted nothing")
        self.assertFalse([t for t in seen if t.startswith("devonly")], "dev text reached a fit")

    # Mutation that turns this red: break ties toward the larger C.
    def test_a_tie_on_dev_goes_to_the_smaller_c(self):
        train = split({i: f"w{i}" for i in range(77)}, 3)
        dev = split({i: f"w{i}" for i in range(77)}, 1)
        c, scores = tfidf.choose_c(train, dev)
        self.assertEqual(set(scores.values()), {1.0}, "every C separates these perfectly, so all tie")
        self.assertEqual(c, min(tfidf.C_GRID))

    # The control's output must be something the gate accepts as an artifact on the registered rows.
    def test_its_artifact_passes_the_gates_integrity_checks(self):
        test = [("x", i % 77) for i in range(77 * 2)]
        predicted = [i % 77 for i in range(77 * 2)]
        art = tfidf.artifact(test, predicted, NAMES, "t" * 64, {"c": 1.0})
        reg = gate.Registered("t" * 64, gate.label_map_digest(NAMES), {r["id"]: r["gold"] for r in art.rows}, NAMES)
        preds, reasons = gate._predictions(art, reg, "tfidf")  # noqa: SLF001 - the gate's own reading of an artifact
        self.assertEqual(reasons, [])
        self.assertEqual(len(preds), 77 * 2)


if __name__ == "__main__":
    unittest.main()
