"""The lineage scorer on its two committed archives.

    python3 -m unittest experiments/mlops-lineage/test_score.py
"""

import io
import os
import sys
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score  # noqa: E402

ARCHIVES = os.path.join(HERE, "..", "..", "hack")


def run_scorer(name: str) -> tuple[int, str]:
    out = io.StringIO()
    argv, sys.argv = sys.argv, ["score.py", os.path.join(ARCHIVES, name)]
    try:
        with redirect_stdout(out):
            rc = score.main()
    finally:
        sys.argv = argv
    return rc, out.getvalue()


class ScoreTest(unittest.TestCase):
    def test_the_amended_run_is_valid(self):
        rc, out = run_scorer("mlops-lineage-20261009T023102Z")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out.splitlines()[-1], "VALID")

    # Fable's audit: the superseded first archive raised KeyError 'done_s' instead of being refused by name.
    def test_the_first_run_is_refused_by_name_not_by_a_traceback(self):
        rc, out = run_scorer("mlops-lineage-20261009T022150Z")
        self.assertEqual(rc, 1, out)
        self.assertIn("poll-rollback-1.tsv has no done_s column, so it predates Amendment 1's poller", out)
        self.assertTrue(out.splitlines()[-1].startswith("VOID"), out)


if __name__ == "__main__":
    unittest.main()
