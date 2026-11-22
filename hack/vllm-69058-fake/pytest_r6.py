"""A fake `python -m pytest` for the vLLM #69058 kit r6's offline test, run in the vLLM checkout once per case.

It reads the connector to tell the arms apart: FIX carries the shutdown() override's comment, CONTROL does not.
By default, as the runtime session expects on a GPU: CONTROL [fail] faults as run r5's [fail] did, CONTROL [recompute] passes,
and FIX passes both.
FAKE_MODE bends the run:
  fixfault       FIX [fail] still faults;
  fixfail        FIX [recompute] fails an assertion, with no illegal access;
  controlclean   CONTROL [fail] passes, so the comparison is inconclusive;
  controlkv      CONTROL [fail] gets no KV cache memory;
  fixkv          FIX [fail] gets no KV cache memory;
  skip           every case is skipped, as without CUDA;
  nosummary      FIX [recompute] dies before its summary;
  hang           every case never returns.
Each run appends "arm:case" to FAKE_ORDER_LOG when it is set, so the offline test can check the order and that each process ran one case.
"""

import os
import sys
import time

TF = "tests/v1/kv_connector/unit/test_hf3fs_load_failure.py"
CONNECTOR = "vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py"
NODE = TF + "::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[{}]"
P = "(MainProcess pid=2429)"

args = sys.argv[1:]
case = next((c for c in ("fail", "recompute") if args == [NODE.format(c), "-q", "-p", "no:cacheprovider", "--tb=short"]), None)
if case is None:
    print(f"fake pytest: unexpected arguments {args}", file=sys.stderr)
    sys.exit(4)
if os.environ.get("VLLM_ENABLE_V1_MULTIPROCESSING") != "0" or "CUDA_LAUNCH_BLOCKING" in os.environ:
    print("fake pytest: the run needs VLLM_ENABLE_V1_MULTIPROCESSING=0 and no CUDA_LAUNCH_BLOCKING", file=sys.stderr)
    sys.exit(4)
if os.environ.get("FAKE_EXPECT_OFFLINE") == "1" and os.environ.get("HF_HUB_OFFLINE") != "1":
    print("fake pytest: the hub is not offline", file=sys.stderr)
    sys.exit(4)
arm = "fix" if "A gather after the cache is freed hits an illegal address." in open(CONNECTOR).read() else "control"
if os.environ.get("FAKE_ORDER_LOG"):
    with open(os.environ["FAKE_ORDER_LOG"], "a") as f:
        f.write(f"{arm}:{case}\n")
mode = os.environ.get("FAKE_MODE", "")
if mode == "hang":
    time.sleep(3600)
if mode == "skip":
    print("1 skipped, 1 warning in 0.10s")
    sys.exit(0)
if mode == "nosummary" and (arm, case) == ("fix", "recompute"):
    print("Fatal Python error: Aborted")
    sys.exit(134)


def faulted():
    print("=================================== FAILURES ===================================")
    print(f"_ TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[{case}] _")
    print("----------------------------- Captured stdout call -----------------------------")
    print(f"{P} ERROR 11-22 21:00:04 [hf3fs_connector.py:458] Read operation failed for Loaded request 7-bb")
    print(f"{P} ERROR 11-22 21:00:04 [hf3fs_connector.py:458] Task execution error: Triton Error [CUDA]: an illegal memory access was encountered for Saved request 6-aa")
    print("=========================== short test summary info ============================")
    print(f"FAILED {NODE.format(case)} - torch.AcceleratorError")
    print(f"ERROR {NODE.format(case)} - torch.AcceleratorError")
    print("1 failed, 20 warnings, 1 error in 131.35s (0:02:11)")
    sys.exit(1)


def kv():
    print("=================================== FAILURES ===================================")
    print(f"_ TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[{case}] _")
    print("E   ValueError: To serve at least one request with the model's max seq len (512), (0.02 GiB KV cache is needed, "
          "which is larger than the available KV cache memory (0.01 GiB).")
    print("=========================== short test summary info ============================")
    print(f"FAILED {NODE.format(case)} - ValueError")
    print("1 failed, 20 warnings in 20.00s")
    sys.exit(1)


if (arm, case) == ("control", "fail"):
    if mode == "controlclean":
        print("1 passed, 20 warnings in 9.00s")
        sys.exit(0)
    if mode == "controlkv":
        kv()
    faulted()
if (arm, case) == ("fix", "fail") and mode == "fixfault":
    faulted()
if (arm, case) == ("fix", "fail") and mode == "fixkv":
    kv()
if (arm, case) == ("fix", "recompute") and mode == "fixfail":
    print("=================================== FAILURES ===================================")
    print("_ TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[recompute] _")
    print("E   assert [2, 50118, 133] == [2, 50118, 4148]")
    print("=========================== short test summary info ============================")
    print(f"FAILED {NODE.format(case)} - AssertionError")
    print("1 failed, 20 warnings in 9.00s")
    sys.exit(1)
print("1 passed, 20 warnings in 9.00s")
sys.exit(0)
