"""A fake `python -m pytest` for the vLLM #69058 kit r5's offline test, run in the vLLM checkout.

It prints a log in the shape of run r4's arm A: both end-to-end cases fail, and each case's captured stdout shows
request 7's read failing, the scheduler failing it, and the illegal memory access on saved request 6.
When the checkout carries the diagnostic patch, which logs "DIAG save", the captured stdout also has the patch's DIAG lines.
FAKE_MODE bends the run:
  oor        the save of request 6 logs its block ids out of range;
  pass       both cases pass, so pytest prints no captured output;
  skip       both cases are skipped, as without CUDA;
  nosummary  pytest dies before its summary;
  hang       pytest never returns.
"""

import os
import sys
import time

TF = "tests/v1/kv_connector/unit/test_hf3fs_load_failure.py"
CONNECTOR = "vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py"
ARGS = [TF + "::TestHF3FSLoadFailureEndToEnd", "-q", "-p", "no:cacheprovider", "--tb=long"]
P = "(MainProcess pid=2429)"

args = sys.argv[1:]
if args != ARGS:
    print(f"fake pytest: unexpected arguments {args}", file=sys.stderr)
    sys.exit(4)
if os.environ.get("CUDA_LAUNCH_BLOCKING") != "1" or os.environ.get("VLLM_ENABLE_V1_MULTIPROCESSING") != "0":
    print("fake pytest: the run needs CUDA_LAUNCH_BLOCKING=1 and VLLM_ENABLE_V1_MULTIPROCESSING=0", file=sys.stderr)
    sys.exit(4)
if os.environ.get("FAKE_EXPECT_OFFLINE") == "1" and os.environ.get("HF_HUB_OFFLINE") != "1":
    print("fake pytest: the hub is not offline", file=sys.stderr)
    sys.exit(4)
if not os.path.exists(TF):
    print(f"ERROR: file or directory not found: {TF}")
    print("no tests ran in 0.01s")
    sys.exit(4)
mode = os.environ.get("FAKE_MODE", "")
if mode == "hang":
    time.sleep(3600)
diag = "DIAG save" in open(CONNECTOR).read()


def captured(case):
    """The captured stdout of one case, in the order the engine wrote it."""
    out = []
    if diag:
        out += [f"{P} WARNING 11-22 10:10:03 [hf3fs_connector.py:610] DIAG step start sync ok",
                f"{P} WARNING 11-22 10:10:03 [hf3fs_connector.py:530] DIAG submit save 6-aa skip=0 block_ids=[40, 41, 42]",
                f"{P} WARNING 11-22 10:10:03 [hf3fs_connector.py:300] DIAG save 6-aa thread=save_0 n=3 min=40 max=42 num_blocks=64 inuse=1 ptrs=[1, 2]"]
        if mode == "oor":
            out.append(f"{P} ERROR 11-22 10:10:03 [hf3fs_connector.py:305] DIAG save 6-aa block ids out of range: [40, 41, 99]")
        out += [f"{P} WARNING 11-22 10:10:03 [hf3fs_connector.py:310] DIAG save 6-aa pre-gather sync ok",
                f"{P} WARNING 11-22 10:10:04 [hf3fs_connector.py:420] DIAG load 7-bb read failed, block ids [40, 41]",
                f"{P} WARNING 11-22 10:10:04 [hf3fs_connector.py:600] DIAG step forward sync ok"]
    out += [f"{P} ERROR 11-22 10:10:04 [hf3fs_connector.py:458] Read operation failed for Loaded request 7-bb",
            f"{P} ERROR 11-22 10:10:04 [scheduler.py:3974] Failing 1 request(s) due to KV load failure (failure_policy={case}, 240 tokens affected).",
            f"{P} ERROR 11-22 10:10:04 [hf3fs_connector.py:458] Task execution error: Triton Error [CUDA]: an illegal memory access was encountered for Saved request 6-aa"]
    if diag:
        out.append(f"{P} WARNING 11-22 10:10:04 [hf3fs_connector.py:610] DIAG step start sync ok")
    return out


if mode == "skip":
    print("2 skipped, 1 warning in 0.10s")
    sys.exit(0)
if mode == "pass":
    print("2 passed, 20 warnings in 210.00s (0:03:30)")
    sys.exit(0)
print("==================================== ERRORS ====================================")
print("_ ERROR at teardown of TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[fail] _")
print(">       torch._C._accelerator_emptyCache()")
print("E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered")
print("")
print("../.venv/lib/python3.12/site-packages/torch/accelerator/memory.py:32: AcceleratorError")
print("----------------------------- Captured stdout call -----------------------------")
for line in captured("fail"):
    print(line)
print("=================================== FAILURES ===================================")
for case in ("fail", "recompute"):
    print(f"______ TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[{case}] _______")
    print(">           llm.llm_engine.engine_core.shutdown()")
    print("E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered")
    print("")
    print("../.venv/lib/python3.12/site-packages/torch/accelerator/memory.py:32: AcceleratorError")
    print("----------------------------- Captured stdout call -----------------------------")
    for line in captured(case):
        print(line)
if mode == "nosummary":
    print("Fatal Python error: Aborted")
    sys.exit(134)
print("=========================== short test summary info ============================")
print(f"FAILED {TF}::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[fail] - torch.AcceleratorError")
print(f"FAILED {TF}::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[recompute] - torch.AcceleratorError")
print(f"ERROR {TF}::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[fail] - torch.AcceleratorError")
print("2 failed, 20 warnings, 1 error in 250.00s (0:04:10)")
sys.exit(1)
