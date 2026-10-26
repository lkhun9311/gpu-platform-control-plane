"""Tests for ddp_step_bench.py's arithmetic and refusals, run without torch and without a GPU.

They pin the model's gradient size, the slowest-rank rule, both correctness checks and every refusal.
They do not exercise DDP, NCCL or a device; the first execution of that path is the registration's smoke block.
"""

from __future__ import annotations

import json
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ddp_step_bench as bench  # noqa: E402


class ModelSize(unittest.TestCase):
    def test_registered_model_is_the_ladders_top(self):
        # Four Linear(4096, 4096): the registration's 67,125,248 parameters and 268,500,992 bytes, about 256 MiB.
        self.assertEqual(bench.parameter_count(4, 4096), 67_125_248)
        self.assertEqual(bench.gradient_bytes(4, 4096), 268_500_992)
        self.assertAlmostEqual(bench.gradient_bytes(4, 4096) / 2**20, 256.06, places=2)


class Settings(unittest.TestCase):
    def test_counts_refused_not_defaulted(self):
        for text in ("", "x", "-1", "2.5", "0"):
            with self.assertRaises(bench.SettingRefused):
                bench.parse_count("STEP_PAIRS", text, 1)
        self.assertEqual(bench.parse_count("STEP_PAIRS", "50", 3), 50)

    def test_device_index(self):
        self.assertEqual(bench.local_device_index({}, 1), 0)
        self.assertEqual(bench.local_device_index({"LOCAL_RANK": "3"}, 4), 3)
        with self.assertRaises(bench.SettingRefused):
            bench.local_device_index({"LOCAL_RANK": "1"}, 1)
        with self.assertRaises(bench.SettingRefused):
            bench.local_device_index({"LOCAL_RANK": "a"}, 4)


class Slowest(unittest.TestCase):
    def test_max_per_step(self):
        self.assertEqual(bench.slowest_per_step([[1.0, 4.0], [2.0, 3.0]]), [2.0, 4.0])

    def test_ragged_and_zero_refused(self):
        with self.assertRaises(ValueError):
            bench.slowest_per_step([[1.0, 2.0], [1.0]])
        with self.assertRaises(ValueError):
            bench.slowest_per_step([[1.0, 0.0]])
        with self.assertRaises(ValueError):
            bench.slowest_per_step([])


