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
A FAILED case is one of two: censored, when the job was still short of an end at its budget, so its recovery time is
known only to exceed the budget; or not recovered, when the job ended, or recovered, other than as the case requires.
The summary counts them apart, because a censored recovery is a slow one and the other is a wrong one.

Exit 0 when every registered case is ACCEPTED, 1 when the run is complete and some case is not, 2 when the run itself is
refused (dirty tree, a trainer other than the approved one, no registration).
"""

from __future__ import annotations

import json
import math
import pathlib
import re
import statistics
import sys

# The registered conventions, each one named in the design's "The paid session: apparatus".
CLOCK_BRACKET_S = 0.5
CLOCK_OFFSET_S = 2.0
PARAM_TOLERANCE = 1e-6
WORLD = 2
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
    """The first condition a case did not meet, as VOID or FAILED, and for FAILED whether it is censored at its budget."""

    def __init__(self, kind: str, reason: str, censored: bool = False) -> None:
        super().__init__(reason)
        self.kind, self.reason, self.censored = kind, reason, censored


def void(reason: str) -> None:
    raise Verdict("VOID", reason)


def failed(reason: str, censored: bool = False) -> None:
    raise Verdict("FAILED", reason, censored)


def records_in(text: str) -> list[dict]:
    """Every JSON record in a rank's stdout, wherever it starts.

    NCCL writes to the same stdout as the trainer and has been seen to leave a line unfinished with a record following
    it on the same line (hack/four-gpu/2026-10-29-run5), so a record is found by where it starts, not by the line.
    """
    out, decoder = [], json.JSONDecoder()
    for match in re.finditer(r'\{"ts": ', text):
        try:
            obj, _ = decoder.raw_decode(text, match.start())
        except ValueError:
            continue
        if isinstance(obj, dict) and "event" in obj:
            out.append(obj)
    return out


def jsonl(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip().startswith("{")]


def epoch(ts: str) -> float:
    import datetime

    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()


def provenance(run: pathlib.Path) -> dict[str, str]:
    path = run / "provenance.txt"
    if not path.exists():
        return {}
    pairs = (line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
    return {k.strip(): v.strip() for k, v in pairs}


class Case:
    def __init__(self, run: pathlib.Path, name: str, reference: list[float] | None, steps: int) -> None:
        self.name, self.dir, self.reference, self.steps = name, run / name, reference, steps
        self.kind = re.sub(r"-\d+$", "", name)
        self.figures: dict = {}

    def load(self) -> None:
        if not self.dir.is_dir():
            void("its directory is missing")
        if (self.dir / "NOTRUN").exists():
            raise Verdict("NOTRUN", (self.dir / "NOTRUN").read_text().strip()[:200])
        if (self.dir / "VOID").exists():
            void("the runner voided it: " + (self.dir / "VOID").read_text().strip()[:200])
        if self.kind not in KINDS:
            void(f"{self.kind} is not a registered kind")
        for need in ("case.json", "final-mltj.json", "pods.jsonl"):
            if not (self.dir / need).exists():
                void(f"no {need}")
        self.spec = json.loads((self.dir / "case.json").read_text())
        if self.spec.get("kind") != self.kind:
            void(f"case.json says {self.spec.get('kind')!r}, the registration {self.kind!r}")
        self.final = json.loads((self.dir / "final-mltj.json").read_text())
        self.status = self.final.get("status") or {}
        self.attempts = self.status.get("attempts") or []
        self.pods = {p["uid"]: p for p in jsonl(self.dir / "pods.jsonl")}
        self.marks = {m["mark"]: m["at"] for m in jsonl(self.dir / "marks.jsonl")}
        self.clocks = jsonl(self.dir / "clock.jsonl")
        before = self.dir / "nodes-before.json"
        self.up_before = {n["metadata"]["name"] for n in json.loads(before.read_text()).get("items", [])} if before.exists() else set()
        self.terminated = (self.spec.get("target") or {}).get("node") if self.kind.startswith("terminate") else None
        # A replacement can come back under the terminated node's name, and it is another machine with its own clock.
        after = self.dir / "nodes-after.json"
        uids_before = {n["metadata"]["name"]: n["metadata"].get("uid") for n in json.loads(before.read_text()).get("items", [])} if before.exists() else {}
        uids_after = {n["metadata"]["name"]: n["metadata"].get("uid") for n in json.loads(after.read_text()).get("items", [])} if after.exists() else {}
        self.name_reused = bool(self.terminated and self.terminated in uids_before and self.terminated in uids_after
                                and uids_before[self.terminated] != uids_after[self.terminated])
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
            bracket = p["after"] - p["before"]
            if bracket < 0 or bracket > CLOCK_BRACKET_S:
                void(f"the clock probe of {node} took {bracket:.3f} s, wider than {CLOCK_BRACKET_S} s")
            off = p["node_time"] - (p["before"] + p["after"]) / 2
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
        return estimate, max(estimate - low, high - estimate)

    def offset(self, node: str | None, attempt: int | None = None) -> float:
        return self.clock(node, attempt)[0]

    def runner_time(self, record: dict) -> float:
        return epoch(record["ts"]) - self.offset(record["_node"], record.get("attempt"))

    # --- the checks, in order -----------------------------------------------------------------------------------------

    def check_job(self, want_attempts: int) -> None:
        phase = self.status.get("phase")
        if phase == "Failed":
            failed(f"not recovered: the job ended {phase!r}, not Succeeded, within its budget")
        # Anything short of an end is a recovery the budget cut off: censored, never a recovery that failed.
        if phase != "Succeeded":
            failed(f"censored at its budget: the job ended {phase!r}, not Succeeded, within its budget", censored=True)
        if len(self.attempts) != want_attempts:
            failed(f"{len(self.attempts)} attempt(s), want {want_attempts}")
        if want_attempts == 2 and self.attempts[0].get("trigger") != TRIGGER[self.kind]:
            failed(f"attempt 1 ended on {self.attempts[0].get('trigger')!r}, not {TRIGGER[self.kind]}, so the restart was not this fault's")

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
            dcgm = json.loads((self.dir / "dcgm.json").read_text()) if (self.dir / "dcgm.json").exists() else {}
            if dcgm.get("node") != target.get("node"):
                void(f"the fault was injected on {dcgm.get('node')!r}, not the target {target.get('node')!r}")
            if str(dcgm.get("readback")) != "79":
                void(f"the injected XID read back as {dcgm.get('readback')!r}, not 79")
            if not dcgm.get("latched") or not dcgm.get("tainted"):
                void(f"the target's NodeHealth latched {dcgm.get('latched')!r} and its node was tainted {dcgm.get('tainted')!r}")
            return
        nodes = json.loads((self.dir / "nodes-before.json").read_text()) if (self.dir / "nodes-before.json").exists() else {}
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
        if target.get("node") not in ack.split(","):
            void(f"the job's fenced-nodes annotation is {ack!r}, not naming the target {target.get('node')}")

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
            dcgm = json.loads((self.dir / "dcgm.json").read_text())
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
        before = {n["metadata"]["name"]: n["metadata"]["uid"] for n in json.loads((self.dir / "nodes-before.json").read_text())["items"]}
        after = {n["metadata"]["name"]: n["metadata"]["uid"] for n in json.loads((self.dir / "nodes-after.json").read_text())["items"]}
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
        prepared: dict[str, float] = {}
        for row in jsonl(self.dir.parent / "nodes-prepared.jsonl"):
            prepared[row["node"]] = min(prepared.get(row["node"], math.inf), epoch(row["prepared_at"]))
        late = sorted(n for n in a2 - a1 if prepared.get(n, math.inf) > fault)
        if late:
            void(f"attempt 2 ran on {late}, up before the fault but not prepared before it (nodes-prepared.jsonl)")
        return "spare"

    def score(self) -> None:
        self.load()
        self.bind()
        if self.kind == "reference":
            if not self.records:
                void("no rank recorded anything")
            self.check_job(1)
            self.check_starts(1)
            self.check_transport(1)
            got = self.final_params(1)
            # DDP keeps every rank's parameters equal, so ranks that disagree did not train one model.
            if any(len(p) != len(got[0]) for p in got.values()):
                failed("the ranks' final parameters have different sizes")
            spread = max(abs(a - b) for p in got.values() for a, b in zip(p, got[0]))
            if spread > PARAM_TOLERANCE:
                failed(f"the ranks ended {spread:.3g} apart, beyond {PARAM_TOLERANCE}")
            self.figures["checkpoint_s"] = self.save_costs(1)
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
        fault, fault_uncertainty = self.fault_time()
        firsts, nodes = {}, set()
        for r in self.rec("step", 2):
            firsts[r["rank"]] = min(firsts.get(r["rank"], float("inf")), self.runner_time(r))
            nodes.add(r["_node"])
        if sorted(firsts) != list(range(WORLD)):
            failed(f"attempt 2 has step records from ranks {sorted(firsts)}, want every rank of {WORLD}")
        lost_from = max(r["step"] for r in self.rec("step", 1))
        self.figures.update({
            "recovery_s": max(firsts.values()) - fault,
            # How far the recovery can be off for the clocks alone: the fault's clock and the worst of attempt 2's.
            "clock_uncertainty_s": fault_uncertainty + max(self.clock(n, 2)[1] for n in nodes),
            "lost_steps": lost_from - resumed["from_step"],
            "class": self.recovery_class(fault),
            "params_gap": gap,
            "checkpoint_s": self.save_costs(1) + self.save_costs(2),
            "checkpoint": self.checkpoint_stats(2),
            **resumed,
        })
        if self.figures["recovery_s"] <= 0:
            void(f"attempt 2's first step is {self.figures['recovery_s']:.3f} s after the fault, which no clock allows")

    def save_costs(self, attempt: int) -> list[float]:
        return [r["save_s"] for r in self.rec("checkpoint", attempt) if isinstance(r.get("save_s"), (int, float))]

    def checkpoint_stats(self, attempts: int) -> dict:
        """Every rank's save cost, as median and maximum per attempt, which the registration names as the figure."""
        out = {}
        for a in range(1, attempts + 1):
            costs = self.save_costs(a)
            out[f"a{a}"] = ({"saves": len(costs), "median_s": round(statistics.median(costs), 3), "max_s": round(max(costs), 3)}
                            if costs else {"saves": 0})
        return out


