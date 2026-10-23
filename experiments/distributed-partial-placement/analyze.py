"""Scores a partial-placement study against experiments/distributed-partial-placement/README.md.

Every rule is evaluated from the evidence directory hack/distributed-partial-placement.sh wrote, and a rule whose
evidence is missing fails: absence is never read as a pass.
Transitions come from the watch streams; the once-a-second samples are the cross-check and the only record of the
ClusterQueue and the squatter, which the watches do not cover.

Usage: python3 experiments/distributed-partial-placement/analyze.py <evidence dir>
Prints, per run, its validity, measures and each registered prediction as held, contradicted or not evaluable, with
the numbers used. Exits 0 when every run could be read, 2 when the study is void.
"""

from __future__ import annotations

import datetime
import glob
import gzip
import json
import os
import re
import sys

import yaml

SETTINGS = ("off", "ready-timeout")
WINDOW = 600.0
LATE_AT = 300.0
MAX_GAP = 3.0
WATCHED = ("workloads", "mltrainingjobs", "jobs", "pods")
# The registered stanza, as the harness writes it and as the study page fixes it.
READY_TIMEOUT_STANZA = {
    "timeout": "120s", "recoveryTimeout": "120s", "blockAdmission": False,
    "requeuingStrategy": {"timestamp": "Eviction", "backoffBaseSeconds": 30,
                          "backoffMaxSeconds": 3600, "backoffLimitCount": 2},
}
SEC = datetime.timedelta(seconds=1)


def ts(value: str | None) -> datetime.datetime | None:
    """Parses the API server's whole-second times and the recorders' and train.py's fractional ones."""
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def read(path: str) -> str | None:
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None


def jsonl(path: str) -> list[dict]:
    """One JSON object per line, read from the file or, when only that exists, its gzipped copy."""
    text = read(path)
    if text is None and os.path.exists(path + ".gz"):
        with gzip.open(path + ".gz", "rt") as f:
            text = f.read()
    return [json.loads(line) for line in (text or "").splitlines() if line.strip()]


def cond(obj: dict | None, ctype: str) -> dict | None:
    for c in ((obj or {}).get("status") or {}).get("conditions") or []:
        if c.get("type") == ctype:
            return c
    return None


def true(obj: dict | None, ctype: str) -> bool:
    c = cond(obj, ctype)
    return bool(c) and c.get("status") == "True"


# --- settings ---------------------------------------------------------------------------------------------------


def setting_problems(out: str, setting: str) -> list[str]:
    """Why the setting was not shown to be in force, or nothing if it was."""
    d = os.path.join(out, "settings", setting)
    problems = []
    cfg_text = read(os.path.join(d, "controller_manager_config.yaml"))
    if cfg_text is None:
        return ["no written configuration"]
    cfg = yaml.safe_load(cfg_text)
    if cfg.get("apiVersion") != "config.kueue.x-k8s.io/v1beta2":
        problems.append(f"configuration apiVersion is {cfg.get('apiVersion')!r}")
    want = READY_TIMEOUT_STANZA if setting == "ready-timeout" else None
    if cfg.get("waitForPodsReady") != want:
        problems.append(f"waitForPodsReady written as {cfg.get('waitForPodsReady')!r}, registered {want!r}")
    written = ts((read(os.path.join(d, "written-at.txt")) or "").strip())
    pods_text = read(os.path.join(d, "pods-after.json"))
    if written is None or pods_text is None:
        return problems + ["no write time or no controller Pod record"]
    pods = json.loads(pods_text)["items"]
    if len(pods) != 1:
        problems.append(f"{len(pods)} controller Pods after the rollout, not 1")
    for p in pods:
        started = ts((p.get("status") or {}).get("startTime"))
        # Both times are whole seconds, and the harness writes the ConfigMap before it restarts Kueue, so equal is after.
        if started is None or started < written:
            problems.append(f"controller Pod {p['metadata']['name']} started {started}, before the write at {written}")
        if not true(p, "Ready"):
            problems.append(f"controller Pod {p['metadata']['name']} not Ready")
    loaded = [line for line in (read(os.path.join(d, "controller-startup.log")) or "").splitlines()
              if "Configuration loaded" in line]
    if len(loaded) != 1:
        problems.append(f"{len(loaded)} 'Configuration loaded' lines in the controller's log, not 1")
    else:
        line = loaded[0].replace("\\n", "\n")
        if setting == "off" and "waitForPodsReady" in line:
            problems.append("the loaded configuration carries waitForPodsReady under off")
        if setting == "ready-timeout":
            for needle in ("waitForPodsReady", "timeout: 2m0s", "recoveryTimeout: 2m0s", "blockAdmission: false",
                           "backoffBaseSeconds: 30", "backoffLimitCount: 2", "backoffMaxSeconds: 3600",
                           "timestamp: Eviction"):
                if needle not in line:
                    problems.append(f"the loaded configuration does not show {needle!r}")
    return problems


# --- the merged watch timeline ----------------------------------------------------------------------------------


