"""The replica-limit scorer on the committed valid run, and on copies of it cut below the registered load.

    python3 -m unittest experiments/gateway-replica-limit/test_score.py
"""

import io
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score  # noqa: E402

# The run the README reports as VALID, captured from loadgen and the runner on 2026-10-09.
VALID_RUN = os.path.join(HERE, "..", "..", "hack", "gateway-replica-limit-20261009T010205Z")


class ScoreTest(unittest.TestCase):
    def setUp(self):
        self.run = tempfile.mkdtemp(prefix="replica-limit-score-")
        for name in os.listdir(VALID_RUN):
            shutil.copy(os.path.join(VALID_RUN, name), self.run)

    def tearDown(self):
        shutil.rmtree(self.run)

    def score(self) -> tuple[int, str]:
        out = io.StringIO()
        argv, sys.argv = sys.argv, ["score.py", self.run]
        try:
            with redirect_stdout(out):
                rc = score.main()
        finally:
            sys.argv = argv
        return rc, out.getvalue()

    def keep_rows(self, name: str, keep) -> None:
        """Rewrite one arm's TSV keeping the data rows keep() selects by index, and keep the run otherwise consistent."""
        path = os.path.join(self.run, name)
        with open(path) as f:
            header, *rows = f.read().splitlines()
        self.put_rows(name, header, [r for i, r in enumerate(rows) if keep(i)])

    def put_rows(self, name: str, header: str, rows: list[str]) -> None:
        # The stub's served count is set to the client's 200s, as the audit's reproduction did, so the existing
        # stub-versus-client check passes and the load check is the only one that can void the copy.
        with open(os.path.join(self.run, name), "w") as f:
            f.write("\n".join([header] + rows) + "\n")
        status = header.split("\t").index("status")
        admitted = sum(r.split("\t")[status] == "200" for r in rows)
        arm, rep = name.removesuffix(".tsv").rsplit("-", 1)
        arms_path = os.path.join(self.run, "arms.tsv")
        with open(arms_path) as f:
            arms_header, *arms = f.read().splitlines()
        cols = arms_header.split("\t")
        out = []
        for line in arms:
            fields = line.split("\t")
            if fields[cols.index("arm")] == arm and fields[cols.index("rep")] == rep:
                fields[cols.index("stub_served")] = str(admitted)
            out.append("\t".join(fields))
        with open(arms_path, "w") as f:
            f.write("\n".join([arms_header] + out) + "\n")

    def assert_void_by_load_alone(self, fragment: str) -> None:
        rc, out = self.score()
        self.assertEqual(rc, 1, out)
        invalid = [line.strip() for line in out.splitlines() if "INVALID" in line]
        self.assertEqual(len(invalid), 1, out)
        self.assertIn(fragment, invalid[0])

    def test_the_committed_run_is_valid(self):
        rc, out = self.score()
        self.assertEqual(rc, 0, out)
        self.assertEqual(out.splitlines()[-1], "VALID")

    # Audit finding 11: five requests over 0.4 s passed every check as a valid repetition.
    def test_five_requests_over_four_tenths_of_a_second(self):
        self.keep_rows("R1-fresh-1.tsv", lambda i: i < 5)
        self.assert_void_by_load_alone("5 requests dispatched over 0.40")

    def test_a_run_cut_short_at_the_same_rate(self):
        self.keep_rows("R2-pinned-2.tsv", lambda i: i < 150)
        self.assert_void_by_load_alone("150 requests dispatched over 14.90")

    def test_the_right_span_at_half_the_rate(self):
        # Every other request dropped keeps the 29.8 s span, so the count is what fails; a span check alone passes it.
        self.keep_rows("R2-fresh-3.tsv", lambda i: i % 2 == 0)
        self.assert_void_by_load_alone("150 requests dispatched over 29.80")

    def test_the_right_count_over_too_short_a_span(self):
        # 300 requests whose dispatch is compressed into half the time: the count passes and the span does not.
        path = os.path.join(self.run, "R2-pinned-1.tsv")
        with open(path) as f:
            header, *rows = f.read().splitlines()
        sent = header.split("\t").index("sent_ms")
        first = float(rows[0].split("\t")[sent])
        squeezed = []
        for r in rows:
            fields = r.split("\t")
            fields[sent] = f"{first + (float(fields[sent]) - first) / 2:.3f}"
            squeezed.append("\t".join(fields))
        self.put_rows("R2-pinned-1.tsv", header, squeezed)
        self.assert_void_by_load_alone("300 requests dispatched over 14.95")


if __name__ == "__main__":
    unittest.main()
