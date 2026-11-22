"""A fake bench_preempt.py for kit p5's offline test, run from the vLLM checkout once per b1 process.

It reads the checkout's connector to report has_fix as the real script does, from AsyncOperationManager.wait_for_saves,
and writes a JSON with the real script's fields and plausible values.
FAKE_B1 bends the runs:
  zeropreempt   the second CONTROL pool-128 run reports no preemption;
  hasfixcontrol every CONTROL run reports has_fix true, as a CONTROL tree carrying the fix would;
  hasfixfix     every FIX run reports has_fix false, as a FIX tree without the fix would;
  nojson        the first CONTROL pool-128 run exits 1 without a JSON;
  storageshort  the first FIX pool-128 run logs the metadata server's warning that it ran short of pages;
  preempt2048   the FIX pool-2048 run reports preemptions;
  hang          every run never returns.
Each run appends ARM-POOL to FAKE_B1_LOG when it is set, ARM read from the checkout, so the offline test can check the order.
"""

import argparse
import json
import os
import sys
import time

CONNECTOR = "vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py"

ap = argparse.ArgumentParser()
ap.add_argument("--pool-blocks", type=int, required=True)
ap.add_argument("--out", required=True)
args = ap.parse_args()
if os.environ.get("VLLM_ENABLE_V1_MULTIPROCESSING") not in (None, "0"):
    sys.exit("fake bench: VLLM_ENABLE_V1_MULTIPROCESSING is set otherwise")
if not os.environ.get("PYTHONPATH", "").startswith(os.getcwd()):
    sys.exit(f"fake bench: the checkout {os.getcwd()} is not on PYTHONPATH ({os.environ.get('PYTHONPATH')})")
has_fix = "    def wait_for_saves(" in open(CONNECTOR).read()
arm = "fix" if has_fix else "control"
mode = os.environ.get("FAKE_B1", "")
if os.environ.get("FAKE_B1_LOG"):
    with open(os.environ["FAKE_B1_LOG"], "a") as f:
        f.write(f"{arm}-{args.pool_blocks}\n")
if mode == "hang":
    time.sleep(3600)
name = os.path.basename(args.out)
if mode == "nojson" and name == "control-128-1.json":
    sys.exit("fake bench: died before its JSON")
if mode == "hasfixcontrol" and arm == "control":
    has_fix = True
if mode == "hasfixfix" and arm == "fix":
    has_fix = False
preempting = args.pool_blocks == 128
preemptions = 0 if (mode == "zeropreempt" and name == "control-128-2.json") else (412 if preempting else 0)
if mode == "preempt2048" and name == "fix-2048-1.json":
    preemptions = 3
if mode == "storageshort" and name == "fix-128-1.json":
    print("(EngineCore pid=7) WARNING 11-23 18:00:01 [hf3fs_metadata_server.py:123] Rank 0 only allocated 12 pages for 31 keys", file=sys.stderr)
waits = arm == "fix" and preemptions > 0
result = {
    "has_fix": has_fix,
    "pool_blocks": args.pool_blocks,
    "num_requests": 64,
    "prompt_tokens": 256,
    "output_tokens": 256,
    "wall_s": 61.23456789 if preempting else 4.5678,
    "output_tok_per_s": 267.5612345 if preempting else 3587.25,
    "steps": 4711 if preempting else 290,
    "step_ms_p50": 11.25,
    "step_ms_p90": 13.5,
    "step_ms_p99": 21.75,
    "step_ms_max": 88.125,
    "preemptions": preemptions,
    "wait_calls": 401 if waits else 0,
    "wait_total_s": 0.8125 if waits else 0,
    "wait_ms_p50": 1.5 if waits else None,
    "wait_ms_max": 9.25 if waits else None,
    "mean_step_ms": 12.0,
}
print(json.dumps(result, indent=2))
with open(args.out, "w") as f:
    json.dump(result, f, indent=2)