class Timeline:
    """Every watched object's state, replayed in arrival order.

    `states` is a list of (time, snapshot) where the snapshot holds from its time to the next one's; each snapshot
    maps kind to {uid: object} for the objects that exist then.
    """

    def __init__(self, run_dir: str, job_name: str, end: datetime.datetime | None = None):
        self.events = []
        self.coverage_problems = []
        self.job_name = job_name
        for kind in WATCHED:
            rows = jsonl(os.path.join(run_dir, f"watch.{kind}.jsonl"))
            if not rows:
                self.coverage_problems.append(f"no {kind} watch")
                continue
            self._check_coverage(kind, rows)
            for r in rows:
                # The recorders outlive the window by a few seconds; nothing they saw after it is evidence.
                if r["type"] in ("ADDED", "MODIFIED", "DELETED") and r.get("object") \
                        and (end is None or ts(r["arrived"]) <= end):
                    self.events.append((ts(r["arrived"]), kind, r["type"], r["object"]))
        self.events.sort(key=lambda e: e[0])
        self.states = []
        current: dict[str, dict[str, dict]] = {k: {} for k in WATCHED}
        for t, kind, etype, obj in self.events:
            uid = obj["metadata"]["uid"]
            if etype == "DELETED":
                current[kind].pop(uid, None)
            else:
                current[kind][uid] = obj
            snap = {k: dict(v) for k, v in current.items()}
            if self.states and self.states[-1][0] == t:
                self.states[-1] = (t, snap)
            else:
                self.states.append((t, snap))

    def ever(self, pred) -> str:
        """Whether pred held after any single event, which `states` can hide when two arrive in one millisecond.

        "seen" when it held after an event no other stream shares a millisecond with, "ambiguous" when it held only
        where another stream's event has the same arrival, since the order between two streams' events is then the
        sort's and not the cluster's, and "none" otherwise.
        """
        current: dict[str, dict[str, dict]] = {k: {} for k in WATCHED}
        kinds_at: dict[datetime.datetime, set[str]] = {}
        for t, kind, _, _ in self.events:
            kinds_at.setdefault(t, set()).add(kind)
        found = "none"
        for t, kind, etype, obj in self.events:
            if etype == "DELETED":
                current[kind].pop(obj["metadata"]["uid"], None)
            else:
                current[kind][obj["metadata"]["uid"]] = obj
            if pred(current):
                if len(kinds_at[t]) == 1:
                    return "seen"
                found = "ambiguous"
        return found

    def _check_coverage(self, kind, rows):
        self.starts = getattr(self, "starts", {})
        started = [ts(r["arrived"]) for r in rows if r["type"] == "WATCH_STARTED"]
        ended = [ts(r["arrived"]) for r in rows if r["type"] == "WATCH_ENDED"]
        self.starts[kind] = (started, ended)

    def coverage(self, created, end) -> list[str]:
        problems = list(self.coverage_problems)
        for kind, (started, ended) in getattr(self, "starts", {}).items():
            if not started or started[0] > created:
                problems.append(f"{kind} watch did not start before the job's creation")
            for e in ended:
                if e >= end:
                    continue
                nxt = [s for s in started if s >= e]
                if not nxt or (nxt[0] - e).total_seconds() > MAX_GAP:
                    problems.append(f"{kind} watch ended at {e.isoformat()} inside the window with no restart within {MAX_GAP} s")
        return problems

    # views of one snapshot

    def mltj(self, snap):
        return next((o for o in snap["mltrainingjobs"].values() if o["metadata"]["name"] == self.job_name), None)

    def job(self, snap):
        return next((o for o in snap["jobs"].values() if o["metadata"]["name"] == self.job_name), None)

    def job_uids(self) -> set[str]:
        return {o["metadata"]["uid"] for _, _, _, o in self.events if o.get("kind") == "Job"
                and o["metadata"]["name"] == self.job_name}

    def workload(self, snap):
        uids = self.job_uids()
        ws = [w for w in snap["workloads"].values()
              if any(r.get("uid") in uids for r in w["metadata"].get("ownerReferences") or [])]
        return ws[0] if len(ws) == 1 else None

    def pods(self, snap):
        return [p for p in snap["pods"].values()
                if (p["metadata"].get("labels") or {}).get("platform.lkhun9311.github.io/mltrainingjob") == self.job_name]

    @staticmethod
    def placed(p) -> bool:
        return bool(p["spec"].get("nodeName"))

    def stranded(self, snap) -> bool:
        for p in self.pods(snap):
            c = cond(p, "PodScheduled")
            if not p["metadata"].get("deletionTimestamp") and c and c.get("status") == "False":
                return True
        return False

    def phase(self, snap):
        return ((self.mltj(snap) or {}).get("status") or {}).get("phase")

    # integration

    def segments(self, start, end):
        """(from, to, snapshot) pieces covering [start, end), each snapshot holding over its piece."""
        out = []
        for i, (t, snap) in enumerate(self.states):
            nxt = self.states[i + 1][0] if i + 1 < len(self.states) else end
            a, b = max(t, start), min(nxt, end)
            if b > a:
                out.append((a, b, snap))
        return out

    def time_where(self, start, end, pred) -> float:
        return sum((b - a).total_seconds() for a, b, s in self.segments(start, end) if pred(s))

    def first(self, pred, after=None):
        return next((t for t, s in self.states if (after is None or t >= after) and pred(s)), None)

    def flips(self, pred):
        """Times the predicate changes value, with the value it changes to."""
        out, prev = [], None
        for t, s in self.states:
            v = bool(pred(s))
            if v != prev:
                out.append((t, v))
                prev = v
        return out

    def spans(self, pred, end):
        """[start, stop) intervals where the predicate held; stop is None when it still held at the window's end."""
        out, start = [], None
        for t, v in self.flips(pred):
            if t >= end:
                break
            if v and start is None:
                start = t
            elif not v and start is not None:
                out.append((start, t))
                start = None
        if start is not None:
            out.append((start, None))
        return out


# --- one run ----------------------------------------------------------------------------------------------------


