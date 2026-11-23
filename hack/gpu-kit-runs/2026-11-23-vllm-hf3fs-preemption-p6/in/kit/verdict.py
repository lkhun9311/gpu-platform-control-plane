"""Verdict for the vLLM HF3FS preemption kit p6: FIX alone, the PR head with gathers.patch, which waits only for gathers.

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt, OUT/STOPPED if present, and OUT/e2e-fix.log; a CONTROL log there is refused, since kit p6 runs none.
Writes OUT/verdict.json and prints pytest's summary line verbatim, the held/reused/hold_timed_out line, the page errors and any traceback.
It also prints each of vLLM's lines that name the available KV cache memory, so a NOT RUN on memory shows what LLM() had.
The per-run reading is kit p5's: the test file holds the GPU test alone, and only the "held-save page errors" line is judged.
The rules, in order:
  FINDING when FIX faults, fails its page comparison, fails before it other than on a precondition, or shows a held-save page error of 0.05 or more;
  INCOMPLETE when a log, the summary, CUDA or a run step is missing, the GPU test was skipped, or a CONTROL log is present;
  NOT RUN when FIX hit the KV memory, GPU memory or model load causes;
  INCONCLUSIVE when a precondition (save held, target preempted, a held block reused) is not met,
    when FIX passed without its hold timing out, or when a held-save page error is not 0.0;
  CONFIRMED when FIX passed, 1 test, with every held-save page error 0.0, every precondition met and hold_timed_out=True.
Exit status: 0 CONFIRMED, 2 FINDING, 3 INCOMPLETE, 4 NOT RUN, 5 INCONCLUSIVE.
"""

import json
import os
import re
import sys

TEST_FILE = "tests/v1/kv_connector/unit/test_hf3fs_preemption.py"
GPU_TEST = "TestHF3FSPreemptionEndToEnd::test_preempted_request_saves_its_own_kv"
# The file holds the GPU test alone, so each process runs exactly one test and there are no CPU tests to judge.
CPU_TESTS = ()
# Kit p6 runs FIX alone; CONTROL is kit p5's, unchanged by gathers.patch.
ARMS = ("fix",)
# The test asserts a page error under this.
ERROR_LIMIT = 0.05
ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")
# vLLM's worker logs "Available KV cache memory: X GiB", and its startup check names "the available KV cache memory (X GiB)".
KV_MEMORY_RE = re.compile(r"[Aa]vailable KV cache memory")
# pytest -q prints its summary without the "=" padding that -rA runs have, so both shapes are read.
SUMMARY_RE = re.compile(r"^=*\s*(\d+ [a-z]+(?:, \d+ [a-z]+)*) in ([0-9.]+)s(?: \([^)]*\))?\s*=*$")
COUNT_RE = re.compile(r"(\d+) (passed|failed|skipped|deselected|errors?|xfailed|xpassed|warnings?)")
# -s lets the prints follow pytest's progress characters on the same line, so these are searched, not matched.
HELD_RE = re.compile(r"held=\[([0-9, ]*)\] reused=\[([0-9, ]*)\] hold_timed_out=(True|False)")
# The test compares the pages read right after the held save completed, and prints them on this line.
ERRORS_RE = re.compile(r"held-save page errors: \[([^\]]*)\]")
# The pages at the end of the run, which a later save may have rewritten: printed, and never judged.
END_ERRORS_RE = re.compile(r"end-of-run page errors: \[([^\]]*)\]")
# Kits p1 to p3 judged this line; a log that has it comes from an older test and decides nothing here.
OLD_ERRORS_RE = re.compile(r"relative page errors: \[")
# Where in the test file the GPU test failed, from its short traceback.
FAIL_AT_RE = re.compile(r"^tests/v1/kv_connector/unit/test_hf3fs_preemption\.py:(\d+): in ")
RESULT_RE = re.compile(r"^(FAILED|ERROR) (\S+)")
# The GPU test's own section in FAILURES or ERRORS, up to the next section header or "=" banner.
GPU_HEADER_RE = re.compile(r"^_+ (?:ERROR at (?:setup|call|teardown) of )?TestHF3FSPreemptionEndToEnd\.test_preempted_request_saves_its_own_kv _+$")
OTHER_HEADER_RE = re.compile(r"^_+ [^_\s].* _+$|^=+ .* =+$")
# The test's precondition asserts, in the order it makes them.
PRECONDITIONS = (
    ("save held", "no save of the target was held"),
    ("target preempted", "the target was not preempted"),
    ("held block reused", "no held block was reused by the other request"),
)
# Harness causes, read from the traceback's ">" and E lines only, since captured logs name things like HF_HUB_OFFLINE on every run.
# An illegal memory access is not among them: it is a fault in the code under test.
HARNESS_CAUSES = (
    ("KV cache memory", re.compile(r"KV cache is needed, which is larger than the available KV cache memory")),
    ("GPU out of memory", re.compile(r"OutOfMemoryError|CUDA out of memory", re.I)),
    ("model download or offline load failure", re.compile(r"LocalEntryNotFoundError|Cannot find the requested files|couldn't connect to|RepositoryNotFound|GatedRepo")),
)


