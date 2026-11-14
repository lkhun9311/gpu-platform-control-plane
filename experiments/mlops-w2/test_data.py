"""Tests for data.py's split rules, label parsing and pinning. Standard library only, so scorer-tests can run them."""

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import data  # noqa: E402


def rows(per_label: int, prefix: str = "t") -> list[tuple[str, int]]:
    return [(f"{prefix} {label} {i}", label) for label in range(data.LABELS) for i in range(per_label)]


class SplitRules(unittest.TestCase):
    # Mutation that turns this red: stop removing train rows whose text is in test.
    def test_a_train_row_also_in_test_is_removed(self):
        train = rows(40)
        test = [("  T 5 3 ", 5)]  # the same text as a train row once normalised
        splits, report = data.build_splits(train, test)
        self.assertEqual(report["removed_in_test"], 1)
        self.assertNotIn("t 5 3", {data.normalise(t) for t, _ in splits["train"] + splits["dev"]})
        self.assertEqual(splits["test"], test, "test is used whole, as published")

    # Mutation that turns this red: keep every copy of a repeated train text.
    def test_a_repeated_train_text_is_kept_once(self):
        train = rows(40) + [("t 7 0", 7)]
        splits, report = data.build_splits(train, [])
        self.assertEqual(report["removed_repeated"], 1)
        self.assertEqual(sum(1 for t, _ in splits["train"] + splits["dev"] if t == "t 7 0"), 1)

    def test_a_repeated_text_with_two_labels_is_refused(self):
        with self.assertRaises(data.DataError):
            data.build_splits(rows(40) + [("t 7 0", 8)], [])

    # Mutation that turns this red: drop the per-label minimum.
    def test_every_label_keeps_at_least_the_minimum_in_dev(self):
        splits, _ = data.build_splits(rows(10), [])
        dev = {}
        for _, label in splits["dev"]:
            dev[label] = dev.get(label, 0) + 1
        self.assertEqual(len(dev), data.LABELS)
        self.assertGreaterEqual(min(dev.values()), data.MIN_DEV_PER_LABEL)
        self.assertEqual(len(splits["train"]) + len(splits["dev"]), data.LABELS * 10)

    def test_the_split_is_fixed_by_its_seed(self):
        a, _ = data.build_splits(rows(40), [])
        b, _ = data.build_splits(list(reversed(rows(40))), [])
        self.assertEqual(data.split_hash(a["dev"]), data.split_hash(b["dev"]), "input order must not move rows")
        c, _ = data.build_splits(rows(40), [], seed=1)
        self.assertNotEqual(data.split_hash(a["dev"]), data.split_hash(c["dev"]))

    def test_a_label_missing_from_train_is_refused(self):
        with self.assertRaises(data.DataError):
            data.build_splits([r for r in rows(40) if r[1] != 3], [])


class Labels(unittest.TestCase):
    def card(self, n: int) -> str:
        return "dataset_info:\n  features:\n    class_label:\n      names:\n" + "".join(
            f"          '{i}': name_{i}\n" for i in range(n)) + "  splits:\n"

    def test_the_77_names_are_read_in_id_order(self):
        names = data.label_names(self.card(77))
        self.assertEqual(names[0], "name_0")
        self.assertEqual(names[76], "name_76")

    # Mutation that turns this red: accept any number of names.
    def test_a_card_with_another_count_is_refused(self):
        for n in (76, 78):
            with self.assertRaises(data.DataError):
                data.label_names(self.card(n))


class Pinning(unittest.TestCase):
    # Mutation that turns this red: skip the sha256 comparison.
    def test_a_file_that_differs_from_the_pinned_one_is_refused(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as dest:
            for name in data.FILES:
                p = Path(src) / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(b"not the measured file")
            with self.assertRaises(data.DataError):
                data.download(Path(dest), base=Path(src).as_uri())

    def test_a_file_that_matches_is_accepted(self):
        with tempfile.TemporaryDirectory() as src, tempfile.TemporaryDirectory() as dest:
            pinned = dict(data.FILES)
            try:
                for name in data.FILES:
                    p = Path(src) / name
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_bytes(name.encode())
                    data.FILES[name] = hashlib.sha256(name.encode()).hexdigest()
                got = data.download(Path(dest), base=Path(src).as_uri())
                self.assertEqual(set(got), set(data.FILES))
            finally:
                data.FILES.clear()
                data.FILES.update(pinned)


if __name__ == "__main__":
    unittest.main()