class Run:
    def __init__(self, path: str, window: float = WINDOW):
        self.path = path
        self.window = window
        self.setting, self.scenario, self.rep, self.name = (read(os.path.join(path, "run.txt")) or "? ? ? ?").split()
        self.void_file = (read(os.path.join(path, "VOID")) or "").strip()
        self.created = ts((read(os.path.join(path, "created-at.txt")) or "").strip())
        self.squat_deleted = ts((read(os.path.join(path, "squatter-deleted-at.txt")) or "").strip())
        iso = read(os.path.join(path, "isolation.json"))
        self.isolation = json.loads(iso) if iso else None
        self.samples = jsonl(os.path.join(path, "timeline.jsonl"))
        for s in self.samples:
            s["t"] = ts(s["observed"])
        self.end = self.created + datetime.timedelta(seconds=window) if self.created else None
        self.ok = [s for s in self.samples if s.get("ok") and (self.end is None or s["t"] <= self.end)]
        self.logs = self._logs()
        self.tl = Timeline(path, self.name, self.end)

    def _logs(self) -> dict[str, list[dict]]:
        """Records by Pod UID, merged across a stream's restarts and de-duplicated."""
        out: dict[str, dict[tuple, dict]] = {}
        for f in sorted(glob.glob(os.path.join(self.path, "log-*.txt"))):
            uid = os.path.basename(f)[4:].split(".")[0]
            with open(f) as fh:
                lines = fh.read().splitlines()
            for line in lines:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if self.end is None or ts(r.get("ts")) <= self.end:
                    out.setdefault(uid, {})[(r.get("event"), r.get("ts"))] = r
        return {u: sorted(rs.values(), key=lambda r: r["ts"]) for u, rs in out.items()}

    def events(self, uid):
        return [r.get("event") for r in self.logs.get(uid, [])]

    def joined_at(self):
        times = [ts(r["ts"]) for rs in self.logs.values() for r in rs if r.get("event") == "rendezvous"]
        return min(times) if times else None

    def max_gap(self) -> float:
        gaps = [(b["t"] - a["t"]).total_seconds() for a, b in zip(self.ok, self.ok[1:])]
        return max(gaps) if gaps else float("inf")

    # pods across the run

    def pod_history(self) -> dict[str, list[tuple[datetime.datetime, dict]]]:
        out: dict[str, list] = {}
        for t, kind, etype, obj in self.tl.events:
            if kind == "pods" and (obj["metadata"].get("labels") or {}).get(
                    "platform.lkhun9311.github.io/mltrainingjob") == self.name:
                out.setdefault(obj["metadata"]["uid"], []).append((t, etype, obj))
        return out

    @staticmethod
    def container(obj) -> dict:
        return ((obj.get("status") or {}).get("containerStatuses") or [{}])[0]

    def started_at(self, hist):
        for _, _, o in hist:
            st = self.container(o).get("state") or {}
            s = (st.get("running") or st.get("terminated") or {}).get("startedAt")
            if s:
                return ts(s)
        return None

    def terminated(self, hist):
        for t, _, o in hist:
            term = (self.container(o).get("state") or {}).get("terminated")
            if term:
                return t, term
        return None, None

    def deletion(self, hist):
        for t, _, o in hist:
            d = o["metadata"].get("deletionTimestamp")
            if d:
                return t, ts(d)
        return None, None

    def gone_at(self, hist):
        return next((t for t, etype, _ in hist if etype == "DELETED"), None)

    # Workload facts

    def admissions(self):
        return self.tl.spans(lambda s: true(self.tl.workload(s), "Admitted"), self.end)

    def reservations(self):
        return self.tl.spans(lambda s: true(self.tl.workload(s), "QuotaReserved"), self.end)

    def requests(self):
        """Each distinct Evicted=True, by its lastTransitionTime: (arrival, reason, lastTransitionTime)."""
        seen, out = set(), []
        for t, s in self.tl.states:
            c = cond(self.tl.workload(s), "Evicted")
            if c and c.get("status") == "True" and c.get("lastTransitionTime") not in seen:
                seen.add(c.get("lastTransitionTime"))
                out.append((t, c.get("reason") or "", ts(c.get("lastTransitionTime"))))
        return [r for r in out if r[0] < self.end]

    def admitted_stamps(self):
        stamps = []
        for t, s in self.tl.states:
            c = cond(self.tl.workload(s), "Admitted")
            if c and c.get("status") == "True":
                v = ts(c.get("lastTransitionTime"))
                if v not in stamps:
                    stamps.append(v)
        return stamps

    def ended_by_eviction(self, hist) -> tuple[bool, str]:
        """Whether this rank's container ended as an eviction ends one, in the registered order."""
        dt_seen, dt = self.deletion(hist)
        term_seen, term = self.terminated(hist)
        gone = self.gone_at(hist)
        reqs = self.requests()
        deleted_at = dt_seen or gone
        if deleted_at is None:
            return False, "never deleted"
        before = [r for r in reqs if r[0] <= deleted_at + SEC]
        if not before:
            return False, "deleted with no eviction request before it"
        if term is not None and term_seen < deleted_at:
            return False, f"terminated (exit {term.get('exitCode')}) before its Pod's deletion"
        if term is None:
            # A deletion request is not an end: without a terminated state, only the Pod's disappearance is one.
            if gone is None:
                return False, "deleted but neither terminated nor gone inside the window"
            return True, "no terminated state before the Pod was gone"
        code = term.get("exitCode")
        uid = hist[0][2]["metadata"]["uid"]
        if code == 143 and "sigterm" in self.events(uid):
            return True, "exit 143 with a sigterm record"
        if code == 137:
            return True, "exit 137 after the grace period"
        return False, f"exit {code} during the deletion"

    # validity

    def problems(self) -> list[str]:
        p = []
        if self.void_file:
            p.append(f"harness: {self.void_file}")
        iso = self.isolation
        if iso is None:
            p.append("no isolation record")
        elif iso["leftovers"] or iso["readErrors"] or iso["squatters"] or iso["gpuReserved"] not in ([], ["0"], [0]) \
                or iso["allocatable"] != ["1", "1"]:
            p.append(f"not isolated at start: {iso}")
        if self.created is None or not self.ok:
            return p + ["no creation time or no successful sample"]
        end = self.end
        if self.max_gap() > MAX_GAP:
            p.append(f"largest gap between successful samples {self.max_gap():.1f} s, over {MAX_GAP} s")
        if self.ok[0]["t"] > self.created + MAX_GAP * SEC:
            p.append("first successful sample more than 3 s after creation")
        if self.ok[-1]["t"] < end - MAX_GAP * SEC:
            p.append("last successful sample more than 3 s before the window's end")
        p += self.tl.coverage(self.created, end)
        p += self.watch_agrees_with_poll()
        if self.scenario == "late" and self.squat_deleted is None:
            p.append("late run with no squatter deletion time")
        held_until = self.squat_deleted if self.scenario == "late" and self.squat_deleted else end
        for s in self.ok:
            if s["t"] >= held_until:
                break
            sq = s.get("squatter")
            if not sq or sq[0].get("phase") != "Running" or sq[0].get("node") is None:
                p.append(f"squatter not Running at {s['observed']}")
                break
        p += self.treatment_problems(held_until)
        # Both ranks never placed together while the squatter held its device.
        for t, s in self.tl.states:
            if t >= held_until:
                break
            live = [x for x in self.tl.pods(s) if self.tl.placed(x) and not x["metadata"].get("deletionTimestamp")]
            if len(live) >= 2:
                p.append(f"both ranks placed at {t.isoformat()} while the squatter held its device")
                break
        for uid, hist in self.pod_history().items():
            started = self.started_at(hist)
            if started is None:
                continue
            if not any(e == "rendezvous_start" for e in self.events(uid)):
                p.append(f"rank Pod {uid} ran and has no rendezvous_start in its log")
            if "rendezvous_failed" in self.events(uid):
                fail = [ts(r["ts"]) for r in self.logs[uid] if r.get("event") == "rendezvous_failed"][0]
                if fail < held_until:
                    p.append(f"rank Pod {uid} logged rendezvous_failed: the trainer ended the stranding")
                    continue
            term_seen, term = self.terminated(hist)
            # A deletion request is not an end: a container still running at the window's end, eviction pending or
            # not, ended neither by itself nor by the eviction inside the window.
            end_t = min(x for x in (term_seen, self.gone_at(hist), end) if x is not None)
            if end_t >= end or end_t >= held_until:
                continue  # still running at the end, or ended after capacity: an outcome, not validity
            ok, why = self.ended_by_eviction(hist)
            if not ok:
                p.append(f"rank Pod {uid} ended by itself before the squatter's deletion: {why}")
        return p

    def watch_agrees_with_poll(self) -> list[str]:
        """A recorder killed without an end marker looks like a quiet stream, so the polls are the check.

        Each successful sample's CR phase, Workload QuotaReserved status and set of rank Pods must be what the
        watch timeline held at some instant within 2 s of the sample, which allows for the order the two read in.
        """
        p = []
        for s in self.ok:
            want_phase = (s.get("mltj") or {}).get("phase")
            ws = [w for w in s.get("workloads") or [] if s.get("jobUID") and s["jobUID"] in w["owners"]]
            want_qr = next((c["status"] for w in ws[:1] for c in w["conditions"] if c["type"] == "QuotaReserved"), None)
            want_pods = sorted(x["uid"] for x in s.get("pods") or [])
            near = [snap for a, b, snap in self.tl.segments(s["t"] - 2 * SEC, s["t"] + 2 * SEC)]
            if not near:
                p.append(f"no watch state near the sample at {s['observed']}")
                break
            # A poll is several reads, not one snapshot, so each resource is matched on its own within the tolerance.
            checks = {
                "phase": any(self.tl.phase(n) == want_phase for n in near),
                "QuotaReserved": want_qr is None or any(
                    (cond(self.tl.workload(n), "QuotaReserved") or {}).get("status") == want_qr for n in near),
                "pods": any(sorted(x["metadata"]["uid"] for x in self.tl.pods(n)) == want_pods for n in near),
            }
            bad = [k for k, ok in checks.items() if not ok]
            if bad:
                p.append(f"the watch disagrees with the poll at {s['observed']} on {', '.join(bad)}")
                break
        return p

    def treatment_problems(self, held_until) -> list[str]:
        p = []
        adm = self.admissions()
        if not adm:
            return ["no admission observed"]
        a0, a1 = adm[0][0], adm[0][1] or self.end
        first = {u: h for u, h in self.pod_history().items()
                 if a0 - 2 * SEC <= ts(h[0][2]["metadata"]["creationTimestamp"]) <= a1}
        if len(first) != 2:
            p.append(f"the first admission created {len(first)} rank Pods, not 2")
        placed = [u for u, h in first.items() if any(self.tl.placed(o) and t < held_until for t, _, o in h)]
        ready = [u for u, h in first.items() if any(self.container(o).get("ready") for _, _, o in h)]
        unsched = [u for u, h in first.items() if any(
            (c := cond(o, "PodScheduled")) and c.get("status") == "False" and c.get("reason") == "Unschedulable"
            and "nvidia.com/gpu" in (c.get("message") or "") for _, _, o in h)]
        if len(placed) != 1:
            p.append(f"{len(placed)} rank Pods of the first admission placed while the squatter held its device, not 1")
        if not set(placed) & set(ready):
            p.append("the placed rank of the first admission never became Ready")
        if len(unsched) != 1 or set(unsched) & set(placed):
            p.append(f"{len(unsched)} rank Pods Unschedulable on nvidia.com/gpu, not exactly the unplaced one")
        for u in placed:
            if "rendezvous_start" not in self.events(u):
                p.append(f"the placed rank {u} has no rendezvous_start in its log")
        joined = self.joined_at()
        if joined and joined < held_until:
            p.append("the ranks joined before the squatter's deletion")
        if self.scenario == "witness":
            p += self.witness_problems()
        return p

    # measures

    def measures(self) -> dict:
        end, tl = self.end, self.tl
        joined = self.joined_at()
        running_stranded = tl.time_where(self.created, end, lambda s: tl.phase(s) == "Running" and tl.stranded(s))
        # Polled cross-check: lower bound needs both ends of an interval to show it, upper bound either end.
        def polled(s):
            ph = (s.get("mltj") or {}).get("phase")
            str_ = any(p.get("deletionTimestamp") is None and any(
                c["type"] == "PodScheduled" and c["status"] == "False" for c in p["conditions"]) for p in s.get("pods") or [])
            return ph == "Running" and str_
        lo = sum((b["t"] - a["t"]).total_seconds() for a, b in zip(self.ok, self.ok[1:]) if polled(a) and polled(b))
        hi = sum((b["t"] - a["t"]).total_seconds() for a, b in zip(self.ok, self.ok[1:]) if polled(a) or polled(b))
        m2 = []
        for start, stop in self.reservations():
            ends = [x for x in (stop, joined) if x is not None and x > start]
            if ends:
                m2.append({"seconds": round((min(ends) - start).total_seconds(), 1), "censored": False})
            else:
                m2.append({"seconds": round((end - start).total_seconds(), 1), "censored": True})
        reqs = self.requests()
        rsv = self.reservations()
        lags, stopped = [], []
        for arrival, reason, ltt in reqs:
            release = [stop for start, stop in rsv if stop is not None and start <= arrival <= stop]
            lags.append({"seconds": round((release[0] - arrival).total_seconds(), 1), "censored": False} if release
                        else {"seconds": round((end - arrival).total_seconds(), 1), "censored": True})
            susp = tl.first(lambda s: bool(((tl.job(s) or {}).get("spec") or {}).get("suspend")), after=arrival - SEC)
            ended = []
            for uid, hist in self.pod_history().items():
                if self.started_at(hist) and self.started_at(hist) < arrival:
                    ok, why = self.ended_by_eviction(hist)
                    dseen, _ = self.deletion(hist)
                    gone = self.gone_at(hist)
                    if ok and (dseen or gone) and (dseen or gone) >= arrival - SEC:
                        ended.append(why)
            stopped.append(bool(susp and susp < end and ended))
        counts = [int((((tl.workload(s) or {}).get("status") or {}).get("requeueState") or {}).get("count") or 0)
                  for _, s in tl.states if tl.workload(s)]
        last_w = next((tl.workload(s) for _, s in reversed(tl.states) if tl.workload(s)), None)
        final = tl.phase(next((s for t, s in reversed(tl.states) if t <= end), {k: {} for k in WATCHED}))
        succeeded = tl.first(lambda s: tl.phase(s) == "Succeeded")
        adm = self.admissions()
        discarded = []
        for i, (start, stop) in enumerate(adm):
            if stop is None:
                continue
            secs, censored = 0.0, False
            for uid, hist in self.pod_history().items():
                created = ts(hist[0][2]["metadata"]["creationTimestamp"])
                started = self.started_at(hist)
                if not (start - 2 * SEC <= created <= stop) or started is None:
                    continue
                _, term = self.terminated(hist)
                fin = ts((term or {}).get("finishedAt"))
                if fin:
                    secs += (fin - started).total_seconds()
                else:
                    censored = True
                    last_running = max(t for t, _, o in hist if (self.container(o).get("state") or {}).get("running"))
                    secs += max(0.0, (last_running - started).total_seconds())
            discarded.append({"admission": i + 1, "container_seconds": round(secs, 1), "censored": censored})
        after = []
        for arrival, reason, _ in reqs:
            seq = [(round((a - arrival).total_seconds(), 1), tl.phase(s)) for a, b, s in tl.segments(arrival, arrival + 30 * SEC)]
            compact = []
            for at, ph in seq:
                if not compact or compact[-1][1] != ph:
                    compact.append((at, ph))
            after.append({"request_reason": reason, "phases_from_request": compact,
                          "left_running": any(ph != "Running" for _, ph in seq)})
        # M8: from each stopped attempt's release to the end of the rank process that still held the device.
        held_after = []
        for (arrival, reason, _), was_stopped in zip(reqs, stopped):
            if not was_stopped:
                continue
            # The attempt this request stopped is the admission it fell in; only that attempt's rank held the device.
            attempt = [a for a, b in adm if a <= arrival and (b is None or arrival <= b + SEC)]
            release = [stop for start, stop in rsv if stop is not None and start <= arrival <= stop]
            for uid, hist in self.pod_history().items():
                started = self.started_at(hist)
                if not started or started >= arrival or not release or not attempt or started < attempt[-1] - 2 * SEC:
                    continue
                _, term = self.terminated(hist)
                fin = ts((term or {}).get("finishedAt"))
                if fin:
                    # The two instants are kept, because the witness's scheduling is judged against the finish itself.
                    held_after.append({"seconds": round((fin - release[0]).total_seconds(), 1), "censored": False,
                                       "exit": term.get("exitCode"), "release": release[0].isoformat(),
                                       "finishedAt": fin.isoformat()})
                else:
                    gone = self.gone_at(hist)
                    held_after.append({"seconds": round(((gone or end) - release[0]).total_seconds(), 1),
                                       "censored": True, "exit": None})
        admitted_at = []
        for _, s in tl.states:
            v = ((tl.mltj(s) or {}).get("status") or {}).get("admittedAt")
            if v and v not in admitted_at:
                admitted_at.append(v)
        second = None
        if self.scenario == "late" and self.squat_deleted:
            second = tl.first(lambda s: len([x for x in tl.pods(s) if tl.placed(x) and not x["metadata"].get("deletionTimestamp")]) >= 2,
                              after=self.squat_deleted)
        return {
            "M1_running_while_stranded_s": round(running_stranded, 1),
            # Unrounded, for Q1: a 20 ms Running while stranded rounds to 0.0 and is still the forbidden state.
            "M1_unrounded_s": running_stranded,
            "M1_polled_upper_unrounded_s": hi,
            "M1_polled_bounds_s": [round(lo, 1), round(hi, 1)],
            "M2_quota_held_before_joining": m2,
            "M3_requests": [{"arrived": a.isoformat(), "reason": r, "lastTransitionTime": l.isoformat() if l else None}
                            for a, r, l in reqs],
            "M3_stopped": stopped,
            "M3_max_requeue_count": max(counts) if counts else None,
            "M3_deactivated": bool(last_w and (last_w.get("spec") or {}).get("active") is False),
            "M4_eviction_lag": lags,
            "M5_final_phase": final,
            "M5_succeeded_after_s": round((succeeded - self.created).total_seconds(), 1) if succeeded and succeeded <= end else None,
            "M6_admissions": len(adm),
            "M6_discarded": discarded,
            "M7_after_request": after,
            "M8_device_held_after_release": held_after,
            "M7_admittedAt_values": admitted_at,
            "admitted_stamps": [x.isoformat() for x in self.admitted_stamps() if x],
            "admissions": [(a.isoformat(), b.isoformat() if b else None) for a, b in adm],
            "second_rank_placed_after_s": round((second - self.created).total_seconds(), 1) if second else None,
            "squatter_deleted_after_s": round((self.squat_deleted - self.created).total_seconds(), 1) if self.squat_deleted else None,
            "joined_after_s": round((joined - self.created).total_seconds(), 1) if joined else None,
            "M9_witness": self.witness_measures(held_after, rsv) if self.scenario == "witness" else None,
        }

    def placed_ready_at(self):
        return self.tl.first(lambda s: any(self.container(p).get("ready") for p in self.tl.pods(s)))

    def first_running_at(self):
        return self.tl.first(lambda s: self.tl.phase(s) == "Running")

    def running_entries(self) -> list[datetime.datetime]:
        """Each entry into Running, from the CR's own events in arrival order, which snapshots coalesce in a tie."""
        out, prev = [], None
        for t, kind, etype, obj in self.tl.events:
            if kind != "mltrainingjobs" or obj["metadata"]["name"] != self.name:
                continue
            phase = None if etype == "DELETED" else (obj.get("status") or {}).get("phase")
            if phase == "Running" and prev != "Running":
                out.append(t)
            prev = phase
        return out

    def both_ready_at(self):
        """When two rank Pods not being deleted were first Ready together, which only a joined pair can be."""
        return self.tl.first(lambda s: len([p for p in self.tl.pods(s) if self.container(p).get("ready")
                                            and not p["metadata"].get("deletionTimestamp")]) >= 2)

    # the witness

    def witness_history(self):
        """The witness Job's Workload and Pod events, which every rank filter above leaves out."""
        wname = "witness-" + self.name
        job_uids = {o["metadata"]["uid"] for _, _, _, o in self.tl.events
                    if o.get("kind") == "Job" and o["metadata"]["name"] == wname}
        workload, pods = [], {}
        for t, kind, etype, obj in self.tl.events:
            if kind == "workloads" and any(r.get("uid") in job_uids for r in obj["metadata"].get("ownerReferences") or []):
                workload.append((t, etype, obj))
            labels = obj["metadata"].get("labels") or {}
            if kind == "pods" and wname in (labels.get("batch.kubernetes.io/job-name"), labels.get("job-name")):
                pods.setdefault(obj["metadata"]["uid"], []).append((t, etype, obj))
        return workload, pods

    def witness_created(self):
        return ts((read(os.path.join(self.path, "witness-created-at.txt")) or "").strip())

    def witness_measures(self, held_after, rsv) -> dict:
        """M9: from the witness's QuotaReserved turning True to its Pod's PodScheduled turning True, by arrival."""
        workload, pods = self.witness_history()
        reserved = next((t for t, _, o in workload if true(o, "QuotaReserved")), None)
        pod_hist = next(iter(pods.values()), [])
        scheduled = next((t for t, _, o in pod_hist if true(o, "PodScheduled")), None)
        unschedulable = []
        for _, _, o in pod_hist:
            c = cond(o, "PodScheduled")
            if c and c.get("status") == "False" and (c.get("reason"), c.get("message")) not in unschedulable:
                unschedulable.append((c.get("reason"), c.get("message")))
        release = next((stop for _, stop in rsv if stop is not None), None)
        # The first release's own rank, and nothing from a later attempt: a censored finish stays missing.
        first_held = next((h for h in held_after if release and h.get("release") == release.isoformat()), None)
        finished = ts(first_held["finishedAt"]) if first_held and not first_held["censored"] else None
        created = self.witness_created()
        return {
            "created": created.isoformat() if created else None,
            "pods": len(pods),
            "first_release": release.isoformat() if release else None,
            "reserved_after_first_release_s": round((reserved - release).total_seconds(), 1) if reserved and release else None,
            "M9_s": round((scheduled - reserved).total_seconds(), 1) if reserved and scheduled else None,
            "unschedulable": unschedulable,
            # finishedAt is whole seconds and the watch arrival is not, so this carries up to a second of rounding.
            "scheduled_minus_rank_finished_s": round((scheduled - finished).total_seconds(), 1) if scheduled and finished else None,
        }

    def witness_problems(self) -> list[str]:
        """The witness runs' own validity rules, from the registration's "Validity, per run"."""
        p = []
        created = self.witness_created()
        workload, pods = self.witness_history()
        rsv, reqs = self.reservations(), self.requests()
        if created is None:
            return ["no witness creation time"]
        if not rsv or created < rsv[0][0]:
            p.append("the witness was created before the job's first reservation")
        if reqs and created >= reqs[0][0]:
            p.append("the witness was created after the job's first Evicted")
        if len(pods) != 1:
            p.append(f"{len(pods)} witness Pods, not 1")
        # The witness must be the only other Pod asking for a device, or another could take the capacity M9 times.
        others = set()
        for _, kind, _, obj in self.tl.events:
            labels = obj["metadata"].get("labels") or {}
            if kind != "pods" or obj["metadata"]["uid"] in pods or labels.get("platform.lkhun9311.github.io/mltrainingjob") == self.name:
                continue
            spec = obj.get("spec") or {}
            # Init containers too: a request there reserves the device for the Pod as much as a main container's.
            asks = [c for c in (spec.get("containers") or []) + (spec.get("initContainers") or [])
                    if "nvidia.com/gpu" in (((c.get("resources") or {}).get("limits") or {}) | ((c.get("resources") or {}).get("requests") or {}))]
            if asks:
                others.add(obj["metadata"]["name"])
        if others:
            p.append(f"other Pods requested nvidia.com/gpu: {sorted(others)}")
        # Never admitted while the job held both units: no instant with both Workloads reserving quota.
        # A finished Workload can keep QuotaReserved=True while holding nothing, so Finished=True counts as released.
        def holds(w):
            return true(w, "QuotaReserved") and not true(w, "Finished")
        uids = {o["metadata"]["uid"] for _, _, o in workload}
        for t, s in self.tl.states:
            mine = [w for w in s["workloads"].values() if w["metadata"]["uid"] in uids]
            if holds(self.tl.workload(s)) and any(holds(w) for w in mine):
                p.append(f"the witness held quota with the job at {t.isoformat()}")
                break
        return p


