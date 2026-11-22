"""Verdict for the vLLM #69058 kit r6: the confirmation run of the shutdown fix.

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt, OUT/STOPPED if present, and the test log OUT/e2e.log.
Writes OUT/verdict.json and prints the verdict.
AS EXPECTED is 2 passed with no illegal memory access anywhere in the log.
Anything else is a FINDING, except a harness cause, which is NOT RUN, and a run that cannot be read, which is INCOMPLETE.
Exit status: 0 AS EXPECTED, 2 FINDING, 3 INCOMPLETE, 4 NOT RUN.
"""

import json
import os
import re
import sys

CLASS = "TestHF3FSLoadFailureEndToEnd"
CASES = ("fail", "recompute")
ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")
# pytest -q prints its summary without the "=" padding that -rA runs have, so both shapes are read.
SUMMARY_RE = re.compile(r"^=*\s*(\d+ [a-z]+(?:, \d+ [a-z]+)*) in ([0-9.]+)s(?: \([^)]*\))?\s*=*$")
COUNT_RE = re.compile(r"(\d+) (passed|failed|skipped|deselected|errors?|xfailed|xpassed|warnings?)")
OUTCOME_RE = re.compile(r"^(FAILED|ERROR) \S*::" + CLASS + r"::test_failed_read_honors_policy\[(\w+)\]")
HEADER_RE = re.compile(r"^_+ (?:ERROR at (?:setup|call|teardown) of )?" + CLASS + r"\.test_failed_read_honors_policy\[(\w+)\] _+$")
# Any other section header, or a "=" banner, ends a case's section; a traceback's "_ _ _" separator does not.
OTHER_HEADER_RE = re.compile(r"^_+ [^_\s].* _+$|^=+ .* =+$")
CAPTURED_RE = re.compile(r"^-+ Captured (stdout|stderr|log) (setup|call|teardown) -+$")
PHASES = {"setup": 0, "call": 1, "teardown": 2}
TIME_RE = re.compile(r" (\d\d-\d\d \d\d:\d\d:\d\d) ")
# Harness causes, read from the traceback's ">" and E lines only, since captured logs name things like HF_HUB_OFFLINE on every run.
# An illegal memory access is not among them: it is what this run checks is gone, so it is a FINDING.
HARNESS_CAUSES = (
    ("KV cache memory", re.compile(r"KV cache is needed, which is larger than the available KV cache memory")),
    ("GPU out of memory", re.compile(r"OutOfMemoryError|CUDA out of memory", re.I)),
    ("model download or offline load failure", re.compile(r"LocalEntryNotFoundError|Cannot find the requested files|couldn't connect to|RepositoryNotFound|GatedRepo")),
)


def parse(text):
    """The log's lines, numbered as grep -n numbers them, its summary and counts, and each case's outcome and section lines."""
    # split("\n") on text read with newline="" keeps grep's line numbers, carriage returns of progress bars included.
    lines = text.split("\n")
    summary = None
    for line in lines:
        m = SUMMARY_RE.match(line.strip())
        if m:
            summary = {"line": line.strip(), "body": m.group(1)}
    counts = {}
    if summary:
        for n, word in COUNT_RE.findall(summary["body"]):
            key = {"error": "errors", "warning": "warnings"}.get(word, word)
            counts[key] = counts.get(key, 0) + int(n)
    outcomes = {c: [] for c in CASES}
    for line in lines:
        m = OUTCOME_RE.match(line)
        if m and m.group(2) in outcomes:
            outcomes[m.group(2)].append(m.group(1))
    sections, current = {c: [] for c in CASES}, None
    for i, line in enumerate(lines, start=1):
        m = HEADER_RE.match(line)
        if m:
            current = m.group(1) if m.group(1) in sections else None
            if current:
                sections[current].append([])
            continue
        if current and OTHER_HEADER_RE.match(line):
            current = None
            continue
        if current:
            sections[current][-1].append((i, line))
    return {"lines": lines, "summary": summary, "counts": counts, "outcomes": outcomes, "sections": sections}