class Checksums(unittest.TestCase):
    def test_synced_must_agree_exactly(self):
        self.assertEqual(bench.checksums_agree([[1.5, 2.5], [1.5, 2.5]]), 0)
        # One rank's step differs by the last bit: a reduction that did not reach it.
        self.assertEqual(bench.checksums_agree([[1.5, 2.5], [1.5, math.nextafter(2.5, 3)]]), 1)
        self.assertEqual(bench.checksums_agree([[float("nan")], [float("nan")]]), 1)
        with self.assertRaises(ValueError):
            bench.checksums_agree([[], []])

    def test_local_must_differ(self):
        self.assertEqual(bench.checksums_differ([[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]), 0)
        # Two ranks equal on a local step: the inputs were not rank-dependent.
        self.assertEqual(bench.checksums_differ([[1.0, 2.0], [1.0, 4.0]]), 1)
        self.assertEqual(bench.checksums_differ([[float("nan")], [1.0]]), 1)


class Reduction(unittest.TestCase):
    # Two ranks, three parameters; local sums differ by rank, and the synced sum is their mean.
    local = [[1.0, -2.0, 4.0], [3.0, 2.0, 0.0]]
    magnitude = [[10.0, 10.0, 10.0], [10.0, 10.0, 10.0]]

    def test_the_average_passes(self):
        synced = [[2.0, 0.0, 2.0], [2.0, 0.0, 2.0]]
        self.assertEqual(bench.reduction_mismatches(synced, self.local, self.magnitude), 0)

    def test_a_rank_that_kept_its_own_gradient_fails(self):
        # Rank 1 never reduced: its synced sums are its local ones. Equal-across-ranks alone could not catch a
        # rank-wide version of this; the oracle does.
        synced = [[2.0, 0.0, 2.0], [3.0, 2.0, 0.0]]
        self.assertEqual(bench.reduction_mismatches(synced, self.local, self.magnitude), 3)

    def test_a_sum_instead_of_a_mean_fails(self):
        synced = [[4.0, 0.0, 4.0], [4.0, 0.0, 4.0]]
        self.assertEqual(bench.reduction_mismatches(synced, self.local, self.magnitude), 2)

    def test_rounding_within_the_derived_tolerance_passes(self):
        # 1e-6 of the mean magnitude 10 is 1e-5; a difference of 5e-6 is float32 rounding, not a missing rank.
        synced = [[2.0 + 5e-6, 0.0, 2.0], [2.0, 0.0, 2.0 - 5e-6]]
        self.assertEqual(bench.reduction_mismatches(synced, self.local, self.magnitude), 0)
        synced = [[2.0 + 2e-5, 0.0, 2.0], [2.0, 0.0, 2.0]]
        self.assertEqual(bench.reduction_mismatches(synced, self.local, self.magnitude), 1)

    def test_an_all_zero_gradient_proves_nothing(self):
        zeros = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
        self.assertEqual(bench.reduction_mismatches(zeros, zeros, zeros), 3)

    def test_nan_fails(self):
        synced = [[float("nan"), 0.0, 2.0], [2.0, 0.0, 2.0]]
        self.assertEqual(bench.reduction_mismatches(synced, self.local, self.magnitude), 1)

    def test_shapes_refused(self):
        with self.assertRaises(ValueError):
            bench.reduction_mismatches([[1.0]], [[1.0]], [[1.0]])
        with self.assertRaises(ValueError):
            bench.reduction_mismatches([[1.0], [1.0, 2.0]], [[1.0], [1.0]], [[1.0], [1.0]])

    def test_tolerance_is_the_derived_one(self):
        # Three float32 additions per element at unit roundoff 2**-24 is about 1.8e-7; 1e-6 is that rounded up.
        self.assertLess(3 * 2.0**-24, bench.REDUCTION_RELATIVE_TOLERANCE)
        self.assertEqual(bench.REDUCTION_RELATIVE_TOLERANCE, 1e-6)


class Summary(unittest.TestCase):
    def test_verified_reports_milliseconds_and_sync_cost(self):
        record = bench.summarise([[0.050, 0.060, 0.055], [0.052, 0.058, 0.070]],
                                 [[0.010, 0.012, 0.011], [0.011, 0.013, 0.010]], 0, 0, 0)
        self.assertTrue(record["verified"])
        # Slowest per step: synced 52, 60, 70 ms (median 60); local 11, 13, 11 ms (median 11).
        self.assertAlmostEqual(record["synced_ms_median"], 60.0)
        self.assertAlmostEqual(record["local_ms_median"], 11.0)
        self.assertAlmostEqual(record["sync_cost_ms"], 49.0)
        self.assertEqual(record["synced_steps"], 3)

    def test_unverified_reports_no_time(self):
        for mismatches, collisions, reduction in ((1, 0, 0), (0, 1, 0), (0, 0, 1)):
            record = bench.summarise([[0.05]], [[0.01]], mismatches, collisions, reduction)
            self.assertFalse(record["verified"])
            self.assertNotIn("synced_ms_median", record)
            self.assertNotIn("sync_cost_ms", record)
            self.assertIn("refused", record)


class Records(unittest.TestCase):
    def test_large_record_only_alone(self):
        big = {"event": "steps", "x": "y" * 5000}
        with self.assertRaises(bench.RecordTooLarge):
            bench.record_line(big, alone=False)
        line = bench.record_line(big, alone=True)
        self.assertEqual(json.loads(line)["event"], "steps")


if __name__ == "__main__":
    unittest.main()
