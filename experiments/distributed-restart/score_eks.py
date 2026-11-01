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
EXTERNAL_MIN_STEP = 10


class Verdict(Exception):
    """The first condition a case did not meet, as VOID or FAILED."""

    def __init__(self, kind: str, reason: str) -> None:
        super().__init__(reason)
        self.kind, self.reason = kind, reason


def void(reason: str) -> None:
    raise Verdict("VOID", reason)


def failed(reason: str) -> None:
    raise Verdict("FAILED", reason)


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
                r["_node"] = node
                self.records.append(r)

    def rec(self, event: str, attempt: int, rank: int | None = None) -> list[dict]:
        return [r for r in self.records
                if r.get("event") == event and r.get("attempt") == attempt and (rank is None or r.get("rank") == rank)]

    # --- clocks -------------------------------------------------------------------------------------------------------

    def offset(self, node: str | None) -> float:
        """Seconds the node's clock runs ahead of the runner's, from the probes of that node, refusing a doubtful one."""
        if not node:
            void("a record whose node is unknown, so its clock cannot be corrected")
        probes = [p for p in self.clocks if p.get("node") == node]
        if not probes:
            void(f"no clock probe of {node}")
        offsets = []
        for p in probes:
            bracket = p["after"] - p["before"]
            if bracket < 0 or bracket > CLOCK_BRACKET_S:
                void(f"the clock probe of {node} took {bracket:.3f} s, wider than {CLOCK_BRACKET_S} s")
            off = p["node_time"] - (p["before"] + p["after"]) / 2
            if abs(off) > CLOCK_OFFSET_S:
                void(f"{node}'s clock is {off:+.3f} s from the runner's, beyond {CLOCK_OFFSET_S} s")
            offsets.append(off)
        return statistics.median(offsets)

    def runner_time(self, record: dict) -> float:
        return epoch(record["ts"]) - self.offset(record["_node"])

    # --- the checks, in order -----------------------------------------------------------------------------------------

    def check_job(self, want_attempts: int) -> None:
        if self.status.get("phase") != "Succeeded":
            failed(f"the job ended {self.status.get('phase')!r}, not Succeeded, within its budget")
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

    def final_params(self, attempt: int) -> list[float] | None:
        last = [r for r in self.rec("step", attempt, 0) if r.get("step") == self.steps and r.get("params") is not None]
        return last[-1]["params"] if last else None

    def params_gap(self, attempt: int) -> float:
        got = self.final_params(attempt)
        if got is None or self.reference is None or len(got) != len(self.reference):
            failed(f"attempt {attempt} has no final parameters comparable with the reference's")
        # A NaN is not greater than any tolerance, so a run that diverged would otherwise compare as equal.
        if not all(math.isfinite(v) for v in got):
            failed(f"attempt {attempt}'s final parameters are not all finite")
        return max(abs(a - b) for a, b in zip(got, self.reference))

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
        return {"from_dir": from_dir, "from_step": from_step}

    def check_delivered(self) -> None:
        """The registered fault reached its registered target, before anything about the recovery is judged.

        Checked first, so a fault that never landed is VOID rather than read as a recovery that failed or, worse, as
        one that succeeded because nothing happened.
        """
        if self.kind in ("rank-kill", "no-rng-control"):
            want = 1 if self.kind == "rank-kill" else 0
            fired = self.rec("fault", 1)
            if len(fired) != 1 or fired[0]["rank"] != want:
                void(f"attempt 1 has fault records from ranks {[r['rank'] for r in fired]}, want exactly one, from rank {want}")
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

    def fault_time(self) -> float:
        """The fault on the runner's clock: the trainer's own record, the node's time in the injecting exec, or the
        mark taken before the termination call, so the call's own latency is inside the recovery."""
        if self.kind in ("rank-kill", "no-rng-control"):
            return self.runner_time(self.rec("fault", 1)[0])
        if self.kind == "dcgm":
            dcgm = json.loads((self.dir / "dcgm.json").read_text())
            return self.runner_time({"ts": dcgm["injected_at"], "_node": dcgm["node"]})
        return epoch(self.marks["fault-start"])

    def recovery_class(self) -> str:
        a1 = set(self.attempts[0].get("nodes") or [])
        a2 = set(self.attempts[1].get("nodes") or [])
        nodes = json.loads((self.dir / "nodes-before.json").read_text()) if (self.dir / "nodes-before.json").exists() else None
        if not a1 or not a2 or nodes is None:
            void("the attempts' nodes or the nodes before the fault were not recorded")
        before = {n["metadata"]["name"] for n in nodes.get("items", [])}
        if a2 <= a1:
            return "same-nodes"
        if a2 <= before:
            return "spare"
        return "replacement"

    def score(self) -> None:
        self.load()
        if self.kind == "reference":
            if not self.records:
                void("no rank recorded anything")
            self.check_job(1)
            self.check_starts(1)
            self.check_transport(1)
            got = self.final_params(1)
            if got is None or not all(math.isfinite(v) for v in got):
                failed("no finite final parameters")
            self.figures["checkpoint_s"] = self.save_costs(1)
            return
        # Delivery, then the outcome, then the evidence the figures need, then what the recovery restored: a recovery
        # that timed out lacks attempt 2's records by its nature, and is FAILED, censored, not VOID for lacking them.
        self.check_delivered()
        self.check_job(2)
        self.check_starts(2)
        self.check_transport(2)
        resumed = self.check_resume()
        gap = self.params_gap(2)
        if self.kind == "no-rng-control":
            # A control the comparison cannot tell from a full resume shows the comparison is blind, not that RNG is moot.
            if gap <= PARAM_TOLERANCE:
                failed(f"dropping the RNG left the parameters within {PARAM_TOLERANCE} of the reference ({gap:.3g})")
            self.figures.update({"params_gap": gap, **resumed})
            return
        if gap > PARAM_TOLERANCE:
            failed(f"the resumed run ended {gap:.3g} from the reference, beyond {PARAM_TOLERANCE}")
        fault = self.fault_time()
        firsts = {}
        for r in self.rec("step", 2):
            firsts[r["rank"]] = min(firsts.get(r["rank"], float("inf")), self.runner_time(r))
        if sorted(firsts) != list(range(WORLD)):
            failed(f"attempt 2 has step records from ranks {sorted(firsts)}, want every rank of {WORLD}")
        lost_from = max(r["step"] for r in self.rec("step", 1))
        self.figures.update({
            "recovery_s": max(firsts.values()) - fault,
            "lost_steps": lost_from - resumed["from_step"],
            "class": self.recovery_class(),
            "params_gap": gap,
            "checkpoint_s": self.save_costs(1) + self.save_costs(2),
            **resumed,
        })
        if self.figures["recovery_s"] <= 0:
            void(f"attempt 2's first step is {self.figures['recovery_s']:.3f} s after the fault, which no clock allows")

    def save_costs(self, attempt: int) -> list[float]:
        return [r["save_s"] for r in self.rec("checkpoint", attempt) if isinstance(r.get("save_s"), (int, float))]


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
    verdicts: dict[str, tuple[str, str]] = {}
    scored: dict[str, Case] = {}
    reference: list[float] | None = None
    if partial:
        cases = [n for n in cases if (run / n).is_dir()]
    for name in cases:
        case = Case(run, name, reference, steps)
        try:
            case.score()
            verdicts[name] = ("ACCEPTED", "")
        except Verdict as v:
            verdicts[name] = (v.kind, v.reason)
        except (ValueError, KeyError, TypeError, IndexError, OSError) as exc:
            # Evidence that cannot be read is that case's VOID, never the end of the report: an empty file left by
            # one failed kubectl call would otherwise leave every other case without a verdict (codex review of 830f64af).
            verdicts[name] = ("VOID", f"its evidence could not be read: {type(exc).__name__}: {str(exc)[:120]}")
        scored[name] = case
        if name == "reference":
            reference = case.final_params(1) if verdicts[name][0] == "ACCEPTED" else None

    for name in cases:
        kind, reason = verdicts[name]
        fig = scored[name].figures
        shown = {k: (round(v, 3) if isinstance(v, float) else v) for k, v in fig.items() if k != "checkpoint_s"}
        print(f"{kind:8} {name}" + (f": {reason}" if reason else f" {json.dumps(shown, sort_keys=True)}"))

    print("summary")
    for kind in KINDS:
        names = [n for n in cases if scored[n].kind == kind]
        if not names:
            continue
        counts = {v: sum(1 for n in names if verdicts[n][0] == v) for v in ("ACCEPTED", "FAILED", "VOID", "NOTRUN")}
        print(f"  {kind}: {len(names)} registered, " + ", ".join(f"{c} {v}" for v, c in counts.items()))
        # Per recovery class, because spare and replacement recoveries are different claims and are never pooled.
        for cls in ("same-nodes", "spare", "replacement"):
            rec = [scored[n].figures["recovery_s"] for n in names
                   if verdicts[n][0] == "ACCEPTED" and scored[n].figures.get("class") == cls]
            lost = [scored[n].figures["lost_steps"] for n in names
                    if verdicts[n][0] == "ACCEPTED" and scored[n].figures.get("class") == cls]
            if rec:
                print(f"    {cls}: recovery median {statistics.median(rec):.1f} s, range {min(rec):.1f} to {max(rec):.1f} s, "
                      f"lost steps {sorted(lost)}, over {len(rec)} accepted; the {counts['FAILED']} FAILED are censored at "
                      f"their budget and not in these figures")
    costs = [c for n in cases if verdicts[n][0] == "ACCEPTED" for c in scored[n].figures.get("checkpoint_s", [])]
    if costs:
        print(f"  checkpoint cost: median {statistics.median(costs):.3f} s, max {max(costs):.3f} s over {len(costs)} saves")
    return 0 if all(v[0] == "ACCEPTED" for v in verdicts.values()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
