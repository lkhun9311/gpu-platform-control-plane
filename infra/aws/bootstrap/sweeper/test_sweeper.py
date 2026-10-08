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


if __name__ == "__main__":
    unittest.main()
