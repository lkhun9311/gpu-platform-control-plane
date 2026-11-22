"""Unit checks for the vLLM #69058 kit r5's verdict.py, on the real CPU logs, run r4's GPU log and logs built from it.

usage: python3 -I hack/vllm-69058-kit-check.py KIT_DIR FAKE_DIR
FAKE_DIR holds cpu-logs/e2e-{fail,recompute}.log and gpu-r4-logs/a-2.log.
Prints one ok or FAIL line per check and exits 1 if any failed.
"""

import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import sys
import tempfile

KIT, FAKES = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("verdict", os.path.join(KIT, "verdict.py"))
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)
R4 = os.path.join(FAKES, "gpu-r4-logs", "a-2.log")

failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


def read(path):
    # newline="" keeps the carriage returns of progress bars, as verdict.py reads them.
    return open(path, errors="replace", newline="").read()


GPU_ENV = {"cuda_available": True, "device_name": "NVIDIA A10G", "torch": "t", "torch_cuda": "13.0", "triton": "3"}
R4_TEXT = read(R4)
R4_LINES = R4_TEXT.split("\n")
# Run r4's [fail] captured stdout has its illegal memory access on the file's line 166, the saved-request Triton error.
R4_ILLEGAL = 166
RID = re.search(r"request ([\w-]+)$", R4_LINES[R4_ILLEGAL - 1]).group(1)
P = "(MainProcess pid=2429)"
DIAG_SAME = f"{P} WARNING 11-22 10:10:04 [hf3fs_connector.py:310] DIAG save {RID} pre-gather sync ok"
DIAG_OOR = f"{P} ERROR 11-22 10:10:04 [hf3fs_connector.py:305] DIAG save {RID} block ids out of range: [40, 41, 99]"
DIAG_SYNC = f"{P} WARNING 11-22 10:10:04 [hf3fs_connector.py:600] DIAG step forward sync ok"
DIAG_LATE = f"{P} WARNING 11-22 10:10:05 [hf3fs_connector.py:610] DIAG step start sync ok"


def with_diag(text):
    """Run r4's log with DIAG records in [fail]'s first captured stdout: the fault's request synced, an out-of-range line,
    another sync, then the fault, then a sync after it."""
    lines = text.split("\n")
    k = R4_ILLEGAL - 1
    assert "illegal memory access" in lines[k], lines[k][:80]
    return "\n".join(lines[:k] + [DIAG_SAME, DIAG_OOR, DIAG_SYNC] + [lines[k], DIAG_LATE] + lines[k + 1:])


def log(*captured, outcome="FAILED", phase="call", stream="stdout", tb=(), summary="1 failed in 100.0s", extra_blocks=()):
    """A one-case log for [fail] with a failure section whose captured blocks hold the given lines."""
    out = ["=================================== FAILURES ===================================",
           "______ TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[fail] _______", *tb]
    for ph, st, lines in [(phase, stream, captured), *extra_blocks]:
        out.append(f"----------------------------- Captured {st} {ph} -----------------------------")
        out.extend(lines)
    out += ["=========================== short test summary info ============================",
            f"{outcome} tests/v1/kv_connector/unit/test_hf3fs_load_failure.py::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[fail] - x",
            summary]
    return "\n".join(out) + "\n"


def rec(text, rc=1, case="fail"):
    d = tempfile.mkdtemp(prefix="v69058r5-")
    path = os.path.join(d, "x.log")
    with open(path, "w", newline="") as f:
        f.write(text)
    r = V.case_record(path, rc, case)
    shutil.rmtree(d)
    return r


def build(fail=None, recompute=None, rcs=None, env=GPU_ENV, stopped=None):
    d = tempfile.mkdtemp(prefix="v69058r5-")
    status = []
    for case, text in (("fail", fail), ("recompute", recompute)):
        if text is not None:
            with open(os.path.join(d, f"e2e-{case}.log"), "w", newline="") as f:
                f.write(text)
            status.append(f"test-{case} exit={(rcs or {}).get(case, 1)} t=1")
    with open(os.path.join(d, "status.txt"), "w") as f:
        f.write("\n".join(status) + "\n")
    if env is not None:
        with open(os.path.join(d, "env.json"), "w") as f:
            json.dump(env, f)
    if stopped:
        with open(os.path.join(d, "STOPPED"), "w") as f:
            f.write(stopped)
    return d


def judged(**kw):
    d = build(**kw)
    r = V.judge(d)
    shutil.rmtree(d)
    return r


GOOD = with_diag(R4_TEXT)
FLOW = [f"{P} WARNING 11-22 10:00:00 [hf3fs_connector.py:610] DIAG step start sync ok",
        f"{P} WARNING 11-22 10:00:00 [hf3fs_connector.py:420] DIAG load 7-bb read failed, block ids [1]",
        f"{P} ERROR 11-22 10:00:00 [hf3fs_connector.py:458] Read operation failed for Loaded request 7-bb"]

# ---------------------------------------------------------------- the real logs
for case in ("fail", "recompute"):
    r = rec(read(os.path.join(FAKES, "cpu-logs", f"e2e-{case}.log")), rc=0, case=case)
    check(f"the real CPU log of [{case}], skipped, is a gap", any("skipped" in g for g in r["gaps"]))
