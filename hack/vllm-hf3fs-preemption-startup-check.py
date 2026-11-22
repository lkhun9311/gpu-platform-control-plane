"""Check, on CPU and before any GPU is bought, that the HF3FS preemption test's engine can start and its requests fit.

usage: python hack/vllm-hf3fs-preemption-startup-check.py VLLM_CHECKOUT
Run it with a CPU vLLM environment's python, with PYTHONPATH and the working directory set to VLLM_CHECKOUT,
a vLLM checkout that holds tests/v1/kv_connector/unit/test_hf3fs_preemption.py, and with the hub offline.
Runs p1 and p2 never reached their tests: LLM() refused max_model_len 1024 against a 48-block pool of 16 tokens.
This reads the test's own constants and prompts, without importing the test, and checks three things:
  the arithmetic: max_model_len fits the pool less the null block BlockPool holds back, and each request's prompt plus decode fits max_model_len;
  vLLM's own startup check: get_kv_cache_configs from the checkout, with the model's real layer shapes and the test's override,
    must accept max_model_len, which is the call that raised "available KV cache memory" on the GPU;
  the wiring: the test passes these very constants to LLM() and to SamplingParams.
Prints one ok or FAIL line per check and exits 1 if any failed.
"""

import ast
import math
import os
import sys

TEST_FILE = "tests/v1/kv_connector/unit/test_hf3fs_preemption.py"
CONSTANTS = ("E2E_MODEL", "BLOCK_SIZE", "NUM_GPU_BLOCKS", "MAX_MODEL_LEN", "DECODE_TOKENS")
# The prompts the GPU test sends, by the tags it passes to _prompt.
TAGS = ("Target", "Other")

failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


def main(checkout):
    src = open(os.path.join(checkout, TEST_FILE)).read()
    tree = ast.parse(src)
    consts = {}
    prompt_def = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) and node.targets[0].id in CONSTANTS:
            consts[node.targets[0].id] = ast.literal_eval(node.value)
        if isinstance(node, ast.FunctionDef) and node.name == "_prompt":
            prompt_def = node
    check(f"the test defines {', '.join(CONSTANTS)} and _prompt", set(consts) == set(CONSTANTS) and prompt_def is not None)
    if set(consts) != set(CONSTANTS) or prompt_def is None:
        return
    model, bs, blocks, mml, decode = (consts[k] for k in CONSTANTS)
    print(f"     {model}: block_size={bs} num_gpu_blocks_override={blocks} max_model_len={mml} decode_tokens={decode}")

    # The wiring: the constants checked here must be the ones the engine and the sampler get.
    llm_kw, sp_kw = [], []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ("LLM", "SamplingParams"):
            kw = {k.arg: ast.unparse(k.value) for k in node.keywords}
            (llm_kw if node.func.id == "LLM" else sp_kw).append(kw)
    check("LLM() is built with model=E2E_MODEL, max_model_len=MAX_MODEL_LEN, block_size=BLOCK_SIZE and num_gpu_blocks_override=NUM_GPU_BLOCKS",
          len(llm_kw) == 1 and all(llm_kw[0].get(k) == v for k, v in (("model", "E2E_MODEL"), ("max_model_len", "MAX_MODEL_LEN"),
                                                                       ("block_size", "BLOCK_SIZE"), ("num_gpu_blocks_override", "NUM_GPU_BLOCKS"))))
    check("the preempting generate uses max_tokens=DECODE_TOKENS with ignore_eos=True, so each request decodes all of them",
          any(kw.get("max_tokens") == "DECODE_TOKENS" and kw.get("ignore_eos") == "True" for kw in sp_kw))

    # The arithmetic, with vLLM's rule that the pool's null block is never handed out.
    usable = (blocks - 1) * bs
    check(f"max_model_len {mml} fits the pool's usable {blocks - 1} blocks x {bs} = {usable} tokens", mml <= usable)
    ns = {}
    exec(compile(ast.Module(body=[prompt_def], type_ignores=[]), TEST_FILE, "exec"), ns)
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(model)
    for tag in TAGS:
        n = len(tok.encode(ns["_prompt"](tag)))
        total = n + decode
        check(f"the {tag} request, {n} prompt tokens plus {decode} decoded = {total}, fits max_model_len {mml} "
              f"and the pool ({math.ceil(total / bs)} of {blocks - 1} blocks)", total <= mml and math.ceil(total / bs) <= blocks - 1)

    # vLLM's own startup check, from the checkout, with the model's real layer shapes.
    import vllm.v1.core.kv_cache_planning as planning
    from vllm.config import CacheConfig, ModelConfig, VllmConfig
    from vllm.v1.kv_cache_interface import AttentionSpec

    mc = ModelConfig(model=model, max_model_len=mml)
    vc = VllmConfig(model_config=mc, cache_config=CacheConfig(block_size=bs, num_gpu_blocks_override=blocks))
    # The engine core resolves the layout at startup; it does not change how many blocks a length needs.
    vc.cache_config.kv_cache_layout = "LBNHC"
    vc.cache_config.prefix_cache_retention_interval = None
    pc = vc.parallel_config
    spec = AttentionSpec(block_size=bs, num_kv_heads=mc.get_num_kv_heads(pc), head_size=mc.get_head_size(), dtype=mc.dtype)
    layers = _full_layers(spec, mc.get_num_layers(pc))
    try:
        configs = planning.get_kv_cache_configs(vc, [layers], [2**34], planning.get_global_kv_cache_groups(vc, [layers]))
        ok, why = True, f"{configs[0].num_blocks} blocks"
    except ValueError as e:
        ok, why = False, str(e).split(" Try increasing")[0]
    check(f"vLLM's get_kv_cache_configs accepts max_model_len {mml} with num_gpu_blocks_override={blocks} ({why})", ok)


def _full_layers(spec, n):
    # The planning tests build full-attention layers with this helper, which picks the manager vLLM uses for them.
    from tests.v1.core.utils import full_layer

    return {f"layers.{i}.attn": full_layer(spec) for i in range(n)}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: vllm-hf3fs-preemption-startup-check.py VLLM_CHECKOUT")
    try:
        main(sys.argv[1])
    except Exception as e:
        # An import or load that fails must read as a failed check, never as a short pass.
        check(f"the startup check ran to the end ({type(e).__name__}: {e})", False)
    print()
    print("startup check passed" if failures == 0 else f"{failures} startup check(s) failed")
    sys.exit(1 if failures else 0)