def first_illegal(parsed, case):
    """A failed case's first illegal access in time: kit r5's order, by capture phase, then vLLM's timestamps, then position."""
    recs = []
    for s, section in enumerate(parsed["sections"][case]):
        phase, stamp = None, "~"
        for pos, (i, line) in enumerate(section):
            m = CAPTURED_RE.match(line)
            if m:
                phase, stamp = PHASES[m.group(2)], "~"
                continue
            if phase is None:
                continue
            t = TIME_RE.search(line)
            if t:
                stamp = t.group(1)
            recs.append((phase, stamp, s, pos, i, line))
    recs.sort(key=lambda r: (r[0], r[1], r[2], r[3]))
    hit = next((r for r in recs if ILLEGAL_RE.search(r[5])), None)
    return f"{hit[4]}:{hit[5]}" if hit else None


def judge(out):
    rec = {"gaps": [], "findings": [], "cases": {}}
    try:
        env = json.load(open(os.path.join(out, "env.json")))
        rec["env"] = env
        if env.get("cuda_available") is not True or not env.get("device_name"):
            rec["gaps"].append(f"torch did not see a named CUDA device (cuda_available={env.get('cuda_available')!r})")
    except (OSError, ValueError) as e:
        rec["gaps"].append(f"env.json unreadable: {e}")
    if os.path.exists(os.path.join(out, "STOPPED")):
        rec["gaps"].append("the run stopped early: " + open(os.path.join(out, "STOPPED")).read().strip())
    rc = None
    path = os.path.join(out, "status.txt")
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"^test-e2e exit=(-?\d+)", line)
            if m:
                rc = int(m.group(1))
    rec["exit"] = rc
    log = os.path.join(out, "e2e.log")
    if not os.path.exists(log):
        rec["gaps"].append("no e2e.log")
        rec["verdict"] = "INCOMPLETE"
        return rec
    # newline="" keeps the carriage returns of progress bars, which text mode would turn into extra lines.
    p = parse(open(log, errors="replace", newline="").read())
    rec["summary"] = p["summary"]["line"] if p["summary"] else None
    # Any illegal access anywhere in the log is the fault this run checks is gone, whatever pytest's summary says.
    rec["illegal_lines"] = [f"{i}:{x}" for i, x in enumerate(p["lines"], start=1) if ILLEGAL_RE.search(x)]
    for case in CASES:
        rec["cases"][case] = {"outcome": "+".join(p["outcomes"][case]) or None, "first_illegal": first_illegal(p, case)}
    tb = "\n".join(x for x in p["lines"] if x.startswith(("E ", ">")))
    first_e = next((x.strip() for x in p["lines"] if x.startswith("E ")), None)
    harness = next((label for label, pattern in HARNESS_CAUSES if pattern.search(tb)), None)
    c = p["counts"]
    if rec["illegal_lines"]:
        rec["findings"].append(f"an illegal memory access is in the log, first at {rec['illegal_lines'][0]}")
    elif harness:
        rec["not_run"] = f"{harness}: {first_e}"
    elif p["summary"] is None or rc not in (0, 1):
        rec["gaps"].append(f"no pytest summary line or an abnormal exit ({rc}), and no illegal memory access in the log")
    elif c.get("skipped"):
        rec["gaps"].append(f"{c['skipped']} skipped, and a skip on the GPU is not a result")
    else:
        got = {k: v for k, v in c.items() if k not in ("warnings", "deselected")}
        if got != {"passed": 2} or rc != 0:
            rec["findings"].append(f"the summary is {got} with exit {rc}, not 2 passed" + (f"; first E line: {first_e}" if first_e else ""))
    if rec["findings"]:
        rec["verdict"] = "FINDING"
    elif rec["gaps"]:
        rec["verdict"] = "INCOMPLETE"
    elif rec.get("not_run"):
        rec["verdict"] = "NOT RUN"
    else:
        rec["verdict"] = "AS EXPECTED"
    return rec


def render(rec):
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    lines.append(f"summary (exit {rec.get('exit')}): {rec.get('summary')}")
    for case, c in rec["cases"].items():
        lines.append(f"case [{case}]: {c['outcome'] or 'not listed as failed or errored'}; first illegal memory access in time: {c['first_illegal']}")
    lines.append(f"illegal memory access lines in the log: {len(rec.get('illegal_lines', []))}")
    lines.extend(f"  {x}" for x in rec.get("illegal_lines", [])[:20])
    if rec.get("not_run"):
        lines.append(f"NOT RUN: {rec['not_run']}")
    for f in rec["findings"]:
        lines.append(f"FINDING: {f}")
    for g in rec["gaps"]:
        lines.append(f"GAP: {g}")
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
    return {"AS EXPECTED": 0, "FINDING": 2, "NOT RUN": 4}.get(rec["verdict"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
