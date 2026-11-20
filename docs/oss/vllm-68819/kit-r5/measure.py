"""Measure the GPU memory peak of post-load weight conversion for a GPTQ MoE model.

Run once on the fix branch and once with the fix reverted, on the same GPU.
It records, around `process_weights_after_loading`, the allocated memory before,
the peak during, and the allocated memory after, plus the conversion time.
It hashes every parameter and buffer after conversion, so the two runs can be compared byte for byte.
It also keeps greedy outputs, which are not a reliable equality check because vLLM is not batch invariant.
"""

import argparse
import hashlib
import json
import os
import time

os.environ.setdefault("VLLM_ENABLE_V1_MULTIPROCESSING", "0")

import torch  # noqa: E402

from vllm.model_executor.model_loader import base_loader, utils  # noqa: E402

GIB = 2**30
stats: dict = {}
_orig = utils.process_weights_after_loading


def _measured(model, model_config, target_device):
    torch.cuda.synchronize()
    before = torch.cuda.memory_allocated()
    torch.cuda.reset_peak_memory_stats()
    start = time.perf_counter()
    _orig(model, model_config, target_device)
    torch.cuda.synchronize()
    stats.update(
        allocated_before_gib=before / GIB,
        peak_during_gib=torch.cuda.max_memory_allocated() / GIB,
        allocated_after_gib=torch.cuda.memory_allocated() / GIB,
        extra_peak_gib=(torch.cuda.max_memory_allocated() - before) / GIB,
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
    args = parser.parse_args()

    t0 = time.perf_counter()
    llm = LLM(
        args.model,
        revision=args.revision,
        max_model_len=2048,
        enforce_eager=True,
        gpu_memory_utilization=0.92,
        seed=0,
    )
    load_seconds = time.perf_counter() - t0
    outs = llm.generate(PROMPTS, SamplingParams(temperature=0, max_tokens=32))
    result = {
        "label": args.label,
        "model": args.model,
        "gpu": torch.cuda.get_device_name(),
        "engine_init_seconds": load_seconds,
        **stats,
        "token_ids": [o.outputs[0].token_ids for o in outs],
        "texts": [o.outputs[0].text for o in outs],
    }
    with open(args.out, "w") as f:
        json.dump(result, f, indent=2, default=list)
    print(json.dumps({k: v for k, v in result.items() if k not in ("token_ids", "texts")}))


if __name__ == "__main__":
    main()
