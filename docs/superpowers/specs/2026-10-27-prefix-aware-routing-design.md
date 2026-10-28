# Experiment A: does prefix-aware routing raise the engines' prefix-cache hits and lower TTFT, without a hot backend — pre-registered

Written 2026-10-26 for a session no earlier than 2026-10-27.
**Registered as v2 and frozen for purchase, 2026-10-27, at the commit that carries this line.** The owner approved every valid experiment of 2026-10-27 on 2026-10-26 ("유효 실험도 전부 승인하니 진행"), and on 2026-10-27, told that this session's proposed ceiling was $40, approved the paid sessions to go ahead ("유료 실험 진행 가능"); $40 is the ceiling. Nothing below changes after this commit, and a session run from code other than this commit's, as promoted to `main`, does not count.
Until this line, the status said: "registered as v2, built, rehearsed on kind end to end (twelve cells, stub engines), not frozen for purchase, nothing bought."
v1 of this page was attacked cold by codex `gpt-6-astra` before the build was finished (13 findings: 1 blocker, 9 major, 3 minor); every finding was re-derived and answered in "The cold attack and what changed" at the end, and v2 below is the result.
The seeds, the four trace checksums and the bytes every request sends are frozen in "Frozen traces", and a test fails if the generator ever produces anything else.
The page became frozen for purchase only at the commit carrying the line above, as C3's did; the owner's approval quoted there is the basis for buying one session, and nothing in this page is.
**Status, 2026-10-28: run 1 STOPPED before its first cell, because the collector Pod never became Ready; no cell ran, nothing was scored and no number below is a result.** "Run 1" and "Amendment for run 2", at the end, say what is known of the stop and what a second attempt changes.

## The question

On two vLLM engines, each alone on one A10G, behind this repository's gateway:
does an approximate prefix-cache-aware routing policy raise the engines' own prefix-cache hit ratio, and lower the premium tenant's time to first token at p50 and p99, against round-robin and against least-queue routing, on a trace whose requests share long system prompts — without one backend taking materially more than its share of the work or the tail?

Why it is asked here.
Until this change the gateway never spread a model's traffic: it sent every request to the oldest `InferenceDeployment` serving the model and treated the others as fallback (`backendsFor` in `internal/gateway/router.go`).
Routing across replicas for quality and cost is what a Kubernetes Gateway API inference gateway does, and the technique measured here is not invented: it re-implements the approximate prefix index of Gateway API Inference Extension proposal 0602 and llm-d's approximate prefix-cache producer, named below with what each source does and does not specify.

## What the technique is, and what was borrowed

