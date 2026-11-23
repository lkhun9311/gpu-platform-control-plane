"""A fake `python -m pytest` for the vLLM HF3FS preemption kit p1's offline test, run in the vLLM checkout once per arm.

It reads the checkout to tell the arms apart: FIX's connector defines handle_preemptions, CONTROL's does not.
The test file must be there in both.
By default, as the runtime session expects on a GPU:
CONTROL fails its two hook CPU tests and the GPU page comparison with errors near 1, preconditions met and hold_timed_out=False,
and FIX passes all four tests with hold_timed_out=True and errors under 0.05.
Without -s, the GPU test's prints are captured: a passing test shows none, a failing one shows them under "Captured stdout call", as pytest does.
FAKE_MODE bends the run:
  fixmismatch     FIX fails the page comparison with errors near 1;
  fixsmallerr     FIX fails the page comparison with a 0.07 error;
  fixcpufail      FIX fails the hook's wait test;
  fixother        FIX's GPU test fails before its comparison, as when its saves never finish;
  fixnotimeout    FIX passes but its hold did not time out;
  fixfault        FIX hits an illegal memory access;
  fixprecond      FIX's target is not preempted;
  controlpass     CONTROL's GPU test passes;
  controlprecond  CONTROL reuses no held block;
  controlsmall    CONTROL fails the comparison with a 0.2 error;
  controltimeout  CONTROL fails the comparison but its hold timed out;
  controlkv       CONTROL gets no KV cache memory;
  fixload         FIX cannot load the model offline;
  skip            the GPU test is skipped in both, as without CUDA;
  nosummary       FIX dies before its summary;
  setupboth       both arms fail at the prefix cache reset, before the page comparison, as run p3 did;
  oldline         both arms print the older test's "relative page errors" line instead of kit p4's;
  fixnonzero      FIX passes with a held-save page error of 0.0012 where kit p6 expects 0.0;
On a gather-only tree, kit p6's, FIX's held-save page errors are all 0.0, as the runtime session expects.
  hang            every run never returns;
  hangterm        every run never returns and ignores SIGTERM, so only the kill after the grace ends it.
Each run appends its arm to FAKE_ORDER_LOG when it is set, so the offline test can check the order.
"""

import os
import signal
import sys
import time

TF = "tests/v1/kv_connector/unit/test_hf3fs_preemption.py"
CONNECTOR = "vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py"
CPU = "TestHF3FSHandlePreemptions"
GPU = "TestHF3FSPreemptionEndToEnd::test_preempted_request_saves_its_own_kv"
P = "(EngineCore pid=2429)"

args = sys.argv[1:]
# Kits p1 to p4 turn pytest's cache provider off; kit p5 runs the runtime session's command, which keeps it.
COMMANDS = ([TF, "-q", "-p", "no:cacheprovider", "-s", "--tb=short"], [TF, "-q", "-s", "--tb=short"])
with_s = args in COMMANDS
if not with_s and args not in ([a for a in c if a != "-s"] for c in COMMANDS):
    print(f"fake pytest: unexpected arguments {args}", file=sys.stderr)
    sys.exit(4)
if "CUDA_LAUNCH_BLOCKING" in os.environ:
    print("fake pytest: the run needs no CUDA_LAUNCH_BLOCKING", file=sys.stderr)
    sys.exit(4)
if os.environ.get("FAKE_EXPECT_OFFLINE") == "1" and os.environ.get("HF_HUB_OFFLINE") != "1":
    print("fake pytest: the hub is not offline", file=sys.stderr)
    sys.exit(4)
if not os.path.exists(TF):
    print(f"ERROR: file or directory not found: {TF}")
    print("no tests ran in 0.01s")
    sys.exit(4)
arm = "fix" if "    def handle_preemptions(" in open(CONNECTOR).read() else "control"
# Kit p4's test compares the pages read right after the held save, and prints them on their own line.
HELD_SAVE = "held-save page errors" in open(TF).read()
# Kit p5's test file holds the GPU test alone, with no CPU tests before it.
HAS_CPU = "class TestHF3FSHandlePreemptions" in open(TF).read()
if os.environ.get("FAKE_ORDER_LOG"):
    with open(os.environ["FAKE_ORDER_LOG"], "a") as f:
        f.write(arm + "\n")
mode = os.environ.get("FAKE_MODE", "")
if mode in ("hang", "hangterm"):
    if mode == "hangterm":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(3600)

# Each GPU outcome: (held, reused, timed_out, errors, failure E lines) or a special word.
if arm == "control":
    gpu = ([20, 21, 22, 23], [21, 22], False, [0.9731, 1.0214], ["E   AssertionError: [0.9731, 1.0214]", "E   assert 1.0214 < 0.05"])
    gpu = {
        "controlpass": ([20, 21, 22, 23], [21, 22], False, [0.0011, 0.0009], None),
        "controlprecond": "E   AssertionError: no held block was reused by the other request",
        "controlsmall": ([20, 21, 22, 23], [21, 22], False, [0.2, 0.1], ["E   AssertionError: [0.2, 0.1]", "E   assert 0.2 < 0.05"]),
        "controltimeout": ([20, 21, 22, 23], [21, 22], True, [0.9731, 1.0214], ["E   AssertionError: [0.9731, 1.0214]", "E   assert 1.0214 < 0.05"]),
        "controlkv": "E   ValueError: To serve at least one request with the model's max seq len (1024), (0.04 GiB KV cache is needed, "
                     "which is larger than the available KV cache memory (0.01 GiB).",
    }.get(mode, gpu)
    cpu_fail = ["test_scheduler_passes_preempted_requests_to_the_worker", "test_waits_for_the_preempted_request_saves_only"]
