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


class ReviewOfB3d1194(Fixture):
    """One test per defect codex gpt-6-astra found in commit b3d1194's scorer; each failed against that commit."""

    RT = "ready-timeout-never-1"
    LATE = "off-late-1"

    def append(self, run, name, rows):
        with open(self.path(run, name), "a") as f:
            f.write("".join(json.dumps(r) + "\n" for r in rows))

    def last_object(self, run, name, pred):
        p = self.path(run, name)
        with open(p) as f:
            rows = [json.loads(line) for line in f if line.strip()]
        return [r["object"] for r in rows if r.get("object") and pred(r["object"])][-1]

    def second_eviction(self):
        """A second PodsReadyTimeout at 06:44:52 that stops the second attempt, whose rank ends at 06:45:05."""
        import copy
        w = self.last_object(self.RT, "watch.workloads.jsonl", lambda o: o["kind"] == "Workload")
        ev = copy.deepcopy(w)
        for c in ev["status"]["conditions"]:
            if c["type"] == "Evicted":
                c.update(status="True", reason="PodsReadyTimeout", lastTransitionTime="2026-10-21T06:44:52Z")
        rel = copy.deepcopy(ev)
        for c in rel["status"]["conditions"]:
            if c["type"] in ("QuotaReserved", "Admitted"):
                c.update(status="False", lastTransitionTime="2026-10-21T06:44:53Z")
        self.append(self.RT, "watch.workloads.jsonl", [
            {"arrived": "2026-10-21T06:44:52.000+00:00", "kind": "workloads", "type": "MODIFIED", "object": ev},
            {"arrived": "2026-10-21T06:44:53.000+00:00", "kind": "workloads", "type": "MODIFIED", "object": rel}])
        j = copy.deepcopy(self.last_object(self.RT, "watch.jobs.jsonl", lambda o: o["kind"] == "Job"))
        j["spec"]["suspend"] = True
        self.append(self.RT, "watch.jobs.jsonl", [
            {"arrived": "2026-10-21T06:44:52.500+00:00", "kind": "jobs", "type": "MODIFIED", "object": j}])
        pod = copy.deepcopy(self.last_object(self.RT, "watch.pods.jsonl",
                                             lambda o: o["metadata"]["uid"].startswith("50bd5486")))
        deleting = copy.deepcopy(pod)
        deleting["metadata"]["deletionTimestamp"] = "2026-10-21T06:44:52Z"
        dead = copy.deepcopy(deleting)
        dead["status"]["containerStatuses"][0]["state"] = {"terminated": {
            "exitCode": 137, "reason": "Error", "startedAt": "2026-10-21T06:44:21Z", "finishedAt": "2026-10-21T06:45:05Z"}}
        self.append(self.RT, "watch.pods.jsonl", [
            {"arrived": "2026-10-21T06:44:52.300+00:00", "kind": "pods", "type": "MODIFIED", "object": deleting},
            {"arrived": "2026-10-21T06:45:05.100+00:00", "kind": "pods", "type": "MODIFIED", "object": dead},
            {"arrived": "2026-10-21T06:45:06.000+00:00", "kind": "pods", "type": "DELETED", "object": dead}])

    def test_m8_takes_each_releases_own_rank(self):
        self.second_eviction()
        m8 = self.run_(self.RT).measures()["M8_device_held_after_release"]
        self.assertEqual([h["seconds"] for h in m8], [28.9, 12.0])

    def test_nothing_after_the_window_is_evidence(self):
        # The rank's end arrives 3.2 s after a 147 s window, so inside that window it has not ended.
        run = analyze.Run(os.path.join(self.out, "runs", self.RT), window=147)
        m8 = run.measures()["M8_device_held_after_release"]
        self.assertTrue(all(h["censored"] for h in m8), m8)

    def test_a_deletion_request_alone_is_not_a_stopped_attempt(self):
        uid = self.placed_uid(self.RT)
        cut = []

        def truncate(e):
            o = e.get("object") or {}
            if o.get("metadata", {}).get("uid") == uid:
                if cut:
                    return None
                if o["metadata"].get("deletionTimestamp"):
                    cut.append(1)
            return e
        self.rewrite(self.RT, "watch.pods.jsonl", truncate)
        self.assertEqual(self.run_(self.RT).measures()["M3_stopped"], [False])

    def test_a_watch_that_stopped_early_disagrees_with_the_poll(self):
        seen = []

        def cut(e):
            o = e.get("object") or {}
            if seen:
                return None
            if o.get("kind") == "MLTrainingJob" and o["status"].get("phase") == "Running":
                seen.append(1)
            return e
        self.rewrite(self.RT, "watch.mltrainingjobs.jsonl", cut)
        self.assertTrue(any("disagrees with the poll" in p for p in self.run_(self.RT).problems()))

    def test_p1_reads_running_while_stranded(self):
        # The late run relabelled as never, with the pending rank scheduled 20 s in: Running, but no longer stranded.
        with open(self.path(self.LATE, "run.txt")) as f:
            setting, _, rep, name = f.read().split()
        with open(self.path(self.LATE, "run.txt"), "w") as f:
            f.write(f"{setting} never {rep} {name}\n")
        os.remove(self.path(self.LATE, "squatter-deleted-at.txt"))

        def schedule(e):
            o = e.get("object") or {}
            if o.get("kind") == "Pod" and e["arrived"] > "2026-10-21T06:45:52":
                for c in o["status"].get("conditions") or []:
                    if c.get("type") == "PodScheduled":
                        c["status"] = "True"
            return e
        self.rewrite(self.LATE, "watch.pods.jsonl", schedule)

        def stay_running(e):
            o = e.get("object") or {}
            if o.get("kind") == "MLTrainingJob" and o["status"].get("phase") == "Succeeded":
                o["status"]["phase"] = "Running"
            return e
        self.rewrite(self.LATE, "watch.mltrainingjobs.jsonl", stay_running)
        run = self.run_(self.LATE)
        m = run.measures()
        # Every other P1 condition is made to hold, so only the share of Running-while-stranded can decide it.
        m["M2_quota_held_before_joining"] = [{"seconds": 190.0, "censored": True}]
        m["M3_requests"] = []
        self.assertLess(m["M1_running_while_stranded_s"], 30)
        self.assertEqual([p[1] for p in analyze.predict(run, m) if p[0] == "P1"], ["contradicted"])

    def test_a_void_registered_run_fails_the_exit(self):
        p = os.path.join(self.out, "provenance.txt")
        with open(p) as f:
            text = f.read().replace("window=200 late_at=100", "window=600 late_at=300")
        with open(p, "w") as f:
            f.write(text)
        import contextlib
        from io import StringIO
        with contextlib.redirect_stdout(StringIO()):
            self.assertEqual(analyze.main([self.out]), 1)



