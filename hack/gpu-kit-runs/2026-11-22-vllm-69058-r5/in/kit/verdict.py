"""Verdict for the vLLM #69058 kit r5: the diagnostic run of PR #69095's head, one process per end-to-end case.

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt, OUT/STOPPED if present, and the test logs OUT/e2e-fail.log and OUT/e2e-recompute.log.
Writes OUT/verdict.json and prints, for each case, the lines the runtime session asked for.
Exit status: 0 when the diagnostic is complete, 3 when it is not.
"""

import json
import os
import re
import sys

CLASS = "TestHF3FSLoadFailureEndToEnd"
CASES = ("fail", "recompute")
# The runtime session's grep, run over each case's whole log: grep -n "DIAG\|illegal\|Failing\|Read operation failed".
GREP_RE = re.compile(r"DIAG|illegal|Failing|Read operation failed")
ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")
# A DIAG line counts only as a log record, which names its source as "[file.py:line]" or, from pytest's log capture, "file.py:line".
# --tb=long also prints the source of the failing function, where `logger.warning("DIAG ... sync ok")` is code that may never have run.
DIAG_RECORD_RE = re.compile(r"(?:\[[\w./-]+\.py:\d+\]|[\w./-]+\.py:\d+) DIAG ")
SYNC_OK_RE = re.compile(r"DIAG .*sync ok")
OUT_OF_RANGE_RE = re.compile(r"DIAG save .*out of range")
# The record that shows the case reached the failure it is about: the connector's failed read, or the patch's own record of it.
FAILED_READ_RE = re.compile(r"Read operation failed|DIAG load \S+ read failed")
# vLLM's records carry "MM-DD HH:MM:SS"; pytest's own log capture does not.
TIME_RE = re.compile(r" (\d\d-\d\d \d\d:\d\d:\d\d) ")
REQUEST_RE = re.compile(r"(?:request|DIAG (?:save|load|submit save)) ([\w-]+)")
# pytest -q prints its summary without the "=" padding that -rA runs have, so both shapes are read.
SUMMARY_RE = re.compile(r"^=*\s*(\d+ [a-z]+(?:, \d+ [a-z]+)*) in ([0-9.]+)s(?: \([^)]*\))?\s*=*$")
COUNT_RE = re.compile(r"(\d+) (passed|failed|skipped|deselected|errors?|xfailed|xpassed|warnings?)")
OUTCOME_RE = re.compile(r"^(FAILED|ERROR) \S*::" + CLASS + r"::test_failed_read_honors_policy\[(\w+)\]")
# A failure or error section opens with a header naming its test; pytest pads it with as few as one underscore a side.
HEADER_RE = re.compile(r"^_+ (?:ERROR at (?:setup|call|teardown) of )?" + CLASS + r"\.test_failed_read_honors_policy\[(\w+)\] _+$")
# Any other section header, or a "=" banner, ends the case's section.
# A header's name never starts with an underscore, so a traceback's "_ _ _" frame separator does not end it.
OTHER_HEADER_RE = re.compile(r"^_+ [^_\s].* _+$|^=+ .* =+$")
CAPTURED_RE = re.compile(r"^-+ Captured (stdout|stderr|log) (setup|call|teardown) -+$")
PHASES = {"setup": 0, "call": 1, "teardown": 2}
PATCH_CAUTION = ("the patch adds device-wide torch.cuda.synchronize() calls, which change timing; "
                 "a fault that does not appear under it is not shown gone, and run r4 is the run without it")


def parse(text, case):
    """One case's log: its lines numbered as grep -n numbers them, summary, counts, outcome and failure sections."""
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
    outcome = [m.group(1) for m in (OUTCOME_RE.match(x) for x in lines) if m and m.group(2) == case]
    sections, current = [], False
    for i, line in enumerate(lines, start=1):
        m = HEADER_RE.match(line)
        if m:
            current = m.group(1) == case
            if current:
                sections.append([])
            continue
        if current and OTHER_HEADER_RE.match(line):
            current = False
            continue
        if current:
            sections[-1].append((i, line))
    return {"lines": lines, "summary": summary, "counts": counts, "outcome": outcome, "sections": sections}


def records(sections):
    """Every line pytest captured from the program, as (phase, time, block, position, line number, text), in time order.

    Within a capture block the lines are in the order the program wrote them.
    Across blocks, the setup, call and teardown phases come in that order, and inside a phase vLLM's timestamps decide.
    A line without a timestamp takes the last one above it in its block, so a traceback stays after the record that led to it.
    A line with no timestamp above it in its block, such as pytest's own log capture, sorts after every timestamp of its phase,
    since its time is unknown and an untimed line must not jump ahead of the records that are timed.
    Ties keep the order pytest printed them in, which is all the log can say.
    """
    out, block_no = [], 0
    for section in sections:
        phase, stamp = None, "~"
        for pos, (i, line) in enumerate(section):
            m = CAPTURED_RE.match(line)
            if m:
                phase, stamp, block_no = PHASES[m.group(2)], "~", block_no + 1
                continue
            if phase is None:
                continue
            t = TIME_RE.search(line)
            if t:
                stamp = t.group(1)
            out.append((phase, stamp, block_no, pos, i, line))
    return sorted(out, key=lambda r: (r[0], r[1], r[2], r[3]))


