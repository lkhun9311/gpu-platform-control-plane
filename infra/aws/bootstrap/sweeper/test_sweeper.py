"""Tests the sweeper's decision without AWS.

    python3 infra/aws/bootstrap/sweeper/test_sweeper.py
"""

import datetime
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sweeper  # noqa: E402

NOW = datetime.datetime(2026, 10, 8, 12, 0, tzinfo=datetime.timezone.utc)


def inst(iid, deadline=None):
    tags = [{"Key": "Name", "Value": "m5c-gpu"}]
    if deadline is not None:
        tags.append({"Key": "study-deadline", "Value": deadline})
    return {"InstanceId": iid, "Tags": tags}


class SweeperTest(unittest.TestCase):
    # KST 20:30 is 11:30 UTC, passed; KST 21:30 is 12:30 UTC, ahead. Mutation that turns it red: compare with >
    # instead of >=, or drop the zone, which reads 20:30 as a UTC time still ahead.
    def test_a_passed_deadline_is_terminated_and_a_future_one_is_not(self):
        got = sweeper.decide([inst("i-past", "2026-10-08T11:59:00Z"), inst("i-now", "2026-10-08T12:00:00+00:00"),
                              inst("i-future", "2026-10-08T12:01:00Z"), inst("i-kst-past", "2026-10-08T20:30:00+09:00"),
                              inst("i-kst-future", "2026-10-08T21:30:00+09:00")], NOW)
        self.assertEqual(sorted(i for i, _ in got), ["i-kst-past", "i-now", "i-past"])

    def test_an_untagged_instance_is_never_touched(self):
        self.assertEqual(sweeper.decide([inst("i-other")], NOW), [])

    # An unreadable deadline is a runner's bug, and an instance nobody can say the end of is terminated.
    def test_an_unreadable_or_zoneless_deadline_is_terminated(self):
        got = sweeper.decide([inst("i-garbage", "tomorrow"), inst("i-naive", "2026-10-09T00:00:00")], NOW)
        self.assertEqual(sorted(i for i, _ in got), ["i-garbage", "i-naive"])

    # A date that overflows when converted to UTC is unreadable, not a crash that ends the sweep (v26 review, C31).
    # Mutation that turns it red: stop catching OverflowError.
    def test_an_overflowing_deadline_is_unreadable_not_a_crash(self):
        got = sweeper.decide([inst("i-edge", "0001-01-01T00:00:00+14:00"), inst("i-past", "2026-10-08T11:59:00Z")], NOW)
        self.assertEqual(sorted(i for i, _ in got), ["i-edge", "i-past"])

    # A refused termination is reported as failed, and the sweep goes on to the next (v26 review, C32).
    # Mutation that turns it red: report every candidate as requested.
    def test_a_refused_termination_is_not_reported_as_requested(self):
        class EC2:
            def get_paginator(self, _):
                class P:
                    def paginate(self, **_):
                        return [{"Reservations": [{"Instances": [inst("i-denied", "2026-10-08T11:00:00Z"),
                                                                 inst("i-ok", "2026-10-08T11:00:00Z")]}]}]
                return P()

            def terminate_instances(self, InstanceIds):
                if InstanceIds == ["i-denied"]:
                    raise RuntimeError("UnauthorizedOperation")
        got = sweeper.sweep(EC2(), NOW)
        self.assertEqual((got["termination_requested"], got["failed"]), (["i-ok"], ["i-denied"]))


if __name__ == "__main__":
    unittest.main()
