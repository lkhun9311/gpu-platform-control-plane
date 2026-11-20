"""Measure GPU memory during post-load weight conversion of a GPTQ MoE model, and whether loading succeeds.

Run once on the fix branch and once with the fix reverted, on the same GPU.
Around `process_weights_after_loading` it records torch allocated and reserved memory
(before, peak, after) and the conversion time.
A background NVML sampler records device-wide used memory, which includes the CUDA context
and other processes.
It hashes every parameter and buffer after conversion, so runs can be compared byte for byte.
It always writes the JSON, with `status` "ok" or the error and the stage it was reached in.
"""

import argparse
import hashlib
import json
import os
import threading
import time
import traceback

os.environ.setdefault("VLLM_ENABLE_V1_MULTIPROCESSING", "0")

import torch  # noqa: E402

from vllm.model_executor.model_loader import base_loader, utils  # noqa: E402
from vllm.utils.import_utils import import_pynvml  # noqa: E402

pynvml = import_pynvml()

GIB = 2**30
stats: dict = {"stage": "init"}
_orig = utils.process_weights_after_loading


class NvmlPeak:
    """Sample device-wide used memory every 5 ms and keep the peak per window."""

    def __init__(self) -> None:
        pynvml.nvmlInit()
        index = int(os.environ.get("CUDA_VISIBLE_DEVICES", "0").split(",")[0])
        self.handle = pynvml.nvmlDeviceGetHandleByIndex(index)
        self.peak = 0
        self.window_peak = 0
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def used(self) -> int:
        return pynvml.nvmlDeviceGetMemoryInfo(self.handle).used

    def run(self) -> None:
        while not self.stop.is_set():
            used = self.used()
            self.peak = max(self.peak, used)
            self.window_peak = max(self.window_peak, used)
            time.sleep(0.005)


nvml = NvmlPeak()


def _measured(model, model_config, target_device):
    torch.cuda.synchronize()
    before = torch.cuda.memory_allocated()
    reserved_before = torch.cuda.memory_reserved()
    torch.cuda.reset_peak_memory_stats()
    nvml.window_peak = nvml.used()
    stats.update(stage="convert", device_used_before_gib=nvml.window_peak / GIB)
    start = time.perf_counter()
    _orig(model, model_config, target_device)
    torch.cuda.synchronize()
    stats.update(
        stage="converted",
        allocated_before_gib=before / GIB,
        peak_during_gib=torch.cuda.max_memory_allocated() / GIB,
        allocated_after_gib=torch.cuda.memory_allocated() / GIB,
        extra_peak_gib=(torch.cuda.max_memory_allocated() - before) / GIB,
        reserved_before_gib=reserved_before / GIB,
        reserved_peak_during_gib=torch.cuda.max_memory_reserved() / GIB,
        reserved_after_gib=torch.cuda.memory_reserved() / GIB,
        device_used_peak_during_gib=nvml.window_peak / GIB,
        convert_seconds=time.perf_counter() - start,
    )
    # The memory numbers are recorded above, so a hashing failure cannot lose them.
    try:
        stats.update(processed_weights_digest(model))
    except Exception as e:  # noqa: BLE001
        stats.update(processed_sha256=None, hash_error=f"{type(e).__name__}: {e}")


def processed_weights_digest(model) -> dict:
    total = hashlib.sha256()
    count = 0
    for name, tensor in list(model.named_parameters()) + list(model.named_buffers()):
        # Flatten first: a 0-dim tensor cannot be viewed as bytes.
        data = tensor.detach().contiguous().reshape(-1).view(torch.uint8).cpu()
        digest = hashlib.sha256(data.numpy().tobytes()).hexdigest()
        total.update(f"{name} {tuple(tensor.shape)} {tensor.dtype} {digest}\n".encode())
        count += 1
    return {"processed_tensors": count, "processed_sha256": total.hexdigest()}


# base_loader imports the function by name, so patch both places.
utils.process_weights_after_loading = _measured
base_loader.process_weights_after_loading = _measured

from vllm import LLM, SamplingParams  # noqa: E402

PROMPTS = [
    "The capital of France is",
    "Write a haiku about GPUs.",
    "Explain mixture-of-experts in one sentence.",
    "1, 1, 2, 3, 5, 8,",
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="Qwen/Qwen3-30B-A3B-GPTQ-Int4")
    parser.add_argument("--revision", default="9b534e4318b7ebc3c961a839f13eb18b1833f441")
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--max-model-len", type=int, default=2048)
    parser.add_argument("--max-num-batched-tokens", type=int, default=None)
    parser.add_argument("--max-num-seqs", type=int, default=None)
    # "unset" leaves vLLM's default (1.0 with the extensible KV cache, sized from measured memory).
    # "auto" uses everything free at start-up.
    parser.add_argument("--gpu-memory-utilization", default="0.92")
    args = parser.parse_args()

    free, total = torch.cuda.mem_get_info()
    if args.gpu_memory_utilization == "unset":
        utilization = None
    elif args.gpu_memory_utilization == "auto":
        # Leave a little room for what vLLM allocates before its own start-up check.
        utilization = (free - 256 * 2**20) / total
    else:
        utilization = float(args.gpu_memory_utilization)
    result = {
        "label": args.label,
        "model": args.model,
        "gpu": torch.cuda.get_device_name(),
        "device_free_at_start_gib": free / GIB,
        "device_total_gib": total / GIB,
        "gpu_memory_utilization": utilization,
    }
    extra = {}
    if utilization is not None:
        extra["gpu_memory_utilization"] = utilization
    if args.max_num_batched_tokens:
        extra["max_num_batched_tokens"] = args.max_num_batched_tokens
    if args.max_num_seqs:
        extra["max_num_seqs"] = args.max_num_seqs

    nvml.thread.start()
    t0 = time.perf_counter()
    try:
        llm = LLM(
            args.model,
            revision=args.revision,
            max_model_len=args.max_model_len,
            enforce_eager=True,
            seed=0,
            **extra,
        )
        stats["stage"] = "loaded"
        result["engine_init_seconds"] = time.perf_counter() - t0
        outs = llm.generate(PROMPTS, SamplingParams(temperature=0, max_tokens=32))
        stats["stage"] = "generated"
        result.update(
            status="ok",
            token_ids=[o.outputs[0].token_ids for o in outs],
            texts=[o.outputs[0].text for o in outs],
        )
    except BaseException as e:  # noqa: BLE001
        result.update(
            status="error",
            error_type=type(e).__name__,
            error=str(e)[:2000],
            out_of_memory=isinstance(e, torch.OutOfMemoryError) or "out of memory" in str(e).lower(),
            traceback_tail=traceback.format_exc()[-3000:],
        )
    finally:
        nvml.stop.set()
        result.update(stats, device_used_peak_gib=nvml.peak / GIB)
        with open(args.out, "w") as f:
            json.dump(result, f, indent=2, default=list)
        print(json.dumps({k: v for k, v in result.items() if k not in ("token_ids", "texts", "traceback_tail", "error")}))


if __name__ == "__main__":
    main()