def ints(text):
    return [int(x) for x in re.findall(r"\d+", text)]


def arm_record(path, rc):
    """One arm's process: its summary, the CPU tests' results, and the GPU test's state and printed lines."""
    rec = {"exit": rc, "summary": None, "held_line": None, "errors": None, "traceback": [], "illegal_lines": [], "cpu_failed": [], "max_error": None, "kv_memory_lines": [], "end_errors": None, "old_errors_lines": [], "fail_at": None, "first_e": None, "summary_raw": None}
    if not os.path.exists(path):
        rec.update(gpu="incomplete", why="no log")
        return rec
    # newline="" keeps the carriage returns of progress bars, which text mode would turn into extra lines.
    lines = open(path, errors="replace", newline="").read().split("\n")
    summary = None
    for line in lines:
        m = SUMMARY_RE.match(line.strip())
        if m:
            summary = m.group(1)
            rec["summary"] = line.strip()
            # The line as pytest wrote it, which goes into the PR as it is.
            rec["summary_raw"] = line.rstrip("\r")
    counts = {}
    for n, word in COUNT_RE.findall(summary or ""):
        key = {"error": "errors", "warning": "warnings"}.get(word, word)
        counts[key] = counts.get(key, 0) + int(n)
    got = {k: v for k, v in counts.items() if k not in ("warnings", "deselected")}
    rec["counts"] = got
    bad = {}
    for line in lines:
        m = RESULT_RE.match(line)
        if m and m.group(2).startswith(TEST_FILE + "::"):
            bad[m.group(2)[len(TEST_FILE) + 2:]] = m.group(1)
    rec["cpu_failed"] = sorted(t for t in CPU_TESTS if t in bad)
    held = [m for m in (HELD_RE.search(x) for x in lines) if m]
    if held:
        m = held[-1]
        rec["held_line"] = m.group(0)
        rec["held"], rec["reused"], rec["hold_timed_out"] = ints(m.group(1)), ints(m.group(2)), m.group(3) == "True"
    errs = [m for m in (ERRORS_RE.search(x) for x in lines) if m]
    if errs:
        rec["errors"] = [float(x) for x in re.findall(r"[0-9.]+(?:e-?\d+)?", errs[-1].group(1))]
    ends = [m for m in (END_ERRORS_RE.search(x) for x in lines) if m]
    if ends:
        rec["end_errors"] = [float(x) for x in re.findall(r"[0-9.]+(?:e-?\d+)?", ends[-1].group(1))]
    rec["old_errors_lines"] = [f"{i}:{x.strip()}" for i, x in enumerate(lines, start=1) if OLD_ERRORS_RE.search(x)]
    section, current = [], False
    for line in lines:
        if GPU_HEADER_RE.match(line):
            current = True
            continue
        if current and OTHER_HEADER_RE.match(line):
            current = False
        if current:
            section.append(line)
    rec["traceback"] = section
    rec["fail_at"] = next((int(m.group(1)) for m in (FAIL_AT_RE.match(x) for x in section) if m), None)
    rec["illegal_lines"] = [f"{i}:{x}" for i, x in enumerate(lines, start=1) if ILLEGAL_RE.search(x)]
    rec["kv_memory_lines"] = [f"{i}:{x.strip()}" for i, x in enumerate(lines, start=1) if KV_MEMORY_RE.search(x)]
    tb = "\n".join(x for x in lines if x.startswith(("E ", ">")))
    first_e = next((x.strip() for x in section if x.startswith("E ")), None) or next((x.strip() for x in lines if x.startswith("E ")), None)
    harness = next((label for label, pattern in HARNESS_CAUSES if pattern.search(tb)), None)
    rec["first_e"] = first_e
    gpu_e = "\n".join(x for x in section if x.startswith("E "))
    precondition = next((name for name, text in PRECONDITIONS if text in gpu_e), None)
    gpu_bad = GPU_TEST in bad
    if rec["illegal_lines"]:
        # An illegal access is a fault, even when pytest died before its summary.
        rec.update(gpu="faulted", why="an illegal memory access in the log")
    elif harness:
        rec.update(gpu="not run", why=f"{harness}: {first_e}")
    elif summary is None or rc not in (0, 1):
        rec.update(gpu="incomplete", why=f"no summary line or an abnormal exit ({rc})")
    elif rec["old_errors_lines"]:
        rec.update(gpu="incomplete", why=f"the log has the older test's page errors line, which this kit does not judge: {rec['old_errors_lines'][0]}")
    elif got.get("skipped"):
        rec.update(gpu="incomplete", why="a test was skipped, and the GPU test skipped is not a result")
    elif sum(got.values()) != 1 + len(CPU_TESTS):
        rec.update(gpu="incomplete", why=f"the summary {got} does not count the file's {1 + len(CPU_TESTS)} tests")
    elif gpu_bad and precondition:
        rec.update(gpu="precondition", why=f"precondition not met: {precondition} ({first_e})")
    elif gpu_bad and rec["held_line"] and (not rec["held"] or not rec["reused"]):
        # The test prints the line only after its preconditions pass, so empty lists here mean the line is not the test's.
        rec.update(gpu="precondition", why=f"the held line shows no held or no reused block: {rec['held_line']}")
    elif gpu_bad and rec["held_line"] and rec["errors"]:
        # The page comparison is the only assert after the errors line, so a failure with it printed is that comparison.
        rec.update(gpu="mismatch", why=f"the page comparison failed, max error {max(rec['errors']):.4f}")
    elif gpu_bad:
        rec.update(gpu="failed", why=f"the GPU test {bad[GPU_TEST]} before its page comparison, at line {rec['fail_at']}: {first_e}")
    elif rec["held_line"] is None or rec["errors"] is None:
        # A pass that printed neither line ran without -s or not at all, so it shows nothing about the hold.
        rec.update(gpu="incomplete", why="the GPU test passed but its held line or page errors were not printed")
    elif not rec["held"] or not rec["reused"]:
        rec.update(gpu="precondition", why=f"the held line shows no held or no reused block: {rec['held_line']}")
    else:
        rec["gpu"] = "passed"
    rec["max_error"] = max(rec["errors"]) if rec["errors"] else None
    return rec


