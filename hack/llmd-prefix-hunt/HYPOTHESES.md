# llm-d-router precise prefix-cache hunt: hypotheses and design

The goal is to find and measure disagreements between llm-d-router's precise prefix-cache index and what a real vLLM
actually serves from cache. This week's defects in this area (#4328, #4342) already have PRs.

Sources read:

- llm-d-router `7fc31fd1334883a1da45c4059fa7faea11b269b1` (main on 2026-11-19). The files: `pkg/kvevents/pool.go`,
  `event_dedup_filter.go`, `zmq_subscriber.go`, `engineadapter/`, `pkg/kvcache/kvblock/token_processor.go`,
  `extra_keys.go`, `in_memory.go`, and `preciseprefixcache/{producer,blockkeys,prerequest}.go`.
- vLLM `v0.34.0` (`62d4bc3c7e33b1b6c906e233e6af2d3506c482ca`, the revision label of `vllm/vllm-openai:v0.34.0`). The
  files: `vllm/distributed/kv_events.py`, `vllm/v1/core/{block_pool,kv_cache_manager,kv_cache_coordinator,kv_cache_utils}.py`,
  and `vllm/config/cache.py`.

## How the two sides meet

The router does not reuse vLLM's block hashes. For every `BlockStored` it rebuilds its own "request keys" from the
event's `token_ids`, `extra_keys`, LoRA name and the parent's request key, at its own `blockSizeTokens`, and it maps
vLLM's hash ("engine key") to those request keys only so it can resolve parents and removals. For a request, it hashes
the rendered tokens at the same block size and walks the index.

Two facts about v0.34.0 set up everything below:

- `CacheConfig.DEFAULT_BLOCK_SIZE` is **64**. The router's `defaultBlockSize` is still 16, with the comment "16 is the
  default value used by vLLM". With both defaults, one engine block maps to four request keys (1:many).
- `max_cache_hit_length` is `prompt_length - 1`, floored to the block size. On a whole-prompt hit vLLM recomputes the
  last token, and so the whole last block.

## Hypotheses

Rank is how likely the hypothesis looked from the code before the run. Every duplicate search ran on 2026-11-19 with `gh search issues --repo
llm-d/llm-d-router`, spaced 3 s apart.

