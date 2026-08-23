# Why the M5-b engine is a 3B model on one T4

Every number in `config/vllm/deployment.yaml` comes from here, and every number here is labelled
**measured**, **derived**, or **estimated**. The distinction matters because the estimated ones are the
only place this page can be wrong, and the run has a cheap way to check them.

## What the card gives you

| | value | source |
|---|---|---|
| T4 memory | 15,360 MiB | measured — `nvidia-smi` reports this for a 16 GB T4 |
| `--gpu-memory-utilization=0.90` budget | 13,824 MiB | derived |
| Qwen2.5-3B-Instruct weights, fp16 | 5,886 MiB | measured — sum of the safetensors sizes on the Hub |
| non-KV overhead (activations, CUDA graphs, allocator) | ~1,400 MiB | **estimated** |
| KV cache left over | ~6,538 MiB | derived from the three above |

## What the KV cache holds

Qwen2.5-3B has 36 layers, 2 key/value heads and a head dimension of 128 (**measured**, read from the
model config). Grouped-query attention is what makes 3B viable here: two KV heads instead of sixteen.

    KV per token = 2 (K and V) x 36 layers x 2 kv_heads x 128 dims x 2 bytes = 36,864 B = 36 KiB

    capacity = 6,538 MiB / 36 KiB ~ 186,000 tokens        (derived, inherits the estimate above)

A contender prompt is **7,695 tokens** (measured; see `internal/bench/testdata/tokenizer_calibration.json`).
So roughly **24 concurrent contenders fill the cache**, and the guard's 0.85 engage threshold is crossed at
about **21**. That is the number the experiment lives or dies on: the pressure the arms are supposed to
differ under has to be reachable, and it is.

`--max-num-seqs=32` sits deliberately above 24. The block manager, not the sequence cap, has to be what
stops admission — otherwise the queue depth the guard reads is one the manifest chose.

## Why not 7B

Qwen2.5-7B-Instruct is 15.2 GB of fp16 weights against a 13,824 MiB budget. It does not fit, and no tuning
makes it fit. Quantising it to 4-bit would, but that puts a quantisation confound inside an experiment whose
whole claim is that the difference between arms comes from the admission policy. The engine here is a load
generator with a realistic shape, not the subject.

## The estimate, and how the run checks it

The ~1,400 MiB overhead figure is the one thing above that was not measured, and the KV capacity inherits
its error. vLLM prints the real answer at startup — the number of GPU blocks it allocated — and block count
times block size times KV-per-token-per-block gives the true capacity.

**The run must record that line and compare it against 186,000 tokens.** If the real capacity is far lower,
21 concurrent contenders is an overestimate and the guard engages sooner than planned; if far higher, the
trace's arrival rate may never reach the threshold and every arm returns the same result for the boring
reason. Either way it is a five-second check against a number that was written down first, which is the
only form of prediction that counts.

## Instance shape

One engine needs one T4. `g4dn.xlarge` (1 x T4, 4 vCPU) is what M5-b actually requires;
`infra/aws/cluster/eks.tf` currently provisions `g4dn.12xlarge` (4 x T4, 48 vCPU) because queuelab needs two
cards on one node. Running M5-b on the queuelab node group works and wastes three cards' worth of hourly
cost. A separate single-card node group is the cheaper shape if the two runs are not on the same day.

## What is still unmeasured

- Throughput. A 7,695-token prefill on a T4 is compute-bound and slow; the arrival rate the trace needs in
  order to build a queue follows from that, and it has not been measured. Set it from the first warmup run,
  not from this page.
- The `/metrics` magnitudes. The committed fixture was captured from the CPU build, so it pins series names,
  types, label sets and number formatting — not values. Recapture from this Deployment before quoting any
  KV-usage figure as characteristic.
