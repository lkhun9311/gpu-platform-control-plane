"""Verdict for the vLLM #69058 HF3FS load-errors kit.

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt, OUT/c-not-run.txt if present, and the six pytest logs OUT/{base,fix}-{a,b,c}.log.
Writes OUT/verdict.json and prints two verdicts, one for the unit commands (a) and (b) and one for the LLM-level command (c).
Exit status: 2 if either is NOT AS EXPECTED, else 3 if either is INCOMPLETE, else 4 if (c) is NOT RUN, else 0.
"""

import json
import os
import re
import sys

FILE = "tests/v1/kv_connector/unit/test_hf3fs_connector.py"
CLASS = FILE + "::TestHF3FSLoadErrors::"
SCHED = FILE + "::TestHF3FSSchedulerLoadFailure::"
E2E = FILE + "::TestHF3FSLoadFailureEndToEnd::"
CUDA_TEST = CLASS + "test_failed_batch_reported_when_last_batch_succeeds"
# The eight tests that command (a) selects, all added by the diff.
# On a GPU every one of them fails on base; on CPU the CUDA-only one is skipped, which leaves seven.
EXPECTED_A = frozenset(
    [CLASS + "test_failed_load_reports_block_ids[" + p + "]" for p in ("missing_key", "lookup_raises", "short_read")]
    + [CUDA_TEST]
    + [SCHED + "test_failed_load_honors_failure_policy[" + p + "]" for p in ("fail", "recompute")]
    + [SCHED + "test_failed_later_batch_keeps_prefix_and_saves_the_rest", SCHED + "test_reused_blocks_do_not_mark_a_finished_load"]
)
E2E_FAIL = E2E + "test_failed_read_honors_policy[fail]"
E2E_RECOMPUTE = E2E + "test_failed_read_honors_policy[recompute]"
# The two tests that command (c) selects, through `LLM` on a GPU.
EXPECTED_C = frozenset([E2E_FAIL, E2E_RECOMPUTE])
# Tests whose outcome the diff is meant to change, so a base and fix difference in them is not a finding.
JUDGED = EXPECTED_A | EXPECTED_C
SIDES = ("base", "fix")
# The unit verdict's claim, per side and command, as the set of tests that must fail.
# Every other test the command ran must pass, except the end-to-end ones, which (c) judges.
EXPECTED_FAILED = {
    ("base", "a"): EXPECTED_A,
    ("fix", "a"): frozenset(),
    ("base", "b"): EXPECTED_A,
    ("fix", "b"): frozenset(),
}
# The assertions in the end-to-end test that decide it, as they appear on pytest's ">" source line.
# A failure anywhere else, the read-count check included, means the test did not get to decide.
C_DECIDING = (
    ('assert retry.finish_reason == "error"', re.compile(r'^>\s+assert retry\.finish_reason == "error"\s*$')),
    ('assert retry.finish_reason == "length"', re.compile(r'^>\s+assert retry\.finish_reason == "length"\s*$')),
    ("assert retry.token_ids == cold.token_ids", re.compile(r"^>\s+assert retry\.token_ids == cold\.token_ids\s*$")),
    ("check_logprobs_close", re.compile(r"^>\s+check_logprobs_close\(\s*$")),
)
# A deciding failure is an assertion failing, which pytest prints as an E line starting with "assert" or "AssertionError".
# A TypeError raised inside check_logprobs_close, for example, is the harness breaking, not the outputs differing.
ASSERT_E_RE = re.compile(r"^E\s+(AssertionError\b|assert )")
# Harness causes the runtime session named, matched on the failure's own text, first match wins.
HARNESS_CAUSES = (
    ("timeout in the 60 s wait for stored keys", re.compile(r"condition not met before the timeout")),
    ("OOM with two LLM instances", re.compile(r"OutOfMemoryError|CUDA out of memory|out of memory", re.I)),
    ("model download or offline load failure", re.compile(r"LocalEntryNotFoundError|HF_HUB_OFFLINE|offline mode|Cannot find the requested files|couldn't connect to|RepositoryNotFound|GatedRepo")),
    ("KV layout registration error", re.compile(r"register_kv_caches|kv[_ ]cache[_ ]layout|layout", re.I)),
    ("the failing read never reached HF3FS", re.compile(r"^>\s+assert faults\.num_failed_reads > 0", re.M)),
)

