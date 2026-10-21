"""Tests for analyze.py, on the second rehearsal's evidence trimmed to what the scorer reads.

Each test copies a fixture run, changes the one input a rule reads, and checks the rule moves: a rule that ignores
its input, or reads absence as a pass, fails here.
The fixtures are a rehearsal on a 200 s window, so they are scored with window=200; their numbers are not results.

    python3 -m unittest experiments/distributed-partial-placement/test_analyze.py
"""

import gzip
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import analyze  # noqa: E402

FIXTURE = os.path.join(HERE, "testdata", "rehearsal-2")


def slurp(path):
    with open(path) as f:
        return f.read()


def spill(path, text):
    with open(path, "w") as f:
        f.write(text)
WINDOW = 200


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.out = os.path.join(self.tmp, "study")
        shutil.copytree(FIXTURE, self.out)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def path(self, run, name):
        return os.path.join(self.out, "runs", run, name)

    def run_(self, name):
        return analyze.Run(os.path.join(self.out, "runs", name), window=WINDOW)

    def rewrite(self, run, name, fn):
        """Rewrites a JSON-lines file of a run, one parsed line at a time; fn returns the line or None to drop it."""
        p = self.path(run, name)
        gz = not os.path.exists(p)
        opener = (lambda m: gzip.open(p + ".gz", m + "t")) if gz else (lambda m: open(p, m))
        with opener("r") as f:
            rows = [json.loads(line) for line in f if line.strip()]
        out = [r for r in (fn(r) for r in rows) if r is not None]
        with opener("w") as f:
            f.write("".join(json.dumps(r) + "\n" for r in out))

    def placed_uid(self, run):
        r = self.run_(run)
        return next(u for u, h in r.pod_history().items()
                    if r.started_at(h) and any(o["spec"].get("nodeName") for _, _, o in h))


class Baseline(Fixture):
    def test_both_rehearsal_runs_are_valid_and_score(self):
        for name in ("off-late-1", "ready-timeout-never-1"):
            self.assertEqual(self.run_(name).problems(), [], name)

    def test_the_registered_window_is_required(self):
        # The fixture recorded window=200, so main() must report a rehearsal and never a registered result.
        from io import StringIO
        import contextlib
        buf = StringIO()
        with contextlib.redirect_stdout(buf):
            analyze.main([self.out])
        self.assertIn("NOT the registered study", buf.getvalue())
        self.assertNotIn("VOID", buf.getvalue())


class Settings(Fixture):
    def cfg(self, setting):
        return os.path.join(self.out, "settings", setting, "controller_manager_config.yaml")

    def test_both_settings_are_in_force(self):
        for s in analyze.SETTINGS:
            self.assertEqual(analyze.setting_problems(self.out, s), [], s)

    def test_a_changed_limit_is_not_the_registered_setting(self):
        spill(self.cfg("ready-timeout"), slurp(self.cfg("ready-timeout")).replace("backoffLimitCount: 2", "backoffLimitCount: 3"))
        self.assertTrue(analyze.setting_problems(self.out, "ready-timeout"))

    def test_a_stanza_under_off_is_refused(self):
        spill(self.cfg("off"), slurp(self.cfg("ready-timeout")))
        self.assertTrue(analyze.setting_problems(self.out, "off"))

    def test_no_loaded_configuration_line_fails(self):
        spill(os.path.join(self.out, "settings", "ready-timeout", "controller-startup.log"), "")
        self.assertTrue(analyze.setting_problems(self.out, "ready-timeout"))

    def test_two_controller_pods_fail(self):
        p = os.path.join(self.out, "settings", "off", "pods-after.json")
        with open(p) as fh:
            d = json.load(fh)
        d["items"] = d["items"] * 2
        with open(p, "w") as fh:
            json.dump(d, fh)
        self.assertTrue(analyze.setting_problems(self.out, "off"))