r = rec(R4_TEXT)
check("run r4's log: [fail] is FAILED and ERROR, its first illegal access in time is line 166", r["outcome"] == "FAILED+ERROR" and r["first_illegal"].startswith("166:"))
check("run r4's log: the fault names its saved request", r["fault_request"] == RID)
check("run r4's log: with no DIAG record it is a gap, though it reached the failed read", any("no DIAG record" in g for g in r["gaps"]) and not any("failed-read" in g for g in r["gaps"]))
check("run r4's log: the grep runs over the whole file as grep -n numbers it, the read failure on 162 and the scheduler's Failing on 164",
      any(g.startswith("162:") and "Read operation failed" in g for g in r["grep"]) and any(g.startswith("164:") and "Failing 1 request" in g for g in r["grep"]))

# ---------------------------------------------------------------- the extraction on run r4's log with DIAG records put in
r = rec(GOOD)
check("with DIAG records: the first illegal access moves to line 169 and the case has no gap", r["first_illegal"].startswith("169:") and r["gaps"] == [])
check("the last DIAG sync ok before it is the record on 168, not the one after the fault", r["last_sync_before_illegal"] == f"168:{DIAG_SYNC}")
check("the last sync for the fault's own request is the record on 166, not the later sync of another stage", r["last_sync_same_request"] == f"166:{DIAG_SAME}")
check("the out-of-range record is reported", r["out_of_range"] == [f"167:{DIAG_OOR}"])

# Finding 1: --tb=long prints source code, and DIAG text there is not a record.
src = ["", "    def _step(self):", ">       torch.cuda.synchronize()", '        logger.warning("DIAG step start sync ok")',
       "E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered"]
r = rec(log(FLOW[2], f"{P} ERROR 11-22 10:00:01 [x.py:1] Task execution error: CUDA error: an illegal memory access for Saved request 6-aa", tb=src))
check("a DIAG line in pytest's traceback source is not a record: no DIAG record is a gap and no sync is claimed",
      any("no DIAG record" in g for g in r["gaps"]) and r["last_sync_before_illegal"] is None)
# A Python traceback captured on stderr prints source too, inside a capture block.
py_tb = ["Traceback (most recent call last):", '  File "/x/hf3fs_connector.py", line 611, in _step',
         '    logger.warning("DIAG step start sync ok")', "RuntimeError: CUDA error: an illegal memory access was encountered"]
r = rec(log(FLOW[2], extra_blocks=[("call", "stderr", py_tb)]))
check("a DIAG line in a captured Python traceback's source is not a record either",
      any("no DIAG record" in g for g in r["gaps"]) and r["last_sync_before_illegal"] is None)
r = rec(log(*FLOW, f"{P} ERROR 11-22 10:00:01 [x.py:1] Task execution error: CUDA error: an illegal memory access for Saved request 6-aa", tb=src))
check("the same log with a real DIAG record is decided on the record", r["gaps"] == [] and r["last_sync_before_illegal"].endswith("DIAG step start sync ok"))

# Finding 3: the first illegal access in time, across stdout and stderr and across phases.
sticky = f"{P} ERROR 11-22 10:00:03 [x.py:1] Task execution error: CUDA error: an illegal memory access (sticky) for Saved request 6-aa"
orig = f"{P} ERROR 11-22 10:00:01 [y.py:2] Task execution error: CUDA error: an illegal memory access (origin) for Saved request 6-aa"
later_sync = f"{P} WARNING 11-22 10:00:02 [hf3fs_connector.py:600] DIAG step forward sync ok"
r = rec(log(*FLOW, later_sync, sticky, extra_blocks=[("call", "stderr", [orig])]))
check("an earlier fault on stderr beats a later one on stdout, though stdout prints first", "(origin)" in r["first_illegal"])
check("a sync logged after the true first fault is not reported as the sync before it", r["last_sync_before_illegal"].endswith(FLOW[0][-40:]))
r = rec(log(f"{P} ERROR 11-22 10:00:09 [x.py:1] teardown: CUDA error: an illegal memory access (teardown)", phase="teardown",
            extra_blocks=[("call", "log", ["WARNING  vllm.hf3fs:hf3fs_connector.py:610 DIAG step start sync ok",
                                           "ERROR    vllm.hf3fs:hf3fs_connector.py:458 Read operation failed for Loaded request 7-bb",
                                                      "ERROR    vllm.hf3fs:hf3fs_connector.py:458 CUDA error: an illegal memory access (origin)"])]))
check("a fault in pytest's untimed call-phase log capture beats a timed teardown fault printed first in the file", "(origin)" in r["first_illegal"])
r = rec(log(*FLOW, sticky, extra_blocks=[("call", "stderr", ["Traceback (most recent call last):", "RuntimeError: CUDA error: an illegal memory access (untimed)"])]))
check("an untimed traceback on stderr does not jump ahead of a timed record of the fault", "(sticky)" in r["first_illegal"])

