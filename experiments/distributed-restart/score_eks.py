"""Scores a paid restart session on EKS: one verdict for every registered case, and the figures of those accepted.

    python3 experiments/distributed-restart/score_eks.py <run directory>

The registration is docs/superpowers/specs/2026-11-01-distributed-restart-design.md, "The paid session: apparatus";
hack/lib/restart-session.sh writes the directory this reads.
Every registered case gets ACCEPTED, FAILED or VOID with the first reason that decided it, and the summary counts all of
them: a recovery that stalled is FAILED and censored at its budget, never dropped, because a summary over the cases that
went well would report the fast half of the distribution as the whole.

VOID means the apparatus did not deliver what the case registers (the fault did not reach its target, the evidence is
missing, a clock cannot be trusted, NCCL ran over a transport nobody registered); FAILED means it did and the platform
or the trainer did not recover as the case requires.
A FAILED case is one of three: censored, when the job had not ended by its budget and attempt 2's first step is not
among the records collected, which is reported with when observation ended and not as a bound, because nothing shows the
logs were followed throughout; past its budget, when that first step was observed and the job still did not end within
its budget, so the recovery has a time and the completion does not; or not recovered, when the job ended, or recovered,
other than as the case requires.
The summary counts them apart, because a recovery not seen is not a wrong one, a late completion is a slow run after a
recovery that came, and the other is a wrong one.

Exit 0 when every registered case is ACCEPTED, 1 when the run is complete and some case is not, 2 when the run itself is
refused (dirty tree, a trainer other than the approved one, no registration).
"""

from __future__ import annotations

import functools
import json
import lzma
import math
import pathlib
import re
import statistics
import sys

# The registered conventions, each one named in the design's "The paid session: apparatus".
CLOCK_BRACKET_S = 0.5
# How near its budget a job's end may lie and still not be placed on either side of it.
# Its creation and its end are whole seconds, truncated, which puts up to 1 s of error on their difference.
# They also come from two clocks, the API server's and the controller's, which nothing here measures; 1 s more is allowed
# for that on the assumption that both are synchronised, and a case inside the band is VOID rather than either verdict.
BUDGET_BAND_S = 2
CLOCK_OFFSET_S = 2.0
PARAM_TOLERANCE = 1e-6
WORLD = 2
# restart_collect follows a Pod's log at most this many times, then stops reading it (hack/lib/restart-session.sh).
LOG_FOLLOWS = 20
# One GPU per node over the VPC network: NCCL's socket transport, and nothing else, is what the figures describe.
REGISTERED_TRANSPORT = re.compile(r"^NET/Socket(/\d+)?$")
TRANSPORT_LINE = re.compile(r"NCCL INFO Channel \S+ : \d+\[\w+\] -> \d+\[\w+\](?: \[\w+\])? via (\S+)")
NETWORK_LINE = re.compile(r"NCCL INFO Using network (\S+)")
KINDS = ("reference", "no-rng-control", "rank-kill", "dcgm", "terminate-spare", "terminate-wait")
TRIGGER = {"no-rng-control": "RankFailed", "rank-kill": "RankFailed", "dcgm": "NodeFault",
           "terminate-spare": "RankFailed", "terminate-wait": "RankFailed"}
# The registered in-trainer faults resume from a step the fault fixes; the external ones from whatever LATEST named.
RESUME_FROM = {"no-rng-control": 12, "rank-kill": 11}
# The registered in-trainer faults, as CKPT_FAULT names them in restart_case_env: the point, the step and the rank.
IN_TRAINER_FAULT = {"no-rng-control": ("kill-after-latest", 12, 0), "rank-kill": ("kill-before-fsync", 12, 1)}
EXTERNAL_MIN_STEP = 10
FENCE_ANNOTATION = "platform.lkhun9311.github.io/fenced-nodes"


class Verdict(Exception):
    """The first condition a case did not meet, as VOID or FAILED, and for FAILED whether its recovery is censored at its
    budget or its recovery came and its completion was late."""

    def __init__(self, kind: str, reason: str, censored: bool = False, late: bool = False) -> None:
        super().__init__(reason)
        self.kind, self.reason, self.censored, self.late = kind, reason, censored, late


def void(reason: str) -> None:
    raise Verdict("VOID", reason)


def failed(reason: str, censored: bool = False, late: bool = False) -> None:
    raise Verdict("FAILED", reason, censored, late)


def no_constant(name: str) -> float:
    # Python's json reads NaN and Infinity, which no JSON producer of the runner writes, and a NaN compares false with
    # every bound, so clock probes holding one passed every check and reached the figures as NaN.
    raise ValueError(f"the JSON constant {name}, which is not a number the runner writes")


def load_json(path: pathlib.Path):
    return json.loads(path.read_text(), parse_constant=no_constant)


