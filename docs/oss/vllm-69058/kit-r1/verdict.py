"""Verdict for the vLLM #69058 HF3FS load-errors kit.

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt and the four pytest logs OUT/{base,fix}-{a,b}.log.
Writes OUT/verdict.json and prints the verdict.
Exit status: 0 AS EXPECTED, 2 NOT AS EXPECTED, 3 INCOMPLETE.
"""

import json
import os
import re
import sys

FILE = "tests/v1/kv_connector/unit/test_hf3fs_connector.py"
CLASS = FILE + "::TestHF3FSLoadErrors::"
SCHED = FILE + "::TestHF3FSSchedulerLoadFailure::"
CUDA_TEST = CLASS + "test_failed_batch_reported_when_last_batch_succeeds"
# The six tests that command (a) selects, all added by the diff.
EXPECTED_A = frozenset(
    [CLASS + "test_failed_load_reports_block_ids[" + p + "]" for p in ("missing_key", "lookup_raises", "short_read")]
    + [CUDA_TEST]
    + [SCHED + "test_failed_load_honors_failure_policy[" + p + "]" for p in ("fail", "recompute")]
)
SIDES = ("base", "fix")
CMDS = ("a", "b")
# What the fix claims, per side and command, as the set of tests that must fail.
# Every other test the command ran must pass.
EXPECTED_FAILED = {
    ("base", "a"): EXPECTED_A,
    ("fix", "a"): frozenset(),
    ("base", "b"): EXPECTED_A,
    ("fix", "b"): frozenset(),
}

SUMMARY_RE = re.compile(r"^=+ (.+) in ([0-9.]+)s(?: \([^)]*\))? =+$")
OUTCOME_RE = re.compile(r"^(PASSED|FAILED|ERROR|XFAIL|XPASS) (\S+)(?: - .*)?$")
SKIPPED_RE = re.compile(r"^SKIPPED \[(\d+)\] (.*)$")
# pytest pads a failure header to the terminal width, so a long test name gets as few as one underscore on each side.
# A name never starts with an underscore, which keeps the traceback's "_ _ _" frame separators from reading as a header.
HEADER_RE = re.compile(r"^_+ ([^_\s].*?) _+$")
COUNT_RE = re.compile(r"(\d+) (passed|failed|skipped|deselected|errors?|xfailed|xpassed|warnings?)")


def parse_log(text):
    """Parse one `pytest -rA` log into its summary, per-test outcomes and failing assertion lines."""
    lines = text.splitlines()
    summary = None
    for line in lines:
        m = SUMMARY_RE.match(line)
        if m:
            summary = {"line": line, "body": m.group(1), "seconds": float(m.group(2))}
    counts = {}
    if summary:
        for n, word in COUNT_RE.findall(summary["body"]):
            key = {"error": "errors", "warning": "warnings"}.get(word, word)
            counts[key] = counts.get(key, 0) + int(n)
    outcomes = {}
    duplicates = []
    skipped_lines = []
    in_short = False
    for line in lines:
        if "short test summary info" in line:
            in_short = True
            continue
        if not in_short:
            continue
        m = OUTCOME_RE.match(line)
        if m:
            if m.group(2) in outcomes:
                duplicates.append(m.group(2))
            outcomes[m.group(2)] = m.group(1)
            continue
        m = SKIPPED_RE.match(line)
        if m:
            skipped_lines.append(line)
    # Failing assertion lines, keyed by the failure section's header.
    asserts = {}
    current = None
    for line in lines:
        m = HEADER_RE.match(line)
        if m:
            current = m.group(1)
            continue
        if current and line.startswith("E "):
            got = asserts.setdefault(current, [])
            if len(got) < 6:
                got.append(line.rstrip())
    return {
        "summary": summary,
        "counts": counts,
        "outcomes": outcomes,
        "duplicates": duplicates,
        "skipped_lines": skipped_lines,
        "assertions": asserts,
    }


def read_status(out):
    """Map each step name in status.txt to its last recorded exit code."""
    rcs = {}
    path = os.path.join(out, "status.txt")
    if not os.path.exists(path):
        return rcs
    for line in open(path):
        m = re.match(r"^(\S+) exit=(-?\d+)", line)
        if m:
            rcs[m.group(1)] = int(m.group(2))
    return rcs


def check_run(side, cmd, run, rc):
    """Return the reasons one run cannot be judged, or an empty list."""
    gaps = []
    name = f"{side}-{cmd}"
    if run is None:
        return [f"{name}: no log"]
    if rc is None:
        gaps.append(f"{name}: no exit code in status.txt")
    elif rc not in (0, 1):
        gaps.append(f"{name}: pytest exited {rc}, so it did not finish its tests")
    if run["summary"] is None:
        gaps.append(f"{name}: no pytest summary line")
        return gaps
    c = run["counts"]
    if run["duplicates"]:
        gaps.append(f"{name}: a test is reported twice: {sorted(set(run['duplicates']))}")
    if c.get("skipped", 0) or run["skipped_lines"]:
        gaps.append(f"{name}: {c.get('skipped', 0)} skipped ({'; '.join(run['skipped_lines']) or 'no SKIPPED line'}), and a skip on the GPU is not a result")
    if c.get("errors", 0):
        gaps.append(f"{name}: {c['errors']} error(s), so a test did not reach its assertions")
    for k in ("xfailed", "xpassed"):
        if c.get(k, 0):
            gaps.append(f"{name}: {c[k]} {k}, which this file does not mark")
    others = sorted(t for t, o in run["outcomes"].items() if o not in ("PASSED", "FAILED"))
    if others:
        gaps.append(f"{name}: outcomes other than PASSED or FAILED: {others}")
    passed = sum(1 for o in run["outcomes"].values() if o == "PASSED")
    failed = sum(1 for o in run["outcomes"].values() if o == "FAILED")
    if (passed, failed) != (c.get("passed", 0), c.get("failed", 0)):
        gaps.append(f"{name}: the summary counts {c.get('passed', 0)} passed and {c.get('failed', 0)} failed, the -rA lines {passed} and {failed}")
    if passed + failed == 0:
        gaps.append(f"{name}: no test ran")
    if rc is not None and rc in (0, 1) and rc != (1 if failed else 0):
        gaps.append(f"{name}: pytest exited {rc} with {failed} failed")
    ids = set(run["outcomes"])
    if cmd == "a" and ids != EXPECTED_A:
        gaps.append(f"{name}: ran {sorted(ids)}, not the six tests the diff adds")
    if cmd == "b" and not EXPECTED_A <= ids:
        gaps.append(f"{name}: the whole file lacks {sorted(EXPECTED_A - ids)}")
    return gaps


