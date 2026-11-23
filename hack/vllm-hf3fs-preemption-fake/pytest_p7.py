"""A fake `python -m pytest` for the vLLM HF3FS preemption kit p7's offline test, run in the vLLM checkout once per arm.

The test file holds two GPU tests: test_preempted_request_saves_its_own_kv and test_failed_gather_still_fences_its_reads.
It reads the connector to tell the arms apart: FIX carries the fence's "could not fence" error, CONTROL (p6's code) does not.
By default, as the runtime session expects: CONTROL passes the first test with every held-save page error 0.0 and fails the new one
at its cuda_event assert, and FIX passes both, the first with every error 0.0 and its hold timed out.
It prints --durations=0's lines before the summary, as pytest does.
FAKE_MODE bends the run:
  fixnewfail       FIX fails the new test;
  controlnewpass   CONTROL passes the new test;
  controlfirstfail CONTROL fails the first test's page comparison;
  fixnonzero       FIX's first test passes with a held-save page error of 0.0012;
  fixnotimeout     FIX's first test passes without its hold timing out;
  setupboth        both arms' first tests fail at the prefix cache reset, the same line and error;
  controlkv        CONTROL gets no KV cache memory;
  skip             both tests skip, as without CUDA;
  hang             every run never returns.
Each run appends its arm to FAKE_ORDER_LOG when it is set.
"""

import os
import sys
import time

TF = "tests/v1/kv_connector/unit/test_hf3fs_preemption.py"
CONNECTOR = "vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py"
FIRST = "TestHF3FSPreemptionEndToEnd::test_preempted_request_saves_its_own_kv"
NEW = "TestHF3FSPreemptionEndToEnd::test_failed_gather_still_fences_its_reads"

args = sys.argv[1:]
want = [TF, "-q", "-s", "--tb=short", "--durations=0"]
with_s = args == want
if not with_s and args != [a for a in want if a != "-s"]:
    print(f"fake pytest: unexpected arguments {args}", file=sys.stderr)
    sys.exit(4)
if "CUDA_LAUNCH_BLOCKING" in os.environ:
    sys.exit(4)
if os.environ.get("FAKE_EXPECT_OFFLINE") == "1" and os.environ.get("HF_HUB_OFFLINE") != "1":
    print("fake pytest: the hub is not offline", file=sys.stderr)
    sys.exit(4)
arm = "fix" if "could not fence" in open(CONNECTOR).read() else "control"
if os.environ.get("FAKE_ORDER_LOG"):
    with open(os.environ["FAKE_ORDER_LOG"], "a") as f:
        f.write(arm + "\n")
mode = os.environ.get("FAKE_MODE", "")
if mode == "hang":
    time.sleep(3600)
if mode == "skip":
    print("ss\n2 skipped, 1 warning in 0.05s")
    sys.exit(0)

timed_out = not (arm == "fix" and mode == "fixnotimeout")
errors = [0.0, 0.0012, 0.0] if (arm == "fix" and mode == "fixnonzero") else [0.0, 0.0, 0.0]
first = "passed"
if arm == "control" and mode == "controlfirstfail":
    first, errors = "mismatch", [0.0, 1.0049, 1.2084]
if mode == "setupboth":
    first = "setup"
if arm == "control" and mode == "controlkv":
    first = "kv"
new_fails = (arm == "control" and mode != "controlnewpass") or (arm == "fix" and mode == "fixnewfail")

prints = [f"held=[32, 33, 34] reused=[33, 34] hold_timed_out={timed_out}", "end-of-run page errors: [0.0, 0.0, 0.0]",
          f"held-save page errors: {errors}"] if first in ("passed", "mismatch") else []
if with_s and prints:
    print("(EngineCore pid=3) INFO 11-23 16:00:01 [llm.py:1] Supported tasks: ['generate']")
    print("\n".join(prints))
print(("." if first == "passed" else "F") + ("F" if new_fails else "."))
failed = ([FIRST] if first != "passed" else []) + ([NEW] if new_fails else [])
if failed:
    print("=================================== FAILURES ===================================")
    if first != "passed":
        print("_______________ TestHF3FSPreemptionEndToEnd.test_preempted_request_saves_its_own_kv _______________")
        if first == "mismatch":
            print(f"{TF}:321: in test_preempted_request_saves_its_own_kv")
            print(f"E   AssertionError: {errors}")
        elif first == "setup":
            print(f"{TF}:268: in test_preempted_request_saves_its_own_kv")
            print("E   Failed: the local prefix cache could not be reset")
        else:
            print(f"{TF}:230: in test_preempted_request_saves_its_own_kv")
            print("E   ValueError: To serve at least one request with the model's max seq len (736), (0.04 GiB KV cache is needed, "
                  "which is larger than the available KV cache memory (0.03 GiB).")
        if not with_s and prints:
            print("----------------------------- Captured stdout call -----------------------------")
            print("\n".join(prints))
    if new_fails:
        print("____________ TestHF3FSPreemptionEndToEnd.test_failed_gather_still_fences_its_reads ____________")
        print(f"{TF}:354: in test_failed_gather_still_fences_its_reads")
        print("    assert gather.cuda_event is not None and gather.cuda_event.query()")
        print("E   assert (None is not None)")
        print("E    +  where None = <_SaveGather object at 0x7f00>.cuda_event")
    print("=========================== short test summary info ============================")
    for t in failed:
        print(f"FAILED {TF}::{t}")
print("============================= slowest durations ==============================")
print(f"61.20s call     {TF}::{FIRST}")
print(f"9.10s call     {TF}::{NEW}")
print(f"0.02s setup    {TF}::{FIRST}")
print(f"0.01s teardown {TF}::{NEW}")
n_passed = 2 - len(failed)
parts = ([f"{len(failed)} failed"] if failed else []) + ([f"{n_passed} passed"] if n_passed else [])
print(", ".join(parts) + ", 21 warnings in 72.34s (0:01:12)")
sys.exit(1 if failed else 0)
