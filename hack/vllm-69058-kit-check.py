"""Unit checks for the vLLM #69058 kit's verdict.py, on real CPU pytest logs and on built ones.

usage: python3 -I hack/vllm-69058-kit-check.py KIT_DIR CPU_LOG_DIR
Prints one ok or FAIL line per check and exits 1 if any failed.
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile

KIT, LOGS = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("verdict", os.path.join(KIT, "verdict.py"))
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)

failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


F = V.FILE
OLD = [
    F + "::TestHf3fsMockClient::test_init_creates_file",
    F + "::TestHf3fsMockClient::test_multiple_tensors_rw",
    F + "::TestHF3FSKVConnectorStats::test_clone_and_reset",
]
NEW = sorted(V.EXPECTED_A)
CUDA = V.CUDA_TEST
GPU_ENV = {"cuda_available": True, "device_name": "NVIDIA A10G", "torch": "t", "torch_cuda": "12.9", "triton": "3"}


def make_log(outcomes, deselected=0, summary=True, extra_counts=""):
    """A `pytest -rA` log in the shape of the real CPU logs, for the given {test id: outcome}."""
    lines = ["============================= test session starts ==============================", f"collected {len(outcomes) + deselected} items"]
    failed = [t for t, o in outcomes.items() if o == "FAILED"]
    if failed:
        lines.append("=================================== FAILURES ===================================")
        for t in failed:
            lines.append(f"_____ {t.split('::', 1)[1].replace('::', '.')} _____")
            lines.append("E       assert set() == {3, 5}")
    lines.append("=========================== short test summary info ============================")
    for t, o in outcomes.items():
        if o == "SKIPPED":
            lines.append(f"SKIPPED [1] {F}:384: a successful load scatters with a Triton kernel")
        else:
            lines.append(f"{o} {t}")
    if summary:
        parts = []
        for word, o in (("failed", "FAILED"), ("passed", "PASSED"), ("skipped", "SKIPPED"), ("errors", "ERROR")):
            n = sum(1 for x in outcomes.values() if x == o)
            if n:
                parts.append(f"{n} {word}")
        if deselected:
            parts.append(f"{deselected} deselected")
        body = ", ".join(parts) + extra_counts
        lines.append(f"============ {body}, 1 warning in 2.50s ============")
    return "\n".join(lines) + "\n"


def expected_runs():
    """The four runs as the fix claims they come out on a GPU."""
    return {
        "base-a": {t: "FAILED" for t in NEW},
        "fix-a": {t: "PASSED" for t in NEW},
        "base-b": {**{t: "PASSED" for t in OLD}, **{t: "FAILED" for t in NEW}},
        "fix-b": {t: "PASSED" for t in OLD + NEW},
    }


def build(runs=None, env=GPU_ENV, rcs=None, texts=None, stopped=None):
    """An OUT directory holding the given runs, env.json and status.txt."""
    d = tempfile.mkdtemp(prefix="v69058-")
    runs = expected_runs() if runs is None else runs
    texts = texts or {}
    status = []
    for name in ("base-a", "fix-a", "base-b", "fix-b"):
        if name in texts:
            text = texts[name]
        elif name in runs:
            text = make_log(runs[name], deselected=16 if name.endswith("-a") else 0)
        else:
            text = None
        if text is not None:
            with open(os.path.join(d, name + ".log"), "w") as f:
                f.write(text)
        if rcs and name in rcs:
            rc = rcs[name]
        elif name in runs:
            rc = 1 if any(o == "FAILED" for o in runs[name].values()) else 0
        else:
            rc = None
        if rc is not None:
            status.append(f"test-{name} exit={rc} t=1")
    with open(os.path.join(d, "status.txt"), "w") as f:
        f.write("\n".join(status) + "\n")
    if env is not None:
        with open(os.path.join(d, "env.json"), "w") as f:
            json.dump(env, f)
    if stopped:
        with open(os.path.join(d, "STOPPED"), "w") as f:
            f.write(stopped)
    return d


def incomplete_for(rec, text):
    """Whether rec is INCOMPLETE with a gap that names text, so the rule under test is the one that fired."""
    return rec["verdict"] == "INCOMPLETE" and any(text in g for g in rec["gaps"])


def verdict_of(d):
    rec = V.judge(d)
    shutil.rmtree(d)
    return rec


# ---------------------------------------------------------------- parsing the real CPU logs
base_a = V.parse_log(open(os.path.join(LOGS, "base-a.log")).read())
check("real base-a: the summary line and its time are read", base_a["summary"] and base_a["summary"]["seconds"] == 11.60)
check("real base-a: counts 5 failed, 1 skipped, 16 deselected, 1 warning", base_a["counts"] == {"failed": 5, "skipped": 1, "deselected": 16, "warnings": 1})
check("real base-a: the five failed tests are the six less the CUDA-only one", {t for t, o in base_a["outcomes"].items() if o == "FAILED"} == set(NEW) - {CUDA})
check("real base-a: the CUDA-only test appears only as a SKIPPED line", CUDA not in base_a["outcomes"] and len(base_a["skipped_lines"]) == 1)
heads = base_a["assertions"]
check("real base-a: each failure keeps its assertion line, the scheduler's two included",
      len(heads) == 5 and sum(a[0] == "E       assert set() == {3, 5}" for a in heads.values()) == 3
      and any("WAITING_FOR_REMOTE_KVS" in a[0] and "FINISHED_ERROR" in a[0] for a in heads.values())
      and any("{'id-2': 1} == {'id-2': 65}" in a[0] for a in heads.values()))
# A traceback's frame separator must not start a new header, or the assertion lines after it would be filed under it.
sep = V.parse_log("__ TestX.test_long[p] __\n_ _ _ _ _ _ _ _\nE   assert 1 == 2\n")
check("a '_ _ _' frame separator is not read as a failure header", list(sep["assertions"]) == ["TestX.test_long[p]"])
base_b = V.parse_log(open(os.path.join(LOGS, "base-b.log")).read())
check("real base-b: counts 9 failed, 12 passed, 1 skipped", (base_b["counts"].get("failed"), base_b["counts"].get("passed"), base_b["counts"].get("skipped")) == (9, 12, 1))
fix_b = V.parse_log(open(os.path.join(LOGS, "fix-b.log")).read())
check("real fix-b: counts 4 failed, 17 passed, 1 skipped", (fix_b["counts"].get("failed"), fix_b["counts"].get("passed"), fix_b["counts"].get("skipped")) == (4, 17, 1))
check("real fix-b: the failing mock-client assertion is kept", any("Write should succeed" in a for v in fix_b["assertions"].values() for a in v))
# The CPU runs are what the GPU run must not look like: a skipped CUDA test and no CUDA.
cpu = {n: open(os.path.join(LOGS, n + ".log")).read() for n in ("base-a", "fix-a", "base-b", "fix-b")}
rec = verdict_of(build(runs={}, texts=cpu, rcs={"base-a": 1, "fix-a": 0, "base-b": 1, "fix-b": 1}, env={"cuda_available": False, "device_name": None}))
check("the real CPU logs are INCOMPLETE, for the skip and for no CUDA", rec["verdict"] == "INCOMPLETE"
      and any("skipped" in g for g in rec["gaps"]) and any("did not see CUDA" in g for g in rec["gaps"]))
# On CPU the four mock-client tests fail on both sides, so the fix changes nothing outside the six.
check("the real CPU logs show no test outside the six that the fix changes", rec["findings"] == [])

# ---------------------------------------------------------------- the verdict rules
rec = verdict_of(build())
check("pass: the expected outcomes are AS EXPECTED", rec["verdict"] == "AS EXPECTED" and rec["cuda_only_test"] == {"base": "FAILED", "fix": "PASSED"} and rec["findings"] == [])
check("the six expected tests include both scheduler policies", len(NEW) == 6 and sum("TestHF3FSSchedulerLoadFailure" in t for t in NEW) == 2)

r = expected_runs(); r["base-b"][OLD[1]] = "FAILED"
rec = verdict_of(build(runs=r))
check("finding: an older test that fails on base and passes with the fix is named, and the verdict is not AS EXPECTED",
      rec["verdict"] == "NOT AS EXPECTED" and rec["findings"] == [f"{OLD[1]}: base FAILED, fix PASSED"])
with contextlib.redirect_stdout(io.StringIO()) as buf:
    print("\n".join(V.render(rec)))
check("finding: verdict.txt prints it on its own FINDING line", f"FINDING outside the six: {OLD[1]}: base FAILED, fix PASSED" in buf.getvalue())
r = expected_runs(); r["base-b"][OLD[1]] = "FAILED"
rec = verdict_of(build(runs=r, env=None))
check("finding: it is named even when a gap leaves the verdict INCOMPLETE", rec["verdict"] == "INCOMPLETE" and len(rec["findings"]) == 1)
r = expected_runs(); r["base-b"][OLD[1]] = "FAILED"; r["fix-b"][OLD[1]] = "FAILED"
rec = verdict_of(build(runs=r))
check("finding: an older test failing on both sides is a deviation, not a finding", rec["verdict"] == "NOT AS EXPECTED" and rec["findings"] == [])
r = expected_runs(); r["fix-a"][CUDA] = "FAILED"; r["fix-b"][CUDA] = "FAILED"
rec = verdict_of(build(runs=r))
check("fail: the CUDA-only test failing with the fix is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED" and rec["cuda_only_test"]["fix"] == "FAILED")
r = expected_runs(); r["base-a"][CUDA] = "PASSED"; r["base-b"][CUDA] = "PASSED"
rec = verdict_of(build(runs=r))
check("fail: the CUDA-only test passing on base is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED" and any("passed but expected to fail" in d for d in rec["deviations"]))
r = expected_runs(); r["fix-b"][OLD[1]] = "FAILED"
rec = verdict_of(build(runs=r))
check("fail: an older test failing in the whole file with the fix is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED" and any(OLD[1] in d for d in rec["deviations"]))
r = expected_runs(); r["base-b"][OLD[0]] = "FAILED"
rec = verdict_of(build(runs=r))
check("fail: an older test failing on base only is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED" and any("base-b: failed but expected to pass" in d for d in rec["deviations"]))
r = expected_runs(); r["base-a"][NEW[0]] = "PASSED"; r["base-b"][NEW[0]] = "PASSED"
rec = verdict_of(build(runs=r))
check("fail: a parametrized test passing on base is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED" and any("base-a: passed but expected to fail" in d for d in rec["deviations"]))

r = expected_runs(); r["fix-a"][CUDA] = "SKIPPED"
rec = verdict_of(build(runs=r))
check("skip: a skipped CUDA-only test is INCOMPLETE, not a pass", rec["verdict"] == "INCOMPLETE" and any("skipped" in g for g in rec["gaps"]))
r = expected_runs(); r["fix-b"][OLD[0]] = "SKIPPED"
rec = verdict_of(build(runs=r))
check("skip: a skip anywhere in the whole file is INCOMPLETE", incomplete_for(rec, "fix-b: 1 skipped"))
r = expected_runs(); del r["fix-a"]
rec = verdict_of(build(runs=r))
check("missing: a missing log is INCOMPLETE", rec["verdict"] == "INCOMPLETE" and any("fix-a: no log" in g for g in rec["gaps"]))
r = expected_runs()
rec = verdict_of(build(runs=r, texts={"fix-a": make_log(r["fix-a"], 16, summary=False)}))
check("missing: a log with no summary is INCOMPLETE", rec["verdict"] == "INCOMPLETE" and any("no pytest summary" in g for g in rec["gaps"]))
r = expected_runs(); r["fix-a"] = {t: "PASSED" for t in NEW if t != CUDA}; r["fix-b"] = {t: "PASSED" for t in OLD + NEW if t != CUDA}
rec = verdict_of(build(runs=r))
check("missing: a CUDA-only test that never ran, with no skip line, is INCOMPLETE", incomplete_for(rec, "fix-a: ran ") and rec["cuda_only_test"]["fix"] == "missing")
rec = verdict_of(build(rcs={"base-a": 1, "fix-a": 2, "base-b": 1, "fix-b": 0}))
check("missing: pytest exiting 2 (interrupted) is INCOMPLETE even with a summary", incomplete_for(rec, "fix-a: pytest exited 2, so"))
rec = verdict_of(build(rcs={"base-a": 1, "fix-a": 1, "base-b": 1, "fix-b": 0}))
check("missing: an exit code that disagrees with the outcomes is INCOMPLETE", incomplete_for(rec, "fix-a: pytest exited 1 with 0 failed"))
d = build(); open(os.path.join(d, "status.txt"), "w").close()
rec = verdict_of(d)
check("missing: no exit codes in status.txt is INCOMPLETE", incomplete_for(rec, "no exit code in status.txt"))
r = expected_runs(); r["fix-a"][CUDA] = "ERROR"; r["fix-b"][CUDA] = "ERROR"
rec = verdict_of(build(runs=r, rcs={"base-a": 1, "fix-a": 1, "base-b": 1, "fix-b": 1}))
check("error: a test that errors in setup is INCOMPLETE", incomplete_for(rec, "fix-a: 1 error(s)"))
check("error: an ERROR outcome line is a gap of its own", incomplete_for(rec, "outcomes other than PASSED or FAILED"))
rec = verdict_of(build(env={"cuda_available": False, "device_name": None}))
check("no CUDA: a run torch saw no GPU in is INCOMPLETE", incomplete_for(rec, "did not see CUDA"))
rec = verdict_of(build(env={"cuda_available": True, "device_name": ""}))
check("no CUDA: a run whose probe names no device is INCOMPLETE", incomplete_for(rec, "names no CUDA device"))
rec = verdict_of(build(env=None))
check("no env.json is INCOMPLETE", incomplete_for(rec, "env.json unreadable"))
r = expected_runs(); r["fix-b"] = {t: "PASSED" for t in OLD}; r["base-b"] = {t: "PASSED" for t in OLD}
rec = verdict_of(build(runs=r))
check("a whole-file run without the new tests is INCOMPLETE", incomplete_for(rec, "the whole file lacks"))
r = expected_runs()
rec = verdict_of(build(runs=r, texts={"fix-a": make_log(r["fix-a"], 16).replace("6 passed", "7 passed")}))
check("a summary that disagrees with the -rA lines is INCOMPLETE", incomplete_for(rec, "the summary counts"))
r = expected_runs()
rec = verdict_of(build(runs=r, texts={"fix-a": make_log(r["fix-a"], 16).replace(f"PASSED {CUDA}\n", f"PASSED {CUDA}\nPASSED {CUDA}\n")}))
check("a test reported twice is INCOMPLETE", incomplete_for(rec, "reported twice"))
r = expected_runs(); r["fix-b"] = {**{t: "PASSED" for t in OLD[:2]}, **{t: "PASSED" for t in NEW}}
rec = verdict_of(build(runs=r))
check("base and fix running different whole-file tests is INCOMPLETE", incomplete_for(rec, "b: base and fix ran different tests"))
rec = verdict_of(build(stopped="the budget ran out before test-fix-b"))
check("a STOPPED run is INCOMPLETE", incomplete_for(rec, "the run stopped early"))
r = expected_runs(); r["fix-a"][CUDA] = "XPASS"
rec = verdict_of(build(runs=r, texts={"fix-a": make_log(r["fix-a"], 16, extra_counts=", 1 xpassed")}))
check("an xpassed test is INCOMPLETE", incomplete_for(rec, "1 xpassed"))
rec = verdict_of(build(runs={k: {} for k in expected_runs()}, rcs={"base-a": 5, "fix-a": 5, "base-b": 5, "fix-b": 5}))
check("runs where no test ran are INCOMPLETE", incomplete_for(rec, "no test ran"))

# ---------------------------------------------------------------- main's exit status and files
for name, d, want in (("AS EXPECTED", build(), 0), ("NOT AS EXPECTED", build(runs={**expected_runs(), "fix-a": {t: "FAILED" for t in NEW}}), 2),
                      ("INCOMPLETE", build(env=None), 3)):
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc = V.main(["verdict.py", d])
    check(f"main exits {want} for {name}, prints it and writes verdict.json",
          rc == want and f"VERDICT: {name}\n" in buf.getvalue() and json.load(open(os.path.join(d, "verdict.json")))["verdict"] == name)
    shutil.rmtree(d)

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
