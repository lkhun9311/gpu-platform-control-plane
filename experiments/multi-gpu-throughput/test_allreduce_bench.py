"""Tests for allreduce_bench.py's arithmetic and refusals, run without torch and without a GPU.

They pin the bandwidth convention, the per-iteration slowest-rank rule and every refusal.
They do not exercise NCCL, CUDA events or a device; the first execution of that path is the registration's smoke
cell, which must treat it as untested code.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import allreduce_bench as bench  # noqa: E402


class BusFactor(unittest.TestCase):
    def test_matches_nccl_tests_convention(self):
        # nccl-tests doc/PERFORMANCE.md: all-reduce busbw = algbw * 2(n-1)/n.
        self.assertEqual(bench.bus_factor(2), 1.0)
        self.assertEqual(bench.bus_factor(4), 1.5)
        self.assertEqual(bench.bus_factor(8), 1.75)

    def test_one_rank_is_refused_not_zero(self):
        with self.assertRaises(bench.SettingRefused):
            bench.bus_factor(1)


class ExpectedSum(unittest.TestCase):
    def test_values(self):
        self.assertEqual(bench.expected_sum(2), 3.0)
        self.assertEqual(bench.expected_sum(4), 10.0)

    def test_buffer_must_hold_it_at_both_ends(self):
        self.assertTrue(bench.buffer_matches(10.0, 10.0, 4))
        # One rank's own value left in place, the shape of a reduction that did not happen.
        self.assertFalse(bench.buffer_matches(1.0, 10.0, 4))
        # A reduction over two of four ranks.
        self.assertFalse(bench.buffer_matches(3.0, 3.0, 4))


class Sizes(unittest.TestCase):
    def test_default_ladder(self):
        self.assertEqual(bench.parse_sizes(""), (1 << 20, 1 << 22, 1 << 24, 1 << 26, 1 << 28))

    def test_explicit(self):
        self.assertEqual(bench.parse_sizes("1024, 4096"), (1024, 4096))

    def test_refusals(self):
        for bad in ("1023", "0", "-4", "1k", "4096,4096", "4096,"):
            with self.subTest(bad=bad), self.assertRaises(bench.SettingRefused):
                bench.parse_sizes(bad)

    def test_counts(self):
        self.assertEqual(bench.parse_count("BENCH_ITERS", "20", 3), 20)
        for bad in ("2", "", "x", "-5"):
            with self.subTest(bad=bad), self.assertRaises(bench.SettingRefused):
                bench.parse_count("BENCH_ITERS", bad, 3)


class Device(unittest.TestCase):
    def test_one_gpu_per_pod_defaults_to_zero(self):
        self.assertEqual(bench.local_device_index({}, 1), 0)

    def test_local_rank_selects(self):
        self.assertEqual(bench.local_device_index({"LOCAL_RANK": "3"}, 4), 3)

    def test_a_device_the_pod_cannot_see_is_refused(self):
        # Four processes in a Pod that was given one GPU would otherwise all drive device 0.
        with self.assertRaises(bench.SettingRefused):
            bench.local_device_index({"LOCAL_RANK": "1"}, 1)
        with self.assertRaises(bench.SettingRefused):
            bench.local_device_index({"LOCAL_RANK": "x"}, 4)


class Summarise(unittest.TestCase):
    def test_slowest_rank_per_iteration(self):
        times = [[0.010, 0.020, 0.030], [0.015, 0.012, 0.040]]
        self.assertEqual(bench.slowest_per_iteration(times), [0.015, 0.020, 0.040])

    def test_ragged_or_empty_or_zero_is_refused(self):
        for bad in ([[0.1, 0.2], [0.1]], [], [[]], [[0.1, 0.0]]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                bench.slowest_per_iteration(bad)

    def test_bandwidth_from_the_median_of_the_slowest(self):
        size = 1 << 28
        times = [[0.1, 0.2, 0.3], [0.1, 0.2, 0.4]]
        record = bench.summarise(size, 4, times, verified=True)
        self.assertEqual(record["time_s_median"], 0.2)
        self.assertAlmostEqual(record["algbw_gigabytes_per_s_median"], size / 0.2 / 1e9)
        self.assertAlmostEqual(record["busbw_gigabytes_per_s_median"], size / 0.2 / 1e9 * 1.5)
        self.assertAlmostEqual(record["busbw_gigabytes_per_s_at_max_time"], size / 0.4 / 1e9 * 1.5)
        self.assertEqual(record["times_s_by_rank"], times)

    def test_an_unverified_size_carries_no_bandwidth(self):
        record = bench.summarise(1 << 20, 4, [[0.1, 0.2, 0.3]] * 4, verified=False)
        self.assertFalse(record["verified"])
        self.assertIn("refused", record)
        for key in ("time_s_median", "algbw_gigabytes_per_s_median", "busbw_gigabytes_per_s_median"):
            self.assertNotIn(key, record)


if __name__ == "__main__":
    unittest.main()
