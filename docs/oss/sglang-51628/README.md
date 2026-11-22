# SGLang #51628: Mamba2 kernels compiling after a NemotronH server is ready

Reproduction kit for [sgl-project/sglang#51628](https://github.com/sgl-project/sglang/issues/51628).
The issue reports that `_chunk_scan_fwd_kernel` compiles during serving on NemotronH, 1.45 s and 1.0 s per rank, inside the first multi-request burst.
The reporter's reply (2026-11-20) names the cause: on NemotronH, prefill CUDA graph is disabled at startup, so nothing compiles the Mamba2 kernels before serving.

## Kits

`kit-r2` is the kit run 2 used, described in the sections below up to "Kit r3"; `kit-r3` is its CONTROL arm alone, described in "Kit r3".
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

## Kit r3

Run 2 (2026-11-21, `hack/gpu-kit-runs/2026-11-21-sglang-51628-r2`, commit 93fac369) gave REPRODUCED: 53 Mamba2 compiles after ready, 33.3 s, `_chunk_scan_fwd_kernel` 24 times.
Its CONTROL arm was skipped for its budget, since MAIN took 1,411 s.
`kit-r3` runs that arm alone: the same image, model, revision, traffic and seeds, with `--warmups prefill_shapes` on the server.

What changes from r2:
- `measure.sh` starts one server, `python3 -m sglang.launch_server --model-path <model> --trust-remote-code --warmups prefill_shapes`, and takes four arguments (no control switch).
- The server also gets `PYTHONUNBUFFERED=1`. In r2, buffered stdout spliced a `/health` log line into the middle of an autotune config line (r2 `server.log` line 137), and r3 reads that report.
- The compile hook keeps `constants` and `signature` whole (r2 cut them at 400 characters), and adds `attrs` (the divisibility specialisations) and `num_warps` and `num_stages` from the compile metadata.
- `r2-reference.json` pins r2's MAIN arm: its first-burst TTFT, its startup time from launch to ready, and its Mamba2 compiles before and after ready per kernel. It names the r2 files it was taken from (`verdict.json`, `arm.txt`, `compiles.jsonl`) and their sha256; the offline test re-derives it from them.

`kit-r3/verdict.py`:

| Verdict | When |
|---|---|
| WARMUP MOVES ALL | no Mamba2 kernel compiled after ready |
| WARMUP MOVES SOME | fewer Mamba2 compiles after ready than r2's 53, with the counts per kernel |
| NO EFFECT | as many Mamba2 compiles after ready as r2, or more |
| GATE FAILED | the server did not start with prefill CUDA graph off (exit 4) |
| INCOMPLETE | a record, a field or the reference is missing (exit 3); r2's rules, plus a startup with no launch time or a log that never says the warmup ended |

It also prints, per Mamba2 kernel, r3's compiles before and after ready beside r2's, the burst each late compile landed in and its class; the warmup burst's TTFT beside r2's; and the startup time beside r2's 153.8 s.

Triton's autotune report (`TRITON_PRINT_AUTOTUNING=1`) gives, per autotune, the kernel, the configs benchmarked (the `Autotuning kernel … with config` lines), the key, the seconds and the config chosen.
Each late compile of a kernel is classed only where the records allow it:
- autotune-config: one of several configs compiled for one specialisation (the same other constants, signature types and attrs), which only an autotune does;
- post-autotune specialisation: the only config compiled for its specialisation, and one an autotune chose;
- unclassified: a record lacks attrs, num_warps or num_stages, or a report is incomplete;
- no autotune report: no report names the kernel, which is not read as "not autotuned".
The n-th set of autotune-config compiles of a kernel, in time, is linked to its n-th report in the log, and the link is shown only when the number of configs and the chosen config agree.

From r2's own records, read with r3's parser (r2's compile records lack attrs, num_warps and num_stages, so its compiles stay unclassified):
the log reports two `_chunk_scan_fwd_kernel` autotunes of 18 configs each (17.15 s and 20.22 s), with keys `(256, 64, 128, True, …dtypes)`.
The second key has three more dtypes than the first, from pointer arguments that the first call passed as None.
The source at 03fde9cc lists 23 configs, keyed on `chunk_size, hdim, dstate, IS_CAUSAL` and pruned by tile size; with hdim 64 the five configs whose BLOCK_SIZE_N is 128 or 256 go, which leaves 18.
By time and tile constants, r2's 19 compiles before ready are the first autotune (18) plus one compile 1.5 s before ready.
Its 24 after ready are the second autotune (18, in the warmup burst), then 3 more in the warmup burst and 3 in c16-r1 and c16-r3.
That the 6 are specialisations of a chosen config is consistent with their tile sizes, but r2 did not record what would show it; r3 does.

Run from the repository root, with the kit committed:

```bash
SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab INSTANCE_TYPE=g5.2xlarge OUT=hack/gpu-kit-runs/2026-11-21-sglang-51628-r3 \
  bash hack/gpu-kit-session.sh docs/oss/sglang-51628/kit-r3
```

r2's pull took 737 s and its MAIN arm 1,411 s, so r3 should end in about 2,300 s of its 3,150 s budget; the session's worst case is still $0.9696.
The offline checks are `bash hack/sglang-51628-kit-r3-test.sh`.

## Kit r4

The runtime session's fix, `prewarm.patch` (local commit 40ca3cd5 on SGLang main cb337923, sha256 `6aa4b47c…24f9`), prewarms the Mamba2 prefill scan with initial states at startup.
`kit-r4` is an A/B of it on one instance, one fresh container per arm, BASE then FIX.
(The runtime session called this kit r3; `kit-r3` was already the CONTROL arm run of 2026-11-21, so this one is r4.)

No published image is built from cb337923 (the nearest nightly, e96e9675, is 48 commits behind it), so both arms run r2's image with a cb337923 tree installed over it:

- `run.sh` fetches cb337923 by commit id with git, copies it, and applies the patch to the copy with `git apply --index`.
  It records each tree's commit, `git write-tree` hash and `git diff --numstat` against cb337923 (`source-<arm>-before.txt`), and stops unless BASE is tree `55785ea9…` with no diff and FIX is tree `dfdd29ff…` (40ca3cd5's tree) with the patch's numstat: 43, 79, 8/1 and 158 lines.
  The same record is taken again after each arm, and the verdict re-checks both.
- Every container runs `pip install --no-deps --no-build-isolation -e python` from its tree, then shows that python imports `sglang` from that tree; the compile hook now also records each kernel's source file, and the verdict refuses an arm whose Mamba2 kernels came from anywhere else.
- A prep container installs the BASE tree, downloads the model and builds SGLang's Rust TreeCore extension from the tree with the loader's own source build.
  r2's server ran the Rust TreeCore the image bundles for 03fde9cc; a tree installed over the image has no bundled build and the image runs with `SGLANG_RUST_BUILD_MODE=never`, so without this the server would quietly fall back to the Python TreeCore.
  The arms copy the built artifact into their fresh HOME, and the servers get the `RUSTUP_HOME` and `CARGO_HOME` the prep built with, so the loader can fingerprint it.
  If the build fails, both arms run the Python TreeCore, and the verdict prints that as a departure from r2.
- FIX first runs `python -m pytest test/registered/unit/layers/test_mamba2_prefill_prewarm.py -q` on a Triton cache of its own (expected: 3 passed).
- Each server: r2's command, empty Triton cache, fresh HOME, default compile threshold; then r2's warmup burst (64 prompts at c32, seed 42) and three c16 runs (32 prompts, seeds 161 to 163). r2's c1 and c128 runs are dropped.
- Gates: both arms must log "Disable prefill CUDA graph because some layers do not apply Standard GQA" and capture no prefill graph; FIX must also log "Prewarmed the Mamba2 prefill scan for N layer geometries in X s.". An arm that fails sends no traffic, and FIX is not run after a BASE that did not reach traffic.

`kit-r4/verdict.py` (rules fixed before any run):

| Verdict | When |
|---|---|
| IMPROVED | both gates passed, FIX's tests gave 3 passed, and FIX's Mamba2 compiles after ready are at most half of BASE's and at least 5 fewer |
| NO CHANGE | both gates passed and that rule does not hold, or the tests did not pass; the reason is printed |
| NOT RUN | a gate failed (exit 4); or the comparison is not the specified one (exit 3): a tree off its pins, the patch hash, kernels from another tree, BASE logging the prewarm line, the arms on different TreeCores, or a missing record |

It prints, per arm: launch to ready and FIX's prewarm seconds; Mamba2 compiles before and after ready, and after ready per kernel per burst, counted as r2 counted them; the warmup burst's TTFT mean and p99 with n; and each c16 run's median ITL and output tokens/s, which are data and not a condition of the verdict.

Run from the repository root, with the kit committed:

```bash
SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab INSTANCE_TYPE=g5.2xlarge OUT=hack/gpu-kit-runs/<date>-sglang-51628-r4 \
  bash hack/gpu-kit-session.sh docs/oss/sglang-51628/kit-r4
```

BUDGET_S is 3,250 s, the most run.sh allows inside the session's 3,300 s (r2 and r3 used 3,150 s): the pull (r2 737 s, r3 438 s), the fetch, the prep (bounded at 900 s), then two arms of about 650 to 800 s each, with each arm bounded at 900 s and BASE's deadline leaving FIX a whole arm.
The run stops before the prep unless 1,920 s remain; after a 737 s pull the prep gets about 560 s.
The session's worst case is unchanged, $0.9696 (4,020 s at $0.8683/h all in).
The offline checks are `bash hack/sglang-51628-kit-r4-test.sh`.