| # | Hypothesis | Predicted observable | Trigger workload | Duplicate check | Rank |
|---|---|---|---|---|---|
| H1 | The router credits prefix tokens the engine cannot serve. (a) A shared prefix that ends inside a 64-token engine block is credited at 16-token granularity. (b) A whole-prompt hit is credited in full while vLLM recomputes the last block. This feeds `prefix_predicted_cached_tokens` and the P/D decider's `nonCachedTokens` (`prefix_based_pd_decider.go` uses `CachedBlockCount * BlockSizeTokens`). | Per request, predicted minus realized is in {16, 32, 48} for (a) and is 64 for (b) at aligned prompt lengths, the latter **even with router block 64**. Realized equals `floor(min(shared, L-1)/64)*64` exactly. | `bias` cases: shared prefixes of 528, 544 and 560 tokens; whole-prompt repeats of 512, 576 and 600 tokens; token-array prompts so both sides hash the same IDs. | No issue for "predicted cached tokens" (it returns metric-feature PRs #2897, #3057, #3171, none about the gap), "over-predict precise prefix", "prediction last block prompt", or "engine block size prediction metric", and later "recompute last token prefix", "last block recompute precise", "cached tokens overestimate", "nonCachedTokens overestimate". | **1** |
| H2 | With `kv_cache_report_mode=full`, vLLM re-announces every reused prefix block as a `BlockStored` (`emit_cached_block_events`, vLLM #45261). The router's `eventDedupFilter` counts each one as another reference. vLLM sends **one** `BlockRemoved` per evicted physical block, so the count never returns to zero, the removal is suppressed, and the index keeps the evicted prefix with no time bound. | After K full-report hits and an eviction flood, the router predicts the whole prefix on pod A while vLLM serves 0 cached tokens. Every one of the prefix's engine hashes shows K+1 stores and 1 removal on the wire. The same flow without reports leaves nothing stale. | `dedup` case: warm a 1,024-token prefix, 3 repeats with `vllm_xargs={"kv_cache_report_mode":"full"}`, a pre-flood probe, a flood sized at 1.5 x A's KV capacity, prediction-only check rows for both families (control first), then a post-flood request each. The control family is identical without the report flag. | No issue for "dedup BlockRemoved suppressed", "kv_cache_report_mode", "report mode full", "eventDedupFilter" (only #2825, a memory leak, closed), or "duplicate BlockStored". **But the mechanism is already described.** Closed-unmerged PR #2510 (vMaroon, "Repair precise cache indexes with bounded full reports", closed 2026-10-05) has it in a commit message ("each re-announced store also inflates the event dedup filter's reference counts, deferring eviction"). A review comment by nilig spells out `store(H) -> report store(H) -> sole remove(H)` leaving the count at 1, and the PR's `trackReport` counted a report only when no reference was tracked. None of that reached main, and no issue tracks it. Full reports are a supported input: tracker #2513 lists vllm#53308 (forwarding `vllm_xargs` so `/v1/messages` can carry `kv_cache_report_mode=full`) as done. So H2 would be a real-vLLM reproduction of a known but unfixed defect, and an issue or PR must credit #2510 and that review. | **2** (known mechanism) |
| C1 | (Control, known) The 1:many `realignExtraFeatures` copies an engine block's extra keys (salt or image hash) to every sub-block, while the request side tags only the first or the overlapping ones. | Router 16 predicts at most the blocks before the first mismatch; router 64 predicts what vLLM serves. | `salt` (a 512-token salted prefix) and `mm` (Qwen2-VL chat with one 336x336 image and a shared paragraph). | **Known**: #3788 (open, no PR found), #4342 (open, PR #4353 per today's survey). Run only as the harness's positive control. | control |
| H3 | `--prefix-match-unit 16` with block 64 registers partial-block entries. Their `BlockStored` (16 tokens, `block_size=16`) is skipped as `conflicting_block_size`, so the router under-predicts the tail by up to 48 tokens. | realized > predicted by at most 48 | not run | No issue for "prefix_match_unit", "conflicting_block_size", or "partial block BlockStored hash_block_size". **Not run**: v0.34's `UnitaryKVCacheCoordinator` asserts `hash_block_size == block_size`, so a dense single-group model cannot trigger it, and a hybrid model is outside this session. | 4 |
| H4 | Many:1 (router block larger than engine block): decode blocks and suffixes after an unaligned cached prefix are dropped as `incomplete_canonical_block` or `unresolved_sub_canonical_parent`. | predicted < realized | not run | **Known**: #2235 (open design), #3322, #3954, #4328. | — |
| H5 | LoRA: the request key uses the adapter as model name, and removals carry no adapter. | — | not run | #2927 (closed, fixed), #3989 (open, parser mapping). Low value without an adapter in the session. | — |

From code reading alone, offline, before the session:

- The C1 control reproduces in a scratch test against the pinned router. With engine block 64 and router block 16, a
  salted 128-token prompt matches 1 of 8 request keys, and an image at tokens 20 to 100 matches 0 of 8.
- `hack/llmd-prefix-hunt/probe`'s offline test runs the pinned router's producers on the event stream of a fake engine
  that follows v0.34's block, salt, last-token and eviction rules. H1 and H2 come out as predicted, and an engine that
  sends no reports leaves nothing stale. This shows what the session will record **if vLLM behaves as the source reads**.
  Only the real run can show that it does.

## Design

**Why a probe and not the full EPP.** The EPP needs a Kubernetes API for its endpoints even in standalone mode, and a
cluster with GPU pods on one g5.xlarge would add bring-up time and failure modes that have nothing to do with the
question. The probe links llm-d-router at the pinned commit and runs the EPP's own plugins:

