"""Unit checks for the vLLM #69058 kit r5's verdict.py, on the real CPU log, run r4's GPU log and logs built from it.

usage: python3 -I hack/vllm-69058-kit-check.py KIT_DIR FAKE_DIR
FAKE_DIR holds cpu-logs/e2e.log and gpu-r4-logs/a-2.log.
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

KIT, FAKES = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("verdict", os.path.join(KIT, "verdict.py"))
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)
CPU = os.path.join(FAKES, "cpu-logs", "e2e.log")
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
DIAG_SYNC = "(MainProcess pid=2429) WARNING 11-22 10:10:04 [hf3fs_connector.py:600] DIAG step forward sync ok"
DIAG_LATE = "(MainProcess pid=2429) WARNING 11-22 10:10:04 [hf3fs_connector.py:610] DIAG step start sync ok"
DIAG_OOR = "(MainProcess pid=2429) ERROR 11-22 10:10:03 [hf3fs_connector.py:305] DIAG save 6-aa block ids out of range: [40, 41, 99]"
DIAG_EARLY = "(MainProcess pid=2429) WARNING 11-22 10:10:03 [hf3fs_connector.py:310] DIAG save 6-aa pre-gather sync ok"


def with_diag(text):
    """Run r4's log with DIAG lines put into [fail]'s first captured stdout: two syncs and an out-of-range line before the fault, a sync after it."""
    lines = text.split("\n")
    k = R4_ILLEGAL - 1
    assert "illegal memory access" in lines[k], lines[k][:80]
    return "\n".join(lines[:k] + [DIAG_EARLY, DIAG_OOR, DIAG_SYNC] + [lines[k], DIAG_LATE] + lines[k + 1:])


def build(log=None, rc=1, env=GPU_ENV, stopped=None):
    d = tempfile.mkdtemp(prefix="v69058r5-")
    if log is not None:
        with open(os.path.join(d, "e2e.log"), "w", newline="") as f:
            f.write(log)
    with open(os.path.join(d, "status.txt"), "w") as f:
        f.write(f"test-e2e exit={rc} t=1\n" if rc is not None else "")
    if env is not None:
        with open(os.path.join(d, "env.json"), "w") as f:
            json.dump(env, f)
    if stopped:
        with open(os.path.join(d, "STOPPED"), "w") as f:
            f.write(stopped)
    return d


def judged(**kw):
    d = build(**kw)
    rec = V.judge(d)
    shutil.rmtree(d)
    return rec


# ---------------------------------------------------------------- the real logs
rec = judged(log=read(CPU), rc=0, env={"cuda_available": False, "device_name": None})
check("the real CPU log, both cases skipped, is INCOMPLETE", rec["verdict"] == "INCOMPLETE" and any("2 skipped" in g for g in rec["gaps"]))
p = V.parse(R4_TEXT)
check("run r4's log: the -q summary is read and [fail] is FAILED and ERROR", p["summary"]["line"].startswith("1 failed, 20 warnings, 1 error") and p["outcomes"]["fail"] == ["FAILED", "ERROR"])
check("run r4's log: [fail] has two sections, its teardown error and its failure", len(p["sections"]["fail"]) == 2 and p["sections"]["recompute"] == [])
r = V.case_record(p, "fail")
check("run r4's log: the first illegal access in time is the captured Triton error on line 166, not the teardown traceback above it",
      r["first_illegal"].startswith("166:") and "Task execution error: Triton Error [CUDA]: an illegal memory access" in r["first_illegal"])
check("run r4's log: the grep lines are numbered as grep -n numbers the file, Read operation failed on 162 and Failing on 164 included",
      any(g.startswith("162:") and "Read operation failed" in g for g in r["grep"]) and any(g.startswith("164:") and "Failing 1 request" in g for g in r["grep"]))
check("run r4's log: no DIAG sync line, so none is claimed", r["last_sync_before_illegal"] is None and r["out_of_range"] == [])
rec = judged(log=R4_TEXT)
check("run r4's log is INCOMPLETE here: it ran with -x, so [recompute] has no outcome, and it has no DIAG line",
      rec["verdict"] == "INCOMPLETE" and any("[recompute] has no outcome" in g for g in rec["gaps"]) and any("no DIAG line" in g for g in rec["gaps"]))
check("run r4's log: [recompute] is not called passed", rec["cases"]["recompute"]["outcome"] == "not run or unknown")

# ---------------------------------------------------------------- the DIAG extraction, on run r4's log with DIAG lines put in
d = V.parse(with_diag(R4_TEXT))
r = V.case_record(d, "fail")
check("the first illegal access moves to line 169 after three inserted lines", r["first_illegal"].startswith("169:"))
check("the last DIAG sync ok before it is the inserted one on line 168, not the earlier one on 166 or the later one after the fault",
      r["last_sync_before_illegal"] == f"168:{DIAG_SYNC}")
check("the DIAG save out-of-range line is reported with its line number", r["out_of_range"] == [f"167:{DIAG_OOR}"])
check("the grep lines hold every DIAG line, the late sync included", sum("DIAG" in g for g in r["grep"]) == 4)
# A traceback above the captured block mentions the fault first in the file but later in time.
check("the teardown traceback's E line, earlier in the file, is not taken as the first illegal access",
      not any(g.startswith(r["first_illegal"].split(":")[0] + ":E ") for g in r["grep"]))
flat = [f"{i}:{x}" for s in d["sections"]["fail"] for i, x in s if "illegal memory access" in x]
check("the file's own first illegal line is the teardown E line, which is why the captured block is read first", flat and flat[0].split(":")[0] != "169")
nocap = "\n".join(["_ TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[fail] _", DIAG_SYNC,
                   "E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered",
                   "=========================== short test summary info ============================",
                   "FAILED tests/x.py::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[fail]",
                   "FAILED tests/x.py::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[recompute]", "2 failed in 9.0s"])
r = V.case_record(V.parse(nocap), "fail")
check("without a captured block, the file's order gives the first illegal access and the sync before it",
      r["first_illegal"].startswith("3:") and r["last_sync_before_illegal"] == f"2:{DIAG_SYNC}")

# ---------------------------------------------------------------- the verdict
both = with_diag(R4_TEXT).replace("1 failed, 20 warnings, 1 error in 123.28s (0:02:03)", "2 failed, 20 warnings, 1 error in 250.00s (0:04:10)")
both = both.replace("=========================== short test summary info ============================",
                    "=========================== short test summary info ============================\n"
                    "FAILED tests/v1/kv_connector/unit/test_hf3fs_load_failure.py::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[recompute] - x")
rec = judged(log=both)
check("a log with both cases' outcomes and DIAG lines is COMPLETE", rec["verdict"] == "COMPLETE" and rec["cases"]["recompute"]["outcome"] == "FAILED")
check("[recompute] without a section says so", rec["cases"]["recompute"]["note"] == "no section of this case in the log")
with contextlib.redirect_stdout(io.StringIO()) as buf:
    print("\n".join(V.render(rec)))
out = buf.getvalue()
check("verdict.txt prints each case's first illegal access, last sync, out-of-range lines and grep lines",
      "case [fail]: FAILED+ERROR" in out and "  first illegal memory access: 169:" in out and f"  last DIAG sync ok before it: 168:{DIAG_SYNC}" in out
      and "  DIAG save out of range: ['167:" in out and "  grep -n 'DIAG|illegal|Failing|Read operation failed'" in out and "case [recompute]: FAILED" in out)
rec = judged(log="Loading: 10%\rLoading: 100%\n" + both)
check("judge reads a progress bar's carriage return as file bytes, so the first illegal access keeps grep's line number 170",
      rec["cases"]["fail"]["first_illegal"].startswith("170:"))
rec = judged(log="2 passed, 20 warnings in 210.00s (0:03:30)\n", rc=0)
check("both cases passing is COMPLETE, with nothing to extract and that said", rec["verdict"] == "COMPLETE"
      and rec["cases"]["fail"]["outcome"] == "passed" and "no captured output for a passing case" in rec["cases"]["fail"]["note"])
rec = judged(log="Fatal Python error: Aborted\n", rc=134)
check("a run that dies before its summary is INCOMPLETE", rec["verdict"] == "INCOMPLETE" and any("no pytest summary" in g for g in rec["gaps"]))
rec = judged(log=both, rc=124)
check("a run cut by its cap is INCOMPLETE", rec["verdict"] == "INCOMPLETE" and any("pytest exited 124" in g for g in rec["gaps"]))
rec = judged(log=both.replace("DIAG", "NOTE"))
check("a failed run with no DIAG line is INCOMPLETE, since the patch did not run", rec["verdict"] == "INCOMPLETE" and any("no DIAG line" in g for g in rec["gaps"]))
rec = judged(log=None)
check("no log is INCOMPLETE", rec["verdict"] == "INCOMPLETE" and "no e2e.log" in rec["gaps"])
rec = judged(log=both, env={"cuda_available": False, "device_name": None})
check("no CUDA is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
rec = judged(log=both, env=None)
check("no env.json is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
rec = judged(log=both, stopped="the budget ran out before test-e2e")
check("a STOPPED run is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
for name, kw, want, rc_want in (("COMPLETE", {"log": both}, "COMPLETE", 0), ("INCOMPLETE", {"log": None}, "INCOMPLETE", 3)):
    dd = build(**kw)
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc = V.main(["verdict.py", dd])
    saved = json.load(open(os.path.join(dd, "verdict.json")))
    check(f"main exits {rc_want} for {name} and writes it", rc == rc_want and saved["verdict"] == want and f"VERDICT: {want}\n" in buf.getvalue())
    shutil.rmtree(dd)

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