# --- predictions ------------------------------------------------------------------------------------------------


def predict(run: Run, m: dict) -> list[tuple[str, str, str]]:
    """(prediction, held|contradicted|not evaluable, the numbers)."""
    out, tl, end = [], run.tl, run.end
    key = (run.setting, run.scenario)
    ready, running = run.placed_ready_at(), run.first_running_at()
    lag = (running - ready).total_seconds() if ready and running else None
    if key in (("off", "never"), ("off", "late")):
        name = "P1" if key[1] == "never" else "P2"
        if ready is None or running is None:
            out.append((name, "not evaluable", f"Ready {ready}, first Running {running}"))
        else:
            stop = end
            second = None
            if key[1] == "late":
                second = tl.first(lambda s: len([x for x in tl.pods(s) if tl.placed(x)
                                                 and not x["metadata"].get("deletionTimestamp")]) >= 2,
                                  after=run.squat_deleted)
                stop = second or end
            span = (stop - running).total_seconds()
            # P1 is about M1, Running while a rank is stranded; P2 is about the CR staying Running until the second placement.
            held = (lambda s: tl.phase(s) == "Running" and tl.stranded(s)) if name == "P1" else (lambda s: tl.phase(s) == "Running")
            share = tl.time_where(running, stop, held) / span if span > 0 else 0.0
            m2 = m["M2_quota_held_before_joining"]
            if name == "P1":
                ok = share >= 0.95 and 0 <= lag <= 10 and len(m2) == 1 and m2[0]["censored"] and not m["M3_requests"]
                detail = (f"Running {share:.1%} of {span:.1f} s from the first Running; first Running {lag:.1f} s after Ready; "
                          f"reservations {m2}; eviction requests {len(m['M3_requests'])}")
            else:
                ok = second is not None and share >= 0.95 and 0 <= lag <= 10 and m["M5_final_phase"] == "Succeeded" \
                    and m["M6_admissions"] == 1
                detail = (f"Running {share:.1%} of {span:.1f} s from the first Running to the second placement at "
                          f"{m['second_rank_placed_after_s']} s; first Running {lag:.1f} s after Ready; "
                          f"final {m['M5_final_phase']}; admissions {m['M6_admissions']}")
            out.append((name, "held" if ok else "contradicted", detail))
    if key == ("ready-timeout", "never"):
        adm = run.admissions()
        reqs = run.requests()
        stamps = run.admitted_stamps()
        timeouts = [r for r in reqs if r[1] == "PodsReadyTimeout"]
        deact = [r for r in reqs if r[1].startswith("Deactivated")]
        initiated = [round((r[2] - st).total_seconds(), 1) for r, st in zip(timeouts, stamps) if r[2] and st]
        stopped = m["M3_stopped"][:len(timeouts)]
        ok = len(adm) == 3 and len(timeouts) == 2 and all(stopped) and len(stopped) == 2 \
            and all(120 <= x <= 135 for x in initiated) and len(initiated) == 2 \
            and len(deact) == 1 and m["M3_max_requeue_count"] == 2
        out.append(("P3", "held" if ok else "contradicted",
                    f"admissions {len(adm)}; PodsReadyTimeout requests {len(timeouts)}, initiated {initiated} s after "
                    f"their admission, stopped {stopped}; requests starting Deactivated {len(deact)}; "
                    f"largest requeue count {m['M3_max_requeue_count']}; eviction lags {m['M4_eviction_lag']}"))
    if key == ("ready-timeout", "late"):
        reqs = run.requests()
        before = [i for i, r in enumerate(reqs) if run.squat_deleted and r[0] < run.squat_deleted and m["M3_stopped"][i]]
        ok = bool(before) and m["M5_final_phase"] == "Succeeded" and m["M6_admissions"] >= 2
        out.append(("P4", "held" if ok else "contradicted",
                    f"stopped attempts before the squatter's deletion {len(before)}; final {m['M5_final_phase']} after "
                    f"{m['M5_succeeded_after_s']} s; admissions {m['M6_admissions']}"))
    if run.setting == "ready-timeout" and any(m["M3_stopped"]):
        held = m["M8_device_held_after_release"]
        ok = bool(held) and all(not h["censored"] and 25 <= h["seconds"] <= 35 and h["exit"] == 137 for h in held)
        out.append(("P6", "held" if ok else "contradicted", f"device held after each release {held}"))
    if run.setting == "ready-timeout" and m["M3_requests"]:
        left = all(a["left_running"] for a in m["M7_after_request"])
        stamps = [ts(x) for x in m["admitted_stamps"]]
        vals = [ts(v) for v in m["M7_admittedAt_values"]]
        stamp_ok = len(vals) <= 1 and (not vals or (stamps and abs((vals[0] - stamps[0]).total_seconds()) <= 1))
        out.append(("P5", "held" if left and stamp_ok else "contradicted",
                    f"phases from each request {[a['phases_from_request'] for a in m['M7_after_request']]}; "
                    f"admittedAt values {m['M7_admittedAt_values']}; Kueue's admission stamps {m['admitted_stamps']}"))
    return out


