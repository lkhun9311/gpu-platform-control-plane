"""A fake `python -m pytest` for the vLLM #69058 kit r4's offline test, run in the vLLM checkout.

It reads the checkout to decide which arm it is in, as the real tests would behave on a GPU:
arm B's connector carries "_unowned_finished_req_ids", and arm A's does not.
Step 1 gives 3 failed and 1 passed on arm A and 4 passed on arm B, as on CPU; step 2 passes both end-to-end cases on both arms.
FAKE_MODE bends one arm's outcome so the verdict's rules can be driven:
  s1_finding     step 1 on arm B has one failure;
  s1_nosummary   step 1 on arm B is interrupted before its summary;
  s2_illegal     step 2 on arm B logs an illegal memory access from the mock client, as run r3's fix side did;
  s2_illegal_tb  step 2 on arm B prints a Python traceback ending in an illegal memory access;
  s2_illegal_pt  step 2 on arm B fails with the illegal memory access in pytest's own traceback;
  s2_crash       step 2 on arm B logs an illegal memory access and dies before its summary;
  s2_kvmem       step 2 on arm A gets no KV cache memory;
  s2_fail        step 2 on arm A fails an assertion, a result without a fault;
  s2_skip        step 2 skips both cases, as without CUDA;
  hang           pytest never returns.
"""

import os
import sys
import time

TF = "tests/v1/kv_connector/unit/test_hf3fs_load_failure.py"
CONNECTOR = "vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py"
SCHED = TF + "::TestHF3FSSchedulerLoadFailure::"
E2E = TF + "::TestHF3FSLoadFailureEndToEnd::"
UNIT = [SCHED + "test_failed_load_honors_failure_policy[fail]", SCHED + "test_failed_load_honors_failure_policy[recompute]",
        SCHED + "test_failed_later_batch_keeps_prefix_and_saves_the_rest", SCHED + "test_reused_blocks_do_not_mark_a_finished_load"]
# The three that fail on arm A in the CPU run, the [recompute] policy case being the one that passes.
A_FAILS = [UNIT[0], UNIT[2], UNIT[3]]
CASES = [E2E + "test_failed_read_honors_policy[fail]", E2E + "test_failed_read_honors_policy[recompute]"]
STEP1 = [TF, "-k", "not EndToEnd", "-q", "-p", "no:cacheprovider"]
STEP2 = [TF + "::TestHF3FSLoadFailureEndToEnd", "-q", "-p", "no:cacheprovider", "-x", "--tb=long"]
LOGGED = [
    "(MainProcess pid=2835) ERROR 11-22 08:16:43 [scheduler.py:3974] Failing 1 request(s) due to KV load failure (failure_policy=fail, 240 tokens affected).",
    "(MainProcess pid=2835) ERROR 11-22 08:16:44 [hf3fs_mock_client.py:110] Batch write error: CUDA error: an illegal memory access was encountered",
    "(MainProcess pid=2835) ERROR 11-22 08:16:44 [hf3fs_mock_client.py:110] Returning 700 (CUDA_ERROR_ILLEGAL_ADDRESS) from cuMemcpyDtoHAsync_v2",
]
PY_TB = [
    "Traceback (most recent call last):",
    '  File "/opt/kit/work/vllm/vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py", line 512, in _execute_save_task',
    "    self._gather_or_scatter_kv_caches(block_ids, buffers, save=True)",
    '  File "/opt/kit/work/vllm/vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/utils/gather_scatter_helper.py", line 141, in gather',
    "    _gather_kernel[grid](src, dst, ids)",
    "torch.AcceleratorError: CUDA error: an illegal memory access was encountered",
]
PT_TB = [
    ">       retry = _greedy_output(llm, target)",
    "",
    "../vllm/v1/worker/gpu_model_runner.py:3120: ",
    ">       torch.cuda.synchronize()",
    "E       torch.AcceleratorError: CUDA error: an illegal memory access was encountered",
    "E       Returning 700 (CUDA_ERROR_ILLEGAL_ADDRESS) from cuStreamSynchronize",
    "",
    "../../.venv/lib/python3.12/site-packages/torch/cuda/__init__.py:1083: AcceleratorError",
]