def case_record(path, rc, case):
    """One case's outcome, grep lines, first illegal access, the syncs before it, out-of-range lines and gaps."""
    rec = {"exit": rc, "gaps": []}
    if not os.path.exists(path):
        rec.update(outcome="not run", grep=[], first_illegal=None, last_sync_before_illegal=None,
                   last_sync_same_request=None, out_of_range=[])
        rec["gaps"].append("no log")
        return rec
    # newline="" keeps the carriage returns of progress bars, which text mode would turn into extra lines.
    p = parse(open(path, errors="replace", newline="").read(), case)
    rec["summary"] = p["summary"]["line"] if p["summary"] else None
    rec["grep"] = [f"{i}:{x}" for i, x in enumerate(p["lines"], start=1) if GREP_RE.search(x)]
    if p["outcome"]:
        rec["outcome"] = "+".join(p["outcome"])
    elif p["summary"] and p["counts"].get("passed") == 1 and not p["counts"].get("failed") and not p["counts"].get("errors"):
        rec["outcome"] = "passed"
    else:
        rec["outcome"] = "unknown"
    if p["summary"] is None:
        rec["gaps"].append(f"no pytest summary line (exit {rc}), so pytest did not print the case's captured output")
    elif rc not in (0, 1):
        rec["gaps"].append(f"pytest exited {rc}")
    if p["counts"].get("skipped"):
        rec["gaps"].append("skipped, and a skip on the GPU is not a diagnostic")
    if rec["outcome"] == "unknown" and p["summary"] is not None:
        rec["gaps"].append("the summary does not give this case's outcome")
    recs = records(p["sections"])
    diag = [r for r in recs if DIAG_RECORD_RE.search(r[5])]
    first = next((r for r in recs if ILLEGAL_RE.search(r[5])), None)
    rec["first_illegal"] = f"{first[4]}:{first[5]}" if first else None
    if first is None:
        # No captured line holds the fault, so the traceback's E line is the only place left, and it says nothing about time.
        e = next(((i, x) for s in p["sections"] for i, x in s if x.startswith("E ") and ILLEGAL_RE.search(x)), None)
        rec["first_illegal"] = f"{e[0]}:{e[1]} (from the traceback; no captured record of it)" if e else None
    before = recs[:recs.index(first)] if first else []
    sync = [r for r in before if r in diag and SYNC_OK_RE.search(r[5])]
    rec["last_sync_before_illegal"] = f"{sync[-1][4]}:{sync[-1][5]}" if sync else None
    # The sync just before the fault may belong to another request; the one for the request the fault names is reported too.
    req = REQUEST_RE.findall(first[5]) if first else []
    same = [r for r in sync if req and req[-1] in REQUEST_RE.findall(r[5])]
    rec["fault_request"] = req[-1] if req else None
    rec["last_sync_same_request"] = f"{same[-1][4]}:{same[-1][5]}" if same else None
    rec["out_of_range"] = [f"{r[4]}:{r[5]}" for r in diag if OUT_OF_RANGE_RE.search(r[5])]
    if rec["outcome"] not in ("passed", "unknown"):
        if not diag:
            rec["gaps"].append("failed with no DIAG record of its own, so the diagnostic patch left no trail")
        if not any(FAILED_READ_RE.search(r[5]) for r in recs):
            rec["gaps"].append("failed without a failed-read record, so it never reached the failure it is about")
    if rec["outcome"] == "passed":
        rec["note"] = "passed, and pytest prints no captured output for a passing case; " + PATCH_CAUTION
    return rec


def judge(out):
    rec = {"gaps": [], "cases": {}, "caution": PATCH_CAUTION}
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
            m = re.match(r"^test-(\w+) exit=(-?\d+)", line)
            if m:
                rcs[m.group(1)] = int(m.group(2))
    for case in CASES:
        c = rec["cases"][case] = case_record(os.path.join(out, f"e2e-{case}.log"), rcs.get(case), case)
        rec["gaps"].extend(f"case [{case}]: {g}" for g in c["gaps"])
    rec["verdict"] = "INCOMPLETE" if rec["gaps"] else "COMPLETE"
    # COMPLETE says the diagnostic has what it needs, not that the fault is gone, so the run says in words whether it faulted.
    faulted = [c for c in CASES if rec["cases"][c]["first_illegal"]]
    rec["result"] = (f"illegal memory access in {', '.join(f'[{c}]' for c in faulted)}" if faulted else
                     "no illegal memory access in either case under the diagnostic patch, which does not show the fault gone (see the caution)")
    return rec


def render(rec):
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    lines.append(f"caution: {rec['caution']}")
    for case, c in rec["cases"].items():
        lines.append(f"case [{case}] (its own process, exit {c.get('exit')}): {c['outcome']}: {c.get('summary')}" + (f" ({c['note']})" if c.get("note") else ""))
        lines.append(f"  first illegal memory access: {c['first_illegal']}")
        lines.append(f"  last DIAG sync ok before it: {c['last_sync_before_illegal']}")
        lines.append(f"  last DIAG sync ok before it for request {c.get('fault_request')}: {c['last_sync_same_request']}")
        lines.append(f"  DIAG save out of range: {c['out_of_range'] or 'none'}")
        lines.append(f"  grep -n 'DIAG|illegal|Failing|Read operation failed' e2e-{case}.log ({len(c['grep'])} lines):")
        lines.extend(f"    {g}" for g in c["grep"])
    lines.append("note: a sync line marks where the fault was observed, not where it began")
    for g in rec["gaps"]:
        lines.append(f"GAP: {g}")
    lines.append(f"RESULT: {rec['result']}")
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
    return 0 if rec["verdict"] == "COMPLETE" else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