def judge(out):
    rec = {"gaps": [], "arms": {}}
    try:
        env = json.load(open(os.path.join(out, "env.json")))
        rec["env"] = env
        if env.get("cuda_available") is not True or not env.get("device_name"):
            rec["gaps"].append(f"torch did not see a named CUDA device (cuda_available={env.get('cuda_available')!r})")
    except (OSError, ValueError) as e:
        rec["gaps"].append(f"env.json unreadable: {e}")
    if os.path.exists(os.path.join(out, "STOPPED")):
        rec["gaps"].append("the run stopped early: " + open(os.path.join(out, "STOPPED")).read().strip())
    # A CONTROL arm has no place in kit p6, so its log means the run is not the one this verdict judges.
    if os.path.exists(os.path.join(out, "e2e-control.log")) or any(line.startswith("test-control ") for line in _status(out)):
        rec["gaps"].append("a CONTROL arm ran, and kit p6 runs FIX alone")
    rcs = {}
    for line in _status(out):
        m = re.match(r"^test-(\w+) exit=(-?\d+)", line)
        if m:
            rcs[m.group(1)] = int(m.group(2))
    fix = rec["arms"]["fix"] = arm_record(os.path.join(out, "e2e-fix.log"), rcs.get("fix"))
    if fix["gpu"] in ("faulted", "mismatch", "failed"):
        rec["verdict"] = "FINDING"
        rec["why"] = f"the fix: the GPU test {fix['gpu']}: {fix.get('why')}"
    elif fix["max_error"] is not None and fix["max_error"] >= ERROR_LIMIT:
        rec["verdict"] = "FINDING"
        rec["why"] = f"the fix: a held-save page error of {fix['max_error']!r}, at or above {ERROR_LIMIT}"
    elif rec["gaps"] or fix["gpu"] == "incomplete":
        rec["verdict"] = "INCOMPLETE"
        rec["why"] = "; ".join(rec["gaps"] + ([f"fix: {fix['why']}"] if fix["gpu"] == "incomplete" else []))
    elif fix["gpu"] == "not run":
        rec["verdict"] = "NOT RUN"
        rec["why"] = f"fix: {fix['why']}"
    elif fix["gpu"] == "precondition":
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = f"fix: {fix['why']}"
    elif fix["hold_timed_out"] is not True:
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = "FIX passed but its hold did not time out, so the pass did not come through the hook's wait"
    elif any(e != 0.0 for e in fix["errors"]):
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = f"FIX passed with held-save page errors {fix['errors']!r}, where kit p6 expects every one 0.0"
    else:
        rec["verdict"] = "CONFIRMED"
        rec["why"] = f"FIX passed its one test with every held-save page error 0.0 ({len(fix['errors'])} pages), every precondition met and hold_timed_out=True"
    return rec


def _status(out):
    path = os.path.join(out, "status.txt")
    return open(path).read().splitlines() if os.path.exists(path) else []


def render(rec):
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    for arm, p in rec["arms"].items():
        lines.append(f"{arm.upper()}: GPU test {p['gpu']} (exit {p.get('exit')}): {p.get('summary')}" + (f"; {p['why']}" if p.get("why") else ""))
        lines.append(f"  held line: {p.get('held_line')}")
        lines.append(f"  held-save page errors: {p.get('errors')}")
        lines.append(f"  end-of-run page errors (information only): {p.get('end_errors')}")
        lines.append(f"  pytest summary (verbatim): {p.get('summary_raw')}")
        lines.extend(f"  illegal: {x}" for x in p.get("illegal_lines", [])[:10])
        lines.extend(f"  kv memory: {x}" for x in p.get("kv_memory_lines", [])[:10])
        tb = [x for x in p.get("traceback", []) if x.strip()][:40]
        if tb:
            lines.append("  traceback of the GPU test:")
            lines.extend(f"    {x}" for x in tb)
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