else:
    gpu = ([20, 21, 22, 23], [21, 22], True, [0.0012, 0.0009], None)
    if "    def wait_for_gathers(" in open(CONNECTOR).read():
        gpu = ([20, 21, 22, 23], [21, 22], True, [0.0, 0.0, 0.0], None)
    if mode == "fixnonzero":
        gpu = ([20, 21, 22, 23], [21, 22], True, [0.0, 0.0012, 0.0], None)
    gpu = {
        "fixmismatch": ([20, 21, 22, 23], [21, 22], True, [0.9731, 1.0214], ["E   AssertionError: [0.9731, 1.0214]", "E   assert 1.0214 < 0.05"]),
        "fixsmallerr": ([20, 21, 22, 23], [21, 22], True, [0.0012, 0.07], ["E   AssertionError: [0.0012, 0.07]", "E   assert 0.07 < 0.05"]),
        "fixother": "E   AssertionError: saves did not finish",
        "fixnotimeout": ([20, 21, 22, 23], [21, 22], False, [0.0012, 0.0009], None),
        "fixprecond": "E   AssertionError: the target was not preempted",
        "fixload": "E   huggingface_hub.errors.LocalEntryNotFoundError: Cannot find an appropriate cached snapshot folder",
    }.get(mode, gpu)
    cpu_fail = ["test_waits_for_the_preempted_request_saves_only"] if mode == "fixcpufail" else []
if mode == "skip":
    gpu = "skip"
if mode == "setupboth":
    gpu = "E   Failed: the local prefix cache could not be reset"

if not HAS_CPU:
    cpu_fail = []
progress = "" if not HAS_CPU else "".join("F" if t in cpu_fail else "." for t in ("test_scheduler_passes_preempted_requests_to_the_worker",
                                                          "test_waits_for_the_preempted_request_saves_only", "test_no_preemption_does_not_wait"))
print(progress, end="", flush=True)
if mode == "fixfault" and arm == "fix":
    print(f"\n{P} ERROR 11-22 21:00:04 [hf3fs_connector.py:458] Task execution error: Triton Error [CUDA]: an illegal memory access was encountered")
    print("Fatal Python error: Aborted")
    sys.exit(134)
if mode == "nosummary" and arm == "fix":
    print("\nFatal Python error: Aborted")
    sys.exit(134)
prints = []
if isinstance(gpu, tuple):
    held, reused, timed_out, errors, _ = gpu
    if HELD_SAVE and mode != "oldline":
        prints = [f"held={held} reused={reused} hold_timed_out={timed_out}", f"end-of-run page errors: {[0.0007, 0.0004]}",
                  f"held-save page errors: {errors}"]
    else:
        prints = [f"held={held} reused={reused} hold_timed_out={timed_out}", f"relative page errors: {errors}"]
gpu_failed = isinstance(gpu, str) and gpu != "skip" or isinstance(gpu, tuple) and gpu[4] is not None
if with_s and prints:
    print(f"\n{P} INFO 11-22 21:00:01 [llm.py:1] Supported tasks: ['generate']")
    print("\n".join(prints))
print("s" if gpu == "skip" else ("F" if gpu_failed else "."))

failed = [f"{CPU}::{t}" for t in cpu_fail] + ([GPU] if gpu_failed else [])
if failed:
    print("=================================== FAILURES ===================================")
    for t in cpu_fail:
        print(f"_ {CPU}.{t} _")
        print(f"{TF}:77: in {t}")
        print("E   assert False")
    if gpu_failed:
        print("_______________ TestHF3FSPreemptionEndToEnd.test_preempted_request_saves_its_own_kv _______________")
        print(f"{TF}:322: in test_preempted_request_saves_its_own_kv")
        if isinstance(gpu, str):
            print(gpu)
        else:
            print("    assert max(errors) < 0.05, errors")
            print("\n".join(gpu[4]))
            if not with_s:
                print("----------------------------- Captured stdout call -----------------------------")
                print("\n".join(prints))
    print("=========================== short test summary info ============================")
    for t in failed:
        print(f"FAILED {TF}::{t}")
n_failed = len(failed)
n_passed = (3 if HAS_CPU else 0) - len(cpu_fail) + (0 if gpu_failed or gpu == "skip" else 1)
parts = ([f"{n_failed} failed"] if n_failed else []) + ([f"{n_passed} passed"] if n_passed else []) + (["1 skipped"] if gpu == "skip" else [])
print(", ".join(parts) + ", 20 warnings in 61.20s (0:01:01)")
sys.exit(1 if failed else 0)
