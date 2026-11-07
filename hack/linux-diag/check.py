#!/usr/bin/env python3
"""Score a run of hack/linux-diag/run.sh against docs/superpowers/specs/2026-11-07-linux-diagnosis-cases-design.md.

Writes verdict.json into the run directory and prints a summary.
A case the instrumentation did not see is INVALID; an observed case reports each expected reading as held or not.
"""

import datetime
import json
import os
import re
import statistics
import sys

MIB = 1 << 20

# The first line of every kernel OOM report; everything up to the next one belongs to it.
REPORT_START = re.compile(r"\binvoked oom-killer:")
USAGE = re.compile(r"\bmemory: usage (\d+)kB, limit (\d+)kB")
STATS_START = re.compile(r"\bMemory cgroup stats for (\S+)")
STAT_LINE = re.compile(r"kernel: ([a-z_]+) (\d+)$")
CONSTRAINT = re.compile(r"\boom-kill:constraint=[^,]+,.*?oom_memcg=([^,]+),task_memcg=([^,]+),task=([^,]+),pid=(\d+)")
GROUP = re.compile(r"\bare going to be killed due to memory\.oom\.group set")
KILLED = re.compile(r"\bKilled process (\d+) \(([^)]+)\) .*?anon-rss:(\d+)kB, file-rss:(\d+)kB, shmem-rss:(\d+)kB")
# The statistics block ends where the task table begins.
STATS_END = re.compile(r"\bMemory cgroup min protection|\bTasks state ")


def parse_reports(lines):
    """Split a kernel journal into OOM reports, each a dict of the fields the cases read."""
    reports = []
    cur = None
    in_stats = False
    for line in lines:
        line = line.rstrip("\n")
        if REPORT_START.search(line):
            cur = {"usage_kb": None, "limit_kb": None, "stats_for": None, "stats": {},
                   "oom_memcg": None, "task_memcg": None, "task": None, "pid": None,
                   "group_kill": False, "killed": {}}
            reports.append(cur)
            in_stats = False
            continue
        if cur is None:
            continue
        m = USAGE.search(line)
        if m and cur["usage_kb"] is None:
            cur["usage_kb"], cur["limit_kb"] = int(m.group(1)), int(m.group(2))
            continue
        m = STATS_START.search(line)
        if m:
            cur["stats_for"] = m.group(1).rstrip(":")
            in_stats = True
            continue
        if in_stats:
            if STATS_END.search(line):
                in_stats = False
                continue
            m = STAT_LINE.search(line)
            if m:
                cur["stats"][m.group(1)] = int(m.group(2))
            continue
        m = CONSTRAINT.search(line)
        if m:
            cur["oom_memcg"], cur["task_memcg"], cur["task"], cur["pid"] = m.group(1), m.group(2), m.group(3), int(m.group(4))
            continue
        if GROUP.search(line):
            cur["group_kill"] = True
            continue
        m = KILLED.search(line)
        if m:
            # The kernel prints the first victim again after a group kill; one entry per pid.
            cur["killed"][int(m.group(1))] = {"name": m.group(2), "anon_rss_kb": int(m.group(3)),
                                              "file_rss_kb": int(m.group(4)), "shmem_rss_kb": int(m.group(5))}
    return reports


def parse_cgroup_dump(log):
    """Read the workload's own cgroup dump, or None when the workload died before printing it."""
    if "--- cgroup begin" not in log or "--- cgroup end" not in log:
        return None
    body = log.split("--- cgroup begin", 1)[1].split("--- cgroup end", 1)[0]
    out = {"events": {}, "stat": {}}
    for line in body.strip().splitlines():
        parts = line.split()
        if parts[0] == "memory.events" and len(parts) == 3:
            out["events"][parts[1]] = int(parts[2])
        elif parts[0] == "memory.stat" and len(parts) == 3:
            out["stat"][parts[1]] = int(parts[2])
        elif len(parts) == 2:
            out[parts[0]] = parts[1]
    return out


