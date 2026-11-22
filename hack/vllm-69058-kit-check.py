"""Unit checks for the vLLM #69058 kit r4's verdict.py, on real CPU logs of both arms, runs r2 and r3's GPU logs, and built ones.

usage: python3 -I hack/vllm-69058-kit-check.py KIT_DIR FAKE_DIR
FAKE_DIR holds cpu-logs/{a,b}-{1,2}.log, gpu-r2-logs/base-c.log and gpu-r3-logs/fix-c.log.
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
CPU = os.path.join(FAKES, "cpu-logs")
R2 = os.path.join(FAKES, "gpu-r2-logs", "base-c.log")
R3 = os.path.join(FAKES, "gpu-r3-logs", "fix-c.log")

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
STEP1_A = "3 failed, 1 passed, 2 deselected, 1 warning in 7.10s\n"
STEP1_B = "4 passed, 2 deselected, 1 warning in 6.85s\n"
STEP2_PASS = "2 passed, 20 warnings in 120.48s (0:02:00)\n"


def build(logs=None, rcs=None, env=GPU_ENV, stopped=None):
    """An OUT directory with the given {name: text} logs, their exit codes and env.json."""
    d = tempfile.mkdtemp(prefix="v69058r4-")
    logs = {"a-1": STEP1_A, "a-2": STEP2_PASS, "b-1": STEP1_B, "b-2": STEP2_PASS} if logs is None else logs
    default_rc = {"a-1": 1, "a-2": 0, "b-1": 0, "b-2": 0}
    rcs = {**default_rc, **(rcs or {})}
    for name, text in logs.items():
        if text is not None:
            with open(os.path.join(d, name + ".log"), "w") as f:
                f.write(text)
    with open(os.path.join(d, "status.txt"), "w") as f:
        f.write("".join(f"test-{n} exit={rc} t=1\n" for n, rc in rcs.items() if rc is not None))
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


def with_logs(**changes):
    logs = {"a-1": STEP1_A, "a-2": STEP2_PASS, "b-1": STEP1_B, "b-2": STEP2_PASS}
    logs.update(changes)
    return logs


# ---------------------------------------------------------------- the real CPU logs of both arms
for arm, want in (("a", {"failed": 3, "passed": 1}), ("b", {"passed": 4})):
    r = V.parse_log(read(os.path.join(CPU, f"{arm}-1.log")))
    s1 = V.judge_step1(arm, r, 1 if arm == "a" else 0)
    check(f"real CPU {arm}-1: the -q summary without '=' padding is read, counts {want}", s1["state"] == "AS EXPECTED" and s1["counts"] == want)
r = V.parse_log(read(os.path.join(CPU, "a-1.log")))
check("real CPU a-1: the three failed tests are named", len(r["failed"]) == 3 and all("TestHF3FSSchedulerLoadFailure" in t for t in r["failed"]))
for arm in ("a", "b"):
    s2 = V.judge_step2(V.parse_log(read(os.path.join(CPU, f"{arm}-2.log"))), 0)
    check(f"real CPU {arm}-2: both end-to-end cases skipped without CUDA is INCOMPLETE, with no illegal access", s2["state"] == "INCOMPLETE" and s2["illegal_access"] is None)

# ---------------------------------------------------------------- run r3's real illegal memory access
r3 = V.parse_log(read(R3))
ia = V.extract_illegal(r3["lines"])
check("r3 GPU log: the first illegal memory access is at the file's line 1117, as grep numbers it", ia is not None and ia["line_no"] == 1117)
check("r3 GPU log: its frame is the mock client's logged site, hf3fs_mock_client.py:110", ia["frame"] == "hf3fs_mock_client.py:110" and ia["method"] == "logged record")
check("r3 GPU log: the extracted block keeps the driver's CUDA_ERROR_ILLEGAL_ADDRESS line", any("CUDA_ERROR_ILLEGAL_ADDRESS" in x and "cuMemcpyDtoHAsync_v2" in x for x in ia["block"]))
s2 = V.judge_step2(r3, 1)
check("r3 GPU log: classified as the result 'CUDA illegal memory access', never a harness failure", s2["state"] == "RESULT" and s2["cause"] == "CUDA illegal memory access")
check("r3 GPU log read in text mode would number lines differently, which is why logs are read with newline=''",
      V.extract_illegal(V.parse_log(open(R3, errors="replace").read())["lines"])["line_no"] != 1117)

# ---------------------------------------------------------------- run r2's real KV memory failure, kept from r3
s2 = V.judge_step2(V.parse_log(read(R2)), 1)
check("r2 GPU log: still NOT RUN for KV cache memory", s2["state"] == "NOT RUN" and s2["cause"].startswith("KV cache memory: E           ValueError: To serve"))
check("r2 GPU log: not labelled a download failure by its captured HF_HUB_OFFLINE line", "download" not in s2["cause"])

# ---------------------------------------------------------------- the other illegal-access shapes
tb = ["noise", "Traceback (most recent call last):", '  File "/x/hf3fs_connector.py", line 512, in _execute_save_task', "    a()",
      '  File "/x/gather_scatter_helper.py", line 141, in gather', "    k()", "torch.AcceleratorError: CUDA error: an illegal memory access was encountered"]
ia = V.extract_illegal(tb)
check("a Python traceback gives its innermost frame, the launch site under CUDA_LAUNCH_BLOCKING",
      ia["frame"] == "/x/gather_scatter_helper.py:141 in gather" and ia["method"] == "python traceback" and ia["line_no"] == 7)
pt = ["_ TestX.test[fail] _", ">       torch.cuda.synchronize()", "E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered",
      "", "../../torch/cuda/__init__.py:1083: AcceleratorError"]
ia = V.extract_illegal(pt)
check("pytest's own traceback gives the raising frame's location", ia["frame"] == "../../torch/cuda/__init__.py:1083 (AcceleratorError)" and ia["method"] == "pytest traceback")
ia = V.extract_illegal(["something", "CUDA_ERROR_ILLEGAL_ADDRESS somewhere"])
check("a bare line is still found, with no frame claimed", ia["frame"] is None and ia["method"] == "line only")
check("a log without an illegal memory access has none", V.extract_illegal(["all good", "2 passed in 1.0s"]) is None)

# ---------------------------------------------------------------- the verdict
rec = judged()
check("pass: step 1 as the spec expects on both arms and step 2 passing is AS EXPECTED", rec["verdict"] == "AS EXPECTED")
b2 = "(MainProcess pid=1) ERROR 11-22 08:16:44 [hf3fs_mock_client.py:110] Batch write error: CUDA error: an illegal memory access was encountered\n1 failed, 20 warnings in 8.23s\n"
rec = judged(logs=with_logs(**{"b-2": b2}), rcs={"b-2": 1})
s2 = rec["arms"]["b"]["step2"]
check("an illegal access in step 2 is a RESULT with its own cause, and does not make the run INCOMPLETE or NOT RUN",
      rec["verdict"] == "AS EXPECTED" and s2["state"] == "RESULT" and s2["cause"] == "CUDA illegal memory access")
with contextlib.redirect_stdout(io.StringIO()) as buf:
    print("\n".join(V.render(rec)))
out = buf.getvalue()
check("verdict.txt says yes for arm B with the frame, and no for arm A",
      "arm B illegal memory access: yes, first at log line 1, frame hf3fs_mock_client.py:110 (logged record)" in out and "arm A illegal memory access: no" in out)
check("verdict.txt puts step 2's result on its own line next to the verdict", "STEP 2 RESULT: arm A RESULT passed, illegal memory access no; arm B RESULT CUDA illegal memory access, illegal memory access yes" in out)
check("verdict.txt says step 3 was not run and why", out.count("step 3 (run.sh fault, nofault): not run: the #69058 issue body names ./run.sh fault") == 2)
rec = judged(logs=with_logs(**{"b-2": "Loading: 10%\rLoading: 100%\n" + b2}), rcs={"b-2": 1})
check("judge reads a log's progress-bar carriage returns as file bytes, so the illegal access keeps its file line number 2",
      rec["arms"]["b"]["step2"]["illegal_access"]["line_no"] == 2)
rec = judged(logs=with_logs(**{"b-2": b2.split("\n")[0] + "\nFatal Python error: Aborted\n"}), rcs={"b-2": 134})
check("an illegal access that kills pytest before its summary is still a RESULT", rec["arms"]["b"]["step2"]["state"] == "RESULT")
kv = "E           ValueError: (0.02 GiB KV cache is needed, which is larger than the available KV cache memory (0.01 GiB).\n1 failed in 3.0s\n"
rec = judged(logs=with_logs(**{"a-2": kv}), rcs={"a-2": 1})
check("a KV memory failure in step 2 is NOT RUN, exit 4", rec["verdict"] == "NOT RUN" and rec["arms"]["a"]["step2"]["cause"].startswith("KV cache memory"))
both = "E   torch.AcceleratorError: CUDA error: an illegal memory access was encountered\nE   (KV cache is needed, which is larger than the available KV cache memory)\n../t.py:1: AcceleratorError\n1 failed in 3.0s\n"
rec = judged(logs=with_logs(**{"a-2": both}), rcs={"a-2": 1})
check("an illegal access outranks a harness cause in the same log", rec["arms"]["a"]["step2"]["cause"] == "CUDA illegal memory access")
captured = ">       assert retry.finish_reason == \"error\"\nE       AssertionError: assert 'length' == 'error'\n" \
    "------------------------------ Captured log call -------------------------------\n" \
    "WARNING  huggingface_hub:_http.py:1 Cannot find the requested files in the disk cache, using the local snapshot\n1 failed in 61.2s\n"
rec = judged(logs=with_logs(**{"a-2": captured}), rcs={"a-2": 1})
check("a captured log line that looks like a harness cause does not relabel an assertion failure",
      rec["arms"]["a"]["step2"]["state"] == "RESULT" and rec["arms"]["a"]["step2"]["cause"].startswith("failed: E       AssertionError"))
fail = ">       assert retry.finish_reason == \"error\"\nE       AssertionError: assert 'length' == 'error'\n1 failed in 61.2s\n"
rec = judged(logs=with_logs(**{"a-2": fail}), rcs={"a-2": 1})
check("a plain assertion failure in step 2 is a RESULT naming its E line", rec["verdict"] == "AS EXPECTED" and rec["arms"]["a"]["step2"]["cause"].startswith("failed: E       AssertionError"))
rec = judged(logs=with_logs(**{"b-1": "1 failed, 3 passed, 2 deselected in 7.0s\n"}), rcs={"b-1": 1})
check("step 1 on arm B with a failure is a FINDING, exit 2", rec["verdict"] == "FINDING" and "expected {'passed': 4}" in rec["arms"]["b"]["step1"]["why"])
rec = judged(logs=with_logs(**{"a-1": "4 passed, 2 deselected in 7.0s\n"}), rcs={"a-1": 0})
check("step 1 on arm A passing everything is a FINDING", rec["verdict"] == "FINDING")
rec = judged(logs=with_logs(**{"a-1": "2 failed, 1 passed, 1 skipped, 2 deselected in 7.0s\n"}), rcs={"a-1": 1})
check("step 1 with a skip is a FINDING, since the counts differ", rec["verdict"] == "FINDING")
rec = judged(logs=with_logs(**{"b-1": "4 passed, 2 deselected, 3 warnings in 7.0s\n"}))
check("step 1 ignores warnings and deselected tests in its counts", rec["verdict"] == "AS EXPECTED")
rec = judged(logs=with_logs(**{"b-1": "!!! KeyboardInterrupt !!!\n"}), rcs={"b-1": 2})
check("step 1 with no summary is INCOMPLETE, exit 3", rec["verdict"] == "INCOMPLETE" and "no pytest summary" in rec["arms"]["b"]["step1"]["why"])
rec = judged(logs=with_logs(**{"b-1": STEP1_B}), rcs={"b-1": 124})
check("step 1 cut by its cap is INCOMPLETE for its exit code", rec["verdict"] == "INCOMPLETE" and rec["arms"]["b"]["step1"]["why"] == "pytest exited 124")
rec = judged(logs=with_logs(**{"b-1": STEP1_B}), rcs={"b-1": 1})
check("step 1 whose exit code disagrees with its counts is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
rec = judged(logs=with_logs(**{"b-1": None}))
check("step 1 with no log is INCOMPLETE", rec["verdict"] == "INCOMPLETE" and rec["arms"]["b"]["step1"]["why"] == "no log")
rec = judged(logs=with_logs(**{"a-2": None}))
check("step 2 with no log is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
rec = judged(logs=with_logs(**{"a-2": "2 skipped in 0.05s\n"}))
check("step 2 skipped on the GPU is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
rec = judged(logs=with_logs(**{"a-2": "collecting ...\n"}), rcs={"a-2": 124})
check("step 2 cut by its cap with no illegal access is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
rec = judged(env={"cuda_available": False, "device_name": None})
check("no CUDA is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
rec = judged(env=None)
check("no env.json is INCOMPLETE", rec["verdict"] == "INCOMPLETE")
rec = judged(stopped="arm b: commit 9ee44f0 has tree x, not the pinned y")
check("a STOPPED run is INCOMPLETE", rec["verdict"] == "INCOMPLETE" and "not the pinned" in rec["gaps"][0])
rec = judged(logs=with_logs(**{"b-1": "1 failed, 3 passed in 7.0s\n"}), rcs={"b-1": 1}, env=None)
check("a FINDING outranks INCOMPLETE", rec["verdict"] == "FINDING")

for name, kw, want, rc_want in (("AS EXPECTED", {}, "AS EXPECTED", 0),
                                ("FINDING", {"logs": with_logs(**{"b-1": "1 failed, 3 passed in 7.0s\n"}), "rcs": {"b-1": 1}}, "FINDING", 2),
                                ("INCOMPLETE", {"env": None}, "INCOMPLETE", 3),
                                ("NOT RUN", {"logs": with_logs(**{"a-2": kv}), "rcs": {"a-2": 1}}, "NOT RUN", 4)):
    d = build(**kw)
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc = V.main(["verdict.py", d])
    saved = json.load(open(os.path.join(d, "verdict.json")))
    check(f"main exits {rc_want} for {name} and writes it", rc == rc_want and saved["verdict"] == want and f"VERDICT: {want}\n" in buf.getvalue())
    shutil.rmtree(d)
d = build(logs=with_logs(**{"b-2": b2}), rcs={"b-2": 1})
with contextlib.redirect_stdout(io.StringIO()):
    V.main(["verdict.py", d])
check("main writes the illegal-access block to b-2-illegal.txt and none for arm A",
      "illegal memory access" in open(os.path.join(d, "b-2-illegal.txt")).read() and not os.path.exists(os.path.join(d, "a-2-illegal.txt")))
shutil.rmtree(d)

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
