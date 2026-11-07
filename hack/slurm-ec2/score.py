#!/usr/bin/env python3
"""Score the Slurm on EC2 session's evidence against docs/superpowers/specs/2026-11-07-slurm-ec2-session-design.md.

Usage: score.py EVIDENCE_DIR VERDICT_JSON

Each repetition of each check is VOID (the session's preconditions failed), NOTRUN (its inputs never came to exist),
INVALID (its instrument failed), or observed, and an observed one says for each rule whether it held.
The procedure on head only records; every decision is here.
Exit status 0 when the evidence could be read and scored, whatever the verdicts; 2 on a usage error.
"""

import datetime
import json
import os
import re
import sys

SLURM_VERSION = "23.11.4-1.2ubuntu5"
CUDA_SUM = float(sum(range(1024)))


def read(path):
    try:
        with open(path, errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def env(path):
    text = read(path) or ""
    out = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def jsonl(path):
    out = []
    for line in (read(path) or "").splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def result(status, reasons=None, rules=None, **readings):
    return {"status": status, "reasons": reasons or [], "rules": rules or [], "readings": readings}


def observed(rules, **readings):
    return result("observed", rules=[{"rule": r, "held": bool(h)} for r, h in rules], **readings)


def preconditions(ev):
    """Reasons the whole session is VOID, or []."""
    reasons = []
    void = read(os.path.join(ev, "VOID"))
    if void:
        reasons.append("head stopped: " + void.strip())
    cfg = read(os.path.join(ev, "config", "scontrol-config.txt"))
    if cfg is None:
        reasons.append("no scontrol show config was recorded")
    elif not re.search(r"^CgroupPlugin\s*=\s*cgroup/v2\s*$", cfg, re.M):
        reasons.append("CgroupPlugin is not cgroup/v2")
    for n in ("gpu1", "gpu2"):
        e = env(os.path.join(ev, "config", f"{n}.env"))
        if not e:
            reasons.append(f"{n} reported nothing")
            continue
        if e.get("cards", "").count("A10G") != 1:
            reasons.append(f"{n} is not one A10G: {e.get('cards')!r}")
        if e.get("slurmd") != SLURM_VERSION:
            reasons.append(f"{n} runs slurmd {e.get('slurmd')!r}")
    pk = read(os.path.join(ev, "config", "head-packages.txt")) or ""
    for p in ("slurmctld", "slurmdbd"):
        if not re.search(rf"^{p}\s+{re.escape(SLURM_VERSION)}$", pk, re.M):
            reasons.append(f"head's {p} is not {SLURM_VERSION}")
    return reasons


def notrun(d):
    text = read(os.path.join(d, "NOTRUN"))
    return text.strip() if text else None


def b1(ev):
    out = []
    root = os.path.join(ev, "b1")
    for rep in range(1, 5):
        d = os.path.join(root, f"rep-{rep}")
        why = notrun(d) or notrun(root)
        if why:
            out.append({"rep": rep, **result("NOTRUN", [why])})
            continue
        try:
            a = json.loads(read(os.path.join(d, "alloc.json")) or "")
        except json.JSONDecodeError:
            out.append({"rep": rep, **result("INVALID", ["the allocated probe left no JSON"])})
            continue
        lines = a.get("nvidia_smi_lines", [])
        a_rules = [
            ("B1a: nvidia-smi lists exactly one A10G", len(lines) == 1 and "A10G" in lines[0]),
            ("B1a: a CUDA op returns the expected sum", a.get("cuda_sum") == CUDA_SUM),
        ]
        a_held = all(h for _, h in a_rules)
        try:
            u = json.loads(read(os.path.join(d, "unalloc.json")) or "")
        except json.JSONDecodeError:
            u = None
        node = env(os.path.join(d, "node.env")).get("node")
        if u is None or "torch_error" in (u or {}):
            res = observed(a_rules, node=node, alloc=a)
            res["b1b"] = result("INVALID", ["the unallocated probe left no usable record"])
        elif not a_held:
            res = observed(a_rules, node=node, alloc=a, unalloc=u)
            res["b1b"] = result("INVALID", ["B1a did not hold in this repetition, so B1b says nothing about confinement"])
        else:
            b_rules = [
                ("B1b: CUDA sees no device", u.get("device_count") == 0 or "cuda_error" in u),
                ("B1b: opening /dev/nvidia0 fails with EPERM", u.get("open_nvidia0") == "EPERM"),
            ]
            res = observed(a_rules + b_rules, node=node, alloc=a, unalloc=u)
        out.append({"rep": rep, **res})
    return out


def b2(ev):
    out = []
    root = os.path.join(ev, "b2")
    before = (read(os.path.join(ev, "b2-slurmd-pid-before.txt")) or "").strip()
    for rep in range(1, 4):
        d = os.path.join(root, f"rep-{rep}")
        why = notrun(d)
        if why:
            out.append({"rep": rep, **result("NOTRUN", [why])})
            continue
        job = env(os.path.join(d, "job.env")).get("job")
        sacct = read(os.path.join(d, "sacct.txt"))
        jobout = read(os.path.join(d, "job.out"))
        kernel = read(os.path.join(d, "kernel.txt"))
        after = (read(os.path.join(d, "slurmd-pid-after.txt")) or "").strip()
        if not job or sacct is None or jobout is None or kernel is None:
            out.append({"rep": rep, **result("INVALID", ["the job, its accounting, its output or the node's journal is missing"])})
            continue
        step_state = None
        for line in sacct.splitlines():
            f = line.split("|")
            if len(f) >= 2 and f[0] == f"{job}.0":
                step_state = f[1]
        m = re.search(r"^job_memory_events oom_kill (\d+)$", jobout, re.M)
        oom_kill = int(m.group(1)) if m else None
        memcg_line = any("task_memcg=" in l and f"job_{job}/" in l for l in kernel.splitlines())
        killed = "Memory cgroup out of memory" in kernel
        node_after = read(os.path.join(d, "node-after.txt")) or ""
        state = re.search(r"\bState=(\S+)", node_after)
        rules = [
            ("B2: sacct reports the step OUT_OF_MEMORY", step_state == "OUT_OF_MEMORY"),
            ("B2: the job's memory.events oom_kill is at least 1", oom_kill is not None and oom_kill >= 1),
            ("B2: the kernel's OOM report names this job's cgroup", killed and memcg_line),
            ("B2: slurmd's MainPID is the one before B2", before.isdigit() and before != "0" and after == before),
            ("B2: the node is not DOWN", bool(state) and "DOWN" not in state.group(1)),
        ]
        out.append({"rep": rep, **observed(rules, job=job, step_state=step_state, oom_kill=oom_kill,
                                           slurmd_pid_before=before, slurmd_pid_after=after)})
    return out


def ts(s):
    return datetime.datetime.fromisoformat(s).timestamp() if s and s not in ("Unknown", "None") else None


def b3(ev):
    out = {}
    root = os.path.join(ev, "b3")
    for name, reason in (("a", "AssocGrpGRES"), ("b", "QOSMaxJobsPerUserLimit")):
        d = os.path.join(root, name)
        why = notrun(d) or notrun(root)
        if why:
            out[name] = result("NOTRUN", [why])
            continue
        jobs = env(os.path.join(d, "jobs.env"))
        first, second = jobs.get("first"), jobs.get("second")
        poll = read(os.path.join(d, "poll.txt"))
        sacct = read(os.path.join(d, "sacct.txt"))
        if not first or not second or poll is None or sacct is None:
            out[name] = result("INVALID", ["the jobs, the poll or the accounting is missing"])
            continue
        submitted = None
        seen = None
        for line in poll.splitlines():
            f = line.split()
            if len(f) == 3 and f[1] == "submitted" and f[2] == second:
                submitted = float(f[0])
            elif len(f) >= 4 and f[1] == second and f[2] == "PENDING" and f[3] == reason and seen is None:
                seen = float(f[0])
        rows = {}
        for line in sacct.splitlines():
            f = line.split("|")
            if len(f) >= 6:
                rows[f[0]] = {"state": f[1], "start": ts(f[3]), "end": ts(f[4])}
        r1, r2 = rows.get(first, {}), rows.get(second, {})
        gap = (r2["start"] - r1["end"]) if r1.get("end") and r2.get("start") else None
        rules = [
            (f"B3{name}: the second job is PENDING with reason {reason} within 30 s of submission",
             submitted is not None and seen is not None and seen - submitted <= 30),
            (f"B3{name}: the second job starts within 60 s of the first ending", gap is not None and gap <= 60),
        ]
        out[name] = observed(rules, reason_seen_after_s=None if seen is None or submitted is None else round(seen - submitted, 1),
                             start_gap_s=gap, first=r1, second=r2)
    return out


def b4(ev):
    d = os.path.join(ev, "b4")
    why = notrun(d)
    if why:
        return result("NOTRUN", [why])
    for f in ("sbatch-error", "reference.timeout", "run.no-ckpt"):
        if read(os.path.join(d, f)):
            return result("INVALID", [f"{f}: {read(os.path.join(d, f)).strip()}"])
    ref = [r for r in jsonl(os.path.join(d, "reference.jsonl")) if r.get("event") == "done"]
    run = jsonl(os.path.join(d, "run.jsonl"))
    events = env(os.path.join(d, "events.env"))
    if not ref or not run or "fault_written" not in events:
        return result("INVALID", ["the reference, the run's log or the fault time is missing"])
    fault = float(events["fault_written"])
    drained = None
    for line in (read(os.path.join(d, "gpu1-state.txt")) or "").splitlines():
        f = line.split(" ", 1)
        if len(f) == 2 and re.search(r"State=\S*DRAIN", f[1]) and "DCGM_FI_DEV_XID_ERRORS=79" in f[1]:
            drained = float(f[0])
            break
    a0 = [r for r in run if r.get("attempt") == 0]
    a1 = [r for r in run if r.get("attempt") == 1]
    after = read(os.path.join(d, "run-job-after.txt")) or ""
    m = re.search(r"\bRestarts=(\d+)", after)
    restarts = int(m.group(1)) if m else None
    hosts1 = {r.get("host") for r in a1}
    ckpts0 = [r["step"] for r in a0 if r.get("event") == "ckpt"]
    start1 = [r for r in a1 if r.get("event") == "start"]
    steps1 = [r["step"] for r in a1 if r.get("event") == "step"]
    done1 = [r for r in a1 if r.get("event") == "done"]
    sacct = read(os.path.join(d, "run-sacct.txt")) or ""
    final_state = None
    for line in sacct.splitlines():
        f = line.split("|")
        if len(f) >= 2 and "." not in f[0]:
            final_state = f[1]
    diff = re.search(r"max_abs_diff=(\S+)", read(os.path.join(d, "param-diff.txt")) or "")
    rules = [
        ("B4a: gpu1 is DRAIN with the Xid 79 reason within 30 s of the write", drained is not None and drained - fault <= 30),
        ("B4b: RestartCnt is 1", restarts == 1),
        ("B4b: the second attempt ran on gpu2", hosts1 == {"gpu2"}),
        ("B4c: the second attempt starts one step after the first attempt's last logged checkpoint",
         bool(ckpts0) and len(start1) == 1 and start1[0].get("resumed_from") == max(ckpts0)
         and start1[0].get("first_step") == max(ckpts0) + 1),
        ("B4c: the job COMPLETED with step 60 logged once in the second attempt",
         final_state == "COMPLETED" and steps1.count(60) == 1 and len(done1) == 1),
        ("B4d: the final parameters equal the reference run's", bool(done1) and done1[0].get("params_sha256") == ref[0].get("params_sha256")),
    ]
    return observed(rules, drain_after_s=None if drained is None else round(drained - fault, 1), restarts=restarts,
                    last_ckpt_attempt0=max(ckpts0) if ckpts0 else None,
                    resumed=start1[0] if start1 else None, final_state=final_state,
                    max_abs_diff=diff.group(1) if diff else None)


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    ev, path = argv[1], argv[2]
    void = preconditions(ev)
    verdict = {"void": void}
    if void:
        verdict.update({"b1": [], "b2": [], "b3": {}, "b4": result("VOID", void)})
    else:
        verdict.update({"b1": b1(ev), "b2": b2(ev), "b3": b3(ev), "b4": b4(ev)})
    with open(path, "w") as fh:
        json.dump(verdict, fh, indent=2, sort_keys=True)

    def line(label, r):
        if r["status"] != "observed":
            return [f"{label}: {r['status']}: {'; '.join(r['reasons'])}"]
        held = sum(1 for x in r["rules"] if x["held"])
        rows = [f"{label}: {held} of {len(r['rules'])} rules held"]
        rows += [f"  did not hold: {x['rule']}" for x in r["rules"] if not x["held"]]
        if "b1b" in r:
            rows += [f"  B1b: {r['b1b']['status']}: {'; '.join(r['b1b']['reasons'])}"]
        return rows

    if void:
        print("SLURM ON EC2: VOID: " + "; ".join(void))
        return 0
    for r in verdict["b1"]:
        print("\n".join(line(f"B1 rep {r['rep']}", r)))
    for r in verdict["b2"]:
        print("\n".join(line(f"B2 rep {r['rep']}", r)))
    for k, r in sorted(verdict["b3"].items()):
        print("\n".join(line(f"B3{k}", r)))
    print("\n".join(line("B4", verdict["b4"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