class Validity(Fixture):
    RT = "ready-timeout-never-1"

    def test_a_missing_watch_fails(self):
        os.remove(self.path(self.RT, "watch.workloads.jsonl"))
        self.assertTrue(any("watch" in p for p in self.run_(self.RT).problems()))

    def test_a_sampling_gap_fails(self):
        rows = []
        self.rewrite(self.RT, "timeline.jsonl", lambda r: None if 50 <= len(rows.append(1) or rows) <= 55 else r)
        self.assertTrue(any("gap" in p for p in self.run_(self.RT).problems()))

    def test_a_failed_read_is_missing_not_empty(self):
        rows = []

        def fail(r):
            rows.append(1)
            if 50 <= len(rows) <= 55:
                return {"observed": r["observed"], "ok": False, "errors": {"namespace": "boom"}}
            return r
        self.rewrite(self.RT, "timeline.jsonl", fail)
        self.assertTrue(any("gap" in p for p in self.run_(self.RT).problems()))

    def test_a_squatter_not_running_fails(self):
        rows = []

        def stop(r):
            rows.append(1)
            if len(rows) == 20:
                r["squatter"] = [{"phase": "Failed", "node": "x", "deletionTimestamp": None}]
            return r
        self.rewrite(self.RT, "timeline.jsonl", stop)
        self.assertTrue(any("squatter not Running" in p for p in self.run_(self.RT).problems()))

    def test_no_rendezvous_start_fails(self):
        uid = self.placed_uid(self.RT)
        for f in os.listdir(os.path.join(self.out, "runs", self.RT)):
            if f.startswith(f"log-{uid}") and f.endswith(".txt"):
                p = self.path(self.RT, f)
                with open(p) as fh:
                    lines = [line for line in fh if '"rendezvous_start"' not in line]
                with open(p, "w") as fh:
                    fh.writelines(lines)
        self.assertTrue(any("rendezvous_start" in p for p in self.run_(self.RT).problems()))

    def test_a_trainer_failure_before_capacity_voids(self):
        uid = self.placed_uid(self.RT)
        p = self.path(self.RT, f"log-{uid}.1.txt")
        with open(p, "a") as f:
            f.write(json.dumps({"event": "rendezvous_failed", "ts": "2026-10-21T06:42:30+00:00", "rank": 0}) + "\n")
        self.assertTrue(any("rendezvous_failed" in p for p in self.run_(self.RT).problems()))

    def _exit(self, code):
        uid = self.placed_uid(self.RT)

        def change(e):
            o = e.get("object") or {}
            if o.get("metadata", {}).get("uid") == uid:
                for c in (o.get("status") or {}).get("containerStatuses") or []:
                    term = (c.get("state") or {}).get("terminated")
                    if term:
                        term["exitCode"] = code
            return e
        self.rewrite(self.RT, "watch.pods.jsonl", change)
        return self.run_(self.RT).problems()

    def test_exit_1_during_an_eviction_is_the_trainer(self):
        self.assertTrue(any("ended by itself" in p for p in self._exit(1)))

    def test_exit_143_without_a_sigterm_record_is_not_accounted(self):
        self.assertTrue(any("ended by itself" in p for p in self._exit(143)))

    def test_exit_137_is_accounted(self):
        self.assertEqual(self._exit(137), [])

    def test_a_container_that_ended_before_its_deletion_ended_by_itself(self):
        # The exit code is the eviction's, but the order is not: the container stopped while its Pod was not yet
        # being deleted, so it was not the eviction that stopped it.
        uid = self.placed_uid(self.RT)
        seen = []

        def early(e):
            o = e.get("object") or {}
            if o.get("metadata", {}).get("uid") == uid:
                seen.append(1)
                if len(seen) == 4 and not o["metadata"].get("deletionTimestamp"):
                    for c in (o.get("status") or {}).get("containerStatuses") or []:
                        c["state"] = {"terminated": {"exitCode": 137, "startedAt": "2026-10-21T06:41:52Z",
                                                     "finishedAt": "2026-10-21T06:42:30Z", "reason": "Error"}}
            return e
        self.rewrite(self.RT, "watch.pods.jsonl", early)
        self.assertGreaterEqual(len(seen), 4)
        self.assertTrue(any("before its Pod's deletion" in p for p in self.run_(self.RT).problems()))

    def test_no_admission_fails(self):
        def strip(e):
            o = e.get("object") or {}
            if o.get("kind") == "Workload":
                o["status"]["conditions"] = [c for c in o["status"].get("conditions") or [] if c["type"] != "Admitted"]
            return e
        self.rewrite(self.RT, "watch.workloads.jsonl", strip)
        self.assertIn("no admission observed", self.run_(self.RT).problems())

    def test_not_unschedulable_on_gpu_fails(self):
        def other(e):
            o = e.get("object") or {}
            for c in (o.get("status") or {}).get("conditions") or []:
                if c.get("type") == "PodScheduled" and c.get("message"):
                    c["message"] = c["message"].replace("nvidia.com/gpu", "memory")
            return e
        self.rewrite(self.RT, "watch.pods.jsonl", other)
        self.assertTrue(any("Unschedulable" in p for p in self.run_(self.RT).problems()))

    def test_not_isolated_fails(self):
        p = self.path(self.RT, "isolation.json")
        with open(p) as fh:
            d = json.load(fh)
        d["gpuReserved"] = ["2"]
        with open(p, "w") as fh:
            json.dump(d, fh)
        self.assertTrue(any("not isolated" in p for p in self.run_(self.RT).problems()))


