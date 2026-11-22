"""Unit checks for the vLLM #69058 kit r6's verdict.py, on the real CPU logs, runs r5 and r2's GPU logs, and built logs.

usage: python3 -I hack/vllm-69058-kit-check.py KIT_DIR FAKE_DIR
FAKE_DIR holds cpu-logs/e2e-{control,fix}-{fail,recompute}.log, gpu-r5-logs/e2e-fail.log and gpu-r2-logs/base-c.log.
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

failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


def read(*parts):
    # newline="" keeps the carriage returns of progress bars, as verdict.py reads them.
    return open(os.path.join(FAKES, *parts), errors="replace", newline="").read()


GPU_ENV = {"cuda_available": True, "device_name": "NVIDIA A10G", "torch": "t", "torch_cuda": "13.0", "triton": "3"}
PASS = "1 passed, 20 warnings in 9.00s\n"
R5 = read("gpu-r5-logs", "e2e-fail.log")
R2 = read("gpu-r2-logs", "base-c.log")
FAIL = "=================================== FAILURES ===================================\nE   assert [2] == [3]\n1 failed, 20 warnings in 9.00s\n"
# The expected GPU outcome: CONTROL [fail] faults as run r5's [fail] did, everything else passes.
GOOD = {("control", "fail"): (R5, 1), ("fix", "fail"): (PASS, 0), ("control", "recompute"): (PASS, 0), ("fix", "recompute"): (PASS, 0)}


def judged(runs=None, env=GPU_ENV, stopped=None, **changes):
    """The verdict on OUT built from {(arm, case): (log or None, exit)}; changes override entries as arm_case=(log, exit)."""
    runs = dict(GOOD if runs is None else runs)
    for k, v in changes.items():
        arm, case = k.split("_")
        runs[(arm, case)] = v
    d = tempfile.mkdtemp(prefix="v69058r6-")
    status = []
    for (arm, case), (log, rc) in runs.items():
        if log is not None:
            with open(os.path.join(d, f"e2e-{arm}-{case}.log"), "w", newline="") as f:
                f.write(log)
        if rc is not None:
            status.append(f"test-{arm}-{case} exit={rc} t=1")
    with open(os.path.join(d, "status.txt"), "w") as f:
        f.write("\n".join(status) + "\n")
    if env is not None:
        with open(os.path.join(d, "env.json"), "w") as f:
            json.dump(env, f)
    if stopped:
        with open(os.path.join(d, "STOPPED"), "w") as f:
            f.write(stopped)
    r = V.judge(d)
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc_main = V.main(["verdict.py", d])
    r["_rc"], r["_text"] = rc_main, buf.getvalue()
    shutil.rmtree(d)
    return r


# ---------------------------------------------------------------- the overall rules
r = judged()
check("CONFIRMED: FIX passes both, CONTROL [fail] faults; exit 0", r["verdict"] == "CONFIRMED" and r["_rc"] == 0)
check("the confirmed run's CONTROL [fail] is faulted with its first illegal access in time", r["runs"]["control [fail]"]["state"] == "faulted"
      and r["runs"]["control [fail]"]["first_illegal"] and "illegal memory access" in r["runs"]["control [fail]"]["first_illegal"])
r = judged(control_fail=(PASS, 0))
check("INCONCLUSIVE: FIX passes both but CONTROL [fail] passes too; exit 5", r["verdict"] == "INCONCLUSIVE" and r["_rc"] == 5 and "passed instead of faulting" in r["why"])
r = judged(control_fail=(FAIL, 1))
check("INCONCLUSIVE: CONTROL [fail] failing without an illegal access does not confirm", r["verdict"] == "INCONCLUSIVE" and "failed instead of faulting" in r["why"])
r = judged(fix_fail=(R5, 1))
check("FINDING: FIX [fail] faulting is a finding; exit 2", r["verdict"] == "FINDING" and r["_rc"] == 2 and "[fail] faulted" in r["why"])
r = judged(fix_recompute=(FAIL, 1))
check("FINDING: FIX [recompute] failing without a fault is a finding", r["verdict"] == "FINDING" and "[recompute] failed" in r["why"])
r = judged(fix_recompute=("(MainProcess pid=1) ERROR 11-22 21:00:04 [x.py:1] CUDA error: an illegal memory access was encountered\n" + PASS, 0))
check("FINDING: FIX passing with an illegal access in its log is still a finding", r["verdict"] == "FINDING" and "[recompute] faulted" in r["why"])
r = judged(fix_fail=("2 passed in 9.0s\n", 0))
check("FINDING: a FIX process that ran other than its one case is a finding", r["verdict"] == "FINDING")
r = judged(fix_fail=(PASS, 1))
check("FINDING: FIX 1 passed with exit 1 is a finding", r["verdict"] == "FINDING")
r = judged(control_recompute=(R5, 1))
check("CONTROL [recompute] faulting is recorded and decides nothing", r["verdict"] == "CONFIRMED" and r["runs"]["control [recompute]"]["state"] == "faulted")
r = judged(control_recompute=(None, None))
check("CONTROL [recompute] missing decides nothing either", r["verdict"] == "CONFIRMED")
r = judged(fix_fail=(R5, 1), env=None)
check("a FINDING outranks a gap", r["verdict"] == "FINDING")

# ---------------------------------------------------------------- harness causes and gaps
r = judged(fix_fail=(R2, 1))
check("NOT RUN: FIX [fail] with run r2's KV memory failure; exit 4", r["verdict"] == "NOT RUN" and r["_rc"] == 4
      and r["runs"]["fix [fail]"]["why"].startswith("KV cache memory: E           ValueError"))
r = judged(control_fail=(R2, 1))
check("NOT RUN: CONTROL [fail] with a harness failure cannot confirm or refute", r["verdict"] == "NOT RUN")
captured = ">       assert retry.token_ids == cold.token_ids\nE   assert [2] == [3]\n----- Captured log call -----\n" \
           "WARNING  huggingface_hub:_http.py:1 Cannot find the requested files in the disk cache, using the local snapshot\n1 failed in 9.0s\n"
r = judged(fix_recompute=(captured, 1))
check("a captured log line that looks like a harness cause does not turn a FIX failure into NOT RUN", r["verdict"] == "FINDING")
for arm, case in (("fix", "fail"), ("fix", "recompute"), ("control", "fail")):
    r = judged(**{f"{arm}_{case}": (None, None)})
    check(f"INCOMPLETE: no {arm.upper()} [{case}] log; exit 3", r["verdict"] == "INCOMPLETE" and r["_rc"] == 3)
r = judged(fix_recompute=("Fatal Python error: Aborted\n", 134))
check("INCOMPLETE: a FIX process that dies before its summary without a fault", r["verdict"] == "INCOMPLETE")
r = judged(fix_recompute=(PASS, 124))
check("INCOMPLETE: a FIX process cut by its cap", r["verdict"] == "INCOMPLETE")
cpu = {(a, c): (read("cpu-logs", f"e2e-{a}-{c}.log"), 0) for a, c in V.RUNS}
r = judged(runs=cpu, env={"cuda_available": False, "device_name": None})
check("INCOMPLETE: the real CPU logs, every case skipped", r["verdict"] == "INCOMPLETE" and r["runs"]["fix [fail]"]["state"] == "incomplete")
r = judged(env={"cuda_available": False, "device_name": None})
check("INCOMPLETE: no CUDA", r["verdict"] == "INCOMPLETE")
r = judged(stopped="the budget ran out before test-fix-recompute")
check("INCOMPLETE: a STOPPED run", r["verdict"] == "INCOMPLETE")
r = judged(control_fail=("Loading: 10%\rLoading: 100%\nE   RuntimeError: CUDA_ERROR_ILLEGAL_ADDRESS\n1 failed in 9.0s\n", 1))
check("the driver's CUDA_ERROR_ILLEGAL_ADDRESS counts, on grep's line 2 after a carriage return", r["verdict"] == "CONFIRMED"
      and r["runs"]["control [fail]"]["illegal_lines"][0].startswith("2:"))

# ---------------------------------------------------------------- the printout
r = judged()
t = r["_text"]
check("verdict.txt prints every process's summary and the illegal-access lines, with CONTROL's roles named",
      "control [fail] (expected to fault): faulted (exit 1): 1 failed, 20 warnings, 1 error" in t and "fix [fail]: passed (exit 0): 1 passed, 20 warnings in 9.00s" in t
      and "control [recompute] (recorded, decides nothing): passed" in t and "illegal memory access" in t and t.rstrip().endswith("VERDICT: CONFIRMED"))

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