def main(argv: list[str]) -> int:
    # --partial scores a run still in progress: a registered case with no directory yet is left out instead of VOID.
    partial = len(argv) == 3 and argv[1] == "--partial"
    if len(argv) != 2 and not partial:
        print(__doc__, file=sys.stderr)
        return 2
    run = pathlib.Path(argv[-1])
    prov = provenance(run)
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
    if refusals:
        for r in refusals:
            print(f"REFUSED: {r}")
        return 2

    steps = int(prov["steps"])
    verdicts: dict[str, tuple[str, str, bool]] = {}
    scored: dict[str, Case] = {}
    reference: list[float] | None = None
    if partial:
        cases = [n for n in cases if (run / n).is_dir()]
    for name in cases:
        case = Case(run, name, reference, steps)
        try:
            case.score()
            verdicts[name] = ("ACCEPTED", "", False)
        except Verdict as v:
            verdicts[name] = (v.kind, v.reason, v.censored)
        except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError) as exc:
            # Evidence that cannot be read is that case's VOID, never the end of the report: an empty file left by
            # one failed kubectl call would otherwise leave every other case without a verdict (codex review of 830f64af).
            verdicts[name] = ("VOID", f"its evidence could not be read: {type(exc).__name__}: {str(exc)[:120]}", False)
        scored[name] = case
        if name == "reference":
            reference = case.final_params(1)[0] if verdicts[name][0] == "ACCEPTED" else None

    for name in cases:
        kind, reason, _ = verdicts[name]
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
        wrong = counts["FAILED"] - censored
        print(f"  {kind}: {len(names)} registered, {counts['ACCEPTED']} ACCEPTED, {counts['FAILED']} FAILED ({censored} censored "
              f"at their budget, {wrong} not recovered), {counts['VOID']} VOID, {counts['NOTRUN']} NOTRUN")
        # Per recovery class, because spare and replacement recoveries are different claims and are never pooled.
        for cls in ("same-nodes", "spare", "replacement"):
            rec = [scored[n].figures["recovery_s"] for n in names
                   if verdicts[n][0] == "ACCEPTED" and scored[n].figures.get("class") == cls]
            lost = [scored[n].figures["lost_steps"] for n in names
                    if verdicts[n][0] == "ACCEPTED" and scored[n].figures.get("class") == cls]
            if rec:
                print(f"    {cls}: recovery median {statistics.median(rec):.1f} s, range {min(rec):.1f} to {max(rec):.1f} s, "
                      f"lost steps {sorted(lost)}, over {len(rec)} accepted; the {censored} FAILED censored at their budget, "
                      f"the {wrong} not recovered and the {counts['VOID']} VOID are not in these figures")
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