class Measures(Fixture):
    RT = "ready-timeout-never-1"
    LATE = "off-late-1"

    def test_m1_reads_the_crs_phase(self):
        before = self.run_(self.RT).measures()["M1_running_while_stranded_s"]

        def demote(e):
            o = e.get("object") or {}
            if o.get("kind") == "MLTrainingJob" and o["status"].get("phase") == "Running":
                o["status"]["phase"] = "Admitted"
            return e
        self.rewrite(self.RT, "watch.mltrainingjobs.jsonl", demote)
        self.assertGreater(before, 100)
        self.assertEqual(self.run_(self.RT).measures()["M1_running_while_stranded_s"], 0)

    def test_m1_reads_the_pods_scheduling(self):
        def schedule(e):
            o = e.get("object") or {}
            for c in (o.get("status") or {}).get("conditions") or []:
                if c.get("type") == "PodScheduled":
                    c["status"] = "True"
            return e
        self.rewrite(self.RT, "watch.pods.jsonl", schedule)
        self.assertEqual(self.run_(self.RT).measures()["M1_running_while_stranded_s"], 0)

    def test_m1_lies_inside_its_polled_bounds(self):
        m = self.run_(self.RT).measures()
        lo, hi = m["M1_polled_bounds_s"]
        self.assertLessEqual(lo - 1, m["M1_running_while_stranded_s"])
        self.assertLessEqual(m["M1_running_while_stranded_s"], hi + 1)

    def test_m2_is_censored_without_a_release(self):
        def hold(e):
            o = e.get("object") or {}
            if o.get("kind") == "Workload":
                for c in o["status"].get("conditions") or []:
                    if c["type"] == "QuotaReserved":
                        c["status"] = "True"
                        c["lastTransitionTime"] = "2026-10-21T06:41:51Z"
            return e
        self.rewrite(self.RT, "watch.workloads.jsonl", hold)
        m2 = self.run_(self.RT).measures()["M2_quota_held_before_joining"]
        self.assertEqual(len(m2), 1)
        self.assertTrue(m2[0]["censored"])

    def test_a_deactivating_reason_is_matched_by_prefix(self):
        def deact(e):
            o = e.get("object") or {}
            if o.get("kind") == "Workload":
                for c in o["status"].get("conditions") or []:
                    if c["type"] == "Evicted":
                        c["reason"] = "DeactivatedDueToRequeuingLimitExceeded"
            return e
        self.rewrite(self.RT, "watch.workloads.jsonl", deact)
        reasons = [r["reason"] for r in self.run_(self.RT).measures()["M3_requests"]]
        self.assertEqual(reasons, ["DeactivatedDueToRequeuingLimitExceeded"])
        out = [p for p in analyze.predict(self.run_(self.RT), self.run_(self.RT).measures()) if p[0] == "P3"][0]
        self.assertIn("requests starting Deactivated 1", out[2])

    def test_m8_reads_the_containers_finish(self):
        m8 = self.run_(self.RT).measures()["M8_device_held_after_release"]
        self.assertEqual(len(m8), 1)
        self.assertFalse(m8[0]["censored"])
        uid = self.placed_uid(self.RT)

        def later(e):
            o = e.get("object") or {}
            if o.get("metadata", {}).get("uid") == uid:
                for c in (o.get("status") or {}).get("containerStatuses") or []:
                    term = (c.get("state") or {}).get("terminated")
                    if term:
                        term["finishedAt"] = "2026-10-21T06:45:21Z"
            return e
        self.rewrite(self.RT, "watch.pods.jsonl", later)
        moved = self.run_(self.RT).measures()["M8_device_held_after_release"][0]["seconds"]
        self.assertAlmostEqual(moved - m8[0]["seconds"], 60, delta=1)

    def test_p6_reads_the_exit_code(self):
        run = self.run_(self.RT)
        self.assertEqual([p[1] for p in analyze.predict(run, run.measures()) if p[0] == "P6"], ["held"])
        m = run.measures()
        m["M8_device_held_after_release"][0]["exit"] = 143
        self.assertEqual([p[1] for p in analyze.predict(run, m) if p[0] == "P6"], ["contradicted"])

    def test_p2_needs_the_second_placement(self):
        run = self.run_(self.LATE)
        self.assertEqual([p[1] for p in analyze.predict(run, run.measures()) if p[0] == "P2"], ["held"])

        def never(e):
            o = e.get("object") or {}
            if o.get("kind") == "Pod" and o["metadata"]["name"].endswith(tuple("abcdefghijklmnopqrstuvwxyz")) \
                    and "-1-" in o["metadata"]["name"]:
                o["spec"].pop("nodeName", None)
            return e
        self.rewrite(self.LATE, "watch.pods.jsonl", never)
        run = self.run_(self.LATE)
        self.assertEqual([p[1] for p in analyze.predict(run, run.measures()) if p[0] == "P2"], ["contradicted"])

    def test_p5_reads_the_phase_after_the_request(self):
        run = self.run_(self.RT)
        m = run.measures()
        self.assertEqual([p[1] for p in analyze.predict(run, m) if p[0] == "P5"], ["held"])
        m["M7_after_request"][0]["left_running"] = False
        self.assertEqual([p[1] for p in analyze.predict(run, m) if p[0] == "P5"], ["contradicted"])


if __name__ == "__main__":
    unittest.main()
