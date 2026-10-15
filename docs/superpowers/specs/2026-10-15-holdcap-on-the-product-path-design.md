# Design: hold-cap's protection, measured on the product path on EKS

Written 2026-10-15. Status: **run, verdict not met** (`hack/eks-serve/holdcap-study/runs/20261015T050622Z/README.md`). Registered as v2, after codex `gpt-6-astra`'s adversarial review of v1 (5 blockers, 12 majors, 1 minor, every one answered in the table at the end); the registration below is as it stood when the session started.
The owner approved paid experiments for this work on 2026-10-15, subject to the purchase gate below.
Chosen over NCCL for `spec.distributed` after independent reviews by astra and me: both found neither ready to buy, and astra's case that this one answers a product question the lab result leaves open was accepted.

## The question

Finding 9 (`docs/11_WHAT_THIS_MEASURED.md`) measured hold-cap in a lab harness: a hand-applied engine, a gateway started with flags, a load generator on the same instance.
The product now renders it: an `InferenceDeployment` with `admission.mode: HoldCap` gets a controller-rendered engine with the cap, and the gateway admits that backend by serial-prefill and binds priority by tier (`docs/superpowers/specs/2026-10-11-holdcap-serving-mode-design.md`).
Does switching that object from `Off` to `HoldCap`, on EKS through the GitOps path, protect a premium tenant's time to first token on the diagnostic's traces, at a contender cost inside the limits registered here?

## What a pass would license, and what it would not

That on one g5.xlarge A10G in EKS, deployed through the GitOps path, switching one `InferenceDeployment` from `Off` to `HoldCap` lowered the premium tenant's scheduled, client-observed TTFT p99 to at most 0.85 of `Off`'s in each block of the diagnostic's three frozen traces, while the contender met each of the limits named below: completion, median and p95 latency, no refusal, no preemption, and the premium content-event gap.
It would replace "no latency, no load, no second tenant" in the "operated" row of `docs/11`; it would not replace "It is not operation".

It would not license:

- **a comparison with the lab's 0.30.** The product's `Off` binds no priority (the gateway runs with no flags, `config/gateway/deployment.yaml`, and `-bind-priority` defaults false, `cmd/gateway/main.go:137`), while `HoldCap` always does (`internal/gateway/server.go:560-569`); both engines schedule by priority (`internal/controller/inference_engine.go:53`). The lab held binding on in every arm. So this treatment is hold, cap and binding together. The two ratios are reported side by side, not compared;
- that the diagnostic's whole cost contract transferred: its line on contender work inside the premium window reads the engine's step log, which the product does not render, and it is not measured here;
- engine scheduling delay: without a gateway arrival stamp, TTFT here includes the client's own sending;
- a success rate, an SLO, another card, model, engine version or load, a tuned fixed spacing, or v27's predictions.

## Apparatus

**Cluster.** The existing session (`hack/eks-gitops-session.sh`) gains a study stage, `STUDY=holdcap`, inside the same armed lifecycle as `SERVE=yes`: after the baseline, `serve-sync`, `serve-rehearse`, the card's purchase and `serve-ready`, and before `gpu_down`. `serve-request` and `serve-recover` are not run in this mode.
The card is one g5.xlarge Spot in `gpu_single`; the diagnostic's was a g5.2xlarge (8 vCPU against 4), the same A10G. That difference is recorded, not controlled.

**Identity, frozen for the whole study.** At the start and after every cell the study records, and requires unchanged:
the revision every Argo Application has synced, the operator's and gateway's image digests and Pod UIDs and restart counts, the gateway's container arguments (exactly `["/gateway"]`), and the GPU node's provider ID.
A Spot replacement or a moved revision ends the study; the cells before it are kept and the study is reported incomplete.

**Tenants.** Two GPUQuotaPolicies applied by the study, frozen here and archived as applied:

```yaml
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: study-premium-1
  annotations: {platform.lkhun9311.github.io/tier: premium}
spec: {tenant: premium-1, targetNamespace: serve-a, limits: {gpuCount: 1}}
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: study-standard-noisy
spec: {tenant: standard-noisy, targetNamespace: serve-a, limits: {gpuCount: 1}}
```

Each creates a namespace ResourceQuota of one GPU in `serve-a` beside `serve-a`'s own; all three apply at once, the strictest wins, and one GPU is what the engine needs.
Their keys are added to `gateway-api-keys`. The trace's tenant names are fixed by `internal/bench/study.go`, which is why the policies take them.
Before every cell the study checks: exactly one policy per study tenant, the tier annotation exactly as above, one InferenceDeployment for the model in `serve-a`, and its Service's EndpointSlice resolving to exactly the engine Pod recorded for the cell.

