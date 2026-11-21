# SGLang #51628: Mamba2 kernels compiling after a NemotronH server is ready

Reproduction kit for [sgl-project/sglang#51628](https://github.com/sgl-project/sglang/issues/51628).
The issue reports that `_chunk_scan_fwd_kernel` compiles during serving on NemotronH, 1.45 s and 1.0 s per rank, inside the first multi-request burst.
The reporter's reply (2026-11-20) names the cause: on NemotronH, prefill CUDA graph is disabled at startup, so nothing compiles the Mamba2 kernels before serving.

## Kits

`kit-r2` is this kit.
Run 1 (2026-11-20, `hack/sglang-51628/` on `feat/sglang-51628-compile-stall`) served Falcon-H1-0.5B, whose every layer has attention, so prefill CUDA graph capture compiled the Mamba2 kernels at startup and nothing Mamba2 compiled while serving.
Its verdict said "reproduces" because it counted three `_small_copy_kernel` compiles; r2's verdict counts Mamba2 kernels only, and lists every other kernel apart.

## Why this model

The runtime session's code reading (storage, `mamba2-serving-compile-51628/prefill-graph-path.md`) is that `cuda_graph_setup.py` turns prefill CUDA graph off unless every local layer is attention, and NemotronH's hybrid prefill graph is on only for SM120.
At the pinned SHA 03fde9cc, `NemotronHForCausalLM.supports_hybrid_prefill_graph` is `is_sm120()`, so on an A10G (sm_86) any NemotronH with separate Mamba layers should take the disabled path.
That is a reading, not a run, which is why the kit gates on the log line.

`nvidia/Nemotron-H-4B-Instruct-128K` at `f3c0b6c3b7fcb39e132b6007386e33a586d6e6cb` is the smallest NemotronH checkpoint on the Hub: 4.49 B parameters, 9.0 GB in BF16, `NemotronHForCausalLM`, pattern `M-M-M-M*-…` (4 attention layers among 52).
The other candidates checked on 2026-11-21: Nemotron-H-4B-Base-8K is the same size (either would do; the instruct one is the one run 1 already pinned by weight hash); Nemotron-H-8B (8.1 B, 16.2 GB) and Nemotron-Nano-9B-v2 (8.9 B, 17.8 GB) would leave little of 24 GB for the Mamba state cache; Nemotron-Nano-12B-v2 does not fit.

## What runs

`kit-r2/run.sh` runs as root on the instance the session bought:

1. Records the GPU and refuses a driver older than 580, which the CUDA 13.0 image needs.
2. Gives docker the NVIDIA runtime if the AMI's docker lacks it (run 1's bring-up).
3. Pulls `lmsysorg/sglang@sha256:d7976d3a…` (nightly-dev-20261120-03fde9cc) and refuses it unless the digest and its `org.opencontainers.image.revision` label, `03fde9cc392a5f84a54a365635ffed0061cdf1b8`, are the pinned ones. That commit is on SGLang main.
4. Runs `measure.sh` in one fresh container, then `verdict.py`.

`kit-r2/measure.sh`, inside the container:

1. Installs `sgl51628_compile_hook.py` as a `.pth` import, so every Python process with `SGL51628_COMPILE_LOG` set records each Triton compilation: kernel name, defining module, duration, cache hit, wall-clock time and pid.
   It sets `triton.knobs.compilation.listener` before SGLang's own watch, which keeps it in the chain.