def final_container(statuses):
    """The last polled status that shows the container terminated, and when the reason first appeared."""
    final = None
    first_reason_at = None
    for i, st in enumerate(statuses):
        cs = (st.get("status", {}).get("containerStatuses") or [{}])[0]
        term = cs.get("state", {}).get("terminated")
        if term:
            final = {"phase": st["status"].get("phase"), "exit": term.get("exitCode"),
                     "reason": term.get("reason"), "container_id": cs.get("containerID", "").split("://")[-1]}
            if first_reason_at is None and term.get("reason"):
                first_reason_at = i
    return final, first_reason_at


def rfc3339(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def load_case(d):
    with open(os.path.join(d, "case.json")) as f:
        meta = json.load(f)
    statuses = []
    for name in sorted(os.listdir(d)):
        if name.startswith("status-") and name.endswith(".json"):
            with open(os.path.join(d, name)) as f:
                statuses.append(json.load(f))
    with open(os.path.join(d, "log.txt")) as f:
        log = f.read()
    with open(os.path.join(d, "journal.txt")) as f:
        journal = f.readlines()
    summary = []
    p = os.path.join(d, "summary.jsonl")
    if os.path.exists(p):
        with open(p) as f:
            summary = [json.loads(line) for line in f if line.strip()]
    return meta, statuses, log, journal, summary


def judge(meta, statuses, log, journal, summary):
    """Return (validity, reasons, readings, expectations) for one case."""
    case = meta["case"]
    invalid = []
    if meta["journal_exit"] != 0:
        invalid.append(f"journalctl exited {meta['journal_exit']}")
    if meta["single_process_oom_kill_effective"] != meta["single_process_oom_kill_wanted"]:
        invalid.append("the cluster's singleProcessOOMKill was "
                       f"{meta['single_process_oom_kill_effective']}, not {meta['single_process_oom_kill_wanted']}")
    final, first_reason_at = final_container(statuses)
    if final is None:
        invalid.append("the container never reached terminated in the polled status")
    if "begin" not in log.split():
        invalid.append("the workload never printed begin")
    if invalid:
        return "INVALID", invalid, {}, []

    reports = [r for r in parse_reports(journal) if r["task_memcg"] and final["container_id"] in r["task_memcg"]]
    dump = parse_cgroup_dump(log)
    readings = {"phase": final["phase"], "exit": final["exit"], "reason": final["reason"],
                "reason_first_polled_at": first_reason_at, "oom_reports": len(reports)}
    if reports:
        r = reports[0]
        readings.update({"oom_memcg": r["oom_memcg"], "task_memcg": r["task_memcg"], "group_kill": r["group_kill"],
                         "killed": sorted(v["name"] for v in r["killed"].values()),
                         "stats_shmem": r["stats"].get("shmem")})
    if dump:
        readings.update({"cg_oom_group": dump.get("memory.oom.group"), "cg_events": dump["events"],
                         "cg_current": dump.get("memory.current"), "cg_max": dump.get("memory.max")})

    exp = []

    def expect(name, ok):
        exp.append({"expected": name, "held": bool(ok)})

    def killed_set():
        return sorted(v["name"] for r in reports for v in r["killed"].values())

    if case == "c1":
        expect("phase Failed", final["phase"] == "Failed")
        expect("exit 137", final["exit"] == 137)
        expect("reason OOMKilled", final["reason"] == "OOMKilled")
        expect("one OOM record with task=python3", len(reports) == 1 and reports[0]["task"] == "python3")
    elif case == "c2a":
        expect("phase Failed", final["phase"] == "Failed")
        expect("exit 137", final["exit"] == 137)
        expect("reason OOMKilled", final["reason"] == "OOMKilled")
        expect("the record has the memory.oom.group line", len(reports) == 1 and reports[0]["group_kill"])
        expect("python3 and sh killed", killed_set() == ["python3", "sh"])
        expect("log has no parent-done", "parent-done" not in log)
    elif case == "c2b":
        expect("phase Succeeded", final["phase"] == "Succeeded")
        expect("exit 0", final["exit"] == 0)
        expect("reason OOMKilled", final["reason"] == "OOMKilled")
        expect("log has child-exit=137 and parent-done", "child-exit=137" in log and "parent-done" in log)
        expect("memory.oom.group 0 in the container", dump is not None and dump.get("memory.oom.group") == "0")
        expect("oom_kill 1 in the container", dump is not None and dump["events"].get("oom_kill") == 1)
        expect("one record, no group line, only python3 killed",
               len(reports) == 1 and not reports[0]["group_kill"] and killed_set() == ["python3"])
    elif case == "c3":
        expect("phase Failed", final["phase"] == "Failed")
        expect("exit 137", final["exit"] == 137)
        expect("reason OOMKilled", final["reason"] == "OOMKilled")
        victims = [v for r in reports for v in r["killed"].values()]
        expect("every victim's anon-rss + shmem-rss under 16 MiB",
               bool(victims) and all((v["anon_rss_kb"] + v["shmem_rss_kb"]) * 1024 < 16 * MIB for v in victims))
        expect("statistics block shmem at least 96 MiB",
               len(reports) == 1 and (reports[0]["stats"].get("shmem") or 0) >= 96 * MIB)
    elif case == "c4":
        # The I/O must have completed or the case did not exercise the page cache.
        if log.count("512+0 records out") != 2 or "write-exit=0" not in log or "read-exit=0" not in log:
            return "INVALID", ["dd did not write and read 512 records"], readings, []
        if dump is None:
            return "INVALID", ["the workload's cgroup dump is missing"], readings, []
        m = re.search(r"read-done (\d+)", log)
        done_at = int(m.group(1)) if m else None
        fresh = {}
        for s in summary:
            t = s.get("time")
            if t and done_at is not None and rfc3339(t) > done_at and s.get("usageBytes"):
                fresh[t] = s
        readings["summary_samples_after_read"] = len(fresh)
        if len(fresh) < 3:
            return "INVALID", [f"{len(fresh)} kubelet samples with distinct times after the read finished, need 3"], readings, []
        ws = statistics.median(s["workingSetBytes"] for s in fresh.values())
        us = statistics.median(s["usageBytes"] for s in fresh.values())
        readings.update({"median_working_set": ws, "median_usage": us})
        expect("phase Succeeded", final["phase"] == "Succeeded")
        expect("exit 0", final["exit"] == 0)
        expect("reason Completed", final["reason"] == "Completed")
        expect("oom_kill 0 in the container", dump["events"].get("oom_kill") == 0)
        expect("memory.events max at least 1", (dump["events"].get("max") or 0) >= 1)
        expect("no matching journal record", len(reports) == 0)
        expect("memory.current at least 90% of memory.max",
               int(dump["memory.current"]) >= 0.9 * int(dump["memory.max"]))
        expect("median workingSetBytes at most 50% of median usageBytes", ws <= 0.5 * us)
    else:
        return "INVALID", [f"unknown case {case}"], readings, []
    return "observed", [], readings, exp


def main(run_dir):
    results = []
    for name in sorted(os.listdir(run_dir)):
        d = os.path.join(run_dir, name)
        if not (os.path.isdir(d) and os.path.exists(os.path.join(d, "case.json"))):
            continue
        meta, statuses, log, journal, summary = load_case(d)
        validity, reasons, readings, exp = judge(meta, statuses, log, journal, summary)
        results.append({"case": meta["case"], "rep": meta["rep"], "validity": validity, "invalid_reasons": reasons,
                        "readings": readings, "expectations": exp,
                        "all_held": validity == "observed" and all(e["held"] for e in exp)})
    by_case = {}
    for r in results:
        s = by_case.setdefault(r["case"], {"scheduled": 0, "invalid": 0, "all_held": 0})
        s["scheduled"] += 1
        s["invalid"] += r["validity"] == "INVALID"
        s["all_held"] += r["all_held"]
    verdict = {"cases": by_case, "repetitions": results}
    with open(os.path.join(run_dir, "verdict.json"), "w") as f:
        json.dump(verdict, f, indent=2, sort_keys=True)
    for case in sorted(by_case):
        s = by_case[case]
        print(f"{case}: held in {s['all_held']} of {s['scheduled']} ({s['invalid']} invalid)")
    for r in results:
        if r["validity"] == "INVALID":
            print(f"  {r['case']} r{r['rep']}: INVALID: {'; '.join(r['invalid_reasons'])}")
        for e in r["expectations"]:
            if not e["held"]:
                print(f"  {r['case']} r{r['rep']}: did not hold: {e['expected']}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: check.py RUN_DIR", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