- the OpenAI parser;
- the `token-producer` with the `vllm` backend, rendering chat requests on replica A;
- one `precise-prefix-cache-producer` per router block size, 16 (the default) and 64 (vLLM's default).

Each producer subscribes per pod through its own `Extract`, which is how the EPP subscribes with discovery. What the
probe leaves out is the scorer, the picker and the gateway, because the question is whether the index is right, not
where a scorer sends a request. A confirmed defect should next be shown in a router unit test fed with the captured
event payloads, which the probe records raw (`events.jsonl`, `payload_b64`).

**Topology.** One g5.xlarge (A10G, 24 GB) runs:

- two `vllm/vllm-openai:v0.34.0` replicas (pinned by digest, revision label checked) of `Qwen/Qwen2-VL-2B-Instruct`
  (Apache-2.0, 4.43 GB, pinned at `895c3a49`);
- each replica gets a fixed 3 GiB KV cache and `--gpu-memory-utilization 0.45`, and keeps vLLM's default block size.
  A fixed KV cache leaves the utilization at 0.92, and `request_memory` refuses to start with less free memory than
  that share, so without 0.45 the second replica would not start;
- profiling is limited to one 336x336 image and no video (`--limit-mm-per-prompt`), not the model's largest image
  and 999 videos;
- the replicas sit on one docker network at their own addresses, as two pods would, and publish ZMQ KV events on 5557
  under `kv@qwen2vl`;
- replica B serves nothing and is the per-row control: every prediction for B must be 0.

**Per-request proof.** Every row of `requests.jsonl` holds:

- the token IDs it sent;
- each router's prediction for each pod, taken **before** sending, after the event stream has been quiet for 400 ms
  (a convenience, not a barrier; see below);
- vLLM's `usage.prompt_tokens` and `prompt_tokens_details.cached_tokens`;
- the TTFT;
- the router's KV-event and index counters;
- the last event sequence number per pod.

`events.jsonl` holds every event batch, raw and decoded. For chat rows the record also keeps the rendered token IDs
and multimodal features the routers hashed. The verdict:

- gates everything on three checks: each pod's event sequence numbers are consecutive and both routers' subscribers
  received exactly as many batches as the independent tap; the engine announced one block size; and calibration (an
  aligned shared prefix) agrees on every side;
- requires every planned row of every repetition, so a run cut by its bound cannot pass as a whole one;
- checks on every measured row that pod B is predicted 0 and that the router and the engine counted the same prompt;
- for H1, checks every row against the engine's block rule, and checks each router's prediction is either what the
  engine served or what the index model gives. It reports the two components separately, and confirms only when both
  appear;
- for H2, reads predictions from **check rows** that send nothing, taken after the flood for both families, the
  control first. The trigger must be on the wire: all 16 engine blocks of each prefix, 4 stores per block for the
  full-report family and 1 for the control, and 1 removal per block before the check. The ordering is the barrier: the
  pool processes one pod's events in order, so a control predicted at 0 shows each router processed the control's
  first removal, and the verdict requires every removal of the reported prefix to come before it. Without the reports
  on the wire, H2 is void, not refuted.

**Outcomes.** For H1 and H2, confirmed and refuted are both results. A void is not, and the session then exits 2. A
void is a failed row, a missing row, a broken stream, no eviction, a missing report or removal, a stale control, two
engine block sizes, or broken parity. The salt control must reproduce #3788 for the session to succeed. The
multimodal control is reported but does not gate, since it also depends on the renderer, which neither hypothesis uses.

**What is not verified before the purchase.** The memory fit of two replicas is read from vLLM's code and estimated
(about 4.4 GB of weights, 3 GiB of KV and the profile peak each, against 10.1 GiB requested per replica on a 22.5 GiB
card). It has not been run. Neither have the Docker Hub pull time and the model download, and the bounds for them are
estimates.

**Cost.** The worst case is 4,140 s to the confirmed termination: **$0.90 Spot** (at the $0.70 cap) and **$1.51
on-demand** (at the pinned $1.237/h), both including EBS and IPv4. The session refuses any rate that puts it at
$3.00 or more.