2. The positive control (`probe_hook.py`): two fresh kernels, one before and one after SGLang's watch is installed on top, must each leave a record, and SGLang must log the second. A run stops here otherwise, since silence could not be told from nothing compiled.
3. Downloads the model at its revision and checks the sha256 of both weight files and the tokenizer.
4. MAIN: `python3 -m sglang.launch_server --model-path <model> --trust-remote-code`, with `TRITON_CACHE_DIR` empty, a fresh `HOME`, `TRITON_PRINT_AUTOTUNING=1`, and the compile threshold at its default.
5. The gate: the server log must hold a `Disable … prefill CUDA graph` line (on this SHA, "Disable prefill CUDA graph because some layers do not apply Standard GQA") and no prefill capture. If not, the run stops before any traffic.
6. The traffic, `python3 -m sglang.benchmark.serving --backend sglang --dataset-name random-ids --random-input-len 1024 --random-output-len 512 --random-range-ratio 1.0 --output-details`: the 64-prompt warmup at concurrency 32, then three runs each at concurrency 1, 16 and 128. Each burst's start and end are timed outside the client.
7. CONTROL, when there is time: the same server plus `--warmups prefill_shapes`, SGLang's own warmup of 17 single prefills from 64 to 32,768 tokens, run before the server listens, then the same bursts.

## Records and verdict

Every compile after ready is placed in the burst whose window holds its end time, or the gap it fell in.
`verdict.py` writes `verdict.json` and `verdict.txt`:

| Verdict | When |
|---|---|
| REPRODUCED | a Mamba2 kernel (the chunked scan, its state, cumsum, state passing, chunk bmm, the decode state update, causal conv1d) compiled after ready in MAIN |
| NOT REPRODUCED | every record is present and no Mamba2 kernel compiled after ready in MAIN; a valid result, stated plainly |
| GATE FAILED | the server did not start with prefill CUDA graph off (exit 4) |
| INCOMPLETE | a record or a field is missing, or the records disagree (exit 3) |

INCOMPLETE covers: the positive control failing; no install record from the server; no compile recorded before ready (the hook not shown live in the server); an SGLang "took N s to compile after serving started" line with no matching hook record; a Triton cache that was not empty; a burst that was skipped, failed, or completed fewer requests than it sent; a burst plan that is not this one.
The headline names `_chunk_scan_fwd_kernel`'s compiles, their seconds and their burst.
The first-burst TTFT hit is MAIN's warmup burst against CONTROL's (mean, median, p99); it says INCOMPLETE when CONTROL did not run or is incomplete, and NOT ISOLATED when CONTROL itself compiled a Mamba2 kernel after ready.
Each concurrency's run 1 against runs 2 and 3 is in the per-burst TTFT table.

## Where the kit departs from the spec, and why

- Prompts per run: the spec gives the concurrencies, not the counts. The runs send 4 prompts at c=1, 32 at c=16 and 128 at c=128, so the whole plan fits the session's 3,300 s with CONTROL after a pull that took 1,011 s in run 1.
- Seeds: each burst has its own `--seed` (42 for the warmup, as the client's default). With one seed, every run would resend the warmup's first prompts and hit the radix cache instead of prefilling, which would hide compiles and flatten the TTFT comparison.
- `HOME` is fresh per arm so one arm's JIT caches under `~/.cache` do not reach the other; `TRITON_CACHE_DIR` is empty per arm, as in the reporter's fresh containers.
- The model is a local directory downloaded at the pinned revision, so the server's `--model-path` is that directory, and the server and client run with `HF_HUB_OFFLINE=1`.
- CONTROL is skipped, with the reason recorded, when the time left is less than MAIN's own time plus 300 s for its warmup.

## How to run

From the repository root, with the kit committed:

```bash
SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab INSTANCE_TYPE=g5.2xlarge OUT=hack/gpu-kit-runs/2026-11-21-sglang-51628-r2 \
  bash hack/gpu-kit-session.sh docs/oss/sglang-51628/kit-r2
```

g5.2xlarge has the same A10G as g5.xlarge with 8 vCPUs and 32 GiB, for the 15.7 GB image's decompression and the model load.
The session's hard stop is 3,720 s after LaunchTime and its worst case is $0.9696 (4,020 s at $0.8683/h all in).
The offline checks are `bash hack/sglang-51628-kit-test.sh`.