class ReviewOfD2453ba(Fixture):
    """One test per defect codex gpt-6-astra found in commit d2453ba's scorer; each failed against that commit."""

    RT = "ready-timeout-never-1"

    def test_an_eviction_pending_at_the_windows_end_is_not_a_self_termination(self):
        # At 147 s the evicted rank is being deleted and still running; that is neither end.
        run = analyze.Run(os.path.join(self.out, "runs", self.RT), window=147)
        self.assertFalse(any("ended by itself" in p for p in run.problems()), run.problems())
        self.assertEqual(run.measures()["M3_stopped"], [False])

    def test_a_poll_is_matched_resource_by_resource(self):
        # A poll that read the CR before the eviction and the Workload after it: true of no single snapshot,
        # but each read is true within the tolerance.
        touched = []

        def torn(r):
            if r.get("ok") and "06:43:52.2" <= r["observed"][11:23] <= "06:43:54.0":
                touched.append(r["observed"])
                r["mltj"] = dict(r.get("mltj") or {}, phase="Running")
                for w in r.get("workloads") or []:
                    for c in w["conditions"]:
                        if c["type"] == "QuotaReserved":
                            c["status"] = "False"
            return r
        self.rewrite(self.RT, "timeline.jsonl", torn)
        self.assertTrue(touched, "the perturbation touched no sample")
        self.assertFalse(any("disagrees" in p for p in self.run_(self.RT).problems()), self.run_(self.RT).problems())


