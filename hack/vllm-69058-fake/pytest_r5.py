"""A fake `python -m pytest` for the vLLM #69058 kit r5's offline test, run in the vLLM checkout once per end-to-end case.

It prints a log in the shape of run r4's arm A: the case fails, its teardown error comes first in the file,
and its captured stdout shows request 7's read failing, the scheduler failing it, and the illegal memory access on saved request 6.
The traceback prints the source of the failing function, where a `logger.warning("DIAG ...")` line is code, not a record.
When the checkout carries the diagnostic patch, which logs "DIAG save", the captured stdout also has the patch's DIAG records.
FAKE_MODE bends the run:
  oor        the save of request 6 logs its block ids out of range;
  pass       the case passes, so pytest prints no captured output;
  skip       the case is skipped, as without CUDA;
  nosummary  pytest dies before its summary;
  nodiag     the case fails with no DIAG record, though the traceback's source shows DIAG code;
  noread     the case fails before its read ever fails;
  hang       pytest never returns.
"""

import os
import sys
import time

TF = "tests/v1/kv_connector/unit/test_hf3fs_load_failure.py"
CONNECTOR = "vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py"
NODE = TF + "::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[{}]"
P = "(MainProcess pid=2429)"

args = sys.argv[1:]
case = next((c for c in ("fail", "recompute") if args == [NODE.format(c), "-q", "-p", "no:cacheprovider", "--tb=long"]), None)
if case is None:
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
diag = "DIAG save" in open(CONNECTOR).read() and mode != "nodiag"
header = f"TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[{case}]"


def captured():
    """The case's captured stdout, in the order the engine wrote it."""
    out = []
    if diag:
        out += [f"{P} WARNING 11-22 10:10:03 [hf3fs_connector.py:610] DIAG step start sync ok",
                f"{P} WARNING 11-22 10:10:03 [hf3fs_connector.py:530] DIAG submit save 6-aa skip=0 block_ids=[40, 41, 42]",
                f"{P} WARNING 11-22 10:10:03 [hf3fs_connector.py:300] DIAG save 6-aa thread=save_0 n=3 min=40 max=42 num_blocks=64 inuse=1 ptrs=[1, 2]"]
        if mode == "oor":
            out.append(f"{P} ERROR 11-22 10:10:03 [hf3fs_connector.py:305] DIAG save 6-aa block ids out of range: [40, 41, 99]")
        out.append(f"{P} WARNING 11-22 10:10:03 [hf3fs_connector.py:310] DIAG save 6-aa pre-gather sync ok")
        if mode != "noread":
            out.append(f"{P} WARNING 11-22 10:10:04 [hf3fs_connector.py:420] DIAG load 7-bb read failed, block ids [40, 41]")
        out.append(f"{P} WARNING 11-22 10:10:04 [hf3fs_connector.py:600] DIAG step forward sync ok")
    if mode != "noread":
        out += [f"{P} ERROR 11-22 10:10:04 [hf3fs_connector.py:458] Read operation failed for Loaded request 7-bb",
                f"{P} ERROR 11-22 10:10:04 [scheduler.py:3974] Failing 1 request(s) due to KV load failure (failure_policy={case}, 240 tokens affected)."]
    out.append(f"{P} ERROR 11-22 10:10:04 [hf3fs_connector.py:458] Task execution error: Triton Error [CUDA]: an illegal memory access was encountered for Saved request 6-aa")
    if diag:
        out.append(f"{P} WARNING 11-22 10:10:05 [hf3fs_connector.py:610] DIAG step start sync ok")
    return out


if mode == "skip":
    print("1 skipped, 1 warning in 0.10s")
    sys.exit(0)
if mode == "pass":
    print("1 passed, 20 warnings in 110.00s (0:01:50)")
    sys.exit(0)
print("==================================== ERRORS ====================================")
print(f"_ ERROR at teardown of {header} _")
print(">       torch._C._accelerator_emptyCache()")
print("E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered")
print("")
print("../.venv/lib/python3.12/site-packages/torch/accelerator/memory.py:32: AcceleratorError")
print("----------------------------- Captured stdout call -----------------------------")
for line in captured():
    print(line)
print("=================================== FAILURES ===================================")
print(f"______ {header} _______")
print("")
print("    def _step(self):")
print(">       torch.cuda.synchronize()")
print('        logger.warning("DIAG step start sync ok")')
print("E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered")
print("")
print("../vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py:611: AcceleratorError")
print("----------------------------- Captured stdout call -----------------------------")
for line in captured():
    print(line)
if mode == "nosummary":
    print("Fatal Python error: Aborted")
    sys.exit(134)
print("=========================== short test summary info ============================")
print(f"FAILED {NODE.format(case)} - torch.AcceleratorError")
print(f"ERROR {NODE.format(case)} - torch.AcceleratorError")
print("1 failed, 20 warnings, 1 error in 125.00s (0:02:05)")
sys.exit(1)