SUMMARY_RE = re.compile(r"^=+ (.+) in ([0-9.]+)s(?: \([^)]*\))? =+$")
OUTCOME_RE = re.compile(r"^(PASSED|FAILED|ERROR|XFAIL|XPASS) (\S+)(?: - .*)?$")
SKIPPED_RE = re.compile(r"^SKIPPED \[(\d+)\] (.*)$")
# pytest pads a failure header to the terminal width, so a long test name gets as few as one underscore on each side.
# A name never starts with an underscore, which keeps the traceback's "_ _ _" frame separators from reading as a header.
HEADER_RE = re.compile(r"^_+ ([^_\s].*?) _+$")
SECTION_END_RE = re.compile(r"^=+ .* =+$")
COUNT_RE = re.compile(r"(\d+) (passed|failed|skipped|deselected|errors?|xfailed|xpassed|warnings?)")


def normalize(test_id):
    """The test's id from the repository root, whichever directory pytest ran in."""
    marker = "test_hf3fs_connector.py::"
    if marker in test_id:
        return FILE + "::" + test_id.split(marker, 1)[1]
    return test_id


def header_id(header):
    """The test id a failure or error section's header names."""
    name = re.sub(r"^ERROR at (setup|teardown|call) of ", "", header)
    return FILE + "::" + name.replace(".", "::", 1)


def parse_log(text):
    """Parse one `pytest -rA` log into its summary, per-test outcomes, assertion lines and failure sections."""
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
            tid = normalize(m.group(2))
            if tid in outcomes:
                duplicates.append(tid)
            outcomes[tid] = m.group(1)
            continue
        m = SKIPPED_RE.match(line)
        if m:
            skipped_lines.append(line)
    # Each failure or error section's lines, and its first assertion lines, keyed by its header.
    asserts = {}
    sections = {}
    current = None
    for line in lines:
        m = HEADER_RE.match(line)
        if m:
            current = m.group(1)
            sections.setdefault(current, [])
            continue
        if current and SECTION_END_RE.match(line):
            current = None
            continue
        if current:
            sections[current].append(line)
            if line.startswith("E "):
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
        "sections": {header_id(h): s for h, s in sections.items()},
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


def check_run(side, cmd, run, rc, b_needs=JUDGED):
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
    # An end-to-end test that errors is a harness failure that (c) records as NOT RUN, so it is not a gap of its own.
    own_errors = {t for t, o in run["outcomes"].items() if o == "ERROR" and t in EXPECTED_C}
    if run["duplicates"]:
        gaps.append(f"{name}: a test is reported twice: {sorted(set(run['duplicates']))}")
    if c.get("skipped", 0) or run["skipped_lines"]:
        gaps.append(f"{name}: {c.get('skipped', 0)} skipped ({'; '.join(run['skipped_lines']) or 'no SKIPPED line'}), and a skip on the GPU is not a result")
    if c.get("errors", 0) > len(own_errors):
        gaps.append(f"{name}: {c['errors']} error(s), so a test did not reach its assertions")
    for k in ("xfailed", "xpassed"):
        if c.get(k, 0):
            gaps.append(f"{name}: {c[k]} {k}, which this file does not mark")
    others = sorted(t for t, o in run["outcomes"].items() if o not in ("PASSED", "FAILED") and t not in own_errors)
    if others:
        gaps.append(f"{name}: outcomes other than PASSED or FAILED: {others}")
    passed = sum(1 for o in run["outcomes"].values() if o == "PASSED")
    failed = sum(1 for o in run["outcomes"].values() if o == "FAILED")
    errored = sum(1 for o in run["outcomes"].values() if o == "ERROR")
    if (passed, failed, errored) != (c.get("passed", 0), c.get("failed", 0), c.get("errors", 0)):
        gaps.append(f"{name}: the summary counts {c.get('passed', 0)} passed, {c.get('failed', 0)} failed and {c.get('errors', 0)} errors, "
                    f"the -rA lines {passed}, {failed} and {errored}")
    if passed + failed + errored == 0:
        gaps.append(f"{name}: no test ran")
    if rc is not None and rc in (0, 1) and rc != (1 if failed or errored else 0):
        gaps.append(f"{name}: pytest exited {rc} with {failed} failed and {errored} errors")
    ids = set(run["outcomes"])
    if cmd == "a" and ids != EXPECTED_A:
        gaps.append(f"{name}: ran {sorted(ids)}, not the eight tests the diff adds")
    if cmd == "b" and not b_needs <= ids:
        gaps.append(f"{name}: the whole file lacks {sorted(b_needs - ids)}")
    if cmd == "c" and ids != EXPECTED_C:
        gaps.append(f"{name}: ran {sorted(ids)}, not the two end-to-end tests")
    return gaps