# Finding 6: a stray DIAG record is not enough; the case must reach the failed read.
r = rec(log(FLOW[0], f"{P} ERROR 11-22 10:00:01 [x.py:1] RuntimeError: unrelated init failure"))
check("a failed case with a DIAG record but no failed read is a gap", any("never reached the failure" in g for g in r["gaps"]))
r = rec(log(FLOW[0], f"{P} WARNING 11-22 10:00:00 [hf3fs_connector.py:420] DIAG load 7-bb read failed, block ids [1]"))
check("the patch's own failed-read record counts as reaching it", not any("never reached" in g for g in r["gaps"]))

# ---------------------------------------------------------------- the per-case and run gaps
r = rec("1 passed, 20 warnings in 110.0s\n", rc=0)
check("a passing case has no gap and its note carries the patch caution", r["gaps"] == [] and r["outcome"] == "passed" and "synchronize() calls, which change timing" in r["note"])
r = rec("Fatal Python error: Aborted\n", rc=134)
check("a case that dies before its summary is a gap", any("no pytest summary" in g for g in r["gaps"]))
r = rec(GOOD, rc=124)
check("a case cut by its cap is a gap", any("pytest exited 124" in g for g in r["gaps"]))
r = rec("1 skipped in 0.1s\n", rc=0)
check("a skipped case is a gap", any("skipped" in g for g in r["gaps"]))
r = rec("2 passed in 0.1s\n", rc=0)
check("a summary that does not give this case's outcome is a gap", r["outcome"] == "unknown" and any("does not give" in g for g in r["gaps"]))
r = rec(GOOD, case="recompute")
check("[recompute]'s record does not take [fail]'s sections", r["first_illegal"] is None or "(from the traceback" in str(r["first_illegal"]))

ok = judged(fail=GOOD, recompute=GOOD.replace("[fail]", "[recompute]"))
check("both cases with their own DIAG trail are COMPLETE, and the result names both as faulted",
      ok["verdict"] == "COMPLETE" and ok["result"] == "illegal memory access in [fail], [recompute]")
clean = judged(fail="1 passed, 20 warnings in 110.0s\n", recompute="1 passed, 20 warnings in 110.0s\n", rcs={"fail": 0, "recompute": 0})
check("two passing cases are COMPLETE, but the result says no fault under the patch and that this does not show it gone",
      clean["verdict"] == "COMPLETE" and clean["result"].startswith("no illegal memory access in either case under the diagnostic patch, which does not show the fault gone")
      and "RESULT: no illegal memory access in either case" in "\n".join(V.render(clean)))
r = judged(fail=GOOD, recompute=None)
check("a case with no log is INCOMPLETE", r["verdict"] == "INCOMPLETE" and "case [recompute]: no log" in r["gaps"])
r = judged(fail=GOOD, recompute=GOOD.replace("[fail]", "[recompute]"), env={"cuda_available": False, "device_name": None})
check("no CUDA is INCOMPLETE", r["verdict"] == "INCOMPLETE")
r = judged(fail=GOOD, recompute=GOOD.replace("[fail]", "[recompute]"), env=None)
check("no env.json is INCOMPLETE", r["verdict"] == "INCOMPLETE")
r = judged(fail=GOOD, recompute=GOOD.replace("[fail]", "[recompute]"), stopped="the budget ran out before test-recompute")
check("a STOPPED run is INCOMPLETE", r["verdict"] == "INCOMPLETE")
r = judged(fail="Loading: 10%\rLoading: 100%\n" + GOOD, recompute=GOOD.replace("[fail]", "[recompute]"))
check("judge reads a progress bar's carriage return as file bytes, so the first illegal access keeps grep's line number 170",
      r["cases"]["fail"]["first_illegal"].startswith("170:"))
with contextlib.redirect_stdout(io.StringIO()) as buf:
    print("\n".join(V.render(ok)))
out = buf.getvalue()
check("verdict.txt prints the caution, and per case its process, first fault, both syncs, out-of-range lines and grep lines",
      out.startswith("gpu: ") and "caution: the patch adds device-wide torch.cuda.synchronize()" in out and "case [fail] (its own process, exit 1): FAILED+ERROR" in out
      and f"  last DIAG sync ok before it: 168:{DIAG_SYNC}" in out and f"  last DIAG sync ok before it for request {RID}: 166:{DIAG_SAME}" in out
      and "  DIAG save out of range: ['167:" in out and "  grep -n 'DIAG|illegal|Failing|Read operation failed' e2e-recompute.log" in out
      and "note: a sync line marks where the fault was observed, not where it began" in out)
for name, kw, want, rc_want in (("COMPLETE", {"fail": GOOD, "recompute": GOOD.replace("[fail]", "[recompute]")}, "COMPLETE", 0),
                                ("INCOMPLETE", {"fail": None, "recompute": None}, "INCOMPLETE", 3)):
    dd = build(**kw)
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc = V.main(["verdict.py", dd])
    saved = json.load(open(os.path.join(dd, "verdict.json")))
    check(f"main exits {rc_want} for {name} and writes it", rc == rc_want and saved["verdict"] == want and f"VERDICT: {want}\n" in buf.getvalue())
    shutil.rmtree(dd)

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