def judge(out):
    """Return the verdict record for the results in OUT."""
    rec = {"verdict": "INCOMPLETE", "gaps": [], "deviations": [], "runs": {}}
    gaps = rec["gaps"]
    env = None
    try:
        env = json.load(open(os.path.join(out, "env.json")))
    except (OSError, ValueError) as e:
        gaps.append(f"env.json unreadable: {e}")
    if env is not None:
        rec["env"] = env
        if env.get("cuda_available") is not True:
            gaps.append(f"torch did not see CUDA (cuda_available={env.get('cuda_available')!r}), so the CUDA-only test could not run")
        if not env.get("device_name"):
            gaps.append("env.json names no CUDA device")
    rcs = read_status(out)
    if os.path.exists(os.path.join(out, "STOPPED")):
        gaps.append("the run stopped early: " + open(os.path.join(out, "STOPPED")).read().strip())
    runs = {}
    for side in SIDES:
        for cmd in CMDS:
            path = os.path.join(out, f"{side}-{cmd}.log")
            run = parse_log(open(path, errors="replace").read()) if os.path.exists(path) else None
            runs[(side, cmd)] = run
            gaps.extend(check_run(side, cmd, run, rcs.get(f"test-{side}-{cmd}")))
            if run is not None:
                rec["runs"][f"{side}-{cmd}"] = {
                    "summary": run["summary"]["line"] if run["summary"] else None,
                    "seconds": run["summary"]["seconds"] if run["summary"] else None,
                    "counts": run["counts"],
                    "failed": sorted(t for t, o in run["outcomes"].items() if o == "FAILED"),
                    "assertions": run["assertions"],
                    "exit": rcs.get(f"test-{side}-{cmd}"),
                }
    for cmd in CMDS:
        b, f = runs[("base", cmd)], runs[("fix", cmd)]
        if b is not None and f is not None and set(b["outcomes"]) != set(f["outcomes"]):
            gaps.append(f"{cmd}: base and fix ran different tests")
    cuda = {side: (runs[(side, "a")] or {"outcomes": {}})["outcomes"].get(CUDA_TEST, "missing") for side in SIDES}
    rec["cuda_only_test"] = cuda
    # A test outside the diff's six that the fix changes is a finding of its own, named even when other gaps leave the verdict open.
    rec["findings"] = findings = []
    b, f = runs[("base", "b")], runs[("fix", "b")]
    if b is not None and f is not None:
        for t in sorted((set(b["outcomes"]) | set(f["outcomes"])) - EXPECTED_A):
            ob, of = b["outcomes"].get(t, "missing"), f["outcomes"].get(t, "missing")
            if ob != of:
                findings.append(f"{t}: base {ob}, fix {of}")
    if gaps:
        return rec
    for (side, cmd), want in EXPECTED_FAILED.items():
        run = runs[(side, cmd)]
        failed = {t for t, o in run["outcomes"].items() if o == "FAILED"}
        if failed != want:
            extra = sorted(failed - want)
            lacking = sorted(want - failed)
            if extra:
                rec["deviations"].append(f"{side}-{cmd}: failed but expected to pass: {extra}")
            if lacking:
                rec["deviations"].append(f"{side}-{cmd}: passed but expected to fail: {lacking}")
    # A decided finding always has one side failing a test outside the six, which is also a deviation.
    # The findings are tested here anyway, so the verdict does not depend on that overlap holding.
    rec["verdict"] = "NOT AS EXPECTED" if rec["deviations"] or findings else "AS EXPECTED"
    return rec


def render(rec):
    """The verdict as the lines verdict.txt keeps."""
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    c = rec["cuda_only_test"]
    lines.append(f"CUDA-only test {CUDA_TEST.rsplit('::', 1)[1]}: base {c['base']}, fix {c['fix']}")
    for name, r in rec["runs"].items():
        lines.append(f"{name} (exit {r['exit']}): {r['summary']}")
        for header, asserts in r["assertions"].items():
            lines.append(f"  {header}: {' | '.join(a.strip() for a in asserts[:2])}")
    for g in rec["gaps"]:
        lines.append(f"GAP: {g}")
    for d in rec["deviations"]:
        lines.append(f"DEVIATION: {d}")
    for x in rec["findings"]:
        lines.append(f"FINDING outside the six: {x}")
    lines.append(f"VERDICT: {rec['verdict']}")
    return lines


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: verdict.py OUT", file=sys.stderr)
        return 3
    out = argv[1]
    rec = judge(out)
    with open(os.path.join(out, "verdict.json"), "w") as f:
        json.dump(rec, f, indent=1, sort_keys=True)
    print("\n".join(render(rec)))
    return {"AS EXPECTED": 0, "NOT AS EXPECTED": 2}.get(rec["verdict"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