**Load.** The diagnostic's traces, byte for byte: seeds 851, 852 and 853, with 4,019, 4,143 and 4,102 requests over about 420 s each.
They were copied unchanged from the diagnostic's local archive (`m5c-20261009-122503-diagD`, never committed) into `hack/eks-serve/holdcap-study/diagnostic/`, with the six manifests the diagnostic replayed them under (its `off` and `hold-cap` cells) and a `SHA256SUMS`.
Each trace's sha256 equals the `traceChecksum` in both of its manifests, checked when copied and again by the runner before each cell.
A new study, `holdcap-product-transfer-2026-10-15`, is registered in `internal/bench/study.go` with the diagnostic's replay settings: replay timing recorded, the 600-connection pooled sender, and the frozen token counts.
For each cell the runner derives a manifest from the archived one: the new study, the cell's arm, a relative trace path, and the live cluster's provenance (commit, gateway and engine digests). The derivation is a committed script, and its output is archived beside the original.
Replay sends no client priority, uses a request-ID prefix unique to the cell, and runs `benchharness` (static, built from the study's commit) in a collector Pod on the CPU node with a guaranteed 1 CPU and 1 GiB, against the gateway's Service inside the cluster. No port-forward carries measured traffic.

**Evidence the replay keeps.** `RawRow` gains the response's `X-Engine-Priority` header, so every row says which priority the gateway bound, or that it bound none.

**Collection.** The collector Pod also reads the engine's `/metrics` (Pod IP, port 8000) and the gateway's (Pod IP, port 8081), since the API server's Pod proxy may not reach either through EKS's security groups. Every series a check needs is parsed before measured traffic starts, or the cell does not start.
After each cell its files are copied off the Pod, hashed, and the inventory checked before the next cell starts.

**Arms and order.** Product `Off` (`admission: {mode: Off}`) and product `HoldCap` (`admission: {mode: HoldCap, maxHold: 25s}`).
**Every cell starts on a fresh engine Pod**: a mode change is a Recreate, and a cell of the same mode as the one before deletes the engine Pod. Both arms therefore get the same startup and the same warm-up, and no cell inherits another's engine.
Within each block the two arms run in the order of `sha256("<seed>/<arm>")`, ascending, which is fixed now and differs between blocks: block 851 runs Off then HoldCap, block 852 HoldCap then Off, block 853 HoldCap then Off (computed with `sha256sum` when this was written, and recomputed by the runner, which refuses a different order).

**Each cell:**

1. set the mode, or delete the engine Pod; wait for `status.admission.mode` equal to the arm with `observedGeneration` current, exactly one ready engine Pod, and the gateway's `gpuaas_gateway_backend_admission_mode` for the backend equal to the arm (`hold-cap` under HoldCap, `gateway` under Off), with `gpuaas_gateway_admission_mode_active` on `off`, which is what `gateway` then means;
2. read the engine log's `non-default args`: `long_prefill_token_threshold: 384` present exactly under HoldCap;
3. warm up: one premium request (200 characters, 64 tokens) and one contender request (40,000 characters, 16 tokens), in that order, each required to complete in full;
4. wait for idle: the engine's running and waiting gauges both 0 for 10 s; read both `/metrics`;
5. replay the trace; sample, every 5 s, `status.admission`, the gauge, and the engine's and gateway's Pod UIDs and restart counts;
6. drain: wait for the replay to return, then for the engine's running and waiting gauges to be 0 for 10 s, at most 120 s; read both `/metrics` again.

A cell is not started unless the card's own deadline (the AWS scale-down `gpu_up` arms) leaves its budget (25 min) plus a 10 min margin; the cluster's teardown after the card is covered by the watchdog's later deadline.

## Registration

**Study** `holdcap-product-transfer-2026-10-15`, seeds 851, 852 and 853, one block per seed, arms Off and HoldCap.

**Definitions.**

- A request's scheduled instant is `replayOriginUnixNanos + scheduledOffsetMs`.
- A request **succeeds** when HTTP status is 200, it carries no error kind, its stream terminated with `[DONE]`, its output tokens equal its limit (64 premium, 16 contender), and its content gaps number exactly one fewer than its output tokens.
- Scheduled client-observed **TTFT** is `firstTokenUnixNanos` minus the scheduled instant. A premium request that does not succeed has TTFT +inf. The premium p99 is the nearest-rank p99 over **every premium request in the trace**.
- A contender's **latency** runs from its scheduled instant to its last content event, taken as `firstTokenUnixNanos + (sum(gaps) + len(gaps)) × 1 µs` (each truncated microsecond added back, as `hack/prospective-pilot/pilot_report.py:659-669` does). It **completes** when it succeeds and that end is within 30 s; otherwise its latency is +inf.
- The premium **content-event gap** p99 is pooled over every gap of every successful premium request. It times non-empty SSE content events, not tokenizer tokens.

**Evidence completeness, per cell; anything missing makes the cell unscorable:**

- exactly the six cells registered, each once, with no other attempt;
- the cell's raw rows in one-to-one correspondence with its trace by index, tenant and scheduled offset: no row missing, duplicated or extra;
- every row stamped with the cell's study, arm and trace checksum, and the sender configuration the study registers;
- every 5 s sample present, with no gap over 15 s between samples during the replay; both `/metrics` reads before and after, parsing.

**Validity, per cell; a failure makes its block inconclusive:**

- every sample shows the cell's arm in `status.admission` and in the gateway's gauge, with the engine's and gateway's Pod UIDs and restart counts unchanged;
- the cap present exactly under HoldCap in the engine's `non-default args`;
- `X-Engine-Priority` on every answered row: absent under Off; 0 for premium and 1 for contender under HoldCap;
- dispatch lag (`sendUnixNanos` minus the scheduled instant) at most 50 ms for every request, and above 13 ms for at most 0.1% of premium requests;
- the frozen identity unchanged;
- in **Off** cells: premium loss under 0.5%, contender completion at least 95%, and finite premium p99 and contender p50 and p95, so every ratio below has a usable denominator.

**Acceptance for HoldCap, each line in each block:**

1. premium TTFT p99 at most 0.85 × Off's;
2. contender completion at least 95%;
3. contender latency p50 at most 1.5 × Off's, and p95 at most 25 s;
4. no refusal of any request, HTTP 429 or other;
5. premium content-event gap p99 at most 1.25 × Off's;
6. zero change in `vllm:num_preemptions_total` across the cell, read after its drain.

**Verdict, in this order of precedence:**

1. **not met**, if any HoldCap cell with complete evidence shows a refusal (line 4) or a preemption (line 6): these are observed in the cell itself, so they count whatever any comparison's validity;
2. **inconclusive**, if any block is unscorable, invalid or cut by the deadline: naming the first check that failed;
3. **not met**, naming the first failing line and block, if any comparative line fails;
4. **observed on these traces**: HoldCap met every line in all three blocks.

Every attempt is kept; no cell is rerun to replace another.

## Before any money

- **Committed:** the study registration, the `X-Engine-Priority` capture with its test, the manifest derivation, the runner, the collector, and the scorer.
- **The scorer** passes a synthetic fixture built to meet every line, and fails, naming the cause, on altered copies of it: a deleted, duplicated or extra row; a duplicated or missing cell; a wrong study or arm label; a missing sample or a sampling gap; malformed or missing metrics; a wrong priority header; a preemption; a refusal in an otherwise invalid block; an Off baseline below 95% completion; each acceptance line breached in turn.
- **On kind**, the runner's whole sequence runs end to end with the real traces: two tenants on one backend under three ResourceQuotas, an engine replacement with all three present, the collector replaying a full 420 s trace against `benchharness stub-serve` streaming with representative delays, metrics read from Pod IPs, files exported and hashed, and the scorer run on the result.
  What kind cannot show is the controller-rendered HoldCap status gate on a real engine; it was shown on an A10G on 2026-10-11 (`hack/holdcap-conformance/runs/20261011T030610Z/README.md`) and is covered by envtest.
- **What runs from where.** The product under test (operator, gateway, engine profile) is what Argo deploys from `main`; this study changes none of it, and the revision and image digests are recorded and frozen as above. The study's own tooling (`run.sh`, the harness binary, `score.py`) runs from the operator's checkout of this branch, and its commit and the harness's sha256 are recorded with the evidence.
- **The purchase gate**, read at the session's start and enforced: credentials, region, the G Spot quota and its current use, no destroy workflow pending, the nightly destroy outside the session, and a g5.xlarge Spot price at most $1.00 an hour in the chosen zone; any failure buys nothing.

## Budget

Downloads: the bundle's own HoldCap engine once, then six fresh engines, each 6.18 GiB of model; the vLLM image once, about 9 GiB, since every cell runs on the same node and a Recreate there keeps it.
That is about 52 GiB through the NAT, $3.3 at $0.059 a GB.
Card: about 2.6 h at up to $1.00 ($2.6); cluster without the card about 3.5 h at $0.26 ($0.9). About $6.8 in all.
The ceiling proposed here is **$15**, about twice the estimate; the owner approved paid work without naming an amount, so this figure is the design's, to be confirmed or changed at the purchase gate. The TTL is set to 300 minutes, because the session refuses to start unless it covers every worst-case wait (six cells at 25 min each among them); it is a cleanup backstop, not a dollar limit: the watchdog starts the destroy at the deadline, and a destroy that fails leaves resources billing until it is retried by hand.
What stops spending before the allowance: the purchase gate, the per-cell start rule above, and the study ending at the first identity change.

## Out of scope

The lab's `hold` and `cap` arms, R1, a fixed spacing, a second card, a heavier load, contender work inside the premium window, and option B of the serving-mode design.

## Run 2, registered 2026-10-15 before it ran

The first run's verdict, **not met**, stands; run 2 neither replaces it nor is pooled with it, and both are reported side by side whatever run 2 shows.
The owner approved it after reading the first run's result.

**What is the same:** every line of the registration above. The traces, the six cells and their order, the definitions, every completeness, validity and acceptance line, including the contender median limit of 1.5 × that the first run missed by 0.01 ×, and the verdict's precedence.

**What differs, and why:**

- **The study ID**, `holdcap-product-transfer-r2-2026-10-15`, registered in `internal/bench/study.go` with every other field equal to the first run's, which a test pins. Rows stamped with it cannot be scored as the first run's, and `score.py` reads it from the run's `study-id.txt`.
- **The product under test** is `main` with #361: the gateway drops an idle backend connection after 4 s, below the engine's 5 s keep-alive. The first run's one refusal was a 502 logged as a connection reset, which that mismatch can produce; run 2 is where that fix meets the same load.
- **The sampler retries** a failed read of the gateway's metrics up to three times within its 5 s tick, and records read errors in `sampler.err`. The rule is unchanged: a sample that still cannot show the arm counts against validity.

**What it can and cannot say beside run 1.** Two runs of one card are two runs, not a rate. If run 2 meets every line where run 1 did not, the record says the registration was met once and missed once, not that it is met; and the near-miss on the median is a property of the treatment the second run may or may not repeat.

## The review that shaped v2

codex `gpt-6-astra`, adversarial, on v1:

| finding | severity | answer |
|---|---|---|
| archived manifests carry an absolute path, the old study and arm; the new study is unregistered | blocker | registered study; derived manifests per cell by a committed script; originals archived |
| Pod-proxy metrics may be blocked by EKS security groups | blocker | read from the collector Pod by Pod IP; series parsed before traffic |
| the session has no multi-cell stage; evidence could die with the Pod | blocker | `STUDY=holdcap` inside the armed lifecycle; per-cell export, hashing and inventory |
| no request-for-request match to the trace | blocker | one-to-one by index, tenant and offset; mutation-tested |
| a TTL is not a dollar ceiling; downloads undercounted | blocker | enforced price gate and per-cell start rule; budget recounted at seven engines |
| added policies need GPU ceilings; three quotas interact | major | frozen YAML with `gpuCount: 1`; engine replacement rehearsed under all three |
| two requests do not witness routing or tier | major | policy, tier, deployment and EndpointSlice checks before every cell; per-row tier |
| the bound priority is not in the raw rows | major | `X-Engine-Priority` captured per row, checked per arm |
| controller status is not what the gateway applied | major | gateway gauge, identity and coverage are validity conditions |
| the fixed order confounds arm with engine age and time | major | a fresh engine for every cell; order per block from sha256 |
| warm-up and drain undefined; no general in-flight gauge | major | fixed warm-up shapes that must complete; idle and drain from the engine's running and waiting gauges |
| premium failures and success predicates underspecified | major | definitions above; failures at +inf in the premium population |
| Off's own completion floor dropped | major | Off validity: completion, loss and finite denominators |
| invalidity could hide a refusal or preemption | major | verdict precedence puts direct harms first |
| "inside the diagnostic's limits" overclaims without the window line | major | the claim names the retained lines; the window line is out of scope |
| revisions and machine not frozen | major | identity recorded and required unchanged; replacement ends the study |
| dispatch lag misses sender-side delay; collector placement unspecified | major | guaranteed 1 CPU collector; full-trace rehearsal; the endpoint named client-observed |
| the 37% bound and "inter-token" overstate | minor | removed; "content-event gap" |
