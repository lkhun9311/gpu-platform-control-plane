"""Unit checks for the vLLM #69058 kit r6's verdict.py, on the real CPU log, runs r5 and r2's GPU logs, and built logs.

usage: python3 -I hack/vllm-69058-kit-check.py KIT_DIR FAKE_DIR
FAKE_DIR holds cpu-logs/e2e.log, gpu-r5-logs/e2e-fail.log and gpu-r2-logs/base-c.log.
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
PASS = "2 passed, 20 warnings in 140.00s (0:02:20)\n"


def judged(log, rc=0, env=GPU_ENV, stopped=None):
    d = tempfile.mkdtemp(prefix="v69058r6-")
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
    r = V.judge(d)
    shutil.rmtree(d)
    return r


# ---------------------------------------------------------------- the 2-passed rule
r = judged(PASS)
check("2 passed, exit 0, no illegal access: AS EXPECTED", r["verdict"] == "AS EXPECTED" and r["summary"].startswith("2 passed"))
r = judged("1 failed, 1 passed, 20 warnings in 150.00s\n", rc=1)
check("1 failed and 1 passed with no illegal access is a FINDING", r["verdict"] == "FINDING" and any("not 2 passed" in f for f in r["findings"]))
r = judged("1 passed, 20 warnings in 70.00s\n")
check("1 passed alone is a FINDING, since a case is missing", r["verdict"] == "FINDING")
r = judged("3 passed, 20 warnings in 70.00s\n")
check("3 passed is a FINDING, since the selection changed", r["verdict"] == "FINDING")
r = judged(PASS, rc=1)
check("2 passed with exit 1 is a FINDING", r["verdict"] == "FINDING")
r = judged("2 passed, 1 xpassed in 70.00s\n")
check("2 passed with anything more in the summary is a FINDING", r["verdict"] == "FINDING")

# ---------------------------------------------------------------- illegal-access detection
r5 = read("gpu-r5-logs", "e2e-fail.log")
r = judged(r5, rc=1)
check("run r5's [fail] log is a FINDING for its illegal memory access", r["verdict"] == "FINDING" and any("illegal memory access is in the log" in f for f in r["findings"]))
check("run r5's [fail] log: the first illegal access in time is a captured record of the fault", r["cases"]["fail"]["first_illegal"] is not None
      and "illegal memory access" in r["cases"]["fail"]["first_illegal"])
r = judged("(MainProcess pid=1) ERROR 11-22 21:00:04 [hf3fs_mock_client.py:110] Batch write error: CUDA error: an illegal memory access was encountered\n" + PASS)
check("2 passed with an illegal access anywhere in the log is still a FINDING", r["verdict"] == "FINDING" and r["illegal_lines"][0].startswith("1:"))
r = judged("Loading: 10%\rLoading: 100%\nE   RuntimeError: CUDA_ERROR_ILLEGAL_ADDRESS\n1 failed, 1 passed in 9.0s\n", rc=1)
check("the driver's CUDA_ERROR_ILLEGAL_ADDRESS counts, on grep's line 2 after a carriage return", r["verdict"] == "FINDING" and r["illegal_lines"][0].startswith("2:"))
r = judged("Fatal Python error: Aborted\n(MainProcess pid=1) ERROR 11-22 21:00:04 [x.py:1] CUDA error: an illegal memory access was encountered\n", rc=134)
check("an illegal access in a log that died before its summary is a FINDING, not INCOMPLETE", r["verdict"] == "FINDING")

# ---------------------------------------------------------------- harness causes and gaps
r2 = read("gpu-r2-logs", "base-c.log")
r = judged(r2, rc=1)
check("run r2's KV memory failure is NOT RUN for KV cache memory, not a FINDING", r["verdict"] == "NOT RUN" and r["not_run"].startswith("KV cache memory: E           ValueError"))
check("its captured HF_HUB_OFFLINE line does not make it a download failure", "download" not in r["not_run"])
r = judged(read("cpu-logs", "e2e.log"), env={"cuda_available": False, "device_name": None})
check("the real CPU log, both cases skipped, is INCOMPLETE", r["verdict"] == "INCOMPLETE" and any("skipped" in g for g in r["gaps"]))
r = judged("Fatal Python error: Aborted\n", rc=134)
check("a run that dies before its summary without an illegal access is INCOMPLETE", r["verdict"] == "INCOMPLETE")
r = judged(PASS, rc=124)
check("a run cut by its cap is INCOMPLETE", r["verdict"] == "INCOMPLETE")
r = judged(None)
check("no log is INCOMPLETE", r["verdict"] == "INCOMPLETE")
r = judged(PASS, env={"cuda_available": False, "device_name": None})
check("no CUDA is INCOMPLETE", r["verdict"] == "INCOMPLETE")
r = judged(PASS, stopped="the budget ran out before test-e2e")
check("a STOPPED run is INCOMPLETE", r["verdict"] == "INCOMPLETE")
for name, log, rc, want, rc_want in (("AS EXPECTED", PASS, 0, "AS EXPECTED", 0), ("FINDING", r5, 1, "FINDING", 2),
                                     ("NOT RUN", r2, 1, "NOT RUN", 4), ("INCOMPLETE", None, None, "INCOMPLETE", 3)):
    d = tempfile.mkdtemp(prefix="v69058r6-")
    if log is not None:
        with open(os.path.join(d, "e2e.log"), "w", newline="") as f:
            f.write(log)
    with open(os.path.join(d, "status.txt"), "w") as f:
        f.write(f"test-e2e exit={rc} t=1\n" if rc is not None else "")
    with open(os.path.join(d, "env.json"), "w") as f:
        json.dump(GPU_ENV, f)
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc_got = V.main(["verdict.py", d])
    saved = json.load(open(os.path.join(d, "verdict.json")))
    check(f"main exits {rc_want} for {name} and writes it", rc_got == rc_want and saved["verdict"] == want and f"VERDICT: {want}\n" in buf.getvalue())
    shutil.rmtree(d)

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