args = sys.argv[1:]
if args == STEP1:
    step = 1
elif args == STEP2:
    step = 2
    if os.environ.get("CUDA_LAUNCH_BLOCKING") != "1" or os.environ.get("VLLM_ENABLE_V1_MULTIPROCESSING") != "0":
        print("fake pytest: step 2 needs CUDA_LAUNCH_BLOCKING=1 and VLLM_ENABLE_V1_MULTIPROCESSING=0", file=sys.stderr)
        sys.exit(4)
else:
    print(f"fake pytest: unexpected arguments {args}", file=sys.stderr)
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
arm = "b" if "_unowned_finished_req_ids" in open(CONNECTOR).read() else "a"
# Each run notes its arm and step, so the offline test can check the order the kit ran them in.
with open(os.environ["FAKE_ORDER_LOG"], "a") if os.environ.get("FAKE_ORDER_LOG") else open(os.devnull, "w") as f:
    f.write(f"{arm}-{step}\n")

print("<frozen importlib._bootstrap>:488: DeprecationWarning: builtin type SwigPyPacked has no __module__ attribute")
if step == 1:
    if mode == "s1_nosummary" and arm == "b":
        print("!!!!!!!!!!!!!!!!!!! KeyboardInterrupt !!!!!!!!!!!!!!!!!!!")
        sys.exit(2)
    failed = A_FAILS if arm == "a" else ([UNIT[1]] if mode == "s1_finding" else [])
    for t in failed:
        print(f"_ {t.split('::', 1)[1].replace('::', '.')} _")
        print("E       AssertionError")
    print("=========================== short test summary info ============================")
    for t in failed:
        print(f"FAILED {t}")
    parts = ([f"{len(failed)} failed"] if failed else []) + [f"{4 - len(failed)} passed", "2 deselected", "1 warning"]
    print(f"{', '.join(parts)} in 7.10s")
    sys.exit(1 if failed else 0)

# Step 2.
if mode == "s2_skip":
    print("2 skipped, 1 warning in 0.05s")
    sys.exit(0)
if arm == "b" and mode in ("s2_illegal", "s2_crash"):
    for line in LOGGED:
        print(line)
    if mode == "s2_crash":
        print("Fatal Python error: Aborted")
        sys.exit(134)
    print("=========================== short test summary info ============================")
    print(f"FAILED {CASES[0]} - torch.AcceleratorError: CUDA error: an illegal memory access was encountered")
    print("1 failed, 20 warnings in 8.23s")
    sys.exit(1)
if arm == "b" and mode == "s2_illegal_tb":
    for line in PY_TB:
        print(line)
    print("=========================== short test summary info ============================")
    print(f"FAILED {CASES[0]} - torch.AcceleratorError")
    print("1 failed, 20 warnings in 8.23s")
    sys.exit(1)
failing = None
if arm == "b" and mode == "s2_illegal_pt":
    failing = PT_TB
elif arm == "a" and mode == "s2_kvmem":
    failing = [">           llm = LLM(", "E           ValueError: To serve at least one request with the model's max seq len (512), "
               "(0.02 GiB KV cache is needed, which is larger than the available KV cache memory (0.01 GiB)."]
elif arm == "a" and mode == "s2_fail":
    failing = ['>           assert retry.finish_reason == "error"', "E           AssertionError: assert 'length' == 'error'"]
if failing:
    print("=================================== FAILURES ===================================")
    print(f"_ {CASES[0].split('::', 1)[1].replace('::', '.')} _")
    for line in failing:
        print(line)
    print("=========================== short test summary info ============================")
    print(f"FAILED {CASES[0]}")
    print("1 failed, 20 warnings in 61.20s (0:01:01)")
    sys.exit(1)
print("2 passed, 20 warnings in 120.48s (0:02:00)")
sys.exit(0)
