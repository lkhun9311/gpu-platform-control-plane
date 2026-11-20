# vLLM #68819: GPTQ MoE layout copies before the Marlin repack

Validation kits and raw results for [vllm-project/vllm#68819](https://github.com/vllm-project/vllm/pull/68819), "[Perf][Quantization] Skip GPTQ MoE layout copies before Marlin repack".

## What the PR changes

When vLLM loads a GPTQ MoE checkpoint for the Marlin kernels, it repacks the expert weights into Marlin's layout after loading.
Before the PR, the weights took a round trip through two full-layer copies first: one from the checkpoint's K-first layout to N-first, and one straight back to K-first.
The PR passes transpose views instead of those copies when the backend is Marlin or Batched Marlin.
The conversion of an MoE layer then holds about one extra copy of its packed weights instead of three.
The PR claims no speedup; the gain is headroom at load time when a model barely fits.

## What the kit checks

`run.sh` builds vLLM at base commit `a3b845e226` twice, once unchanged and once with the PR's change applied from `fix.patch`.
It then runs, on the same GPU:

- the PR's unit tests on both sides, which must fail on the base and pass with the fix;
- full model loads of `Qwen/Qwen3-30B-A3B-GPTQ-Int4` on each side, recording the GPU memory peak during the conversion, the conversion time and a SHA-256 over every converted tensor;
- in run 6, an out-of-memory sweep: `filler.py` holds GPU memory so that only a set amount stays free, and each side tries to load and generate.

The SHA-256 over the converted tensors, and the unit tests that compare them with `torch.equal`, show that the fix changes how the conversion uses memory, not the weights it produces.
The generated token ids are recorded but are not an equality check, because vLLM's greedy output is not batch-invariant.

## Kits

Each run used the kit as it stood when it ran, so each kit is kept separately.
`fix.patch` is not stored here; it is the PR's commit in `git format-patch` form, and its SHA-256 identifies the exact file each run applied.

| File | SHA-256 as run |
|---|---|
| `kit-r5/run.sh` | `f78758f7be26dab28547c82fee43ced3fb20db32f507f8a29d368fadabaddf89` |
| `kit-r5/measure.py` | `b9ff9e489665561a5e28e935d8c18258e0b26ef27d140529f7868aa6d19c01ac` |
| run 5's `fix.patch`: the PR's commit `0b64393e9dec` | `7062f11f4c23f62fc1951188454e1e6fa4533a8c742afceca576ae692363e208` |
| `kit-r6/run.sh` | `fbfbf99377b057926d011b64d39a50c425fe8d11312516f155f57a296a6c98ab` |
| `kit-r6/measure.py` | `84a644eb69cf3e5bd9ae96ccd59ed186d332a37b929297dce0a0aa2f0843540b` |
| `kit-r6/filler.py` | `0624322ff3d4fc31eea2459291c18054fd384a6c6fbf6fed1d783e46901da160` |
| run 6's `fix.patch`: a later revision of the PR's commit, `adf1efbea37f`, with tests for 8-bit, a padded tile and Batched Marlin; not yet pushed to the PR | `126dab959cc922d7a32dc30ad3651831cb9c0227db1de2a39e6b6f9854f565f9` |

## How to rerun

On a machine with one GPU of at least 24 GB, at least 32 GB of RAM, and `uv` on the PATH:

```bash
cd kit-r5
git -C <a vLLM clone with the PR fetched> format-patch -1 --stdout 0b64393e9dec > fix.patch
sha256sum fix.patch   # 7062f11f… as in the table above
OUT=./results bash run.sh
```

The script writes everything to `$OUT`: a `status.txt` with each step's exit code, one JSON and one log per load, and the test logs.

## Runs

Each run's instance, LaunchTime, confirmed termination and cost bound are in [`runs.md`](runs.md), copied from the session records.

| Run | Instance | Cost (at most) | Outcome |
|---|---|---|---|
| 1 | g5.xlarge | $0.1033 | Stopped early: the kit called a command the instance did not have (exit 127). |
| 2 | g5.xlarge | $0.1810 | Tests as expected; every load was refused an mmap of the 16.9 GB checkpoint in 16 GiB of RAM, so later runs used g5.2xlarge. |
| 3 | g5.2xlarge | $0.2299 | Tests as expected; all four loads measured, with the same extra peaks as run 5. |
| 4 | g5.2xlarge | $0.2246 | Tests as expected; every load stopped in the kit's own weight hashing, which run 5's kit fixed. |
| 5 | g5.2xlarge | $0.2619 | All steps passed; see below. |
| 6 | g5.2xlarge | $0.4720 | All steps ran, including the sweep; see below. |

## Run 5 results (`results-r5/`, kit `kit-r5/`)

Four loads, two per side, in the order base, fix, fix, base:

| Side | Extra GPU memory peak during conversion | Conversion time | Converted tensors SHA-256 |
|---|---|---|---|
| base | 0.877 GiB (both loads) | 7.51 s, 7.48 s | `75413e90…` |
| fix | 0.292 GiB (both loads) | 7.37 s, 7.35 s | `75413e90…` |

The fix lowers the conversion's extra peak by 0.585 GiB on this model, and all four loads produce the same converted tensors.

## Run 6 results (`results-r6/`, kit `kit-r6/`)

The A/B loads repeat run 5's figures: 0.877 GiB on the base, 0.292 GiB with the fix, one converted-tensor SHA-256 throughout.

The sweep loads each side with only F GiB of GPU memory free, using `max_model_len` 512, `max_num_batched_tokens` 512, `max_num_seqs` 4 and `gpu_memory_utilization` "auto".
Each entry is the stage the load reached:

| F (GiB free) | Base | Fix |
|---|---|---|
| 16.4, 16.6, 16.8 | CUDA out of memory during the conversion | Conversion completes; then no memory is left for the KV cache |
| 17.0, 17.2 | Conversion completes; then no memory is left for the KV cache | Conversion completes; then no memory is left for the KV cache |
| 17.4 | Loads and generates | Loads and generates |

The fix converts at every F tried, down to 16.4 GiB free, while the base runs out of memory in the conversion at 16.8 GiB and converts at 17.0 GiB.
In this range the KV cache, not the conversion, decides whether either side can serve, so there is no F here where the base runs out of memory and the fix generates.

Each results folder carries a `SHA256SUMS` file for its contents.
