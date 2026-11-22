# SPDX-License-Identifier: Apache-2.0
"""Cost of HF3FS handle_preemptions under a preemption-heavy load (not for upstream).

Runs one in-process LLM with the HF3FS connector (in-tree mock file client,
in-process metadata state) and records:
- wall time and output tokens per second;
- engine step latency p50/p90/p99 (a TPOT proxy that shows stalls);
- preemption count;
- with the fix, the time spent in AsyncOperationManager.wait_for_saves.

usage: python bench_preempt.py --pool-blocks 128 --out result.json
"""

import argparse
import atexit
import json
import os
import statistics
import tempfile
import time
from unittest.mock import patch

os.environ["VLLM_ENABLE_V1_MULTIPROCESSING"] = "0"

import numpy as np  # noqa: E402

from vllm import LLM, SamplingParams  # noqa: E402
from vllm.config import KVTransferConfig  # noqa: E402
from vllm.distributed.kv_transfer import get_kv_transfer_group  # noqa: E402
from vllm.distributed.kv_transfer.kv_connector.v1.hf3fs import (  # noqa: E402
    hf3fs_connector,
)
from vllm.distributed.kv_transfer.kv_connector.v1.hf3fs.hf3fs_metadata_server import (  # noqa: E402,E501
    GlobalMetadataState,
)
from vllm.distributed.kv_transfer.kv_connector.v1.hf3fs.utils.hf3fs_mock_client import (  # noqa: E402,E501
    Hf3fsClient as MockHf3fsClient,
)


class InProcessMetadataService:
    def __init__(self):
        self.state = GlobalMetadataState()
        self.num_pages = 0

    def initialize(self, rank, num_pages=0, role="worker"):
        if role == "worker":
            self.num_pages = num_pages
            self.state.initialize_rank(rank, num_pages)

    def allocate_pages_for_keys(self, rank, keys):
        return list(self.state.allocate_pages_for_keys(rank, keys).items())

    def confirm_write_for_keys(self, rank, key_confirmations, pages_to_release=None):
        self.state.confirm_write_for_keys(rank, key_confirmations, pages_to_release)

    def batch_key_exists(self, keys):
        return self.state.batch_key_exists(keys)

    def get_key_locations(self, rank, keys):
        return self.state.get_key_locations(rank, keys)

    def num_stored_keys(self) -> int:
        with self.state.global_lock:
            return sum(m.is_complete() for m in self.state.key_metadata.values())


def wait_for_saves(manager, timeout=300.0):
    """Poll until no save is queued and every save future is done."""
    deadline = time.monotonic() + timeout
    while True:
        pending = [f for fs in manager._save_futures.values() for f in fs]
        if manager._save_queue.empty() and all(f.done() for f in pending):
            return
        assert time.monotonic() < deadline, "saves did not finish"
        time.sleep(0.05)


def pct(values, q):
    return float(np.percentile(values, q)) if values else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool-blocks", type=int, required=True)
    ap.add_argument("--num-requests", type=int, default=64)
    ap.add_argument("--prompt-tokens", type=int, default=256)
    ap.add_argument("--output-tokens", type=int, default=256)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    metadata = InProcessMetadataService()
    patches = [
        patch.object(
            hf3fs_connector, "Hf3fsMetadataClient", lambda *_a, **_k: metadata
        ),
        patch.object(hf3fs_connector, "Hf3fsClient", MockHf3fsClient),
    ]
    for p in patches:
        p.start()

    storage = tempfile.mkdtemp(prefix="hf3fs-bench-")
    max_model_len = args.prompt_tokens + args.output_tokens + 16
    llm = LLM(
        model="facebook/opt-125m",
        enforce_eager=True,
        gpu_memory_utilization=0.3,
        max_model_len=max_model_len,
        block_size=16,
        num_gpu_blocks_override=args.pool_blocks,
        enable_prefix_caching=True,
        kv_transfer_config=KVTransferConfig(
            kv_connector="HF3FSKVConnector",
            kv_role="kv_both",
            kv_connector_extra_config={
                "hf3fs_storage_path": storage,
                # 8 GiB of 576 KiB OPT-125m pages: about 14,500 pages, so no save is dropped.
                "hf3fs_file_size": 8 * 1024 * 1024 * 1024,
                "hf3fs_client_numjobs": 2,
            },
        ),
    )
    core = llm.llm_engine.engine_core.engine_core
    scheduler = core.scheduler
    worker = get_kv_transfer_group()
    manager = worker._async_manager

    counts = {"preemptions": 0}
    preempt = scheduler._preempt_request

    def count_preempt(*a, **k):
        counts["preemptions"] += 1
        return preempt(*a, **k)

    scheduler._preempt_request = count_preempt

    waits = []
    has_fix = hasattr(manager, "wait_for_saves")
    if has_fix:
        wait = manager.wait_for_saves

        def timed_wait(request_ids):
            t = time.perf_counter()
            wait(request_ids)
            waits.append(time.perf_counter() - t)

        manager.wait_for_saves = timed_wait

    step_times = []
    # The in-process client calls core.step_fn (step or step_with_batch_queue).
    step = core.step_fn

    def timed_step(*a, **k):
        t = time.perf_counter()
        out = step(*a, **k)
        step_times.append(time.perf_counter() - t)
        return out

    core.step_fn = timed_step

    rng = np.random.default_rng(0)
    prompts = [
        {"prompt_token_ids": rng.integers(1000, 30000, args.prompt_tokens).tolist()}
        for _ in range(args.num_requests)
    ]
    params = SamplingParams(
        temperature=0, max_tokens=args.output_tokens, ignore_eos=True
    )
    # Warm up kernels outside the measurement with an unrelated prompt.
    llm.generate([{"prompt_token_ids": [5] * 64}], params, use_tqdm=False)
    # Start the clock with an empty save queue.
    wait_for_saves(manager)
    step_times.clear()
    waits.clear()
    counts["preemptions"] = 0

    t0 = time.perf_counter()
    outputs = llm.generate(prompts, params, use_tqdm=False)
    wall = time.perf_counter() - t0
    out_tokens = sum(len(o.outputs[0].token_ids) for o in outputs)
    # Not timed: confirms no save was dropped for lack of storage pages.
    wait_for_saves(manager)

    result = {
        "has_fix": has_fix,
        "pool_blocks": args.pool_blocks,
        "num_requests": args.num_requests,
        "prompt_tokens": args.prompt_tokens,
        "output_tokens": args.output_tokens,
        "wall_s": wall,
        "output_tok_per_s": out_tokens / wall,
        "steps": len(step_times),
        "step_ms_p50": pct(step_times, 50) * 1e3,
        "step_ms_p90": pct(step_times, 90) * 1e3,
        "step_ms_p99": pct(step_times, 99) * 1e3,
        "step_ms_max": max(step_times) * 1e3,
        "preemptions": counts["preemptions"],
        "wait_calls": len(waits),
        "wait_total_s": sum(waits),
        "wait_ms_p50": pct(waits, 50) * 1e3 if waits else None,
        "wait_ms_max": max(waits) * 1e3 if waits else None,
        "mean_step_ms": statistics.mean(step_times) * 1e3,
        "stored_keys": metadata.num_stored_keys(),
        "storage_pages": metadata.num_pages,
    }
    print(json.dumps(result, indent=2))
    with open(args.out, "w") as f:
        json.dump(result, f, indent=2)

    for c in (scheduler.connector, worker):
        atexit.unregister(c.close)
        c.close()
    llm.llm_engine.engine_core.shutdown()
    for p in patches:
        p.stop()


if __name__ == "__main__":
    main()
