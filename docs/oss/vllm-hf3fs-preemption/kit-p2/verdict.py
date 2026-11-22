"""Verdict for the vLLM HF3FS preemption kit p2: the fix (FIX) against the base plus the test (CONTROL), one process per arm.

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt, OUT/STOPPED if present, and OUT/e2e-{control,fix}.log.
Writes OUT/verdict.json and prints, per arm, the summary line, the held/reused/hold_timed_out line, the page errors and any traceback.
It also prints each of vLLM's lines that name the available KV cache memory, so a NOT RUN on memory shows what LLM() had.
These are the rules of kit p1, unchanged.
The rules, in order:
  FINDING when FIX fails on its own terms: a CPU test fails, the GPU test faults or fails other than on a precondition,
    or FIX shows a page error of 0.05 or more;
  INCOMPLETE when a log, the summary, CUDA or a run step is missing, or the GPU test was skipped;
  NOT RUN when either arm hit the KV memory, GPU memory or model load causes;
  INCONCLUSIVE when a precondition (save held, target preempted, a held block reused) is not met in either arm,
    or CONTROL did not fail the page comparison with an error near 1 and hold_timed_out=False,
    or FIX passed without its hold timing out;
  CONFIRMED otherwise.
Exit status: 0 CONFIRMED, 2 FINDING, 3 INCOMPLETE, 4 NOT RUN, 5 INCONCLUSIVE.
"""

import json
import os
import re
import sys

TEST_FILE = "tests/v1/kv_connector/unit/test_hf3fs_preemption.py"
GPU_TEST = "TestHF3FSPreemptionEndToEnd::test_preempted_request_saves_its_own_kv"
CPU_TESTS = (
    "TestHF3FSHandlePreemptions::test_scheduler_passes_preempted_requests_to_the_worker",
    "TestHF3FSHandlePreemptions::test_waits_for_the_preempted_request_saves_only",
    "TestHF3FSHandlePreemptions::test_no_preemption_does_not_wait",
)
ARMS = ("control", "fix")
# The test asserts a page error under this.
ERROR_LIMIT = 0.05
# Another request's KV gives a relative error near 1, and batching noise stays far below this.
OTHER_KV_MIN = 0.5
ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")
# vLLM's worker logs "Available KV cache memory: X GiB", and its startup check names "the available KV cache memory (X GiB)".
KV_MEMORY_RE = re.compile(r"[Aa]vailable KV cache memory")
# pytest -q prints its summary without the "=" padding that -rA runs have, so both shapes are read.
SUMMARY_RE = re.compile(r"^=*\s*(\d+ [a-z]+(?:, \d+ [a-z]+)*) in ([0-9.]+)s(?: \([^)]*\))?\s*=*$")
COUNT_RE = re.compile(r"(\d+) (passed|failed|skipped|deselected|errors?|xfailed|xpassed|warnings?)")
# -s lets the prints follow pytest's progress characters on the same line, so these are searched, not matched.
HELD_RE = re.compile(r"held=\[([0-9, ]*)\] reused=\[([0-9, ]*)\] hold_timed_out=(True|False)")
ERRORS_RE = re.compile(r"relative page errors: \[([^\]]*)\]")
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
    rec = {"exit": rc, "summary": None, "held_line": None, "errors": None, "traceback": [], "illegal_lines": [], "cpu_failed": [], "max_error": None, "kv_memory_lines": []}
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
    rec["illegal_lines"] = [f"{i}:{x}" for i, x in enumerate(lines, start=1) if ILLEGAL_RE.search(x)]
    rec["kv_memory_lines"] = [f"{i}:{x.strip()}" for i, x in enumerate(lines, start=1) if KV_MEMORY_RE.search(x)]
    tb = "\n".join(x for x in lines if x.startswith(("E ", ">")))
    first_e = next((x.strip() for x in section if x.startswith("E ")), None) or next((x.strip() for x in lines if x.startswith("E ")), None)
    harness = next((label for label, pattern in HARNESS_CAUSES if pattern.search(tb)), None)
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
        rec.update(gpu="failed", why=f"the GPU test {bad[GPU_TEST]} before its page comparison: {first_e}")
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
    rcs = {}
    path = os.path.join(out, "status.txt")
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"^test-(\w+) exit=(-?\d+)", line)
            if m:
                rcs[m.group(1)] = int(m.group(2))
    for arm in ARMS:
        rec["arms"][arm] = arm_record(os.path.join(out, f"e2e-{arm}.log"), rcs.get(arm))
    control, fix = rec["arms"]["control"], rec["arms"]["fix"]
    states = (control["gpu"], fix["gpu"])
    finding = []
    if fix["cpu_failed"] and fix["summary"] is not None:
        finding.append("CPU tests failed: " + ", ".join(fix["cpu_failed"]))
    if fix["gpu"] in ("faulted", "failed", "mismatch"):
        finding.append(f"the GPU test {fix['gpu']}: {fix.get('why')}")
    elif fix["max_error"] is not None and fix["max_error"] >= ERROR_LIMIT:
        finding.append(f"a page error of {fix['max_error']:.4f}, at or above {ERROR_LIMIT}")
    if finding:
        rec["verdict"] = "FINDING"
        rec["why"] = "the fix: " + "; ".join(finding)
    elif rec["gaps"] or "incomplete" in states:
        rec["verdict"] = "INCOMPLETE"
        rec["why"] = "; ".join(f"{a}: {rec['arms'][a]['why']}" for a in ARMS if rec["arms"][a]["gpu"] == "incomplete") or None
    elif "not run" in states:
        rec["verdict"] = "NOT RUN"
        rec["why"] = "; ".join(f"{a}: {rec['arms'][a]['why']}" for a in ARMS if rec["arms"][a]["gpu"] == "not run")
    elif "precondition" in states:
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = "; ".join(f"{a}: {rec['arms'][a]['why']}" for a in ARMS if rec["arms"][a]["gpu"] == "precondition")
    elif control["gpu"] != "mismatch":
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = f"CONTROL's GPU test {control['gpu']} instead of failing the page comparison" + (f": {control['why']}" if control.get("why") else "")
    elif control["max_error"] < OTHER_KV_MIN:
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = f"CONTROL's max page error {control['max_error']:.4f} is under {OTHER_KV_MIN}, so it is not another request's KV"
    elif control["hold_timed_out"] is not False:
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = "CONTROL's hold timed out, so its save did not run after the other request reused the blocks"
    elif fix["hold_timed_out"] is not True:
        rec["verdict"] = "INCONCLUSIVE"
        rec["why"] = "FIX passed but its hold did not time out, so the pass did not come through the hook's wait"
    else:
        rec["verdict"] = "CONFIRMED"
        rec["why"] = (f"CONTROL failed the page comparison (max error {control['max_error']:.4f}) with every precondition met and hold_timed_out=False, "
                      f"and FIX passed (max error {fix['max_error']:.4f}, hold_timed_out=True)")
    return rec


def render(rec):
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    for arm, p in rec["arms"].items():
        lines.append(f"{arm.upper()}: GPU test {p['gpu']} (exit {p.get('exit')}): {p.get('summary')}" + (f"; {p['why']}" if p.get("why") else ""))
        lines.append(f"  held line: {p.get('held_line')}")
        lines.append(f"  page errors: {p.get('errors')}")
        lines.append(f"  CPU tests failed: {', '.join(p['cpu_failed']) or 'none'}")
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
