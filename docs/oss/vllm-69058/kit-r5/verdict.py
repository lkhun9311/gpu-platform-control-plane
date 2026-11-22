"""Verdict for the vLLM #69058 kit r5: the diagnostic run of PR #69095's head.

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt, OUT/STOPPED if present, and the test log OUT/e2e.log.
Writes OUT/verdict.json and prints, for each end-to-end case, the lines the runtime session asked for.
Exit status: 0 when the diagnostic is complete, 3 when it is not.
"""

import json
import os
import re
import sys

CLASS = "TestHF3FSLoadFailureEndToEnd"
CASES = ("fail", "recompute")
# The runtime session's grep: grep -n "DIAG\|illegal\|Failing\|Read operation failed".
GREP_RE = re.compile(r"DIAG|illegal|Failing|Read operation failed")
ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")
SYNC_OK_RE = re.compile(r"DIAG .*sync ok")
OUT_OF_RANGE_RE = re.compile(r"DIAG save .*out of range")
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
    # Each case's sections, as (line number, text) pairs, in the order pytest printed them.
    sections = {c: [] for c in CASES}
    current = None
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


def captured_blocks(section):
    """The captured stdout, stderr and log blocks of one section, each in the order the program wrote it."""
    blocks, block = [], None
    for i, line in section:
        if CAPTURED_RE.match(line):
            block = []
            blocks.append(block)
            continue
        if block is not None:
            block.append((i, line))
    return blocks


def case_record(parsed, case):
    """One case's outcome, grep lines, last sync before the first illegal access, and out-of-range lines."""
    sections = parsed["sections"][case]
    # -q lists only failed and errored tests, so a case without such a line passed only if the summary's passed count covers it.
    unlisted = [c for c in CASES if not parsed["outcomes"][c]]
    covered = parsed["summary"] is not None and parsed["counts"].get("passed", 0) == len(unlisted)
    outcome = "+".join(parsed["outcomes"][case]) or ("passed" if covered else "not run or unknown")
    rec = {"outcome": outcome}
    if not sections:
        rec["note"] = ("pytest prints no captured output for a passing case, so there is nothing to extract"
                       if outcome == "passed" else "no section of this case in the log")
        rec.update(grep=[], last_sync_before_illegal=None, first_illegal=None, out_of_range=[])
        return rec
    seen, grep = set(), []
    for section in sections:
        for i, line in section:
            if GREP_RE.search(line) and i not in seen:
                seen.add(i)
                grep.append(f"{i}:{line}")
    rec["grep"] = grep
    # The first illegal access in time is the first in a captured block, which is the program's own order.
    # A traceback above that block may mention the fault earlier in the file but later in time, after the engine already failed.
    first, last_sync = None, None
    for block in (b for s in sections for b in captured_blocks(s)):
        hit = next((k for k, (_, x) in enumerate(block) if ILLEGAL_RE.search(x)), None)
        if hit is not None:
            first = block[hit]
            last_sync = next(((i, x) for i, x in reversed(block[:hit]) if SYNC_OK_RE.search(x)), None)
            break
    if first is None:
        # No captured block holds the fault, so the file's order is the only order there is.
        flat = [p for s in sections for p in s]
        hit = next((k for k, (_, x) in enumerate(flat) if ILLEGAL_RE.search(x)), None)
        if hit is not None:
            first = flat[hit]
            last_sync = next(((i, x) for i, x in reversed(flat[:hit]) if SYNC_OK_RE.search(x)), None)
    rec["first_illegal"] = f"{first[0]}:{first[1]}" if first else None
    rec["last_sync_before_illegal"] = f"{last_sync[0]}:{last_sync[1]}" if last_sync else None
    rec["out_of_range"] = [g for g in grep if OUT_OF_RANGE_RE.search(g)]
    return rec


def judge(out):
    rec = {"gaps": [], "cases": {}}
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
    else:
        # newline="" keeps the carriage returns of progress bars, which text mode would turn into extra lines.
        parsed = parse(open(log, errors="replace", newline="").read())
        rec["summary"] = parsed["summary"]["line"] if parsed["summary"] else None
        if parsed["summary"] is None:
            rec["gaps"].append(f"no pytest summary line (exit {rc}), so pytest did not print the cases' captured output")
        elif rc not in (0, 1):
            rec["gaps"].append(f"pytest exited {rc}")
        if parsed["counts"].get("skipped"):
            rec["gaps"].append(f"{parsed['counts']['skipped']} skipped, and a skip on the GPU is not a diagnostic")
        if not any("DIAG" in x for x in parsed["lines"]) and parsed["summary"] and any(parsed["outcomes"].values()):
            rec["gaps"].append("a case failed but the log has no DIAG line, so the diagnostic patch did not run")
        for case in CASES:
            rec["cases"][case] = case_record(parsed, case)
            # Without -x both cases run, so one the summary does not account for means the run did not finish.
            if rec["cases"][case]["outcome"] == "not run or unknown":
                rec["gaps"].append(f"case [{case}] has no outcome in the summary")
    rec["verdict"] = "INCOMPLETE" if rec["gaps"] else "COMPLETE"
    return rec


def render(rec):
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    lines.append(f"summary (exit {rec.get('exit')}): {rec.get('summary')}")
    for case, c in rec["cases"].items():
        lines.append(f"case [{case}]: {c['outcome']}" + (f" ({c['note']})" if c.get("note") else ""))
        lines.append(f"  first illegal memory access: {c['first_illegal']}")
        lines.append(f"  last DIAG sync ok before it: {c['last_sync_before_illegal']}")
        lines.append(f"  DIAG save out of range: {c['out_of_range'] or 'none'}")
        lines.append(f"  grep -n 'DIAG|illegal|Failing|Read operation failed' ({len(c['grep'])} lines):")
        lines.extend(f"    {g}" for g in c["grep"])
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
    return 0 if rec["verdict"] == "COMPLETE" else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
