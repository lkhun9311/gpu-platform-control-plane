"""Verdict for the vLLM #69058 kit r6: the shutdown fix (FIX) against the unchanged additions (CONTROL), one process per case.

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt, OUT/STOPPED if present, and OUT/e2e-{control,fix}-{fail,recompute}.log.
Writes OUT/verdict.json and prints each process's summary line and illegal-access lines, then the verdict.
CONFIRMED needs FIX to pass both cases with no illegal access and CONTROL [fail] to fault.
FIX faulting or failing is a FINDING; FIX clean with CONTROL [fail] clean is INCONCLUSIVE; CONTROL [recompute] is recorded and decides nothing.
Exit status: 0 CONFIRMED, 2 FINDING, 3 INCOMPLETE, 4 NOT RUN, 5 INCONCLUSIVE.
"""

import json
import os
import re
import sys

CLASS = "TestHF3FSLoadFailureEndToEnd"
RUNS = (("control", "fail"), ("fix", "fail"), ("control", "recompute"), ("fix", "recompute"))
ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")
# pytest -q prints its summary without the "=" padding that -rA runs have, so both shapes are read.
SUMMARY_RE = re.compile(r"^=*\s*(\d+ [a-z]+(?:, \d+ [a-z]+)*) in ([0-9.]+)s(?: \([^)]*\))?\s*=*$")
COUNT_RE = re.compile(r"(\d+) (passed|failed|skipped|deselected|errors?|xfailed|xpassed|warnings?)")
HEADER_RE = re.compile(r"^_+ (?:ERROR at (?:setup|call|teardown) of )?" + CLASS + r"\.test_failed_read_honors_policy\[(\w+)\] _+$")
# Any other section header, or a "=" banner, ends a case's section; a traceback's "_ _ _" separator does not.
OTHER_HEADER_RE = re.compile(r"^_+ [^_\s].* _+$|^=+ .* =+$")
CAPTURED_RE = re.compile(r"^-+ Captured (stdout|stderr|log) (setup|call|teardown) -+$")
PHASES = {"setup": 0, "call": 1, "teardown": 2}
TIME_RE = re.compile(r" (\d\d-\d\d \d\d:\d\d:\d\d) ")
# Harness causes, read from the traceback's ">" and E lines only, since captured logs name things like HF_HUB_OFFLINE on every run.
# An illegal memory access is not among them: it is the fault the run compares.
HARNESS_CAUSES = (
    ("KV cache memory", re.compile(r"KV cache is needed, which is larger than the available KV cache memory")),
    ("GPU out of memory", re.compile(r"OutOfMemoryError|CUDA out of memory", re.I)),
    ("model download or offline load failure", re.compile(r"LocalEntryNotFoundError|Cannot find the requested files|couldn't connect to|RepositoryNotFound|GatedRepo")),
)


def first_illegal(lines, case):
    """The case's first illegal access in time, kit r5's order: capture phase, then vLLM's timestamps, then position."""
    recs, current, phase, stamp, sec = [], False, None, "~", 0
    for i, line in enumerate(lines, start=1):
        m = HEADER_RE.match(line)
        if m:
            current, phase, stamp, sec = m.group(1) == case, None, "~", sec + 1
            continue
        if current and OTHER_HEADER_RE.match(line):
            current = False
            continue
        if not current:
            continue
        m = CAPTURED_RE.match(line)
        if m:
            phase, stamp = PHASES[m.group(2)], "~"
            continue
        if phase is None:
            continue
        t = TIME_RE.search(line)
        if t:
            stamp = t.group(1)
        recs.append((phase, stamp, sec, i, line))
    recs.sort(key=lambda r: (r[0], r[1], r[2], r[3]))
    hit = next((r for r in recs if ILLEGAL_RE.search(r[4])), None)
    return f"{hit[3]}:{hit[4]}" if hit else None