def c_state(run, test):
    """One end-to-end test's state on one side: PASSED, FAILED at a deciding assertion, or NOT RUN with its cause."""
    outcome = run["outcomes"].get(test, "missing")
    if outcome == "PASSED":
        return {"state": "PASSED"}
    lines = run["sections"].get(test, [])
    if outcome == "FAILED":
        # pytest prints the test's own frame first, so the first ">" line is the statement in the test that raised.
        # An inner frame's ">" line is a helper's or vLLM's, and never decides the test even if its text looks like one.
        own = next((line for line in lines if line.startswith(">")), "")
        asserted = any(ASSERT_E_RE.match(line) for line in lines)
        for label, pattern in C_DECIDING:
            if pattern.match(own) and asserted:
                return {"state": "FAILED", "at": label}
    text = "\n".join(lines)
    first = next((line.strip() for line in lines if line.startswith("E ")), None) or f"{outcome} with no E line"
    for label, pattern in HARNESS_CAUSES:
        if pattern.search(text):
            return {"state": "NOT RUN", "cause": f"{label}: {first}"}
    return {"state": "NOT RUN", "cause": f"other harness failure ({outcome}): {first}"}


def judge(out):
    """Return the verdict record for the results in OUT."""
    rec = {"verdict": "INCOMPLETE", "gaps": [], "deviations": [], "runs": {}, "findings": []}
    c_rec = {"verdict": "INCOMPLETE", "gaps": [], "deviations": [], "states": {}, "not_run": []}
    rec["c"] = c_rec
    common = []
    env = None
    try:
        env = json.load(open(os.path.join(out, "env.json")))
    except (OSError, ValueError) as e:
        common.append(f"env.json unreadable: {e}")
    if env is not None:
        rec["env"] = env
        if env.get("cuda_available") is not True:
            common.append(f"torch did not see CUDA (cuda_available={env.get('cuda_available')!r}), so the CUDA-only tests could not run")
        if not env.get("device_name"):
            common.append("env.json names no CUDA device")
    rcs = read_status(out)
    if os.path.exists(os.path.join(out, "STOPPED")):
        common.append("the run stopped early: " + open(os.path.join(out, "STOPPED")).read().strip())
    rec["gaps"].extend(common)
    c_rec["gaps"].extend(common)
    runs = {}
    for side in SIDES:
        for cmd in ("a", "b", "c"):
            path = os.path.join(out, f"{side}-{cmd}.log")
            run = parse_log(open(path, errors="replace").read()) if os.path.exists(path) else None
            runs[(side, cmd)] = run
            if run is not None:
                rec["runs"][f"{side}-{cmd}"] = {
                    "summary": run["summary"]["line"] if run["summary"] else None,
                    "seconds": run["summary"]["seconds"] if run["summary"] else None,
                    "counts": run["counts"],
                    "failed": sorted(t for t, o in run["outcomes"].items() if o == "FAILED"),
                    "assertions": run["assertions"],
                    "exit": rcs.get(f"test-{side}-{cmd}"),
                }
    for side in SIDES:
        for cmd in ("a", "b"):
            # When (c) could not run, run.sh deselects the end-to-end class from (b) too, so (b) then owes only the eight.
            b_needs = EXPECTED_A if os.path.exists(os.path.join(out, "c-not-run.txt")) else JUDGED
            rec["gaps"].extend(check_run(side, cmd, runs[(side, cmd)], rcs.get(f"test-{side}-{cmd}"), b_needs))
    for cmd in ("a", "b"):
        b, f = runs[("base", cmd)], runs[("fix", cmd)]
        if b is not None and f is not None and set(b["outcomes"]) != set(f["outcomes"]):
            rec["gaps"].append(f"{cmd}: base and fix ran different tests")
    rec["cuda_only_test"] = {side: (runs[(side, "a")] or {"outcomes": {}})["outcomes"].get(CUDA_TEST, "missing") for side in SIDES}
    # A test outside the ten that the fix changes is a finding of its own, named even when other gaps leave the verdict open.
    b, f = runs[("base", "b")], runs[("fix", "b")]
    if b is not None and f is not None:
        for t in sorted((set(b["outcomes"]) | set(f["outcomes"])) - JUDGED):
            ob, of = b["outcomes"].get(t, "missing"), f["outcomes"].get(t, "missing")
            if ob != of:
                rec["findings"].append(f"{t}: base {ob}, fix {of}")
    if not rec["gaps"]:
        for (side, cmd), want in EXPECTED_FAILED.items():
            run = runs[(side, cmd)]
            failed = {t for t, o in run["outcomes"].items() if o == "FAILED" and t not in EXPECTED_C}
            extra = sorted(failed - want)
            lacking = sorted(want - failed)
            if extra:
                rec["deviations"].append(f"{side}-{cmd}: failed but expected to pass: {extra}")
            if lacking:
                rec["deviations"].append(f"{side}-{cmd}: passed but expected to fail: {lacking}")
        # A decided finding always has one side failing a test outside the ten, which is also a deviation.
        # The findings are tested here anyway, so the verdict does not depend on that overlap holding.
        rec["verdict"] = "NOT AS EXPECTED" if rec["deviations"] or rec["findings"] else "AS EXPECTED"
    judge_c(out, runs, rcs, c_rec)
    return rec