def finite(value) -> bool:
    """A real number that is not NaN or infinite; a bool is not one, though Python counts it an int."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def records_in(text: str) -> list[dict]:
    """Every JSON record in a rank's stdout, wherever it starts.

    NCCL writes to the same stdout as the trainer and has been seen to leave a line unfinished with a record following
    it on the same line (hack/four-gpu/2026-10-29-run5), so a record is found by where it starts, not by the line.
    """
    # Unlike the runner's files, a trainer's NaN is kept: json.dumps writes one for a run that diverged, which is the
    # trainer's outcome, refused where each value is used, and a record dropped here would read as one never printed.
    out, decoder = [], json.JSONDecoder()
    for match in re.finditer(r'\{"ts": ', text):
        try:
            obj, _ = decoder.raw_decode(text, match.start())
        except ValueError:
            continue
        if isinstance(obj, dict) and "event" in obj:
            out.append(obj)
    return out


def jsonl_text(path: pathlib.Path) -> str | None:
    """The text of a JSON-lines file, or of its .xz when only that exists; None when neither does."""
    # The paid archives commit their largest records, the status timelines, xz-compressed.
    # Reading only the plain name voided every termination case of a committed archive the run itself had accepted.
    packed = path.with_name(path.name + ".xz")
    if path.exists():
        return path.read_text()
    if packed.exists():
        # LZMAError is not a ValueError, so a damaged archive would escape the per-case handlers and end the report.
        try:
            return lzma.decompress(packed.read_bytes()).decode()
        except lzma.LZMAError as exc:
            raise ValueError(f"{packed.name} could not be decompressed: {exc}") from exc
    return None


def jsonl(path: pathlib.Path) -> list[dict]:
    text = jsonl_text(path)
    if text is None:
        return []
    try:
        return [json.loads(line, parse_constant=no_constant) for line in text.splitlines() if line.strip().startswith("{")]
    except ValueError as exc:
        # The file is named, because the per-case VOID that reports this is the only place a reader learns which one.
        raise ValueError(f"{path.name}: {exc}") from exc


def epoch(ts: str) -> float:
    import datetime

    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()


def timeline_reads(path: pathlib.Path) -> list[tuple[float, dict]]:
    """status_reads over a timeline file parsed row by row, so one row that is not JSON is skipped like any malformed read.

    The whole file was parsed at once, and a row cut short ended the case instead of being skipped (codex gpt-6-astra
    attack of the retarget registration).
    Other evidence files stay strict: a timeline is a sampler's many reads, each standing alone.
    """
    text = jsonl_text(path)
    rows = []
    for line in (text or "").splitlines():
        if not line.strip().startswith("{"):
            continue
        try:
            rows.append(json.loads(line, parse_constant=no_constant))
        except ValueError:
            continue
    return status_reads(rows)


def status_reads(rows: list[dict]) -> list[tuple[float, dict]]:
    """The sampler's successful, well-formed reads of the job, in order: when it saw each, and the status it read.

    The sampler writes a row for a read that failed as well, with a null status, and a row can be malformed; either
    shows nothing about the job, so it is skipped rather than read as a status without a stamp.
    A well-formed status lists its attempts from the first, so one whose first attempt is not numbered 1 is malformed.
    Both evaluators read timelines through this, so they skip the same rows (codex gpt-6-astra attack of the retarget
    registration: one of them counted a status whose attempts were [null] and extended a bound by an hour).
    """
    out = []
    for r in rows:
        status = r.get("status") if isinstance(r, dict) else None
        if not isinstance(status, dict):
            continue
        attempts = status.get("attempts")
        if attempts is not None and not (isinstance(attempts, list) and all(isinstance(a, dict) for a in attempts)):
            continue
        if attempts and attempts[0].get("number") != 1:
            continue
        try:
            seen = epoch(r["observed"])
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
        if finite(seen):
            out.append((seen, status))
    return out


def provenance(run: pathlib.Path) -> dict[str, str]:
    path = run / "provenance.txt"
    if not path.exists():
        return {}
    pairs = (line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
    return {k.strip(): v.strip() for k, v in pairs}


class Case:
    def __init__(self, run: pathlib.Path, name: str, reference: list[float] | None, steps: int, budget: int) -> None:
        self.name, self.dir, self.reference, self.steps, self.budget = name, run / name, reference, steps, budget
        self.kind = re.sub(r"-\d+$", "", name)
        self.figures: dict = {}
        self._clocks: list[dict] | None = None

    @property
    def clocks(self) -> list[dict]:
        """The clock probes, read when first used: delivery does not depend on them, so an unreadable probe file voids
        what the clocks place, the recovery, and not the check that the fault was delivered (codex gpt-6-astra attack
        of the retarget registration)."""
        if self._clocks is None:
            self._clocks = jsonl(self.dir / "clock.jsonl")
        return self._clocks

    def load(self, runner_void: bool = True) -> None:
        """The case's evidence; with runner_void False, a VOID the runner wrote does not stop it.

        H1 reads delivery from the evidence itself: the runner voids a rank-kill whose probe before the fault failed,
        and the trainer's own fault may have fired by then, so the marker alone once removed a delivered fault's valid
        stop interval (codex gpt-6-astra attack of the retarget registration).
        """
        if not self.dir.is_dir():
            void("its directory is missing")
        if (self.dir / "NOTRUN").exists():
            raise Verdict("NOTRUN", (self.dir / "NOTRUN").read_text().strip()[:200])
        if runner_void and (self.dir / "VOID").exists():
            void("the runner voided it: " + (self.dir / "VOID").read_text().strip()[:200])
        if self.kind not in KINDS:
            void(f"{self.kind} is not a registered kind")
        for need in ("case.json", "final-mltj.json", "pods.jsonl"):
            if not (self.dir / need).exists():
                void(f"no {need}")
        self.spec = load_json(self.dir / "case.json")
        if self.spec.get("kind") != self.kind:
            void(f"case.json says {self.spec.get('kind')!r}, the registration {self.kind!r}")
        self.final = load_json(self.dir / "final-mltj.json")
        self.status = self.final.get("status") or {}
        self.attempts = self.status.get("attempts") or []
        self.pods = {p["uid"]: p for p in jsonl(self.dir / "pods.jsonl")}
        self.marks = {m["mark"]: m["at"] for m in jsonl(self.dir / "marks.jsonl")}
        self._clocks = None
        self.terminated = (self.spec.get("target") or {}).get("node") if self.kind.startswith("terminate") else None
        # Each record is tagged with the node its Pod ran on, which decides whose clock its timestamp is.
        # A Pod's log may be in several files, because a stream that broke while the Pod ran is read again from its
        # start, so the same record can appear twice and is counted once.
        self.records, seen = [], set()
        for log in sorted(self.dir.glob("log-*.txt")):
            uid = log.name[len("log-"):].split(".")[0]
            node = (self.pods.get(uid) or {}).get("node")
            for r in records_in(log.read_text(errors="replace")):
                key = json.dumps(r, sort_keys=True)
                if key in seen:
                    continue
                seen.add(key)
                r["_node"], r["_uid"] = node, uid
                self.records.append(r)

    def bind(self) -> None:
        """Every record is this case's: its job's run_id, from a Pod the collector listed, of the rank that Pod's index is,
        of one attempt per Pod, and from a Pod on a node the controller recorded for that attempt.

        Records were associated by their file's name alone, so a record of another job or of a rank its Pod did not hold
        was scored as this case's (codex review of f57e11a1).
        Any of these is VOID: the evidence is not shown to be the case's, which says nothing of how the platform recovered.
        """
        job = self.spec.get("name")
        held: dict[str, set] = {}
        for r in self.records:
            # train.py's run_id is CKPT_RUN_ID, which the runner sets to the job's name (restart_render_job).
            if r.get("run_id") != job:
                void(f"a record of run {r.get('run_id')!r} is among the logs of job {job!r}")
            pod = self.pods.get(r["_uid"])
            if pod is None:
                void(f"a log of Pod {r['_uid']}, which the collector never listed")
            if str(r.get("rank")) != str(pod.get("index")):
                void(f"a record of rank {r.get('rank')} from Pod {r['_uid']}, whose index is {pod.get('index')}")
            held.setdefault(r["_uid"], set()).add(r.get("attempt"))
        owner: dict[tuple, str] = {}
        seen_at: dict[int, list[float]] = {}
        for uid, attempts in sorted(held.items()):
            # An Indexed Job is recreated per attempt and runs each index once, so one Pod prints one attempt.
            if len(attempts) != 1:
                void(f"Pod {uid} holds records of attempts {sorted(attempts, key=str)}")
            (a,), pod = attempts, self.pods[uid]
            key = (a, str(pod.get("index")))
            if key in owner:
                void(f"attempt {a} rank {key[1]} has records from two Pods, {owner[key]} and {uid}")
            owner[key] = uid
            nodes = (self.attempts[a - 1].get("nodes") or []) if isinstance(a, int) and 0 < a <= len(self.attempts) else []
            if nodes and pod.get("node") not in nodes:
                void(f"Pod {uid} of attempt {a} ran on {pod.get('node')}, which is not among the nodes the controller recorded for attempt {a}, {nodes}")
            seen_at.setdefault(a, []).append(epoch(pod["observed"]))
        # The next attempt's Job exists only after the previous one is stopped, so its Pods cannot be seen first.
        if 1 in seen_at and 2 in seen_at and min(seen_at[2]) < max(seen_at[1]):
            void("a Pod of attempt 2 was seen before a Pod of attempt 1, so which attempt each Pod ran cannot be trusted")

    def rec(self, event: str, attempt: int, rank: int | None = None) -> list[dict]:
        return [r for r in self.records
                if r.get("event") == event and r.get("attempt") == attempt and (rank is None or r.get("rank") == rank)]

    # --- clocks -------------------------------------------------------------------------------------------------------

    @functools.cached_property
    def up_before(self) -> set[str]:
        """The nodes up before the fault, read when a clock needs them and not when the case is loaded, for the same
        reason as name_reused (codex review of 35ba9c4a)."""
        before = self.dir / "nodes-before.json"
        return {n["metadata"]["name"] for n in load_json(before).get("items", [])} if before.exists() else set()

    @functools.cached_property
    def name_reused(self) -> bool:
        """The terminated node's name came back as another Node, a replacement with its own clock.

        Read when a clock is, not when the case is loaded, so a node list the runner could not write afterwards cannot
        turn a recovery already judged censored into VOID before its outcome is read (codex review of 0f8e3811).
        """
        if not self.terminated:
            return False
        uids = []
        for f in ("nodes-before.json", "nodes-after.json"):
            items = load_json(self.dir / f).get("items", []) if (self.dir / f).exists() else []
            uids.append({n["metadata"]["name"]: n["metadata"].get("uid") for n in items})
        before, after = uids
        return self.terminated in before and self.terminated in after and before[self.terminated] != after[self.terminated]

    def clock(self, node: str | None, attempt: int | None = None) -> tuple[float, float]:
        """Seconds the node's clock runs ahead of the runner's and the uncertainty of that, refusing a doubtful clock.

        The median of probes that disagree hides the disagreement: probes at -1.9 s and +1.9 s, each within the
        registered offset, had a median of zero and were accepted (codex review of f57e11a1).
        When a replacement took the terminated node's name, the name is two machines: attempt 1's records and the
        probes before the fault are the old one's, attempt 2's and the probes after it the new one's.
        """
        if not node:
            void("a record whose node is unknown, so its clock cannot be corrected")
        probes = [p for p in self.clocks if p.get("node") == node]
        if self.name_reused and node == self.terminated:
            if attempt not in (1, 2):
                void(f"{node} is two machines, and a time on it belongs to neither attempt")
            side = "before" if attempt == 1 else "after"
            probes = [p for p in probes if p.get("when") == side]
            if not probes:
                void(f"no probe {side} the fault of the machine named {node} then")
        if not probes:
            void(f"no clock probe of {node}")
        offsets, low, high = [], math.inf, -math.inf
        for p in probes:
            # A NaN fails no comparison below, and a literal like 1e999 reads as infinity, whose differences are NaN.
            # Both were accepted: NaN probes with a NaN recovery_s, and probes of 1e999 with an infinite one.
            times = {k: p.get(k) for k in ("before", "node_time", "after")}
            if not all(finite(v) for v in times.values()):
                void(f"a clock probe of {node} holds {times}, not three finite times")
            bracket = p["after"] - p["before"]
            off = p["node_time"] - (p["before"] + p["after"]) / 2
            if not (finite(bracket) and finite(off)):
                void(f"a clock probe of {node} gives a bracket of {bracket} s and an offset of {off} s, not finite")
            if bracket < 0 or bracket > CLOCK_BRACKET_S:
                void(f"the clock probe of {node} took {bracket:.3f} s, wider than {CLOCK_BRACKET_S} s")
            if abs(off) > CLOCK_OFFSET_S:
                void(f"{node}'s clock is {off:+.3f} s from the runner's, beyond {CLOCK_OFFSET_S} s")
            offsets.append(off)
            low, high = min(low, off - bracket / 2), max(high, off + bracket / 2)
        # A figure subtracts a time before the fault from one after it, so a clock that moved in between must be seen to
        # have stayed: probed on both sides, except where the node did not exist, the replacement before and the
        # terminated node after.
        whens = {p.get("when") for p in probes}
        # Each of a reused name's two machines exists on one side of the fault only, and was required its side above.
        if not (self.name_reused and node == self.terminated):
            if node in self.up_before and "before" not in whens:
                void(f"no probe of {node} before the fault, though it was up then")
            if node != self.terminated and "after" not in whens:
                void(f"no probe of {node} after the recovery, though it was not the node terminated")
        # Each probe puts the offset within half its bracket of the truth, so two probes of a clock that held agree
        # within the bracket; probes further apart mean the clock stepped or a probe was wrong.
        if max(offsets) - min(offsets) > CLOCK_BRACKET_S:
            void(f"the probes of {node} disagree by {max(offsets) - min(offsets):.3f} s "
                 f"({min(offsets):+.3f} to {max(offsets):+.3f} s), beyond {CLOCK_BRACKET_S} s")
        # The true offset lies within some probe's bracket, so the median is off from it by at most its distance to the
        # far end of all of them.
        estimate = statistics.median(offsets)
        uncertainty = max(estimate - low, high - estimate)
        if not (finite(estimate) and finite(uncertainty)):
            void(f"{node}'s clock correction is {estimate} s with an uncertainty of {uncertainty} s, not finite")
        return estimate, uncertainty

    def offset(self, node: str | None, attempt: int | None = None) -> float:
        return self.clock(node, attempt)[0]

    def runner_time(self, record: dict) -> float:
        return epoch(record["ts"]) - self.offset(record["_node"], record.get("attempt"))

    # --- the checks, in order -----------------------------------------------------------------------------------------

    def check_job(self, want_attempts: int) -> None:
        phase = self.status.get("phase")
        # The runner reads the final status only after its last clock probe, which comes after the budget has run out, so
        # a job that ended in those seconds would otherwise read as ended within it.
        # Its end is placed by the cluster's own stamps instead: the API server's creation time and the controller's time
        # of the last phase change, which for an ended job is when it ended.
        if phase in ("Succeeded", "Failed"):
            created = (self.final.get("metadata") or {}).get("creationTimestamp")
            ended = self.status.get("lastTransitionTime")
            if not created or not ended:
                void(f"the job ended {phase!r} with no creation time or no end time, so whether it ended within its "
                     f"budget is unknown")
            took = epoch(ended) - epoch(created)
            if abs(took - self.budget) <= BUDGET_BAND_S:
                void(f"the job ended {phase!r} {took:.0f} s after its creation, within {BUDGET_BAND_S} s of its "
                     f"{self.budget} s budget, which its stamps cannot place on either side")
            if took > self.budget:
                self.past_budget(want_attempts, f"the job ended {phase!r} {took:.0f} s after its creation, beyond its "
                                                f"{self.budget} s budget")
        if phase == "Failed":
            failed(f"not recovered: the job ended {phase!r}, not Succeeded, within its budget")
        # Anything short of an end is a run the budget cut off, never a recovery that failed.
        if phase != "Succeeded":
            self.past_budget(want_attempts, f"the job ended {phase!r}, not Succeeded, within its budget")
        if len(self.attempts) != want_attempts:
            failed(f"{len(self.attempts)} attempt(s), want {want_attempts}")
        if want_attempts == 2 and self.attempts[0].get("trigger") != TRIGGER[self.kind]:
            failed(f"attempt 1 ended on {self.attempts[0].get('trigger')!r}, not {TRIGGER[self.kind]}, so the restart was not this fault's")

    def past_budget(self, want_attempts: int, what: str) -> None:
        """FAILED for a job that had not ended within its budget: censored only when attempt 2's first step was never seen.

        The job's completion was once read as its recovery: a case whose every rank of attempt 2 stepped 47.5 s after the
        fault, and whose job ended after its 720 s budget, was reported censored at its budget, a recovery known only to
        exceed the budget.
        The outcome is still decided here, before the evidence the figures need: a recovery that cannot be timed, or a
        bound that cannot be computed, is said so in the reason and leaves the verdict FAILED.
        """
        if want_attempts == 1:
            # The reference has no fault and so no recovery; only its completion can be late.
            failed(f"past its budget: {what}", late=True)
        if sorted({r.get("rank") for r in self.rec("step", 2)}, key=str) == list(range(WORLD)):
            failed(f"past its budget after a recovery: {what}; {self.observed_recovery()}", late=True)
        failed(f"censored at its budget: {what}; {self.observation_end()}", censored=True)

    def observed_recovery(self) -> str:
        """The recovery time of a case whose completion was late, kept as a figure though the case is not ACCEPTED.

        A late case never reaches check_resume, so its earliest remaining step stood for its first: with attempt 2's
        steps 12 to 17 removed, a 47.5 s recovery read 61.2 s (sixth attack, 5).
        The time is kept only from each rank's own step after the checkpoint it resumed from, and only once a probe of
        each node it ran on was taken after it (sixth attack, 7); otherwise later progress is all that is said.
        """
        try:
            fault, _ = self.placed_fault()
            resumes = self.rec("resume", 2)
            from_steps = {r.get("from_step") for r in resumes}
            if sorted(r.get("rank") for r in resumes) != list(range(WORLD)) or len(from_steps) != 1:
                raise ValueError(f"attempt 2's resume records are {[(r.get('rank'), r.get('from_step')) for r in resumes]}, "
                                 f"not one checkpoint for every rank, so its first step is not known")
            first = from_steps.pop() + 1
            records = [r for r in self.rec("step", 2) if r.get("step") == first]
            ranks = sorted(r.get("rank") for r in records)
            if ranks != list(range(WORLD)):
                return (f"every rank of attempt 2 stepped, but ranks {ranks} recorded step {first}, the first after the "
                        f"checkpoint, so only later progress was observed and no recovery time is given")
            self.check_probed_after(records)
            recovery = max(self.runner_time(r) for r in records) - fault
            if not finite(recovery) or recovery <= 0:
                raise ValueError(f"it computes as {recovery} s after the fault, which no clock allows")
        except (Verdict, ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
            why = exc.reason if isinstance(exc, Verdict) else f"{type(exc).__name__}: {str(exc)[:120]}"
            return f"every rank of attempt 2 stepped, at a time that cannot be placed: {why}"
        self.figures["recovery_s"] = recovery
        return f"every rank of attempt 2 had stepped {recovery:.1f} s after the fault, so the recovery came and the completion did not"

    def observation_end(self) -> str:
        """When observation of a recovery that was never seen ended, reported as that and never as a bound on it.

        It was reported as a lower bound, the time from the fault to the last sample, and that claimed the logs had been
        followed throughout: a follow that never connected, hung, or lost its output leaves no record that says so, and
        with the attempt-2 logs removed from an archive whose recovery took 47.5 s the bound read 94.9 s (codex
        gpt-6-astra attack of the retarget registration).
        Observation ends at the last successful, well-formed read of the job; the fault's clock uncertainty is taken off.
        Follows given up before it, of Pods not labelled attempt 1, are named, since they are the gap a reader would ask
        about (codex reviews of 9499dba5 and eca90990).
        """
        try:
            fault, uncertainty = self.placed_fault()
            reads = timeline_reads(self.dir / "timeline.jsonl")
            if not reads:
                raise ValueError("no sample read the job's status")
            cutoff = reads[-1][0]
            window = cutoff - fault - uncertainty
            if not finite(window) or window <= 0:
                raise ValueError(f"the last read of the job comes {window} s after the fault")
            first_attempt = {p["uid"] for p in jsonl(self.dir / "pods.jsonl") if str(p.get("attempt_token")) == "1"}
            ends: dict[str, list[float]] = {}
            for s in jsonl(self.dir / "streams.jsonl"):
                if s["uid"] not in first_attempt:
                    ends.setdefault(s["uid"], []).append(epoch(s["at"]))
            given_up = sorted(u for u, at in ends.items() if len(at) >= LOG_FOLLOWS and max(at) < cutoff)
        except (Verdict, ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
            why = exc.reason if isinstance(exc, Verdict) else f"{type(exc).__name__}: {str(exc)[:120]}"
            return f"attempt 2's first step is not among the records collected, and when observation ended cannot be placed: {why}"
        gap = f"; the log follows of {given_up} were given up before it" if given_up else ""
        return (f"attempt 2's first step is not among the records collected; observation ended {window:.1f} s after the "
                f"fault, at the last read of the job, which is not a bound on the recovery because the logs are not shown "
                f"to cover that time{gap}")

    def attempt1_logs_cut(self) -> str:
        """Which attempt-1 Pods' logs are not shown to have been read to their end, or "" when none.

        Lost steps are counted from attempt 1's last recorded step, so a log whose end was lost understated them and the
        case stayed ACCEPTED: a read-only simulation dropping dcgm-1's step 12 gave zero lost steps for one (gpt-6-astra's
        defect review of #505).
        A Pod's last stream must have exited cleanly, and, where the collector recorded it, not with its container
        still running or unread; a Pod already gone when its stream ended is taken as ended with it, which a deletion
        that outran the stream would defeat.
        Archives written before the collector recorded the container's state are judged on the exit alone.
        """
        first = {p["uid"] for p in jsonl(self.dir / "pods.jsonl") if str(p.get("attempt_token")) == "1"}
        last: dict[str, dict] = {}
        for s in jsonl(self.dir / "streams.jsonl"):
            if s.get("uid") in first and s.get("stream", 0) >= last.get(s["uid"], {}).get("stream", 0):
                last[s["uid"]] = s
        cut = []
        for uid in sorted(first):
            s = last.get(uid)
            if s is None:
                cut.append(f"{uid} has no ended stream")
            elif s.get("exit") != 0:
                cut.append(f"{uid}'s last stream exited {s.get('exit')}")
            elif s.get("container", "terminated") not in ("terminated", "gone"):
                cut.append(f"{uid}'s last stream ended with its container {s.get('container')}")
        return "; ".join(cut)

    def placed_fault(self) -> tuple[float, float]:
        """fault_time, refused when a probe labelled before the fault ended after it, as score() refuses it."""
        fault, uncertainty = self.fault_time()
        # A probe is "before" by when it was taken, not by its label: rank-kill's trainer kills itself at its own step,
        # so a round of probes that ran long could end after that fault and still be labelled before it, and a clock
        # that moved in between would go unseen (codex review before the full stage).
        late = sorted({p["node"] for p in self.clocks if p.get("when") == "before" and p["after"] > fault})
        if late:
            void(f"the probe of {late} labelled before the fault ended after it, so the clock before the fault is not shown")
        return fault, uncertainty

    def check_probed_after(self, records: list[dict]) -> None:
        """Each node a timed record of attempt 2 ran on was probed after that record, by when the probe was taken.

        clock() asks only that some probe be labelled after: probes moved 180 s earlier, before the recovery they were
        to bracket, left a case ACCEPTED with the same uncertainty (sixth attack, 7).
        The record's time and the probe's node_time are both read from the node's own clock, so they compare directly.
        """
        last: dict[str, float] = {}
        for r in records:
            last[r["_node"]] = max(last.get(r["_node"], -math.inf), epoch(r["ts"]))
        for node, t in sorted(last.items()):
            if not any(p.get("node") == node and p.get("when") == "after" and finite(p.get("node_time"))
                       and p["node_time"] > t for p in self.clocks):
                void(f"no probe of {node} was taken after attempt 2's step on it, so its clock after the recovery is not shown")

    def first_steps(self) -> tuple[dict, set]:
        """Each rank's first step of attempt 2 on the runner's clock, and the nodes those steps ran on."""
        firsts, nodes = {}, set()
        for r in self.rec("step", 2):
            firsts[r["rank"]] = min(firsts.get(r["rank"], math.inf), self.runner_time(r))
            nodes.add(r["_node"])
        return firsts, nodes

    def check_starts(self, attempts: int) -> None:
        for a in range(1, attempts + 1):
            starts = self.rec("start", a)
            ranks = sorted(r["rank"] for r in starts)
            if ranks != list(range(WORLD)):
                failed(f"attempt {a} has start records from ranks {ranks}, want every rank of {WORLD}")
            for r in starts:
                # A rank of another world size is not the registered case, whatever it recovered.
                if r.get("world_size") != WORLD:
                    void(f"attempt {a} rank {r['rank']} started with world size {r.get('world_size')!r}, not {WORLD}")
                if r.get("backend") != "nccl" or not str(r.get("device", "")).startswith("cuda"):
                    void(f"attempt {a} rank {r['rank']} trained with {r.get('backend')!r} on {r.get('device')!r}, not nccl on cuda")

    def check_transport(self, attempts: int) -> None:
        """Every rank of every attempt connected over the registered transport, each shown by its own NCCL log.

        The runner names each process's log a<attempt>-r<rank>-..., so one healthy log cannot vouch for a process
        whose log is missing.
        """
        nccl = self.dir / "nccl"
        for a in range(1, attempts + 1):
            for rank in range(WORLD):
                logs = sorted(nccl.glob(f"a{a}-r{rank}-*.log")) if nccl.is_dir() else []
                if not logs:
                    void(f"no NCCL log of attempt {a} rank {rank}, so the transport its steps ran over is unknown")
                text = "".join(log.read_text(errors="replace") for log in logs)
                channels, networks = TRANSPORT_LINE.findall(text), NETWORK_LINE.findall(text)
                if not channels:
                    void(f"the NCCL log of attempt {a} rank {rank} names no channel transport")
                stray = sorted({c for c in channels if not REGISTERED_TRANSPORT.match(c)})
                if stray:
                    void(f"attempt {a} rank {rank} connected over {stray}, not only the registered NET/Socket")
                if not networks or any(n != "Socket" for n in networks):
                    void(f"attempt {a} rank {rank}'s network was {sorted(set(networks)) or 'never named'}, not Socket")

    def final_params(self, attempt: int) -> dict[int, list[float]]:
        """Every rank's parameters at the last step of the attempt, each required and finite, as score_kind.py reads them.

        Reading rank 0 alone accepted a run whose rank 1 ended with NaN or never reached the last step (codex review of
        f57e11a1), and train.py records them on every rank.
        """
        out = {}
        for rank in range(WORLD):
            last = [r for r in self.rec("step", attempt, rank) if r.get("step") == self.steps and r.get("params") is not None]
            if not last:
                failed(f"rank {rank} of attempt {attempt} recorded no final parameters at step {self.steps}")
            got = last[-1]["params"]
            # A NaN is not greater than any tolerance, so a run that diverged would otherwise compare as equal.
            if not isinstance(got, list) or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in got):
                failed(f"attempt {attempt}: rank {rank}'s final parameters are not all finite")
            out[rank] = got
        return out

    def params_gap(self, attempt: int) -> dict[int, float]:
        """Each rank's largest difference from the reference on any component."""
        if self.reference is None:
            failed("there is no accepted reference to compare the final parameters with")
        gaps = {}
        for rank, got in self.final_params(attempt).items():
            if len(got) != len(self.reference):
                failed(f"rank {rank}'s final parameters have {len(got)} components, the reference's {len(self.reference)}")
            gaps[rank] = max(abs(a - b) for a, b in zip(got, self.reference))
        return gaps

    def check_resume(self) -> dict:
        if self.rec("restart_from_zero", 2):
            failed("attempt 2 restarted from step zero, which is not a recovery")
        resumes = self.rec("resume", 2)
        ranks = sorted(r["rank"] for r in resumes)
        if ranks != list(range(WORLD)):
            failed(f"attempt 2 has resume records from ranks {ranks}, want every rank of {WORLD}")
        dirs = {(r["from_dir"], r["from_step"]) for r in resumes}
        if len(dirs) != 1:
            failed(f"the ranks of attempt 2 resumed from different checkpoints: {sorted(dirs)}")
        (from_dir, from_step), = dirs
        if from_step <= 0:
            failed(f"attempt 2 resumed from step {from_step}, which is not a resume")
        want = RESUME_FROM.get(self.kind)
        if want is not None and from_step != want:
            failed(f"attempt 2 resumed from step {from_step}, and this fault leaves step {want}")
        if want is None and from_step < EXTERNAL_MIN_STEP:
            void(f"attempt 2 resumed from step {from_step}: the fault came before the published step {EXTERNAL_MIN_STEP} it waits for")
        # train.py names a checkpoint a<attempt>/<step>-<uuid> and never revisits it, so the name says which attempt
        # wrote it and at which step; a resume from attempt 2's own directory, or one whose name and step disagree,
        # is not a resume from what attempt 1 published.
        named = re.fullmatch(r"a(\d+)/(\d{8})-[0-9a-f]{32}", str(from_dir))
        if not named or int(named.group(1)) >= 2:
            failed(f"attempt 2 resumed from {from_dir!r}, which is not a checkpoint of an earlier attempt")
        if int(named.group(2)) != from_step:
            failed(f"attempt 2 resumed from {from_dir!r}, which names step {int(named.group(2))} and the ranks say {from_step}")
        # The runner lists the job's files after its writers are retired and before it deletes them (shared-files.txt).
        # No checkpoint record shows a published manifest in general, because kill-after-latest publishes one and dies
        # before the barrier any rank records a checkpoint after.
        listing = self.dir / "shared-files.txt"
        if not listing.exists():
            void("no listing of the job's files on the volume, so the checkpoint resumed from is not shown to be published")
        manifest = f"/{self.spec.get('job_id')}/{from_dir}/MANIFEST"
        if not any(line.strip().endswith(manifest) for line in listing.read_text().splitlines()):
            void(f"the volume's listing has no {manifest}, so the checkpoint resumed from is not shown to be published")
        # The first step after a resume is the one after the checkpoint, and every step to the last follows once.
        for rank in range(WORLD):
            steps = sorted(r.get("step") for r in self.rec("step", 2, rank))
            want_steps = list(range(from_step + 1, self.steps + 1))
            if steps != want_steps:
                lack = sorted(set(want_steps) - set(steps))
                extra = sorted(set(steps) - set(want_steps), key=str)
                failed(f"rank {rank} of attempt 2 resumed from step {from_step}, and its steps lack {lack[:5]}"
                       + (f" and add {extra[:5]}" if extra else "") + (" and repeat some" if len(set(steps)) != len(steps) else ""))
        return {"from_dir": from_dir, "from_step": from_step}

    def check_delivered(self) -> None:
        """The registered fault reached its registered target, before anything about the recovery is judged.

        Checked first, so a fault that never landed is VOID rather than read as a recovery that failed or, worse, as
        one that succeeded because nothing happened.
        """
        if self.kind in IN_TRAINER_FAULT:
            point, step, want = IN_TRAINER_FAULT[self.kind]
            fired = self.rec("fault", 1)
            if len(fired) != 1 or fired[0]["rank"] != want:
                void(f"attempt 1 has fault records from ranks {[r['rank'] for r in fired]}, want exactly one, from rank {want}")
            # Another point is another fault: kill-after-latest leaves step 12 published and kill-before-fsync does not.
            if (fired[0].get("point"), fired[0].get("step")) != (point, step):
                void(f"attempt 1's fault was {fired[0].get('point')!r} at step {fired[0].get('step')}, not the registered {point!r} at step {step}")
            return
        target = self.spec.get("target") or {}
        rank1 = sorted((p for p in self.pods.values() if str(p.get("index")) == "1"), key=lambda p: p.get("observed", ""))
        if not rank1 or rank1[0].get("node") != target.get("node"):
            void(f"the target node {target.get('node')!r} is not where rank 1 of attempt 1 ran")
        if self.kind == "dcgm":
            dcgm = load_json(self.dir / "dcgm.json") if (self.dir / "dcgm.json").exists() else {}
            if dcgm.get("node") != target.get("node"):
                void(f"the fault was injected on {dcgm.get('node')!r}, not the target {target.get('node')!r}")
            if str(dcgm.get("readback")) != "79":
                void(f"the injected XID read back as {dcgm.get('readback')!r}, not 79")
            if not dcgm.get("latched") or not dcgm.get("tainted"):
                void(f"the target's NodeHealth latched {dcgm.get('latched')!r} and its node was tainted {dcgm.get('tainted')!r}")
            return
        nodes = load_json(self.dir / "nodes-before.json") if (self.dir / "nodes-before.json").exists() else {}
        pid = {n["metadata"]["name"]: n["spec"].get("providerID", "") for n in nodes.get("items", [])}
        if not target.get("instance") or not pid.get(target["node"], "").endswith("/" + target["instance"]):
            void(f"the terminated instance {target.get('instance')!r} is not the target node's {pid.get(target.get('node'))!r}")
        if "fault-start" not in self.marks or "terminated-read" not in self.marks:
            void("no mark of the termination call or of EC2 reporting the instance terminated")
        # The fence is the runner's part of the fault: written only once EC2 describes the instance as terminated, it
        # is what the registration lets release the stop barrier, so a fence missing or written before that is VOID,
        # the apparatus not delivering the registered fault, and says nothing about the platform.
        if "fenced" not in self.marks or "fence-request" not in self.marks:
            void("no fence-request or fenced mark, so the acknowledgement the next attempt waits for is not shown to "
                 "have been written")
        start, read, request, fenced = (epoch(self.marks[m]) for m in ("fault-start", "terminated-read", "fence-request", "fenced"))
        if not start <= read <= request <= fenced:
            void(f"the marks are fault-start {self.marks['fault-start']}, terminated-read {self.marks['terminated-read']}, "
                 f"fence-request {self.marks['fence-request']} and fenced {self.marks['fenced']}: the fence was asked "
                 f"for before EC2 reported the instance terminated, or EC2 before the call")
        ack = str(((self.final.get("metadata") or {}).get("annotations") or {}).get(FENCE_ANNOTATION, ""))
        # An entry may bind the name to one machine as name@uid, and then it must be the machine attempt 1 ran on.
        node = target.get("node")
        uid = ((self.attempts[0].get("nodeUIDs") or {}).get(node)) if self.attempts else None
        if node not in ack.split(",") and not (uid and f"{node}@{uid}" in ack.split(",")):
            void(f"the job's fenced-nodes annotation is {ack!r}, not naming the target {node}")

    def check_barrier(self) -> None:
        """Attempt 2 of a termination case was created only after the fence, on the runner's clock where it can be.

        FAILED, not VOID: the fence was delivered (check_delivered), and starting the next attempt before it is the
        platform's stop barrier letting a node that may still write the volume share it with the new attempt.
        """
        # The annotation can take effect, and the controller act on it, before the annotate call returns.
        # So the earliest moment the fence may exist is the request, and only a creation before that is shown early.
        request = epoch(self.marks["fence-request"])
        timeline = jsonl(self.dir / "timeline.jsonl")
        if not timeline:
            void("no timeline of the job's status, so when attempt 2 appeared is not shown")
        # The runner's samples are on its own clock, as the mark is, so one taken before the request decides it exactly.
        for s in timeline:
            if epoch(s["observed"]) < request and len((s.get("status") or {}).get("attempts") or []) >= 2:
                failed(f"attempt 2 was already in the job's status at {s['observed']}, before the fence was asked "
                       f"for at {self.marks['fence-request']}")
        created = self.attempts[1].get("createdAt")
        if not created:
            void("attempt 2 has no createdAt, so when it was created is not shown")
        # createdAt is the controller's clock, which nothing probes, in whole seconds truncated, so it is allowed the
        # second and the registered largest offset before it is read as earlier than the fence.
        if epoch(created) + 1 + CLOCK_OFFSET_S < request:
            failed(f"attempt 2 was created at {created}, before the fence was asked for at {self.marks['fence-request']} "
                   f"by more than the {CLOCK_OFFSET_S} s an unprobed clock is allowed")

    def fault_time(self) -> tuple[float, float]:
        """The fault on the runner's clock, and its uncertainty: the trainer's own record, the node's time in the
        injecting exec, or the mark taken before the termination call, so the call's own latency is inside the recovery.

        The mark is the runner's own clock, so it adds no uncertainty of a probe's.
        """
        if self.kind in ("rank-kill", "no-rng-control"):
            record = self.rec("fault", 1)[0]
            return self.runner_time(record), self.clock(record["_node"])[1]
        if self.kind == "dcgm":
            dcgm = load_json(self.dir / "dcgm.json")
            return self.runner_time({"ts": dcgm["injected_at"], "_node": dcgm["node"]}), self.clock(dcgm["node"])[1]
        return epoch(self.marks["fault-start"]), 0.0

    def recovery_class(self, fault: float) -> str:
        """same-nodes, spare or replacement, by the Node each name was, read from the cluster before and after.

        Names alone called a replacement that took the terminated node's name same-nodes, and a terminate-wait that
        recovered on a node up before the fault a spare (codex review of f57e11a1).
        A Node's UID is new for every Node object, so a machine the group launched is told apart whatever its name.
        """
        a1 = set(self.attempts[0].get("nodes") or [])
        a2 = set(self.attempts[1].get("nodes") or [])
        if not a1 or not a2:
            void("the attempts' nodes were not recorded")
        for name in ("nodes-before.json", "nodes-after.json"):
            if not (self.dir / name).exists():
                void(f"the nodes {'before the fault' if 'before' in name else 'after the recovery'} were not recorded")
        before = {n["metadata"]["name"]: n["metadata"]["uid"] for n in load_json(self.dir / "nodes-before.json")["items"]}
        after = {n["metadata"]["name"]: n["metadata"]["uid"] for n in load_json(self.dir / "nodes-after.json")["items"]}
        if not a1 <= set(before):
            void(f"attempt 1's nodes {sorted(a1 - set(before))} are not among the nodes before the fault")
        if not a2 <= set(after):
            void(f"attempt 2's nodes {sorted(a2 - set(after))} are not among the nodes after the recovery, so which machines they were is not shown")
        if self.terminated and after.get(self.terminated) == before.get(self.terminated) and self.terminated in a2:
            void(f"attempt 2 ran on {self.terminated}, the node that was terminated, as the same Node")
        new = sorted(n for n in a2 if after[n] not in set(before.values()))
        # terminate-wait runs with the group at two, so its recovery must wait for a machine the group launches.
        if self.kind == "terminate-wait" and not new:
            void(f"terminate-wait recovered on {sorted(a2)}, every one up before the fault, so no replacement was waited for")
        if new:
            return "replacement"
        if {after[n] for n in a2} <= {before[n] for n in a1}:
            return "same-nodes"
        # A spare is a node up and prepared before the fault; one up but never prepared had its first pull and mount
        # inside the recovery, which is neither what a spare nor what a replacement registers.
        # Preparation is matched by the Node's UID, as the runner records it, and not by its name: a machine that took a
        # prepared one's name inherited its preparation and was scored a spare (codex review before the full stage).
        prepared: dict[str, float] = {}
        for row in jsonl(self.dir.parent / "nodes-prepared.jsonl"):
            if not row.get("uid"):
                void(f"a preparation of {row.get('node')} names no Node UID, so which machine was prepared is not shown")
            prepared[row["uid"]] = min(prepared.get(row["uid"], math.inf), epoch(row["prepared_at"]))
        late = sorted(n for n in a2 - a1 if prepared.get(after[n], math.inf) > fault)
        if late:
            void(f"attempt 2 ran on {late}, up before the fault but not prepared before it (nodes-prepared.jsonl)")
        return "spare"

    def check_steps(self, attempt: int, last: int | None = None) -> None:
        """Each rank's step records of the attempt run from 1 without a gap, to `last` when it is given.

        The save check compares saves with steps, so a step and its save both missing passed it: the reference with only
        its step 30 left was ACCEPTED on two saves, and attempt 1 with its step 12 removed moved lost steps from 1 to 0
        (codex gpt-6-astra attack of the retarget registration).
        An in-trainer fault's record names the step its rank reached, so that rank's steps must reach it.
        """
        for rank in range(WORLD):
            steps = {r.get("step") for r in self.rec("step", attempt, rank)}
            if not steps or not all(isinstance(s, int) and not isinstance(s, bool) for s in steps):
                void(f"attempt {attempt} rank {rank} has no step records, or one that is not a whole number")
            stepped = sorted(steps)
            top = last if last is not None else max(stepped)
            if stepped != list(range(1, top + 1)):
                void(f"attempt {attempt} rank {rank} recorded steps {stepped[:3]}...{stepped[-3:]}, not every step from 1 to {top}")
        if attempt == 1 and self.kind in IN_TRAINER_FAULT:
            fired = self.rec("fault", 1)
            _, step, rank = IN_TRAINER_FAULT[self.kind]
            reached = max((r.get("step") for r in self.rec("step", 1, rank)), default=0)
            if fired and reached < step:
                void(f"attempt 1 rank {rank}'s steps end at {reached}, before step {step} its fault record says it reached")

    def score(self) -> None:
        self.load()
        self.bind()
        if self.kind == "reference":
            if not self.records:
                void("no rank recorded anything")
            self.check_job(1)
            self.check_starts(1)
            self.check_transport(1)
            self.check_steps(1, self.steps)
            got = self.final_params(1)
            # DDP keeps every rank's parameters equal, so ranks that disagree did not train one model.
            if any(len(p) != len(got[0]) for p in got.values()):
                failed("the ranks' final parameters have different sizes")
            spread = max(abs(a - b) for p in got.values() for a, b in zip(p, got[0]))
            if spread > PARAM_TOLERANCE:
                failed(f"the ranks ended {spread:.3g} apart, beyond {PARAM_TOLERANCE}")
            self.figures["checkpoint_s"] = self.save_costs(1, completed=True)
            self.figures["checkpoint"] = self.checkpoint_stats(1)
            return
        # Delivery, then the outcome, then the evidence the figures need, then what the recovery restored: a recovery
        # that timed out lacks attempt 2's records by its nature, and is FAILED, censored, not VOID for lacking them.
        self.check_delivered()
        self.check_job(2)
        if self.kind.startswith("terminate"):
            self.check_barrier()
        self.check_starts(2)
        self.check_transport(2)
        self.check_steps(1)
        resumed = self.check_resume()
        gaps = self.params_gap(2)
        gap = max(gaps.values())
        if self.kind == "no-rng-control":
            # A control the comparison cannot tell from a full resume shows the comparison is blind, not that RNG is moot.
            # Every rank must differ: a rank that matched the reference is one the comparison could not see the RNG through.
            if min(gaps.values()) <= PARAM_TOLERANCE:
                failed(f"dropping the RNG left the parameters within {PARAM_TOLERANCE} of the reference ({min(gaps.values()):.3g})")
            self.figures.update({"params_gap": gap, "checkpoint": self.checkpoint_stats(2), **resumed})
            return
        for rank, g in sorted(gaps.items()):
            if g > PARAM_TOLERANCE:
                failed(f"the resumed run's rank {rank} ended {g:.3g} from the reference, beyond {PARAM_TOLERANCE}")
        fault, fault_uncertainty = self.placed_fault()
        firsts, nodes = self.first_steps()
        if sorted(firsts) != list(range(WORLD)):
            failed(f"attempt 2 has step records from ranks {sorted(firsts)}, want every rank of {WORLD}")
        lost_from = max(r["step"] for r in self.rec("step", 1))
        # Attempt 1 recorded at least the step its resume came from, or its log is not all there.
        if lost_from < resumed["from_step"]:
            void(f"attempt 1's step records end at {lost_from}, before step {resumed['from_step']} it resumed from, so its log is incomplete")
        # A log whose end was not read can have lost its last steps, and lost steps counted from it are too few.
        cut = self.attempt1_logs_cut()
        if cut:
            self.figures["lost_steps_withheld"] = f"attempt 1's logs may lack their end: {cut}"
        self.figures.update({
            "recovery_s": max(firsts.values()) - fault,
            # How far the recovery can be off for the clocks alone: the fault's clock and the worst of attempt 2's.
            "clock_uncertainty_s": fault_uncertainty + max(self.clock(n, 2)[1] for n in nodes),
            "lost_steps": None if cut else lost_from - resumed["from_step"],
            "class": self.recovery_class(fault),
            "params_gap": gap,
            "checkpoint_s": self.save_costs(1, completed=False) + self.save_costs(2, completed=True),
            "checkpoint": self.checkpoint_stats(2),
            **resumed,
        })
        # check_resume has shown every rank's steps run from the one after the checkpoint, so these are the first steps.
        # After recovery_class, whose refusal of a recovery on the terminated node names the cause and not its probe.
        self.check_probed_after([r for r in self.rec("step", 2) if r.get("step") == resumed["from_step"] + 1])
        # A NaN is not at most zero, so the positivity test alone passed a recovery_s of NaN.
        for figure in ("recovery_s", "clock_uncertainty_s"):
            if not finite(self.figures[figure]):
                void(f"{figure} computes as {self.figures[figure]}, not a finite duration")
        if self.figures["recovery_s"] <= 0:
            void(f"attempt 2's first step is {self.figures['recovery_s']:.3f} s after the fault, which no clock allows")

    def save_costs(self, attempt: int, completed: bool) -> list[float]:
        """Every save cost of the attempt, each rank's included, refusing a checkpoint record without a cost.

        Records whose cost was missing or not a number were once left out of the figure, and the ranks were counted
        among the records, not the costs: a run with no rank-1 cost, or no cost at all, was ACCEPTED with "saves": 0.
        completed says the attempt ran to the job's success, which train.py returns only after its last save.
        """
        records = self.rec("checkpoint", attempt)
        # Each rank of each attempt must have saved, or the figure is one rank's and reads as both (codex review before
        # the full stage).
        ranks = sorted({r.get("rank") for r in records}, key=str)
        if ranks != list(range(WORLD)):
            void(f"attempt {attempt} has save records from ranks {ranks}, want every rank of {WORLD}")
        # Every step a rank took is saved, but for the last one a fault can cut before its save: the figure is then every
        # save, and not a sample of them that reads as all (codex gpt-6-astra attack of the retarget registration, where
        # 2 of the reference's 60 saves gave an ACCEPTED median of 0.286 s for 0.250 s).
        # Read from both paid archives: each attempt and rank saved every step it took, or all but its last.
        # Only a fault can cut that last save, so an attempt that completed saved them all: with both of the reference's
        # step-30 saves removed it was ACCEPTED on 58 (sixth attack, 6).
        for rank in range(WORLD):
            stepped = {r.get("step") for r in self.rec("step", attempt, rank)}
            saves = [r.get("step") for r in records if r.get("rank") == rank]
            saved = set(saves)
            if not all(isinstance(s, int) and not isinstance(s, bool) for s in stepped | saved):
                void(f"attempt {attempt} rank {rank} records a step that is not a whole number")
            # Identical records were counted once when the logs were read, so two left for one step disagree, and a
            # set of steps hid that: a second cost of 10 s became the reference's maximum (sixth attack, 6).
            twice = sorted(s for s in saved if saves.count(s) > 1)
            if twice:
                void(f"attempt {attempt} rank {rank} has differing save records of steps {twice[:5]}, so which cost was "
                     f"paid is not shown")
            unsaved, unstepped = stepped - saved, saved - stepped
            if unstepped or len(unsaved) > 1 or (unsaved and unsaved != {max(stepped)}):
                void(f"attempt {attempt} rank {rank} has save records of steps {sorted(saved)} for steps "
                     f"{sorted(stepped)}, which is not every step but at most its last")
            if completed and unsaved:
                void(f"attempt {attempt} rank {rank} completed with no save record of its last step {max(unsaved)}, "
                     f"and an attempt that completed saved every step")
        for r in records:
            cost = r.get("save_s")
            if not finite(cost) or cost < 0:
                what = "no save cost" if "save_s" not in r else f"save cost {cost!r}, which no save takes"
                void(f"attempt {attempt} rank {r.get('rank')}'s checkpoint of step {r.get('step')} records {what}")
        return [r["save_s"] for r in records]

    def checkpoint_stats(self, attempts: int) -> dict:
        """Every rank's save cost, as median and maximum per attempt, which the registration names as the figure.

        Called once the job is shown Succeeded, so the last attempt is the one that completed.
        """
        out = {}
        for a in range(1, attempts + 1):
            costs = self.save_costs(a, completed=a == attempts)
            out[f"a{a}"] = {"saves": len(costs), "median_s": round(statistics.median(costs), 3), "max_s": round(max(costs), 3)}
        return out