def process(path, rc, case):
    """One process: its summary, the illegal-access lines, and its state (passed, faulted, failed, not run or incomplete)."""
    rec = {"exit": rc}
    if not os.path.exists(path):
        rec.update(state="incomplete", why="no log", illegal_lines=[], summary=None)
        return rec
    # newline="" keeps the carriage returns of progress bars, which text mode would turn into extra lines,
    # and split("\n") then numbers lines as grep -n does.
    lines = open(path, errors="replace", newline="").read().split("\n")
    summary = None
    for line in lines:
        m = SUMMARY_RE.match(line.strip())
        if m:
            summary = m.group(1)
            rec["summary"] = line.strip()
    rec.setdefault("summary", None)
    counts = {}
    for n, word in COUNT_RE.findall(summary or ""):
        key = {"error": "errors", "warning": "warnings"}.get(word, word)
        counts[key] = counts.get(key, 0) + int(n)
    rec["illegal_lines"] = [f"{i}:{x}" for i, x in enumerate(lines, start=1) if ILLEGAL_RE.search(x)]
    rec["first_illegal"] = first_illegal(lines, case)
    tb = "\n".join(x for x in lines if x.startswith(("E ", ">")))
    first_e = next((x.strip() for x in lines if x.startswith("E ")), None)
    harness = next((label for label, pattern in HARNESS_CAUSES if pattern.search(tb)), None)
    got = {k: v for k, v in counts.items() if k not in ("warnings", "deselected")}
    if rec["illegal_lines"]:
        # An illegal access is the fault itself, even when pytest died before its summary.
        rec["state"] = "faulted"
    elif harness:
        rec.update(state="not run", why=f"{harness}: {first_e}")
    elif summary is None or rc not in (0, 1):
        rec.update(state="incomplete", why=f"no summary line or an abnormal exit ({rc})")
    elif got.get("skipped"):
        rec.update(state="incomplete", why="skipped, and a skip on the GPU is not a result")
    elif got == {"passed": 1} and rc == 0:
        rec["state"] = "passed"
    else:
        rec.update(state="failed", why=f"the summary is {got} with exit {rc}" + (f"; first E line: {first_e}" if first_e else ""))
    return rec


def judge(out):
    rec = {"gaps": [], "runs": {}}
    try:
        env = json.load(open(os.path.join(out, "env.json")))
        rec["env"] = env
        if env.get("cuda_available") is not True or not env.get("device_name"):
            rec["gaps"].append(f"torch did not see a named CUDA device (cuda_available={env.get('cuda_available')!r})")
    except (OSError, ValueError) as e:
        rec["gaps"].append(f"env.json unreadable: {e}")
    if os.path.exists(os.path.join(out, "STOPPED")):
        rec["gaps"].append("the run stopped early: " + open(os.path.join(out, "STOPPED")).read().strip())
    rcs = {}
    path = os.path.join(out, "status.txt")
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"^test-(\w+)-(\w+) exit=(-?\d+)", line)
            if m:
                rcs[(m.group(1), m.group(2))] = int(m.group(3))
    for arm, case in RUNS:
        rec["runs"][f"{arm} [{case}]"] = process(os.path.join(out, f"e2e-{arm}-{case}.log"), rcs.get((arm, case)), case)
    fix = [rec["runs"]["fix [fail]"], rec["runs"]["fix [recompute]"]]
    control = rec["runs"]["control [fail]"]
    states = [p["state"] for p in fix]
    if any(s in ("faulted", "failed") for s in states):
        rec["verdict"] = "FINDING"
        rec["why"] = "the fix " + "; ".join(f"[{c}] {p['state']}" for c, p in zip(("fail", "recompute"), fix) if p["state"] in ("faulted", "failed"))
    elif rec["gaps"] or "incomplete" in states or control["state"] == "incomplete":
        rec["verdict"] = "INCOMPLETE"
    elif "not run" in states or control["state"] == "not run":
        rec["verdict"] = "NOT RUN"
    elif control["state"] != "faulted":
        # The fix passed, but the control did not show the fault this time, so the pass is not shown to be the fix's doing.
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = f"the fix passed both cases, but CONTROL [fail] {control['state']} instead of faulting"
    else:
        rec["verdict"] = "CONFIRMED"
        rec["why"] = "the fix passed both cases with no illegal access, and CONTROL [fail] faulted"
    return rec


def render(rec):
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    for name, p in rec["runs"].items():
        note = " (recorded, decides nothing)" if name == "control [recompute]" else (" (expected to fault)" if name == "control [fail]" else "")
        lines.append(f"{name}{note}: {p['state']} (exit {p.get('exit')}): {p.get('summary')}" + (f"; {p['why']}" if p.get("why") else ""))
        lines.append(f"  first illegal memory access in time: {p.get('first_illegal')}")
        lines.extend(f"  {x}" for x in p.get("illegal_lines", [])[:10])
    for g in rec["gaps"]:
        lines.append(f"GAP: {g}")
    if rec.get("why"):
        lines.append(f"WHY: {rec['why']}")
    lines.append(f"VERDICT: {rec['verdict']}")
    return lines


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: verdict.py OUT", file=sys.stderr)
        return 3
    rec = judge(argv[1])
    with open(os.path.join(argv[1], "verdict.json"), "w") as f:
        json.dump(rec, f, indent=1, sort_keys=True)
    print("\n".join(render(rec)))
    return {"CONFIRMED": 0, "FINDING": 2, "NOT RUN": 4, "INCONCLUSIVE": 5}.get(rec["verdict"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