def predict_after_fix(run: Run, m: dict, earlier: list[tuple[str, str, str]]) -> list[tuple[str, str, str]]:
    """Q1 to Q7 of 2026-10-22-finding-10-after-the-phase-fix-design.md, beside P1 to P6, which describe the old code.

    A witness run is read only for Q1, Q6 and Q7, since the witness changes the job's later admissions.
    """
    out, tl, end = [], run.tl, run.end
    key = (run.setting, run.scenario)
    verdict = {name: v for name, v, _ in earlier}
    entries = run.running_entries()
    # Zero integrated time is not proof the state never occurred, so every single event is checked as well.
    seen = tl.ever(lambda s: tl.phase(s) == "Running" and tl.stranded(s))
    zero = m["M1_unrounded_s"] == 0 and m["M1_polled_upper_unrounded_s"] == 0
    out.append(("Q1", "contradicted" if not zero or seen == "seen" else "not evaluable" if seen == "ambiguous" else "held",
                f"M1 {m['M1_running_while_stranded_s']} s, polled bounds {m['M1_polled_bounds_s']}, "
                f"Running while stranded after any single event {seen}"))
    statuses = [((tl.mltj(s) or {}).get("status") or {}) for _, s in tl.states]
    final = statuses[-1] if statuses else {}
    if key == ("off", "never"):
        m2 = m["M2_quota_held_before_joining"]
        observed = [st.get("runningObservedAt") for st in statuses if st.get("runningObservedAt")]
        # "To the window's end": from the first status with one rank Ready, every later one must still say so.
        first_ready = next((i for i, st in enumerate(statuses) if st.get("readyRanks") == 1), None)
        lapses = [] if first_ready is None else [
            (st.get("phase"), st.get("readyRanks")) for st in statuses[first_ready:]
            if st.get("phase") != "Admitted" or st.get("readyRanks") != 1]
        ok = (m["M5_final_phase"] == "Admitted" and final.get("readyRanks") == 1 and first_ready is not None
              and not lapses and not observed and not entries
              and len(m2) == 1 and m2[0]["censored"] and m2[0]["seconds"] >= run.window - 10)
        out.append(("Q2", "held" if ok else "contradicted",
                    f"final {m['M5_final_phase']}, readyRanks {final.get('readyRanks')}, lapses after the first Ready "
                    f"{lapses[:3]}, runningObservedAt {observed[:1]}, "
                    f"entries into Running {len(entries)}, reservations {m2}"))
    if key == ("off", "late"):
        both = run.both_ready_at()
        a2r = final.get("admitToRunningSeconds")
        admitted = ts(final.get("admittedAt"))
        stamps = run.admitted_stamps()
        first = stamps[0] if stamps else None
        after_ready = (entries[0] - both).total_seconds() if entries and both else None
        # The floor comes from Kueue's own first admission stamp, not the CR's admittedAt, so a controller that moved
        # admittedAt to the Running entry cannot lower the bar along with the figure it is judging.
        floor = (run.squat_deleted - first).total_seconds() - 1 if run.squat_deleted and first else None
        same_stamp = admitted is not None and first is not None and abs((admitted - first).total_seconds()) <= 1
        ok = (len(entries) == 1 and after_ready is not None and 0 <= after_ready <= 10
              and run.squat_deleted is not None and entries[0] >= run.squat_deleted
              and same_stamp and a2r is not None and floor is not None and float(a2r) >= floor
              and m["M5_succeeded_after_s"] is not None)
        out.append(("Q3", "held" if ok else "contradicted",
                    f"entries into Running {len(entries)}, the first {after_ready} s after both ranks were Ready; "
                    f"admitToRunningSeconds {a2r} against at least {floor}; succeeded after {m['M5_succeeded_after_s']} s"))
    if key == ("ready-timeout", "never"):
        stamps = [ts(x) for x in m["admitted_stamps"]]
        vals = [ts(v) for v in m["M7_admittedAt_values"]]
        stamp_ok = len(vals) == 1 and bool(stamps) and abs((vals[0] - stamps[0]).total_seconds()) <= 1
        ok = verdict.get("P3") == "held" and not entries and stamp_ok
        out.append(("Q4", "held" if ok else "contradicted",
                    f"P3 {verdict.get('P3')}; entries into Running {len(entries)}; admittedAt values "
                    f"{m['M7_admittedAt_values']} against the first stamp {m['admitted_stamps'][:1]}"))
    if key == ("ready-timeout", "late"):
        both = run.both_ready_at()
        # "The only entry": a phase that left Running and came back is a contradiction even after both were Ready.
        ok = verdict.get("P4") == "held" and len(entries) == 1 and both is not None and entries[0] >= both
        out.append(("Q5", "held" if ok else "contradicted",
                    f"P4 {verdict.get('P4')}; entries into Running {[e.isoformat() for e in entries]}; "
                    f"both ranks first Ready {both.isoformat() if both else None}"))
    if run.setting == "ready-timeout" and any(m["M3_stopped"]):
        held = m["M8_device_held_after_release"]
        ok = bool(held) and all(not h["censored"] and h["exit"] == 143 and -3 <= h["seconds"] <= 5 for h in held)
        out.append(("Q6", "held" if ok else "contradicted",
                    f"device held after each release {[(h['seconds'], h['exit'], h['censored']) for h in held]}"))
    if run.scenario == "witness":
        w = m["M9_witness"] or {}
        lag, m9, gap = w.get("reserved_after_first_release_s"), w.get("M9_s"), w.get("scheduled_minus_rank_finished_s")
        ok = lag is not None and 0 <= lag <= 3 and m9 is not None and m9 <= 5 and gap is not None and gap >= -1
        out.append(("Q7", "held" if ok else "contradicted",
                    f"reserved {lag} s after the first release; M9 {m9} s; scheduled {gap} s after the evicted rank's "
                    f"finishedAt, which is whole seconds, so -1 s is the same instant; unschedulable {w.get('unschedulable')}"))
    return out