def judge_c(out, runs, rcs, c_rec):
    """Fill the (c) verdict: NOT RUN for a harness cause, INCOMPLETE for a gap, else the comparison with the expectation."""
    not_run_path = os.path.join(out, "c-not-run.txt")
    if os.path.exists(not_run_path):
        c_rec["not_run"].append(open(not_run_path).read().strip())
        c_rec["verdict"] = "NOT RUN"
        return
    for side in SIDES:
        c_rec["gaps"].extend(check_run(side, "c", runs[(side, "c")], rcs.get(f"test-{side}-c")))
    if c_rec["gaps"]:
        return
    for side in SIDES:
        for test in sorted(EXPECTED_C):
            st = c_state(runs[(side, "c")], test)
            c_rec["states"][f"{side} {test.rsplit('::', 1)[1]}"] = st
            if st["state"] == "NOT RUN":
                c_rec["not_run"].append(f"{side} {test.rsplit('::', 1)[1]}: {st['cause']}")
    if c_rec["not_run"]:
        c_rec["verdict"] = "NOT RUN"
        return
    s = c_rec["states"]
    name_f, name_r = E2E_FAIL.rsplit("::", 1)[1], E2E_RECOMPUTE.rsplit("::", 1)[1]
    if s[f"base {name_f}"] != {"state": "FAILED", "at": 'assert retry.finish_reason == "error"'}:
        c_rec["deviations"].append(f"base {name_f}: {s[f'base {name_f}']}, expected to fail at assert retry.finish_reason == \"error\"")
    for name in (name_f, name_r):
        if s[f"fix {name}"] != {"state": "PASSED"}:
            c_rec["deviations"].append(f"fix {name}: {s[f'fix {name}']}, expected to pass")
    # Base recompute most likely fails at the token comparison, but that is not guaranteed, so it is recorded and not judged.
    c_rec["base_recompute"] = s[f"base {name_r}"]
    c_rec["verdict"] = "NOT AS EXPECTED" if c_rec["deviations"] else "AS EXPECTED"


def overall(rec):
    """The run's one verdict word: the worst of the two, in the order the exit status ranks them."""
    verdicts = (rec["verdict"], rec["c"]["verdict"])
    for v in ("NOT AS EXPECTED", "INCOMPLETE", "NOT RUN"):
        if v in verdicts:
            return v
    return "AS EXPECTED"


def render(rec):
    """The verdict as the lines verdict.txt keeps."""
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    c = rec["cuda_only_test"]
    lines.append(f"CUDA-only test {CUDA_TEST.rsplit('::', 1)[1]}: base {c['base']}, fix {c['fix']}")
    for name, st in rec["c"]["states"].items():
        lines.append(f"end-to-end {name}: " + " ".join(f"{k}={v}" for k, v in st.items()))
    for name, r in rec["runs"].items():
        lines.append(f"{name} (exit {r['exit']}): {r['summary']}")
        for header, asserts in r["assertions"].items():
            lines.append(f"  {header}: {' | '.join(a.strip() for a in asserts[:2])}")
    for g in rec["gaps"]:
        lines.append(f"GAP (a,b): {g}")
    for d in rec["deviations"]:
        lines.append(f"DEVIATION (a,b): {d}")
    for x in rec["findings"]:
        lines.append(f"FINDING outside the ten: {x}")
    for g in rec["c"]["gaps"]:
        lines.append(f"GAP (c): {g}")
    for n in rec["c"]["not_run"]:
        lines.append(f"NOT RUN (c): {n}")
    for d in rec["c"]["deviations"]:
        lines.append(f"DEVIATION (c): {d}")
    lines.append(f"VERDICT (a,b): {rec['verdict']}")
    lines.append(f"VERDICT (c): {rec['c']['verdict']}")
    lines.append(f"VERDICT: {overall(rec)}")
    return lines


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: verdict.py OUT", file=sys.stderr)
        return 3
    out = argv[1]
    rec = judge(out)
    rec["overall"] = overall(rec)
    with open(os.path.join(out, "verdict.json"), "w") as f:
        json.dump(rec, f, indent=1, sort_keys=True)
    print("\n".join(render(rec)))
    return {"AS EXPECTED": 0, "NOT AS EXPECTED": 2, "NOT RUN": 4}.get(rec["overall"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