| piece | source | what this repository does |
|---|---|---|
| hash chain | proposal 0602: "hash(chunk i) = hash(chunk i content + hash(chunk i-1))", fixed-size character chunks, no tokenizer ([0602](https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/main/docs/proposals/0602-prefix-cache-aware-routing-proposal/README.md)) | the same chain, FNV-1a 64 over each message's role and content, seeded with the model and the **tenant**, so one tenant's index entries can never steer another tenant's request (`prefixChain`, `internal/gateway/prefixindex.go`) |
| longest-prefix lookup | 0602: "find a server with longest prefix matching" | the backend holding the longest run of the request's leading chunks |
| index update | llm-d's producer "records the selected endpoint(s) in the index after scheduling", assuming the Pod now holds the prefix ([llm-d docs](https://llm-d.ai/docs/architecture/kv-management/prefix-cache-aware-routing); `pkg/epp/framework/plugins/requestcontrol/dataproducer/approximateprefix/README.md` at llm-d-inference-scheduler `b5cb5f8`) | the same, at routing time, before the engine has prefilled anything |
| eviction and sizing | 0602 says "mimic … LRU" and gives no size; llm-d sizes each endpoint's LRU to the engine's token capacity, `CacheNumBlocks × engine block size / router block` (`makeserver` in that directory's plugin source, same commit) | a per-backend LRU sized by that rule from the engine's measured capacity (below), plus a bound on how many backends the index remembers, so memory is finite whatever the backend count |
| block size | llm-d: 64 tokens by default and at minimum, approximated without a tokenizer by its estimate backend | 64 tokens at the gateway's own estimate of four characters a token: **256 characters** |
| load awareness | 0602: "a combined weighted score of servers depending on: prefix cache hit ratio, queue length and k-v cache utilization", with no weights; llm-d's affinity filter breaks stickiness when the sticky endpoint's TTFT exceeds the others' by a configured penalty | a load escape of this repository's own, stated next, because neither source gives a number |

**The load escape is an uncalibrated heuristic** (adopted from astra's finding 6).
The gateway sends a matched request to the backend A holding its prefix unless `outstanding(A) − outstanding(least loaded) > matchedTokens / 512`, where 512 is the profile's `--max-num-batched-tokens` and `matchedTokens` is the matched characters over four.
The reasoning behind the form: a hit saves about `matchedTokens / 512` engine steps, and a request queued ahead on A costs at least one step.
That "at least" is the weakness: a miss queued ahead costs about 16 steps (7,900 tokens / 512), so with misses in A's queue the rule keeps requests on A longer than the saving justifies.
For this trace's 40,000-character prompt the rule tolerates a gap of up to 19 requests.
Nothing measured supports 19; the registration therefore records, for every request, the two outstanding counts the decision saw and the chunks it matched (`X-Routing-Load`, `X-Routing-Match`, carried into each raw row), and judges the outcome the heuristic exists to prevent — a hot backend — directly, in rule 5.

## Arms

Three routing policies, each a value of the new `InferenceDeployment.spec.routing.policy`.
The gateway applies a policy only when every deployment serving the model in the namespace names the same one and none is HoldCap; otherwise it routes exactly as before, which a pipeline test pins (`internal/gateway/routing_pipeline_test.go`).

| arm | gateway behaviour | role |
|---|---|---|
| `RoundRobin` | the next backend in a per-model rotation, the other as fallback | the control a plain Service or load balancer gives |
| `LeastQueue` | the backend with the fewest requests this gateway has outstanding on it, ties taken in turn | the load-aware control that knows nothing of prefixes |
| `PrefixAffinity` | the backend holding the longest indexed prefix, unless the load escape sends it to the least-loaded one; with no match, least-queue | the treatment |

Ties take turns rather than going to the older backend because the first kind rehearsal showed what the older rule does at this load: with both backends usually idle, `LeastQueue` sent 67% of block 941's requests to `qwen-a`, and `PrefixAffinity`, whose unmatched prompts go to the least-loaded backend, placed 69% of its requests there, past the block's 0.624 share bound ("Rehearsal on kind"). That rule is changed before any purchase, which is what a rehearsal is for; it is recorded so the change is not mistaken for tuning on a result.

"Queue" is the gateway's own count of requests it has forwarded to a backend and not yet finished, not the engine's waiting queue.
With one gateway replica, which `config/gateway/deployment.yaml` fixes at `replicas: 1`, that count is exact for the traffic it routes and has no scrape staleness; the engines' own running and waiting gauges are sampled beside it as an endpoint.

## Apparatus

**Cluster.** `hack/eks-gitops-session.sh` gains `STUDY=prefixroute`, inside the same armed lifecycle as its other modes: the local TTL watchdog armed before anything is created, the GitOps baseline, then the study's gates, the AWS-side GPU deadline (`hack/lib/gpu-ttl.sh`), the purchase, the study, the verified scale-down and the destroy.
The cards are two g5.xlarge On-Demand in the `gpu` node group at `gpu_max_nodes = 2`, the group `TRAIN=ddp` bought on 2026-10-22, through the same gates (`hack/lib/train-session.sh`: `train_price_gate`, `train_quota_gate`, `train_qualify_nodes`, `train_scale_down`). Like `TRAIN=ddp`, the mode refuses a cluster it did not create, `KEEP_UP`, and `SERVE` or `TRAIN` beside it (`hack/test/check-train-session-refusals.sh`).
`gpu_single` is not used: its `max_size` is 1.

**Product under test, frozen across cells** (astra's finding 9). What Argo deploys from `main`: the CRD, operator and gateway carrying this change. So this branch must be merged and promoted, and the images built, before the session; the runner refuses a cluster whose CRD has no `spec.routing`.
Once both engines first run, the runner records the Argo revisions, the gateway's and operator's image IDs, the gateway's arguments (which must be `["/gateway"]`, so the routing sizes are the registered defaults) and the two GPU nodes' provider IDs, and requires all of them unchanged after every cell; the gateway Pod alone is replaced per cell, by design. The study's own tooling runs from the operator's checkout, and its commit and the harness binary's sha256 are recorded.

**Engines, pinned.** Two `InferenceDeployment`s, `qwen-a` then `qwen-b`, created two seconds apart so `qwen-a` is the older, in namespace `prefix-route` (`hack/eks-serve/prefix-route-study/engine.yaml.tmpl`): `replicas: 1`, `gpuCount: 1`, `gpuClass: a10g`, `port: 8000`, image `vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967` (v0.27.1), model `Qwen/Qwen2.5-3B-Instruct` at revision `aa8e72537993ba99e69dfaafa59ed015b17504d1`, and the new engine profile **`v0.27.1-a10g-prefix-cache`**: the measured profile `v0.27.1-a10g` with exactly one argument changed, `--enable-prefix-caching` in place of `--no-enable-prefix-caching` (`internal/controller/inference_engine.go`; `TestPrefixCacheProfileDiffersOnlyInCaching` fails on any other difference). No admission is set; the CRD refuses HoldCap on the new profile, because HoldCap was measured with caching off.
No controller-rendered profile turned prefix caching on before. The engine has been run with it once, by hand: `config/vllm/deployment.yaml` records a 7,695-token prompt at 0.092 to 0.097 s when seen before against 1.004 to 1.021 s when unique, which is the size of what a hit can save (corrected from v1, astra's finding 12).
Caching is read back from each engine's own startup line, `'enable_prefix_caching': True`, and from `vllm:cache_config_info{enable_prefix_caching="True"}`, in every cell.

**Tenant.** One GPUQuotaPolicy, `prefix-study-premium`, tenant `premium-1`, tier annotation `premium`, target namespace `prefix-route`, `gpuCount: 2` (`hack/eks-serve/prefix-route-study/study.yaml`), applied by the study and archived as applied.
There is no standard tenant: this study's load is one premium population, and "premium TTFT" means that tenant's TTFT.

**Gateway configuration.** The defaults, which are therefore the registered settings: chunk 256 characters; per-backend index capacity 7,985 chunks; at most 8 backends remembered; at most 2,048 chunks hashed per request (llm-d's `maxPrefixBlocksToMatch` default); step budget 512 tokens (`DefaultRoutingConfig`, `internal/gateway/routing.go`).
7,985 is llm-d's sizing rule applied to this engine: its measured capacity, `kv_cache_size_tokens="393232"` (`num_gpu_blocks="24577"`, block 16) in `vllm:cache_config_info` on the hold-cap product run's A10G (`hack/eks-serve/holdcap-study/runs/20261021T021149Z/holdcap-study/cells/*/metrics-engine-before.prom`), times 5.198 characters a token measured on this corpus (40,000 / 7,695, `internal/bench/testdata/tokenizer_calibration.json`), over 256 characters a chunk.
Each cell reads `cache_config_info` on both engines again; a capacity more than 5% from 393,232 makes the cell invalid, since the index would then be sized for a different engine.

**Sender, frozen** (astra's finding 8). The replay's whole-request timeout is 30,000 ms, the connection mode `pooled`, the pool 600 connections, as the admission studies' (`internal/bench/study.go`, `StudyPrefixRoute`); each cell's request IDs carry its own prefix. The scorer refuses a cell whose recorded sender configuration differs.

**Load.** Study `prefix-route-2026-10-27`, registered in `internal/bench/study.go` with its whole load, so `benchharness gen-trace` refuses every load flag for it (`cmd/benchharness/prefixtrace.go`):

- Poisson arrivals at **0.8 requests a second for 600 s**, one tenant, each request one user message of **41,000 characters**, output fixed at **64 tokens** (`min_tokens = max_tokens`), streamed with usage.
- **Shared trace:** each request draws one of **77 system prompts** uniformly; its message is that prompt's 40,000 characters, each prompt opening with its own header line so no two share a first chunk, followed by a 1,000-character part opening with the request's own seed and index, so no two requests share a suffix.
- **Unique-prefix control:** the same generator with the request's own header moved to the front, so every request's first chunk is unique and only the chat template can be shared. Its arrivals, lengths and draws are its seed's.
- Blocks: shared seeds **941, 942 and 943**; control seed **944**.

Why 77 prompts and not "a few", which the question's first wording asked for.
With caching on, what routing changes is which prefixes each engine keeps; if every prompt fits in one engine's cache, any routing hits after each engine's first miss per prompt.
The capacity is 393,232 tokens and a 40,000-character prompt is about 7,700 tokens, so about 51 prompts fill one engine.
77 prompts are 1.5 times one engine's capacity and 0.75 of each engine's under a perfect split, the regime where affinity can matter.
`hack/eks-serve/prefix-route-study/predict.py` replays the frozen traces through a token-level LRU model of two engines; with the same arrivals folded onto 4 prompts it predicts a difference of 0.007 to 0.008 between the policies, and on the 77 prompts 0.27 to 0.32 ("Predictions").
So the brief's "a few" would have tested nothing about routing; that is a prediction, and nothing below is set from it.

Why 0.8 a second, provisionally (astra's finding 7).
The control must be replayable at the same rate with no prefix hit at all, when each request pays a full prefill of about 7,900 tokens: about 1.0 s on this engine at its default step budget (`config/vllm/deployment.yaml`) and about 1.35 s at 512 (Finding 9).
Two engines at 0.4 a second each are then busy with prefill about 0.4 to 0.56 of the time; decode for 64 tokens a request and batching are not in that figure, and no measurement at this load bounds them.
So 0.8 is a provisional choice, not a demonstrated headroom. What protects the verdict if it is wrong is the validity line that requires `RoundRobin` to complete 99% of requests in every block: a saturated control makes its block inconclusive rather than producing a comparison between overloaded arms.

**Each cell.**

1. Set `spec.routing.policy` on both deployments to the arm; read it back.
2. Delete both engine Pods and the gateway Pod, so the cell starts with empty KV caches and an empty gateway index; wait for two fresh Ready engine Pods with `EngineInForce` True for the current generation, and one fresh Ready gateway Pod.
3. Read each engine's `non-default args` and `cache_config_info`.
4. Warm up each engine by its Pod IP, not through the gateway, with one 200-character request of 16 tokens that must end in `[DONE]`; the gateway's index never sees it.
5. Wait for both engines idle (running and waiting 0 for 10 s); read both engines' and the gateway's `/metrics`.
6. Replay the trace from a collector Pod against the gateway's Service; every 5 s sample both engines' running and waiting gauges and every Pod's UID and restart count.
7. Drain: the replay returns, then both engines idle for 10 s within 120 s; read every `/metrics` again; export, hash and check the files; read the product identity again.

The arm order is a Latin square over the shared blocks, so each arm runs once first, once second and once third (astra's finding 5):

| block | first | second | third |
|---|---|---|---|
| shared-941 | RoundRobin | LeastQueue | PrefixAffinity |
| shared-942 | LeastQueue | PrefixAffinity | RoundRobin |
| shared-943 | PrefixAffinity | RoundRobin | LeastQueue |
| control-944 | RoundRobin | LeastQueue | PrefixAffinity |

With three blocks no pairwise order can be balanced: `PrefixAffinity` precedes `RoundRobin` in two of them and follows it in one, and that is stated rather than hidden. The control block runs last.

## Endpoints

| endpoint | definition | unit |
|---|---|---|
| **H**, prefix-cache hit ratio | (Δ`vllm:prefix_cache_hits_total` summed over both engines) / (Δ`vllm:prefix_cache_queries_total` summed over both), each Δ from the cell's before read to its after read | tokens / tokens |
| premium TTFT p50, p99 | nearest-rank percentiles over **every** request in the trace of `firstTokenUnixNanos − (replayOriginUnixNanos + scheduledOffsetMs)`; a request that does not succeed is +∞ | ms |
| request share | per backend, answered rows whose `X-Routing-Backend` names it, over all answered rows | fraction |
| per-backend TTFT p99 | the TTFT p99 over the rows routed to each backend, +∞ entries included | ms |
| queue imbalance | mean over the cell's samples of \|(running + waiting) on `qwen-a` − the same on `qwen-b`\|, from the engines' gauges | requests |
| completion | succeeded / offered | fraction |

A request **succeeds** when HTTP status is 200, it carries no error, its stream ended with `[DONE]`, and the engine's own usage count of generated tokens is 64.
The engine's count and not the number of content events: the hold-cap product run recorded 14 requests that generated 64 tokens in 63 events (`hack/eks-serve/holdcap-study/runs/20261021T021149Z/README.md`), and counting events would have made them failures (astra's finding 2). Content events are recorded per row and not judged.
H is the engines' own count: what the gateway's index believed is never an endpoint. Every endpoint is printed for every cell whatever the verdict.

## Evidence completeness, per cell; anything missing makes the block unscorable

- the cell was run and recorded complete;
- raw rows one-to-one with the frozen trace by index, scheduled offset and tenant;
- every row stamped with the study, the arm and the trace checksum, and the sender configuration as frozen above;
- the product identity after the cell present and comparable;
- samples: a sample counts only if every read in it succeeded, and the counted samples leave no gap over 15 s; a sample with a failed read is dropped, never read as a value;
- each engine's and the gateway's `/metrics` before and after, carrying every series the endpoints and validity lines read.

## Validity, per cell; a failure makes its block inconclusive

- every answered row carries `X-Routing-Policy` equal to the arm and an `X-Routing-Backend` naming one of the two deployments;
- for each engine, Δ`vllm:request_success_total` equals exactly the HTTP 200 rows routed to it: the rows say where the work went, the engines say where it arrived;
- Δ`gpuaas_gateway_backend_fallbacks_total` is 0, so no row was served by a backend other than the one it names;
- both engines report prefix caching on, in their startup line and in `cache_config_info`, and a capacity within 5% of 393,232 tokens;
- every Pod's UID and restart count unchanged through the cell, and the product identity unchanged from the study's start;
- dispatch lag (`sendUnixNanos` − scheduled instant) at most 50 ms for every request;
- in every `RoundRobin` cell, completion at least 99% and a finite TTFT p99 on each backend, so every comparison below has a finite reference (astra's finding 4).

## Verdict rules, in this order of precedence

Each block is scored on its own, so a block that completed keeps its result when another did not (astra's finding 10).

1. **Not met**, naming each failure, if any complete and valid shared block fails rule 3, 4 or 5 below. A failure a valid block shows stands whatever else is missing, and the verdict then says the study is incomplete.
2. **Inconclusive**, naming the first cause, if any block is unscorable or invalid, or the study stopped.
3. Rules on each shared block:
   - **rule 3, hit ratio**: `PrefixAffinity`'s H exceeds both other arms' H;
   - **rule 4, TTFT**: `PrefixAffinity`'s p50 is below both other arms', and separately its p99;
   - **rule 5, no hot backend**: in the `PrefixAffinity` cell neither backend's request share exceeds the block's bound below, and its worse backend's TTFT p99 is no higher than `RoundRobin`'s worse backend's; an infinite treatment tail is a worse tail.
4. **Not attributable to prefix affinity**, if on the control block `PrefixAffinity`'s H exceeds `RoundRobin`'s or `LeastQueue`'s by 0.01 or more, or if in any shared block `PrefixAffinity`'s gain over a control arm is not larger than its gain over that arm on the control (astra's finding 3).
5. **Observed on these traces** otherwise: rules 3, 4 (both halves) and 5 held in every shared block, and the gain is attributable.

`hack/eks-serve/prefix-route-study/score.py` implements exactly this; its tests (`test_score.py`, 32) build a study meeting every line and fail it on each altered copy, and five mutations of the scorer's own rules were each caught ("Build status").
Every attempt is kept; no cell is rerun to replace another.

## Where every number comes from

| number | used in | basis |
|---|---|---|
| "in each of three shared blocks", rules 3 to 5 | the verdicts | **convention with its reason**: a direction required in three of three blocks, with no magnitude bar, because there is no pilot from which a variance could be derived and the repository has just published that its earlier magnitude bars had no basis (`docs/11_WHAT_THIS_MEASURED.md`, "What the targets were based on"). If the three blocks' orders were exchangeable fair coins under no effect, three agreeing would have probability 1/8; the order is a Latin square but the sessions are one card pair in one time sequence, so that 1/8 is a reference, **not a calibrated error rate** (astra's finding 5). The magnitudes are reported, not judged |
| 0.01, the control's absolute limit, rule 4 | attribution | **derived bound plus a stated margin**: on the control only the chat template can be shared, about 25 tokens of about 7,900 queried, 0.32% (`tokenizer_calibration.json`: the template is the fixed ~25 tokens); 0.01 is three times that. It is not enough alone, which is why rule 4 also requires every shared block's gain to exceed the control's |
| share bound, rule 5 | hot backend | **derived per block from its trace, with a two-standard-deviation convention**: if each prompt's requests all went to one backend chosen by a fair coin, a backend's share has mean 0.5 and standard deviation `sqrt(Σ n_g²) / (2N)`, `n_g` being the trace's requests of prompt `g` and `N` its total; the bound is 0.5 plus two of those. Computed exactly on the frozen traces by `share_coverage.py`, chance placement stays inside it with probability 0.954 to 0.956 (corrected from v1's bare "95%", astra's finding 11). A hot backend is one that does worse than chance placement |
| worse-backend p99 no higher than `RoundRobin`'s, rule 5 | hot backend | **convention with its reason**: round-robin is the placement a plain Service gives, so a treatment whose worst backend has a worse tail than round-robin's worst has created the hot spot the question asks about. A direction, for the reason in the first row |
| 99% completion and finite per-backend p99 in `RoundRobin` cells | validity | **derived**: the p99 is the 5th largest of 482 to 521 requests; with more than 1% failed, the p99 is +∞ and no comparison is defined |
| 50 ms dispatch lag | validity | **borrowed**: the hold-cap product study's bound, met in all three of its runs (`2026-10-15-holdcap-on-the-product-path-design.md`, "Validity"); here it is 5% of the ~1 s miss cost the TTFT endpoint separates |
| 5% capacity tolerance | validity | **convention with its reason**: one shared prompt is about 2% of 393,232 tokens; 5% is about two and a half prompts, past which the index would misjudge which prompts an engine still holds by more than two. Chosen before any card is read |
| 15 s sample gap | completeness | **borrowed** from the hold-cap product study, three times the 5 s sampling period |
| 0.8/s, 600 s, 41,000 characters, 77 prompts | load | **derived** above (capacity, the measured miss cost) except 0.8/s, a **provisional** choice whose headroom is not established, and 600 s, a **convention**: about 480 requests, so the p99 is not the maximum (the repository's 100-sample floor), and twelve cells fit one session |
| 64 output tokens, 30 s timeout, pool 600 | load, sender | **borrowed** from the admission studies' premium tenant and sender |
| 256 characters, 7,985 chunks, 2,048 chunks, 512 tokens | gateway defaults | **borrowed** (llm-d's 64-token block and match cap, the gateway's four characters a token), **derived** (llm-d's sizing rule on the measured capacity), **borrowed** (the profile's `--max-num-batched-tokens`) |
| the load escape's tolerance | gateway | **uncalibrated heuristic**, stated above, with the evidence to test it recorded per request |

## What would falsify it

- H not higher under `PrefixAffinity` in a valid shared block: on this load the approximate index does not raise the engines' hits.
- H higher and TTFT not lower: the hits do not buy first-token time at this load, for instance because affinity queues what caching saves.
- The control reproducing the gain: the gain is not prefix affinity.
- A backend past the share bound, or its tail past round-robin's worst: the policy creates the hot backend the escape was meant to prevent.
- Row-to-engine counts disagreeing: the routing record is not where the work went, and nothing the rows say about placement holds.

## What a pass would license, and what it would not

That on two A10Gs, one engine version and profile with prefix caching on, one model, one gateway replica and these four traces, this gateway's approximate prefix routing raised the engines' measured prefix-cache hit ratio and lowered the premium tenant's client-observed TTFT at p50 and p99 against round-robin and least-queue, without a backend exceeding chance placement's share or round-robin's worst tail.

It would not license:

- a working set other than 77 prompts at 1.5 times one engine's cache, popularity other than uniform, other prompt lengths or rates, or prompts that share less than a whole system prompt;
- that the load escape's tolerance is right, only that at this load the outcome it guards against did not occur;
- more than two engines, more than one gateway replica (the index and the counts live in one process), or any other card, model or engine version;
- a comparison with llm-d's or the Inference Extension's own implementation, which were read and re-implemented, not run;
- anything about tenant isolation of the engines' caches: the index is tenant-scoped, the engines' caches are not, and with one tenant nothing here measures either;
- an SLO, a cost per token, or production operation.

## Cost, duration and stopping

| item | estimate | from |
|---|---|---|
| cells | 12 × about 15 min: two engine starts in parallel (the hold-cap cells took 208 to 237 s outside a 420 s replay, `holdcap-study/runs/20261021T021149Z/README.md`), 600 s of replay, drain and export | measured overhead, registered replay length |
| card time | about 3.4 h each for two g5.xlarge On-Demand at $1.237 an hour (`hack/multi-pod-ddp-eks-20261022T004202Z/train/price.txt`): **about $8.4** | the price gate reads the list price again before buying |
| cluster | about 5 h at about $0.26 an hour: **about $1.3** | `hack/eks-gitops-session.sh` header |
| NAT data | the vLLM image, 9.1 GiB on each node, and 26 engine starts at 6.18 GiB of model each: about 179 GiB at $0.059: **about $10.6** | the hold-cap runs' figures |
| total | **about $20**, an estimate, not a bill | |

**What bounds the spend, and what does not** (corrected from v1, astra's blocker 1).
v1 said the cluster is destroyed "whatever this machine does". That is false, and it is withdrawn.
Two clocks exist. The **AWS-side GPU deadline** (`hack/lib/gpu-ttl.sh`, an EventBridge schedule) scales the `gpu` group to zero ten minutes before the local watchdog fires, and it runs whatever happens to this machine: it bounds the cards. The **TTL watchdog** that destroys the cluster is a local detached process using the operator's credentials: if this machine sleeps, dies or loses its session, the cluster, its CPU node and its NAT gateway keep billing, about $0.26 an hour, until destroyed by hand. That is true of every session this script runs, and it is the operator's residual risk to watch, not something this study can remove.
The envelope that is enforced: at `TTL_MINUTES=420`, the cards can bill at most the GPU deadline, about 6.2 h each after the build, **at most about $15.3** at the gated price; with the watchdog alive the cluster at most 7 h, **about $1.8**; NAT data at most the twelve cells' downloads, **about $10.6**, because no cell is retried. **About $28 in all**, which the proposed ceiling of **$40** covers, for the owner to confirm or change at the purchase gate.
What stops spending early: nothing is bought unless the On-Demand price is at most $1.40 an hour (the training gate's ceiling), the G-family quota fits 8 more vCPU, no destroy workflow is pending and the nightly destroy is outside the session; the runner stops at the first cell that cannot be run (no fresh engines, a failed replay, a failed export), at the first change of product identity, and before any cell that would not finish ahead of the teardown reserve. A stop is not a verdict: the scorer then scores every block that completed, and a failure a complete block shows still stands (rule 1).
The TTL must cover node join (900 s), plugin (600 s), setup (900 s), twelve cells of at most 1,500 s, scale-down (600 s) and 300 s, plus an hour for build and destroy: **at least 415 minutes**; the session refuses less (tested).
Instances carry the cluster root's `project=gpu-platform-control-plane` tag, which the session's residue check reads after the destroy.

## How to buy it, once approved

After this branch is merged to `dev`, promoted to `main`, and Argo's images are built from it:

```
AWS_PROFILE=gpu-lab SESSION_CONFIRM=yes STUDY=prefixroute TTL_MINUTES=420 hack/eks-gitops-session.sh
```

It needs SSO credentials for the `gpu-lab` profile (not `gpu-lab-ro`, which cannot decrypt the state), `gh` authenticated to check for a pending destroy workflow, `terraform`, `kubectl`, `aws` and `helm` on the PATH, and the nightly destroy outside the session's window. It creates its own cluster and refuses an existing one.

## Build status

Built in the working tree of `feat/prefix-aware-routing`, uncommitted, for the main session to review and commit:

- API: `spec.routing.policy` and the profile `v0.27.1-a10g-prefix-cache`, with the CRD regenerated by controller-gen v0.20.1 in a scratch copy and diffed before it was copied (only this CRD and the deepcopy changed); envtest specs for the HoldCap refusal and the policy enum.
- Gateway: `internal/gateway/routing.go` and `prefixindex.go`, the `X-Routing-*` headers, four metrics, flags whose defaults are the registered sizes; unit and pipeline tests.
- Harness: the shared-prefix load and `--prefix-control`, the routing headers in every raw row, the stub engine's prefix cache (`--enable-prefix-caching` and its counters).
- Study: `hack/eks-serve/prefix-route-study/` (runner, scorer, tests, predictor, share coverage, frozen checksums) and the session's `STUDY=prefixroute`.
- Mutations, each shown red and restored byte for byte: take the earliest tied backend; never move a fallen-back request's count; delete the HoldCap-on-prefix-cache rule from the generated CRD; delete `LeastQueue` from the generated CRD's enum; skip the scorer's replay-coverage check; skip its registered-arguments check; drop the load escape; drop the tenant from the chain; decide the policy on the head alone; never release a refused request's count; apply a policy when none is named; never evict from the index; drop a routing header from the sender; never evict from the stub's cache; add an argument to the prefix-cache profile; skip the session's TTL refusal; and in the scorer, drop the shared-versus-control comparison, drop the engine-count agreement, read content events as success, let an infinite treatment tail pass, let a stop hide an established failure.
  One mutation was equivalent and is recorded as such: counting stub cache hits past the first missing block changes nothing, because the hash chain makes a later block unmatchable once an earlier one misses.

## The bare review of the diff

codex `gpt-6-astra` reviewed the uncommitted change with no prompt (`codex review --uncommitted`), statically: it reports that its sandbox could not run the full Go suite. Its three findings are in `data/2026-10-27-prefix-aware-routing/codex-review-1.txt`; each was reproduced before it was fixed.

| finding | reproduced | fix |
|---|---|---|
| a request that falls back stays outstanding on the backend first chosen, so `LeastQueue` and the escape read a dead backend as busy and the live one as idle | yes: the count was taken at the decision and released at the end, with nothing between | `tryBackendsObserved` reports each attempt and the count moves with the request; a pipeline spec holds a fallen-back request on the live backend and reads 0 and 1, and the mutation that drops the move is caught |
| the sample gap line judged only the gaps between surviving samples, so two early samples passed | yes: the fixture with only its first two samples scored "observed" | the first and last counted samples must lie within 15 s of the replay's start and its last return; tested, mutation caught |
| a gateway started with a changed routing size passed, because identity was only compared across cells | yes: the fixture with `--routing-prefix-capacity-chunks=1` throughout scored "observed" | the scorer refuses any gateway arguments but `["/gateway"]`; tested, mutation caught. The runner also refuses them before the first cell, so the session does not pay for cells it could never score |

A second bare review, of the diff with these fixes and the tie rotation below, found no actionable regression (`data/2026-10-27-prefix-aware-routing/codex-review-2.txt`). Both reviews were static; the test, lint and mutation runs are mine and are reported in "Build status".

## Frozen traces

Generated by `benchharness gen-trace --study prefix-route-2026-10-27 --seed <seed> [--prefix-control]`; `TestPrefixTracesMatchTheFrozenChecksums` regenerates them and `TestPrefixPromptsMatchTheFrozenBytes` pins the bytes every request sends, which the trace checksum alone does not cover.

| block | sha256 of the trace | requests | prompts drawn | share bound | chance placement inside it |
|---|---|---:|---:|---:|---:|
| shared-941 | `2bdd82f10730e9e2d1408add4092ced7a09d51ce493cab5956f877df282f9efe` | 485 | 77 | 0.6243 | 0.9538 |
| shared-942 | `2b42ce96ed4037dd83c9e96c4a35956c2b32a1557150adcfa954fc0a8c5392e1` | 482 | 77 | 0.6240 | 0.9540 |
| shared-943 | `4b218170cbb32359446185fccc01a70fd1111b21eec102a08980a7e87ddd2dc5` | 521 | 77 | 0.6222 | 0.9560 |
| control-944 | `fd452cbcbd12d036205f7108a1bac1ab1bc1cdc315733c724f7e708e99d6a0f3` | 491 | 77 | — | — |

The list is `hack/eks-serve/prefix-route-study/frozen-traces.sha256`, which the runner checks before anything is applied.

## Predictions

`predict.py` on the frozen traces, a model without a clock: it ignores running requests' blocks, queueing and timing, so it cannot model `LeastQueue` and prints `RoundRobin`'s alternation for it. These are predictions, not bars.

| block | RoundRobin H | PrefixAffinity H | difference | the same arrivals on 4 prompts |
|---|---:|---:|---:|---:|
| shared-941 | 0.552 | 0.821 | +0.269 | +0.008 |
| shared-942 | 0.541 | 0.820 | +0.279 | +0.008 |
| shared-943 | 0.512 | 0.832 | +0.320 | +0.007 |
| control-944 | 0.002 | 0.002 | +0.000 | — |

The TTFT prediction is only qualitative: a hit's first token comes about ten times sooner than a miss's (0.09 against 1.0 s, `config/vllm/deployment.yaml`), so the p50 should move with H; the p99 sits among the misses in every arm and may move little.

## Rehearsal on kind

`hack/eks-serve/prefix-route-study/rehearse-kind.sh` on a throwaway kind cluster (context `kind-prefixroute`, deleted afterwards), 2026-10-26: the operator rendered both engines from the CRD and was stopped, each Deployment was pointed at `benchharness stub-serve --enable-prefix-caching` (a modelled cache of 513,000 of the stub's tokens, 130 µs of serial prefill per uncached token), and `run.sh` ran all twelve cells unchanged: arm set through each `InferenceDeployment`'s spec, fresh engines and a fresh gateway per cell, warm-up by Pod IP, the four frozen traces replayed in full from the collector, metrics read by Pod IP, export, hashing and scoring. It shows the apparatus and the scorer working end to end on the real traces; **every number below is the stub's, not an engine's, and none of it is evidence about vLLM**.

**First rehearsal, stopped after block 941.** Ties in the outstanding count went to the older backend, so at this load `LeastQueue` sent 67.2% of its requests to `qwen-a`, and `PrefixAffinity`, whose unmatched prompts take the least-loaded backend, 68.9%, past the block's share bound of 0.6243. Its hit ratio was 0.793 against 0.554 and 0.580. Ties now rotate (`leastLoaded`, `TestTiesRotate`), and the rehearsal was rerun from the start.

**Second rehearsal, all twelve cells, 15:03 to 17:17 UTC, verdict `observed on these traces`** (`data/2026-10-27-prefix-aware-routing/rehearsal-v2-verdict.txt`, `rehearsal-v2-run.log`). Every cell was complete and valid: 482 to 521 rows one-to-one with its trace, 114 samples, each engine's finished count equal to the rows routed to it, no fallback, completion 1.0.

| block | arm | H | p50 ms | p99 ms | share a / b |
|---|---|---:|---:|---:|---|
| shared-941 | RoundRobin | 0.554 | 300.5 | 2,491.2 | 0.501 / 0.499 |
| | LeastQueue | 0.564 | 58.3 | 2,322.7 | 0.505 / 0.495 |
| | PrefixAffinity | 0.822 | 54.9 | 1,365.8 | 0.536 / 0.464 |
| shared-942 | RoundRobin | 0.553 | 76.8 | 2,853.6 | 0.500 / 0.500 |
| | LeastQueue | 0.541 | 59.0 | 2,855.3 | 0.504 / 0.496 |
| | PrefixAffinity | 0.821 | 55.0 | 2,722.9 | 0.535 / 0.465 |
| shared-943 | RoundRobin | 0.529 | 626.2 | 2,316.8 | 0.501 / 0.499 |
| | LeastQueue | 0.519 | 694.6 | 2,538.4 | 0.501 / 0.499 |
| | PrefixAffinity | 0.832 | 55.0 | 1,805.9 | 0.449 / 0.551 |
| control-944 | all three | 0.000 | 1,355 | 2,997 to 2,999 | 0.501 / 0.499 |

What the rehearsal does and does not show:

- The stub's hit ratios land on `predict.py`'s (0.821, 0.820, 0.832 predicted for `PrefixAffinity`, 0.552, 0.541, 0.512 for `RoundRobin`), which says the gateway's index, the stub's cache and the predictor agree with each other; it says nothing about vLLM's cache.
- The control behaved as a control: no arm shared anything (the stub applies no chat template, so its floor is 0, not the engine's ~0.003).
- In block 942 `PrefixAffinity`'s p99 was below the others by 131 ms of about 2,850; a direction rule passes on such margins, which is why the registration reports magnitudes beside every verdict.
- The registered capacity bar was replaced, for the stub, by `--capacity-tokens 513000`, printed in the verdict; the paid session passes nothing.
- The second rehearsal ran the final code: tie rotation, fallback accounting, the scorer's replay-coverage and gateway-argument checks, and the runner's gateway-argument pre-check all predate its start. Later edits were to documents only.

## The cold attack and what changed

astra attacked v1 cold (`data/2026-10-27-prefix-aware-routing/astra-a-prompt.txt`, which names no place to look; the reply is `astra-a-reply.txt`). Each finding was re-derived before acting on it.

| # | severity | finding | re-derived | resolution |
|---|---|---|---|---|
| 1 | blocker | "destroyed whatever this machine does" is false: the cluster's watchdog is local; only the GPU deadline is AWS-side; no enforced envelope | yes: `hack/eks-gitops-session.sh` starts the watchdog with `setsid nohup bash`, and `ttl_arm` schedules only a node-group scale-down | **adopted in part**: the claim is withdrawn, the two clocks and the residual cluster risk are stated, and the enforced envelope is computed (about $28 under a $40 ceiling). **Rejected**: an independently enforced cluster teardown, because it is an infrastructure change every session shares, not this study's |
| 2 | major | success by content events would fail requests that generated 64 tokens in 63 events | yes: run 3's README, block 853, indexes 0 to 13 | **adopted**: success uses the engine's own token count; events recorded, not judged; tested |
| 3 | major | a 0.002 gain everywhere, control included, passed | yes, by the rules' arithmetic | **adopted**: every shared block's gain must exceed the control's, besides the 0.01 limit; tested, and the mutation that removes it is caught |
| 4 | major | rule 5 could pass ∞ ≤ ∞ | yes: four failures on one 240-request backend make its p99 +∞ while the cell completes 99.2% | **adopted**: `RoundRobin`'s per-backend p99 must be finite (validity), and an infinite treatment tail fails rule 5; both tested |
| 5 | major | the hash order put `PrefixAffinity` before `RoundRobin` in all three blocks; 1/8 is not calibrated | yes: 941, 942 and 943 all order `PrefixAffinity` first of the two | **adopted**: a Latin square; the 1/8 is a reference, not an error rate |
| 6 | major | the escape's "one step per queued request" is not derived for misses ahead | yes: a queued miss is about 16 steps | **adopted**: called an uncalibrated heuristic; each request records its outstanding counts and matched chunks |
| 7 | major | 0.56 utilisation omits decode; "a faster rate would overload" does not follow | yes: prefill alone saturates near 1.43/s | **adopted**: 0.8/s is provisional; the `RoundRobin` completion line turns saturation into an inconclusive block; the false sentence is gone |
| 8 | major | the sender configuration was never frozen | yes | **adopted**: 30 s, pooled, 600, enforced by the scorer; tested |
| 9 | major | the product's identity was not frozen across cells | yes: only in-cell Pod identity was checked | **adopted**: Argo revisions, images, gateway arguments and GPU nodes recorded at the start and required unchanged after every cell; tested |
| 10 | major | a stop turned an established failure into "inconclusive" | yes, by the v1 precedence | **adopted**: blocks are scored independently, and a valid block's failure stands; the runner scores even when it stops; tested |
| 11 | minor | two standard deviations is not exactly 95% | yes: exact coverage 0.954 to 0.956 on the frozen traces | **adopted**: labelled a convention, exact coverage published |
| 12 | minor | prefix caching had been run before, in `config/vllm/deployment.yaml` | yes: lines 93 to 99 | **adopted**: sentence corrected, and the measurement now supports the TTFT prediction |
| 13 | minor | checksums, predictor and bounds were placeholders | yes, at v1 | **adopted**: filled above from the committed generator and scripts |

## Run 1, 2026-10-28: STOPPED before its first cell, the collector Pod not Ready

**What ran.** The command in "How to buy it, once approved", from a clean worktree at `main` `1b4a8c07`, started 23:28:51Z on 2026-10-27, after the four-GPU session had torn down and every residue query had come back empty; the owner approved paid sessions on 2026-10-28 ("유료 실행 승인").
`main` had moved since this page's freeze, by the four-GPU and GPU-fault work: a dcgm-exporter toleration for the GPU-fault taint, which no node here carried, GPU-fault scoring and tests, the four-GPU scorer, and the operator's and gateway's images rebuilt by CI; nothing this study renders, sends or scores changed.
Every check before the purchase passed: P1 at $1.237 an hour against the $1.40 ceiling, P2 (0 in use plus 8 within 52), the GPU deadline armed for 393 minutes, and P3 with both nodes joined.
The study wrote the four traces, created the namespace, the quota policy, `qwen-a` and `qwen-b` and the study key, and then created the collector Pod.

**What failed.** `kubectl wait --for=condition=Ready pod/collector --timeout=300s` timed out, and the runner stopped with "collector not Ready" at 23:51:39Z; no engine was warmed and no cell started.
**The cause is not known.** The runner recorded only the timeout, and the cluster was destroyed eight minutes later.
The Pod is the hold-cap study's collector byte for byte: the same busybox digest, one CPU and 1 GiB requested, no node selector and no toleration, so it can only run on a CPU node, the GPU nodes carrying `nvidia.com/gpu:NoSchedule`; that Pod was Running in all three hold-cap sessions (`hack/eks-serve/holdcap-study/runs/*/holdcap-study/collector-pod.json`), where the GPU node carried the same taint (`gpu-node.json` of `20261021T021149Z`).
**That comparison does not carry**, as codex `gpt-6-astra` found in an adversarial review before run 2: the hold-cap clusters ran `kueue-crds` alone, and run 1's ran the full `gpu-platform-kueue` controller (`runbook-apply/applications.txt` of each), whose Deployment requests 500m CPU (`config/kueue-controller/manifests.yaml`).
On a t3.large's 1,930m allocatable, the controller and the collector's 1,000m leave 430m for every other Pod on the node, and the system Pods alone may need more.
**A CPU shortfall is the likely cause and is not verified**: the archive holds no Pod inventory or scheduler event, and an image pull or a failed container remain consistent with it.

**Teardown.** Both GPU instances were launched at 23:45:19Z and terminated at 23:53:58Z (CloudTrail); the cluster's destroy finished at 00:10:44Z with every residue query answered and empty, and the watchdog was disarmed.
**Cost, estimated, not billed:** 519 s of two g5.xlarge at $1.237 an hour, about $0.36, and about 41.5 minutes of the cluster at about $0.26 an hour, about $0.18.

**Evidence:** `hack/prefix-route/2026-10-28-run1/`, listed in `SHA256SUMS`; `NOT-COMMITTED.sha256` holds the hashes of `terraform.log`, `seeded-key.txt`, `ttl.pid`, the study key `prefix-study-key.txt` and the 40 MB harness binary, which are not committed (the binary's hash equals the run's `benchharness.sha256`). `session-stdout.log` is the session's terminal output.

## Amendment for run 2, 2026-10-28, approved by the owner before it is bought

The owner approved paid sessions on 2026-10-28 ("유료 실행 승인") and, after codex `gpt-6-astra` attacked both re-runs, told me to proceed with the recommendation after that review ("codex와 적대적 검토 후 권장안 진행"); the recommendation after the review was this run 2 with every change below, and the four-GPU run 3 held back until its scorer is hardened.
**One finding of that review is not acted on, and is disclosed instead:** the scorer runs only after the last cell, so a cell whose apparatus is already unscorable (an engine's cache capacity off its registered range, persistent sampling failures) does not stop the purchase of the rest; it costs money, not a false result, since the scorer still refuses those blocks.

**What changes**, and only this: when the collector is not Ready, `run.sh` saves the Pod's description, its namespace's events and every node's description into the study directory before it stops (`collector-describe.txt`, `collector-events.txt`, `nodes-describe.txt`).
A capture that fails keeps its error in its file and does not skip the stop or its scoring; exercised against a stub `kubectl` that fails the wait and two of the three captures, the block wrote `STOPPED`, and with the guards removed it did not.
It changes what a stop records and nothing the study does when the collector is Ready.
**Two more changes, found after run 1 by a whole-project audit (Claude `fable`, 2026-10-28) and re-derived here; without them run 2 would very likely have stopped at its first cell.**
First, each cell read the engine's `non-default args` line with `kubectl logs | grep -m1` under `pipefail`: grep exits at the match, the next write takes SIGPIPE, and the pipeline fails although the line was there.
An engine log of this profile is 59,494 bytes with the line at its seventh (`hack/mps-capability/2026-10-24-run2/m5c-run/mpscap/diag/logs-engines-m5c-a.txt`); streamed in two writes around the match it failed the same pipeline here, and the kind rehearsal passed only because a stub engine's log arrives in one write.
`run.sh` now saves each engine's log in the cell directory (`engine-a.log`, `engine-b.log`) and greps the file.
Second, cell 1 was the engines' first start on both new nodes, and a cell gives its fresh engines at most 600 s and its replay only until 1,200 s; one node's first start took 451 to 493 s in the hold-cap sessions, two nodes now pull the 9.1 GiB image through one NAT gateway, and a start past about 510 s fails the cell, which stops the study.
`run.sh` now waits for both engines' first start before any cell, for at most `FIRST_START` = 1,500 s, and stops if they do not start; every cell still replaces both engines, so none starts warm.
The session budgets those 1,500 s, so the TTL must be **at least 440 minutes**, not 415, and the session refuses 439 (`check-train-session-refusals.sh`; with the budget reverted that check fails).
Run 2 is bought with `TTL_MINUTES=440`; at the gated price that adds about $1 to the envelope, inside the ceiling.
**The collector's capacity is asked before any GPU is bought.** The collector requests 250m CPU instead of 1,000m and keeps its one-CPU limit, so the sender may still use a whole idle core; the value lives once, in `hack/eks-serve/prefix-route-study/collector.env`, which `run.sh` and the session both read.
A new gate, P4, after P2 and before the GPU deadline is armed, sums the CPU requests of every live Pod on each CPU node and refuses the purchase unless one node has the collector's request unrequested; it records its accounting in `cpu-capacity.txt`.
Exercised on stub inputs: a node of 1,930m with 1,300m requested passes 250m and 630m and refuses 1,000m, finished Pods and GPU nodes are left out, and unreadable input refuses.
The sender's registered configuration (30 s, pooled, 600 connections) is unchanged; its CPU request is not part of it, and the limit, which bounds what it can use, is unchanged.
**What does not change:** everything above this section except the TTL, the ceiling of $40 among it; run 1 spent about $0.54 of it.
A run 2 that stops at the collector again is reported with its cause and is not repeated under this amendment; one that passes the collector runs as registered.
**Run 2 is bought from `main` at the promotion that carries this section, once the owner approves this amendment.**