def main(argv: list[str]) -> int:
    out = argv[0]
    if os.path.exists(os.path.join(out, "VOID")):
        print(f"VOID: setup failed at: {read(os.path.join(out, 'VOID')).strip()}")
        return 2
    # A rehearsal may shorten the window; its runs are reported but never scored as the registered study.
    prov = read(os.path.join(out, "provenance.txt")) or ""
    window = re.search(r"window=(\d+) late_at=(\d+)", prov)
    registered = bool(window) and float(window.group(1)) == WINDOW and float(window.group(2)) == LATE_AT
    if not registered:
        print(f"NOT the registered study: provenance records {window.group(0) if window else 'no window'}, "
              f"registered window={WINDOW:.0f} late_at={LATE_AT:.0f}; every run below is a rehearsal")
    setting_bad = {s: setting_problems(out, s) for s in SETTINGS if os.path.isdir(os.path.join(out, "settings", s))}
    for s, probs in setting_bad.items():
        print(f"setting {s}: " + ("in force" if not probs else "NOT shown in force: " + "; ".join(probs)))
    voids = 0
    for d in sorted(glob.glob(os.path.join(out, "runs", "*"))):
        run = Run(d, WINDOW if registered or not window else float(window.group(1)))
        probs = run.problems()
        if run.setting not in setting_bad:
            probs.insert(0, f"no record of setting {run.setting}")
        elif setting_bad[run.setting]:
            probs.insert(0, f"setting {run.setting} not shown in force")
        print(f"\n== {run.setting} {run.scenario} {run.rep} ({run.name})")
        if not registered:
            print(f"(rehearsal) validity problems: {probs or 'none'}")
        elif probs:
            print("VOID: " + "; ".join(probs))
            voids += 1
            continue
        m = run.measures()
        print(json.dumps(m, indent=1, sort_keys=True, default=str))
        earlier = predict(run, m)
        # A witness run is scored only by its Q lines; the P lines describe runs without a second tenant.
        lines = ([] if run.scenario == "witness" else earlier) + predict_after_fix(run, m, earlier)
        for name, verdict, numbers in lines:
            print(f"{name} {verdict}: {numbers}")
    if voids:
        print(f"\n{voids} registered run(s) void")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
