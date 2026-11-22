"""A fake `python -m pytest` for the vLLM #69058 kit r6's offline test, run in the vLLM checkout.

With the shutdown fix in the connector, both end-to-end cases pass, as the fix should make them.
Without it, [fail] fails as run r5's did: the saved request's gather hits an illegal memory access after the engine shut down.
FAKE_MODE bends the run:
  illegal    the fix is in, both cases pass, yet the captured log of a passing run still shows an illegal access on stderr;
  onefail    [recompute] fails an assertion, with no illegal access;
  kvmem      [fail] gets no KV cache memory;
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
NODE = TF + "::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[{}]"
P = "(MainProcess pid=2429)"

args = sys.argv[1:]
if args != ARGS:
    print(f"fake pytest: unexpected arguments {args}", file=sys.stderr)
    sys.exit(4)
if os.environ.get("VLLM_ENABLE_V1_MULTIPROCESSING") != "0" or "CUDA_LAUNCH_BLOCKING" in os.environ:
    print("fake pytest: the run needs VLLM_ENABLE_V1_MULTIPROCESSING=0 and no CUDA_LAUNCH_BLOCKING", file=sys.stderr)
    sys.exit(4)
if os.environ.get("FAKE_EXPECT_OFFLINE") == "1" and os.environ.get("HF_HUB_OFFLINE") != "1":
    print("fake pytest: the hub is not offline", file=sys.stderr)
    sys.exit(4)
mode = os.environ.get("FAKE_MODE", "")
if mode == "hang":
    time.sleep(3600)
fixed = "A save that gathers after the cache is freed" in open(CONNECTOR).read()

if mode == "skip":
    print("2 skipped, 1 warning in 0.10s")
    sys.exit(0)
if mode == "nosummary":
    print("Fatal Python error: Aborted")
    sys.exit(134)
if fixed and mode == "illegal":
    print(f"{P} ERROR 11-22 21:00:04 [hf3fs_mock_client.py:110] Batch write error: CUDA error: an illegal memory access was encountered")
    print("2 passed, 20 warnings in 140.00s (0:02:20)")
    sys.exit(0)
if fixed and mode == "kvmem":
    print("=================================== FAILURES ===================================")
    print("______ TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[fail] _______")
    print(">           llm = LLM(")
    print("E           ValueError: To serve at least one request with the model's max seq len (512), (0.02 GiB KV cache is needed, "
          "which is larger than the available KV cache memory (0.01 GiB).")
    print("----------------------------- Captured log call -----------------------------")
    print("INFO     vllm.engine.arg_utils:arg_utils.py:928 HF_HUB_OFFLINE is True, replace model_id [facebook/opt-125m] to model_path")
    print("=========================== short test summary info ============================")
    print(f"FAILED {NODE.format('fail')} - ValueError")
    print("1 failed, 1 passed, 20 warnings in 60.00s (0:01:00)")
    sys.exit(1)
if fixed and mode == "onefail":
    print("=================================== FAILURES ===================================")
    print("______ TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[recompute] _______")
    print(">       assert retry.token_ids == cold.token_ids")
    print("E       assert [2, 50118, 133] == [2, 50118, 4148]")
    print("=========================== short test summary info ============================")
    print(f"FAILED {NODE.format('recompute')} - AssertionError")
    print("1 failed, 1 passed, 20 warnings in 150.00s (0:02:30)")
    sys.exit(1)
if fixed:
    print("2 passed, 20 warnings in 140.00s (0:02:20)")
    sys.exit(0)
print("==================================== ERRORS ====================================")
print("_ ERROR at teardown of TestHF3FSLoadFailureEndToEnd.test_failed_read_honors_policy[fail] _")
print(">       torch._C._accelerator_emptyCache()")
print("E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered")
print("----------------------------- Captured stdout call -----------------------------")
print(f"{P} ERROR 11-22 21:00:04 [hf3fs_connector.py:458] Read operation failed for Loaded request 7-bb")
print(f"{P} ERROR 11-22 21:00:04 [hf3fs_connector.py:458] Task execution error: Triton Error [CUDA]: an illegal memory access was encountered for Saved request 6-aa")
print("=========================== short test summary info ============================")
print(f"FAILED {NODE.format('fail')} - torch.AcceleratorError")
print(f"ERROR {NODE.format('fail')} - torch.AcceleratorError")
print("1 failed, 1 passed, 20 warnings, 1 error in 140.00s (0:02:20)")
sys.exit(1)