def run_refusals(prov: dict[str, str]) -> list[str]:
    """Why a run cannot be scored at all, from its provenance; empty when it can. phases_eks.py asks the same."""
    refusals = []
    if prov.get("dirty_files") != "0":
        refusals.append(f"the run was made from a tree with {prov.get('dirty_files', 'an unknown number of')} uncommitted change(s)")
    if not prov.get("train_py_sha256") or prov.get("train_py_sha256") != prov.get("approved_train_py_sha256"):
        refusals.append(f"train.py {prov.get('train_py_sha256')!r} is not the approved {prov.get('approved_train_py_sha256')!r}")
    cases = prov.get("cases", "").split()
    if not cases or cases[0] != "reference":
        refusals.append("no registered case list starting with the reference")
    if not prov.get("steps", "").isdigit():
        refusals.append("no registered step count")
    if not prov.get("case_budget", "").isdigit():
        refusals.append("no registered case budget")
    return refusals


def main(argv: list[str]) -> int:
    # --partial scores a run still in progress: a registered case with no directory yet is left out instead of VOID.
    partial = len(argv) == 3 and argv[1] == "--partial"
    if len(argv) != 2 and not partial:
        print(__doc__, file=sys.stderr)
        return 2
    run = pathlib.Path(argv[-1])
    prov = provenance(run)
    refusals = run_refusals(prov)
    if refusals:
        for r in refusals:
            print(f"REFUSED: {r}")
        return 2

    steps = int(prov["steps"])
    cases = prov["cases"].split()
    verdicts: dict[str, tuple[str, str, bool, bool]] = {}
    scored: dict[str, Case] = {}
    reference: list[float] | None = None
    if partial:
        cases = [n for n in cases if (run / n).is_dir()]
    for name in cases:
        case = Case(run, name, reference, steps, int(prov["case_budget"]))
        try:
            case.score()
            verdicts[name] = ("ACCEPTED", "", False, False)
        except Verdict as v:
            verdicts[name] = (v.kind, v.reason, v.censored, v.late)
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
            # Evidence that cannot be read is that case's VOID, never the end of the report: an empty file left by
            # one failed kubectl call would otherwise leave every other case without a verdict (codex review of 830f64af).
            verdicts[name] = ("VOID", f"its evidence could not be read: {type(exc).__name__}: {str(exc)[:120]}", False, False)
        scored[name] = case
        if name == "reference":
            reference = case.final_params(1)[0] if verdicts[name][0] == "ACCEPTED" else None

    for name in cases:
        kind, reason = verdicts[name][:2]
        fig = scored[name].figures
        shown = {k: (round(v, 3) if isinstance(v, float) else v) for k, v in fig.items() if k != "checkpoint_s"}
        print(f"{kind:8} {name}" + (f": {reason}" if reason else f" {json.dumps(shown, sort_keys=True)}"))

    print("summary")
    for kind in KINDS:
        names = [n for n in cases if scored[n].kind == kind]
        if not names:
            continue
        counts = {v: sum(1 for n in names if verdicts[n][0] == v) for v in ("ACCEPTED", "FAILED", "VOID", "NOTRUN")}
        censored = sum(1 for n in names if verdicts[n][0] == "FAILED" and verdicts[n][2])
        late = sum(1 for n in names if verdicts[n][0] == "FAILED" and verdicts[n][3])
        wrong = counts["FAILED"] - censored - late
        print(f"  {kind}: {len(names)} registered, {counts['ACCEPTED']} ACCEPTED, {counts['FAILED']} FAILED ({censored} censored "
              f"at their budget, {late} past their budget after a recovery, {wrong} not recovered), {counts['VOID']} VOID, "
              f"{counts['NOTRUN']} NOTRUN")
        # Per recovery class, because spare and replacement recoveries are different claims and are never pooled.
        for cls in ("same-nodes", "spare", "replacement"):
            rec = [scored[n].figures["recovery_s"] for n in names
                   if verdicts[n][0] == "ACCEPTED" and scored[n].figures.get("class") == cls]
            lost = [scored[n].figures["lost_steps"] for n in names
                    if verdicts[n][0] == "ACCEPTED" and scored[n].figures.get("class") == cls]
            withheld = sum(1 for v in lost if v is None)
            shown = sorted(v for v in lost if v is not None)
            if rec:
                print(f"    {cls}: recovery median {statistics.median(rec):.1f} s, range {min(rec):.1f} to {max(rec):.1f} s, "
                      f"lost steps {shown}{f' ({withheld} withheld, their logs not shown read to the end)' if withheld else ''}, "
                      f"over {len(rec)} accepted; the {censored} FAILED censored at their budget, "
                      f"the {late} past their budget after a recovery, the {wrong} not recovered and the {counts['VOID']} VOID are not in these figures")
        # The registration counts a terminate-spare that recovered on a replacement as a replacement, never as a spare,
        # and says so here, so a spare figure over fewer cases than ran is not read as every spare recovery.
        if kind == "terminate-spare":
            moved = [n for n in names if verdicts[n][0] == "ACCEPTED" and scored[n].figures.get("class") == "replacement"]
            if moved:
                print(f"    terminate-spare: {len(moved)} of {counts['ACCEPTED']} accepted recovered on a replacement, not the "
                      f"spare ({', '.join(moved)}), and are in its replacement figures only")
    costs = [c for n in cases if verdicts[n][0] == "ACCEPTED" for c in scored[n].figures.get("checkpoint_s", [])]
    if costs:
        print(f"  checkpoint cost: median {statistics.median(costs):.3f} s, max {max(costs):.3f} s over {len(costs)} saves")
    return 0 if all(v[0] == "ACCEPTED" for v in verdicts.values()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