class AfterFix(Fixture):
    """Q1 to Q7 of the registration after the phase and signal fixes, on the old rehearsal, so the old code contradicts them."""

    RT = "ready-timeout-never-1"
    LATE = "off-late-1"

    def q(self, run, m, name):
        return [v for n, v, _ in analyze.predict_after_fix(run, m, analyze.predict(run, m)) if n == name]

    def test_q1_reads_m1_and_its_polled_bound(self):
        run = self.run_(self.RT)
        m = run.measures()
        self.assertEqual(self.q(run, m, "Q1"), ["contradicted"])
        m["M1_unrounded_s"], m["M1_polled_upper_unrounded_s"] = 0.0, 0.0
        # The old code was Running while stranded, which every-event replay still sees with M1 set to zero.
        self.assertEqual(self.q(run, m, "Q1"), ["contradicted"])
        run.tl.ever = lambda pred: "none"
        self.assertEqual(self.q(run, m, "Q1"), ["held"])
        run.tl.ever = lambda pred: "ambiguous"
        self.assertEqual(self.q(run, m, "Q1"), ["not evaluable"])
        m["M1_polled_upper_unrounded_s"] = 1.0
        self.assertEqual(self.q(run, m, "Q1"), ["contradicted"])
        # 20 ms rounds to the published 0.0 and is still Running while stranded.
        m["M1_polled_upper_unrounded_s"], m["M1_unrounded_s"], m["M1_running_while_stranded_s"] = 0.0, 0.02, 0.0
        self.assertEqual(self.q(run, m, "Q1"), ["contradicted"])

    def test_q5_needs_exactly_one_entry_into_running(self):
        run = self.run_(self.RT)
        both = analyze.ts("2026-10-21T06:44:30+00:00")
        run.setting, run.scenario = "ready-timeout", "late"
        run.both_ready_at = lambda: both
        m = run.measures()
        earlier = [("P4", "held", "")]
        after = [both + analyze.SEC * 5]
        run.running_entries = lambda: after
        self.assertEqual([v for n, v, _ in analyze.predict_after_fix(run, m, earlier) if n == "Q5"], ["held"])
        after.append(both + analyze.SEC * 50)
        self.assertEqual([v for n, v, _ in analyze.predict_after_fix(run, m, earlier) if n == "Q5"], ["contradicted"])

    @staticmethod
    def timeline(job, rows):
        """A Timeline from (time, phase, readyRanks, stranded) rows: a CR event per row, and a Pod event when stranded
        is not None, so a test can put the two streams in one millisecond or keep them apart."""
        tl = analyze.Timeline.__new__(analyze.Timeline)
        tl.job_name, tl.events, tl.states = job, [], []
        current = {"workloads": {}, "mltrainingjobs": {}, "jobs": {}, "pods": {}}
        for t, phase, ready, stranded in rows:
            new = []
            if phase is not None:
                new.append(("mltrainingjobs", {"kind": "MLTrainingJob", "metadata": {"name": job, "uid": "cr"},
                                               "status": {"phase": phase, "readyRanks": ready}}))
            if stranded is not None:
                new.append(("pods", {"kind": "Pod", "metadata": {"name": "r1", "uid": "rank-1",
                                                                 "labels": {"platform.lkhun9311.github.io/mltrainingjob": job}},
                                     "spec": {}, "status": {"conditions": [
                                         {"type": "PodScheduled", "status": "False" if stranded else "True"}]}}))
            for kind, obj in new:
                tl.events.append((t, kind, "MODIFIED", obj))
                current[kind][obj["metadata"]["uid"]] = obj
            snap = {k: dict(v) for k, v in current.items()}
            if tl.states and tl.states[-1][0] == t:
                tl.states[-1] = (t, snap)
            else:
                tl.states.append((t, snap))
        return tl

    def test_q1_sees_a_running_event_two_updates_hide_in_one_millisecond(self):
        t = analyze.ts("2026-10-21T06:42:00+00:00")
        tl = self.timeline("j", [(t, None, None, True), (t + analyze.SEC, "Running", 1, None),
                                 (t + analyze.SEC, "Admitted", 1, None), (t + 2 * analyze.SEC, "Admitted", 1, None)])
        pred = lambda s: tl.phase(s) == "Running" and tl.stranded(s)  # noqa: E731
        # The snapshots integrate to nothing, and the replay of the CR's own stream still sees the forbidden state.
        self.assertEqual(tl.time_where(t, t + 3 * analyze.SEC, pred), 0.0)
        self.assertEqual(tl.ever(pred), "seen")

    def test_a_cross_stream_tie_is_ambiguous_not_seen(self):
        # The Pod is scheduled and the CR goes Running in the same millisecond: the sort's order is not the cluster's.
        t = analyze.ts("2026-10-21T06:42:00+00:00")
        tl = self.timeline("j", [(t, "Admitted", 1, True), (t + analyze.SEC, "Running", 1, False)])
        self.assertEqual(tl.ever(lambda s: tl.phase(s) == "Running" and tl.stranded(s)), "ambiguous")

    def test_running_entries_come_from_the_crs_own_events(self):
        run = self.run_(self.RT)
        t = run.created
        run.tl = self.timeline(run.name, [(t, "Admitted", 1, None), (t + analyze.SEC, "Running", 2, None),
                                          (t + analyze.SEC, "Admitted", 1, None), (t + analyze.SEC, "Running", 2, None)])
        self.assertEqual(len(run.running_entries()), 2)
        # The coalesced snapshots see one entry, which is the miscount the events replace.
        self.assertEqual(len([v for _, v in run.tl.flips(lambda s: run.tl.phase(s) == "Running") if v]), 1)

    def test_q2_reads_every_status_after_the_first_ready(self):
        run = self.run_(self.RT)
        run.setting, run.scenario = "off", "never"
        m = run.measures()
        m["M5_final_phase"] = "Admitted"
        m["M2_quota_held_before_joining"] = [{"seconds": run.window - 1, "censored": True}]
        t = run.created
        steady = [(t, "Pending", None, True), (t + 5 * analyze.SEC, "Admitted", 1, True), (t + 150 * analyze.SEC, "Admitted", 1, True)]
        run.tl = self.timeline(run.name, steady)
        self.assertEqual([v for n, v, _ in analyze.predict_after_fix(run, m, []) if n == "Q2"], ["held"])
        run.tl = self.timeline(run.name, steady[:2] + [(t + 50 * analyze.SEC, "Admitted", 0, True)] + steady[2:])
        self.assertEqual([v for n, v, _ in analyze.predict_after_fix(run, m, []) if n == "Q2"], ["contradicted"])

    def test_q3_needs_running_after_both_ranks_are_ready(self):
        # The old rule entered Running before the second rank was placed.
        run = self.run_(self.LATE)
        self.assertEqual(self.q(run, run.measures(), "Q3"), ["contradicted"])

    def test_q3_holds_admit_to_running_to_kueues_first_stamp(self):
        def q3(admitted_at, a2r):
            def edit(r):
                st = ((r.get("object") or {}).get("status"))
                if st is not None:
                    st["admittedAt"], st["admitToRunningSeconds"] = admitted_at, a2r
                return r
            self.rewrite(self.LATE, "watch.mltrainingjobs.jsonl", edit)
            run = self.run_(self.LATE)
            first = run.admitted_stamps()[0]
            entry = run.squat_deleted + analyze.SEC * 5
            # The old rule entered Running early; the ordering is set to the fixed rule's, so only the stamp is judged.
            run.running_entries, run.both_ready_at = (lambda: [entry]), (lambda: entry - analyze.SEC)
            return first, entry, self.q(run, run.measures(), "Q3")
        first, entry, verdict = q3("2026-10-21T06:45:55Z", "200.0")
        self.assertEqual(verdict, ["held"])
        # admittedAt moved to the Running entry, with a figure that agrees with it: the floor must not move with it.
        _, _, verdict = q3(entry.strftime("%Y-%m-%dT%H:%M:%SZ"), "0")
        self.assertEqual(verdict, ["contradicted"])
        _, _, verdict = q3("2026-10-21T06:45:55Z", "5.0")
        self.assertEqual(verdict, ["contradicted"])
        # A moved admittedAt is wrong whatever figure sits beside it.
        _, _, verdict = q3(entry.strftime("%Y-%m-%dT%H:%M:%SZ"), "200.0")
        self.assertEqual(verdict, ["contradicted"])

    def test_q6_reads_exit_code_and_seconds(self):
        run = self.run_(self.RT)
        m = run.measures()
        self.assertEqual(self.q(run, m, "Q6"), ["contradicted"])
        h = m["M8_device_held_after_release"][0]
        h["exit"], h["seconds"] = 143, 1.0
        self.assertEqual(self.q(run, m, "Q6"), ["held"])
        h["seconds"] = -3.0
        self.assertEqual(self.q(run, m, "Q6"), ["held"])
        h["seconds"] = 5.1
        self.assertEqual(self.q(run, m, "Q6"), ["contradicted"])
        h["seconds"], h["exit"] = 1.0, 137
        self.assertEqual(self.q(run, m, "Q6"), ["contradicted"])
        h["exit"], h["censored"] = 143, True
        self.assertEqual(self.q(run, m, "Q6"), ["contradicted"])

    # The witness, added to the rehearsal: its Job, its Workload reserved 0.4 s after the job's release at
    # 06:43:52.091, and its Pod unschedulable until 0.4 s after the evicted rank's finishedAt of 06:44:21.

    def add_witness(self, created="2026-10-21T06:42:10.000Z"):
        d = os.path.join(self.out, "runs", self.RT)
        name = "pp-rt-never-1-064148"
        spill(os.path.join(d, "run.txt"), f"ready-timeout witness 1 {name}\n")
        spill(os.path.join(d, "witness-created-at.txt"), created + "\n")
        wname = "witness-" + name
        job = {"kind": "Job", "metadata": {"name": wname, "uid": "witness-job", "creationTimestamp": "2026-10-21T06:42:10Z"},
               "spec": {"suspend": True}, "status": {}}
        owner = [{"kind": "Job", "name": wname, "uid": "witness-job"}]

        def workload(status, finished=False):
            conds = [{"type": "QuotaReserved", "status": status}]
            if finished:
                conds.append({"type": "Finished", "status": "True"})
            return {"kind": "Workload", "metadata": {"name": "job-" + wname, "uid": "witness-wl", "ownerReferences": owner},
                    "spec": {"active": True}, "status": {"conditions": conds}}

        def pod(status, reason=None, message=None):
            c = {"type": "PodScheduled", "status": status}
            if reason:
                c.update(reason=reason, message=message)
            return {"kind": "Pod", "metadata": {"name": wname + "-x", "uid": "witness-pod", "labels": {"job-name": wname},
                                                "creationTimestamp": "2026-10-21T06:43:52Z"},
                    "spec": {}, "status": {"conditions": [c]}}

        def add(kind, rows):
            with open(os.path.join(d, f"watch.{kind}.jsonl"), "a") as f:
                for arrived, etype, obj in rows:
                    f.write(json.dumps({"arrived": "2026-10-21T" + arrived + "+00:00", "kind": kind, "type": etype,
                                        "object": obj}) + "\n")
        add("jobs", [("06:42:10.100", "ADDED", job)])
        # The rehearsal's job was admitted again at 06:44:21.042, which a real witness holding a unit would have
        # prevented, so this one finishes just before it, still reserved, as a finished Workload can be.
        add("workloads", [("06:42:10.300", "ADDED", workload("False")), ("06:43:52.491", "MODIFIED", workload("True")),
                          ("06:44:21.000", "MODIFIED", workload("True", finished=True))])
        add("pods", [("06:43:52.800", "ADDED", pod("False", "Unschedulable", "0/3 nodes are available: 1 Insufficient nvidia.com/gpu")),
                     ("06:44:21.400", "MODIFIED", pod("True"))])
        return self.run_(self.RT)

    def test_m9_is_read_from_the_witness_objects(self):
        run = self.add_witness()
        self.assertEqual(run.witness_problems(), [])
        w = run.measures()["M9_witness"]
        self.assertEqual(w["pods"], 1)
        self.assertEqual(w["reserved_after_first_release_s"], 0.4)
        self.assertEqual(w["M9_s"], 28.9)
        self.assertEqual(w["scheduled_minus_rank_finished_s"], 0.4)
        self.assertEqual(w["unschedulable"], [("Unschedulable", "0/3 nodes are available: 1 Insufficient nvidia.com/gpu")])

    def test_q7_reads_lag_m9_and_order(self):
        run = self.add_witness()
        m = run.measures()
        # The old trainer's 28.9 s hold is the gap Q7 says is gone.
        self.assertEqual(self.q(run, m, "Q7"), ["contradicted"])
        w = m["M9_witness"]
        w["M9_s"] = 5.0
        self.assertEqual(self.q(run, m, "Q7"), ["held"])
        w["reserved_after_first_release_s"] = 3.1
        self.assertEqual(self.q(run, m, "Q7"), ["contradicted"])
        w["reserved_after_first_release_s"], w["scheduled_minus_rank_finished_s"] = 0.4, -1.1
        self.assertEqual(self.q(run, m, "Q7"), ["contradicted"])

    def test_m9_compares_only_with_the_first_releases_rank(self):
        run = self.add_witness()
        rsv = run.reservations()
        held = run.measures()["M8_device_held_after_release"]
        # The first release's rank censored, and a later attempt's finish present: the later one must not be used.
        later = dict(held[0], release="2026-10-21T06:50:00+00:00", finishedAt="2026-10-21T06:50:30+00:00")
        first = dict(held[0], censored=True, finishedAt=None)
        w = run.witness_measures([first, later], rsv)
        self.assertIsNone(w["scheduled_minus_rank_finished_s"])

    def test_another_gpu_pod_in_the_namespace_voids_a_witness_run(self):
        self.add_witness()
        other = {"kind": "Pod", "metadata": {"name": "intruder", "uid": "intruder", "labels": {}},
                 "spec": {"containers": [{"name": "c", "resources": {"limits": {"nvidia.com/gpu": "1"}}}]}, "status": {}}
        with open(self.path(self.RT, "watch.pods.jsonl"), "a") as f:
            f.write(json.dumps({"arrived": "2026-10-21T06:43:00.000+00:00", "kind": "pods", "type": "ADDED", "object": other}) + "\n")
        self.assertTrue(any("intruder" in p for p in self.run_(self.RT).problems()))

    def test_an_init_container_asking_for_a_gpu_counts(self):
        self.add_witness()
        other = {"kind": "Pod", "metadata": {"name": "init-intruder", "uid": "init-intruder", "labels": {}},
                 "spec": {"containers": [{"name": "c"}],
                          "initContainers": [{"name": "i", "resources": {"requests": {"nvidia.com/gpu": "1"}}}]}, "status": {}}
        with open(self.path(self.RT, "watch.pods.jsonl"), "a") as f:
            f.write(json.dumps({"arrived": "2026-10-21T06:43:00.000+00:00", "kind": "pods", "type": "ADDED", "object": other}) + "\n")
        self.assertTrue(any("init-intruder" in p for p in self.run_(self.RT).problems()))

    def test_a_witness_run_is_scored_only_by_q1_q6_and_q7(self):
        run = self.add_witness()
        m = run.measures()
        self.assertEqual(sorted(n for n, _, _ in analyze.predict_after_fix(run, m, analyze.predict(run, m))), ["Q1", "Q6", "Q7"])

    def test_a_witness_created_before_the_reservation_is_void(self):
        run = self.add_witness(created="2026-10-21T06:41:50.000Z")
        # Through problems(), which is what voids a run, and not only through the helper.
        self.assertTrue(any("before the job's first reservation" in p for p in run.problems()), run.problems())

    def test_a_witness_created_after_the_eviction_is_void(self):
        run = self.add_witness(created="2026-10-21T06:43:55.000Z")
        self.assertTrue(any("after the job's first Evicted" in p for p in run.witness_problems()))

    def test_a_witness_holding_quota_with_the_job_is_void(self):
        self.add_witness()
        # Only the reservation moves, to 06:43:40, while the job's own reservation still holds both units.
        self.rewrite(self.RT, "watch.workloads.jsonl",
                     lambda r: dict(r, arrived="2026-10-21T06:43:40.000+00:00")
                     if (r.get("object") or {}).get("metadata", {}).get("uid") == "witness-wl"
                     and r["arrived"].startswith("2026-10-21T06:43:52.491") else r)
        self.assertTrue(any("held quota with the job" in p for p in self.run_(self.RT).witness_problems()))


if __name__ == "__main__":
    unittest.main()
