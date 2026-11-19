# OSS Validation Case Studies

This repository's paid-session and lab tooling has been reused to check changes proposed to upstream open-source projects.
Some cases are fixes written here and sent upstream.
Others check someone else's pull request or issue on real hardware.
The count of merged pull requests is not the point.
The point is that the same pieces, built once for the GPUaaS platform, now re-run an upstream question with pinned inputs and a fixed cost ceiling.

Every number below is read from a file committed in this repository, and the file is named next to it.
Some evidence sits on a branch that is not merged into `dev` yet; the branch and commit are named in those cases.
Upstream status was checked with `gh` on 2026-11-19.

## Contents

- [Summary](#summary)
- [What the platform provides](#what-the-platform-provides)
- [Cases](#cases)
  - [1. vLLM #58420: SRPF scheduling and its starvation threshold](#1-vllm-58420-srpf-scheduling-and-its-starvation-threshold)
  - [2. vLLM #67811: adaptive prefill time budget](#2-vllm-67811-adaptive-prefill-time-budget)
  - [3. vLLM #68548: TPOT observed as zero for single-token requests](#3-vllm-68548-tpot-observed-as-zero-for-single-token-requests)
  - [4. vLLM #68414, #68415, #68416: FLA kernel fixes](#4-vllm-68414-68415-68416-fla-kernel-fixes)
  - [5. AIBrix #3439: a failed metric source lets the rest scale down](#5-aibrix-3439-a-failed-metric-source-lets-the-rest-scale-down)
  - [6. AIBrix #3509: the opt-in hold for #3439](#6-aibrix-3509-the-opt-in-hold-for-3439)
  - [7. Kubernetes #142885: lowering limits.swap below swap usage](#7-kubernetes-142885-lowering-limitsswap-below-swap-usage)
  - [8. dra-driver-nvidia-gpu #1278: PrepareCompleted entries for deleted claims](#8-dra-driver-nvidia-gpu-1278-preparecompleted-entries-for-deleted-claims)
  - [9. llm-d-router #4258, #4259 and llm-d-inference-sim #920](#9-llm-d-router-4258-4259-and-llm-d-inference-sim-920)
- [Own pull requests with no experiment in this repository](#own-pull-requests-with-no-experiment-in-this-repository)
- [Not yet in this repository](#not-yet-in-this-repository)

## Summary

| # | Case | Kind | Hardware | Cost | Upstream status (2026-11-19) |
|---|---|---|---|---|---|
| 1 | vLLM #58420 SRPF threshold sweep | validation of someone else's work | 1× A10G, g5.xlarge Spot | cap $2.86, about $0.98 spent (threshold run) | PR open; author made 3 the default and cites the sweep |
| 2 | vLLM #67811 adaptive prefill | validation of someone else's work | 1× A10G, g5.xlarge Spot | caps $2.91 and $0.94 | PR open; 3 result comments posted |
| 3 | vLLM #68548 TPOT for single-token requests | own PR | 1× A10G, g5.xlarge Spot | cap $1.04 | PR open |
| 4 | vLLM #68414, #68415, #68416 FLA kernels | own fixes | 1× A10G, g5.xlarge Spot, 5 runs | caps $0.61 to $1.09 per run | issues open and claimed; vLLM PRs not opened; SGLang port #51413 open |
| 5 | AIBrix #3439 failed metric source | validation of someone else's work | kind, no GPU | $0 | issue open; the replay comment preceded the maintainer's choice of an opt-in annotation |
| 6 | AIBrix #3509 opt-in hold | validation of someone else's work | kind, no GPU | $0 | PR open; review comment posted |
| 7 | Kubernetes #142885 swap resize | validation of someone else's work | 2× t3.large on demand, no GPU | cap $0.26 per instance | PR open; reproduction comment posted |
| 8 | dra-driver-nvidia-gpu #1278 | validation of someone else's work | 1× A10G, g5.xlarge Spot | cap $1.99 (attempt 5) | issue open; nothing posted; S1 did not reach the issue's condition, S5 pending |
| 9 | llm-d-router #4258, #4259; llm-d-inference-sim #920 | own PR | kind, no GPU | $0 | all three merged |

A cap is the session's own worst-case bill: the hard stop plus the sweeper's period, at the all-in hourly rate the session prints before it launches.
It is a ceiling, not the amount spent.
Where a record holds the time actually billed, the case says so.

## What the platform provides

These are the pieces the cases reuse.
None was written for an upstream project; each came from the platform's own paid sessions and was then pointed at an upstream question.

| Piece | What it does | Where |
|---|---|---|
| Pinned CI images | Each vLLM session runs vLLM's own post-merge CI image by sha256 digest, and checks the image's `org.opencontainers.image.revision` against the commit the run claims | `public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:…` in each run's `session-provenance.txt` and `pytest-summary.txt` |
| Before and after patch application | A pinned diff is split in two: `vllm/*` is applied to the installed package under `dist-packages`, the rest (tests, docs) to the source checkout. Every touched file's sha256 is pinned for base, before and after, and a mismatch stops the state | `hack/vllm-tpot/state.sh`, `hack/vllm-tpot/pins.txt`, `hack/vllm-gdn-68414/state.sh`, `hack/vllm-gdn-68414/*-pins.txt` |
| Collection and import probes | The files the test collection actually loads are recorded on the instance and compared with the image; a loaded file that differs from the diff's base voids the case instead of passing it. For #58420 each engine core reports the threshold its scheduler holds after `Scheduler.__init__` | `hack/vllm-gdn-68414/fla_loaded_modules.py`, `hack/vllm-gdn-68414/import-closure.py`, `internal/bench/srpf_sweep.go` |
| Spot launch, termination sweeper and cost cap | `spot_launch` tags every instance with a study deadline; the sweeper Lambda ends any instance past its deadline; each session computes its worst case before buying and refuses above its cap | `hack/lib/spot-run.sh`, `infra/aws/bootstrap/sweeper/sweeper.py`, `hack/sweeper-exercise.sh` |
| Evidence archive | Each run gets a directory with `outcome.txt`, `session-provenance.txt`, `termination.txt` and the raw rows; large files left out are listed with their sha256 in `NOT-COMMITTED.sha256` | `hack/<study>/…/runs/<date>-<label>/` |
| Offline tests and mutation runners | Each session script runs offline against fakes for AWS and the engine; the mutation runner breaks each guard and checks the offline test fails | `hack/vllm-58420-session-test.sh`, `hack/vllm-tpot-session-test.sh`, `hack/vllm-gdn-68414-session-test.sh`, `hack/vllm-gdn-68414-session-mutate.sh` |
| kind labs | Pinned, free clusters that run upstream controllers against simulators, with a timeline sampled every 5 s and the controller's own log | `hack/aibrix-lane2.sh`, `hack/llmd-kv-lab.sh`, `hack/aibrix-pr3509.sh` (branch) |

Reuse across the cases:

| Piece | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|
| Pinned CI image | ✓ | ✓ | ✓ | ✓ | | | | | |
| Patch into the installed package | overlay | overlay | ✓ | ✓ | | | | | |
| Collection or import probe | engine core | identity | identity | ✓ | | | | | |
| Spot launch, sweeper, cap | ✓ | ✓ | ✓ | ✓ | | | sweeper tag | ✓ | |
| Evidence archive | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Offline test, mutation runner | ✓ | ✓ | ✓ | ✓ | | | | ✓ | |
| kind lab | | | | | ✓ | ✓ | | kind on EC2 | ✓ |

## Cases

### 1. vLLM #58420: SRPF scheduling and its starvation threshold

**Validation of someone else's work.**
Reused: pinned CI image, scheduler overlay pinned by sha256, engine-core probe, Spot launch with sweeper and cap, offline session test.

1. **Problem.**
   [vllm-project/vllm#58420](https://github.com/vllm-project/vllm/pull/58420) proposes Shortest Remaining Prefill First scheduling with a starvation threshold, `VLLM_SRPF_STARVATION_THRESHOLD`.
   Its author asked for a measurement on real hardware and then for a sweep of the threshold.
2. **Experiment environment.**
   One g5.xlarge Spot (A10G), ap-northeast-2c, AMI `ami-097edab977037f65f`.
   Image `vllm-ci-postmerge-repo@sha256:bfb59377…f35467`, vLLM `0.34.0rc1.dev527+g5039f736e`, with the PR head `b8b0d361`'s `scheduler.py` overlaid (sha256 `2b394353…72a`).
   Qwen2.5-3B-Instruct; a frozen open-loop trace of 4,102 requests, 3,917 short and 185 long.
   Sources: `hack/vllm-58420/2026-11-19-threshold-run1/session-provenance.txt`, `sr-run/sweep/summary.json`.
3. **Baseline.**
   The `fcfs` arm: short TTFT p99 5,983.5 ms, long completion p95 6,868.0 ms (`sr-run/summary.txt`, line 5).
4. **Result after the change.**
   Seven arms in a seeded order, 3,917 of 3,917 short and 185 of 185 long completed in each, 0 preemptions (`sr-run/summary.txt`).

   | Arm | Short TTFT p99 (ms) | Long completion p95 (ms) |
   |---|---:|---:|
   | fcfs | 5,983.5 | 6,868.0 |
   | priority | 1,476.4 | 7,936.8 |
   | srpf, threshold 2 | 1,717.6 | 7,901.8 |
   | srpf, threshold 3 | 1,799.2 | 7,814.1 |
   | srpf, threshold 5 | 1,942.3 | 7,791.6 |
   | srpf, threshold 8 | 2,176.3 | 7,683.8 |
   | srpf, threshold 10 | 2,359.4 | 7,685.5 |

   A lower threshold gave a lower short-request p99.
   Runs 1 to 8 before it (`hack/vllm-58420/2026-11-1[67]-run*/outcome.txt`) show the tooling being made trustworthy.
   Runs 2 and 6 returned evidence with every arm refused, because the engine-core probe found `PYTHONPYCACHEPREFIX` unset in the engine core, so the overlay could not be proven in use.
   Run 7 was reclaimed by Spot.
   Run 8 measured six arms on the earlier head, with fcfs at 5,967.4 ms and srpf at 1,939.2 ms short TTFT p99.
5. **Reproduction command.**
   `SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VLLM58420_AMI_ID=ami-... bash hack/vllm-58420-session.sh`, offline check `bash hack/vllm-58420-session-test.sh`.
   Cap: hard stop 12,100 s, worst case 12,400 s at $0.8292/h, about $2.86 (`session.log`, line 2).
   The last request ended 78 minutes after launch (16:41:03 to 17:59:02 UTC, from `launch-time.txt` and the raw rows); the README records the session at about 83 minutes and $0.98, with termination confirmed (`termination.txt`).
   The README's "Upstream open-source validation" section has a standard-library script that recomputes the table from the raw rows.
6. **Upstream status.**
   Open, not merged.
   [Results comment](https://github.com/vllm-project/vllm/pull/58420#issuecomment-6987224085).
   **Comment that changed a decision:** the author [replied](https://github.com/vllm-project/vllm/pull/58420#issuecomment-6987567919) and made 3 the default; the PR description now carries the sweep table and credits the measurement.

### 2. vLLM #67811: adaptive prefill time budget

**Validation of someone else's work.**
Reused: pinned CI image, PR files overlaid, image identity check, Spot launch with sweeper and cap, offline session test.

1. **Problem.**
   [vllm-project/vllm#67811](https://github.com/vllm-project/vllm/pull/67811) adds an opt-in adaptive prefill time budget.
   The thread named a `serve.py` baseline against the opt-in mode as the next gate.
2. **Experiment environment.**
   One g5.xlarge Spot (A10G), ap-northeast-2d.
   Image `vllm-ci-postmerge-repo@sha256:c0c20a4c…eac15`, Qwen2.5-3B-Instruct fp16, `max_num_batched_tokens` 8192 (`hack/vllm-67811/2026-11-18-run1/ap-run/summary.txt`, `ap-run/sweep/ap-*.args.txt`).
3. **Baseline.**
   `base` (`long_prefill_token_threshold` 1024, adaptive off), median of 5 scored runs: short TTFT p95 1,501 ms, decode token gap p99 549 ms, 351 output tokens/s (`ap-run/sweep/ap-1-base.r0.json` to `r4.json`; `ap-6-base` repeats it within 1 ms).
4. **Result after the change.**
   Both adaptive engines stalled in the warm-up invocation and scored 0 of 5 runs (`ap-run/summary.txt`: "ap-2-adaptive: done, 0 of 5 scored runs").
   The comparison arm `t512` (threshold 512) scored 5 of 5: short TTFT p95 839 ms, decode gap p99 287 ms, 346 tokens/s.
   Run 2 started one adaptive engine and traced every controller call: 7,397 timed steps, warm-up not passed (`hack/vllm-67811/2026-11-18-run2/ap-run/sweep/summary.tsv`).
5. **Reproduction command.**
   `SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VLLM67811_AMI_ID=ami-... bash hack/vllm-67811-session.sh`, offline check `bash hack/vllm-67811-session-test.sh`.
   Caps from each `session.log`: run 1 13,440 s at $0.7792/h, about $2.91; run 2 4,340 s, about $0.94.
6. **Upstream status.**
   Open, not merged.
   Three comments: [the measurement](https://github.com/vllm-project/vllm/pull/67811#issuecomment-6967453629), [a CPU reproduction attempt](https://github.com/vllm-project/vllm/pull/67811#issuecomment-6967700360), [the traced re-run](https://github.com/vllm-project/vllm/pull/67811#issuecomment-6968495394).
   No author reply after them as of 2026-11-19.

### 3. vLLM #68548: TPOT observed as zero for single-token requests

**Own PR.**
Reused: pinned CI image, before and after patch application into `dist-packages`, file pins, Spot launch with sweeper and cap, offline session test.

1. **Problem.**
   `vllm:request_time_per_output_token_seconds` recorded a TPOT of 0 for every request with fewer than two output tokens, while `vllm bench serve` excludes them.
2. **Experiment environment.**
   One g5.xlarge Spot (A10G).
   Image `vllm-ci-postmerge-repo@sha256:9f77cb65…145bb`, checkout head `3a1c6c43`, vLLM `0.34.0rc1.dev796+g3a1c6c43d`, TinyLlama-1.1B pinned (`hack/vllm-tpot/runs/2026-11-18-run1/tp-run/summary.txt`, `tp-run/sweep/before/versions.txt`).
3. **Baseline.**
   The new test alone (`serving-test-only.diff`): `test_tpot_skips_single_token_requests[-text]` failed, `assert (5.0 - 0.0) == 2`, so the histogram count rose by 5 where 2 were expected (`tp-run/sweep/before/tpot-lines.txt`, `before/tpot.log`).
4. **Result after the change.**
   With `fix.diff`: 3 of 3 parametrisations of the test passed, and the whole test file passed 12 of 12 (`verdict.txt`: `before=failed-as-expected`, `before_delta=5`, `after=passed`, `verdict=confirmed`).
5. **Reproduction command.**
   `SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VLLMTPOT_AMI_ID=ami-... bash hack/vllm-tpot-session.sh`, offline check `bash hack/vllm-tpot-session-test.sh`.
   Cap: 4,800 s at $0.7792/h, about $1.04 (`session.log`).
   Launch 14:10:25 UTC, both states done 14:32:11 UTC (`launch-time.txt`, `tp-run/summary.txt`).
6. **Upstream status.**
   [vllm-project/vllm#68548](https://github.com/vllm-project/vllm/pull/68548), open.
   When the README's section was written the PR was not opened yet; it is now.

### 4. vLLM #68414, #68415, #68416: FLA kernel fixes

**Own fixes** for three issues filed by someone else.
Reused: pinned CI images, before and after application into `dist-packages`, collection and import probes, Spot launch with sweeper and cap (including the on-demand option added for run 2), offline tests and the mutation runner.

1. **Problem.**
   - [#68414](https://github.com/vllm-project/vllm/issues/68414): `chunk_gated_delta_rule` skips every sequence after a zero-length one in `cu_seqlens`.
   - [#68415](https://github.com/vllm-project/vllm/issues/68415): `fused_recurrent_kda` allocates the wrong output shape when key and value sizes differ.
   - [#68416](https://github.com/vllm-project/vllm/issues/68416): recurrent delta-rule kernels read the wrong state slots for strided index tables.
2. **Experiment environment.**
   One g5.xlarge Spot (A10G) per run, in `hack/vllm-gdn-68414/runs/`.
   | Run | Image digest | vLLM commit |
   |---|---|---|
   | 1, 2 | `sha256:45feec27…d99ed` | `8700cc9b` |
   | 3 | `sha256:9071b00d…3f5f` | `428c371b` |
   | 4 | `sha256:639209c4…f8ac` | `3e469e9f` |
   | 5 (branch) | `sha256:36190169…0fff` | `4c1ddc6d` (Python 3.14 image) |
3. **Baseline, and 4. result after the change.**
   | Run | Item | Before | After | Verdict |
   |---|---|---|---|---|
   | 1 | #68414 repro | 70 unwritten rows, `o_err` 1234.1, `state_err` nan | 0 unwritten, errors 0.0 | after unit test missing: Spot reclaimed during the after pytest |
   | 2 | #68414 | run 1's before | new CPU test 12 passed | confirmed |
   | 2 | #68416 | 2 failed | 2 passed | confirmed |
   | 2 | #68415 | 1 failed (64-32 case) | 3 passed | confirmed |
   | 3 | #68415 | 2 failed, 2 passed | 5 passed | confirmed |
   | 3 | #68416 | 3 failed | 3 passed, file 21 passed | **void**: the collection loaded `kv_cache_planning.py` and `detokenizer.py`, which differ from the diff's base |
   | 4 | #68416 | 3 failed (192/768 and 384/768 elements mismatched) | 3 passed, file 21 passed | confirmed |
   | 5 | #68415 + #68416 as one PR | before-A 2 failed, 2 passed; before-B 3 failed | KDA file 5 passed, sigmoid-gating file 21 passed | confirmed in all three states |

   Sources: each run's `verdict.txt` or `*-verdict.txt`, `outcome.txt` and `pytest-summary.txt`.
   Run 3's void is the import probe doing its job: the tests passed, but the run could not show they ran against the base the diff was written for, so run 4 repeated #68416 on an image that differs from its diff base only in a recipe.
   Run 5 is on branch `feat/vllm-gdn-run5`, commit `01234f03`, not pushed; its record is `hack/vllm-gdn-68414/runs/2026-11-19-run5-pr-68415-68416-confirmed/` there.
   Run 6, run 5's two before commands on the full fix in one Spot state, is prepared on branch `feat/vllm-gdn-run6` (`553558c1`) and has not produced a record: **pending**.
5. **Reproduction command.**
   `PURCHASE=spot SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VLLMGDN_AMI_ID=ami-... bash hack/vllm-gdn-68414-session.sh` (run 4's configuration on `dev`), offline check `bash hack/vllm-gdn-68414-session-test.sh`, mutants `bash hack/vllm-gdn-68414-session-mutate.sh` (34 killed for run 4, commit `12279fcc`; 48 for run 5, `854b5166`).
   Caps from each `session.log` or `session-provenance.txt`: run 1 5,040 s at $0.7792/h, about $1.09; run 2 $0.8441; run 3 $0.7013; run 4 $0.6104; run 5 $0.7013; the session refuses any configuration whose worst case reaches $1.50.
   Attempt 1 bought nothing: no zone had g5.xlarge Spot capacity.
6. **Upstream status.**
   All three issues open; a claim with the fix plan was posted on each on 2026-11-18.
   No vLLM pull request is opened yet; the combined #68415 + #68416 PR that run 5 checks is drafted, not filed.
   The #68414 fix was ported to SGLang as [sgl-project/sglang#51413](https://github.com/sgl-project/sglang/pull/51413), open; that port was not run on the platform.

### 5. AIBrix #3439: a failed metric source lets the rest scale down

**Validation of someone else's work** (an issue and its proposed fix).
Reused: the kind lab, pinned upstream controller image, the gpuaas `External` replica owner, the evidence archive.

1. **Problem.**
   [vllm-project/aibrix#3439](https://github.com/vllm-project/aibrix/issues/3439): KPA and APA skip a failed metric source and take the maximum over the rest, so the target can scale down while one source is unreadable.
   The maintainer's open question was the capacity cost of holding replicas through an outage.
2. **Experiment environment.**
   One kind node `kindest/node:v1.31.12`, AIBrix main `01ac3858c6a1` built locally, llm-d-inference-sim `6ab9d4b2367a` as the serving pods (`hack/aibrix-lane2/runs/20261118T133004Z-cooldown-0s/pins.txt`).
   A pod metric asking for 2 and an external queue metric asking for 4.
3. **Baseline.**
   Both sources readable: recommendations [2,4], 4 replicas (`docs/15_AIBRIX_AUTOSCALING_LAB.md`, "The #3439 replay").
4. **Result after the change** (the outage).
   Cooldown 0s: 4 → 2 on the first reconcile, 13 s after the endpoint went, reason "All metrics below target" (`runs/20261118T133004Z-cooldown-0s/timeline.tsv`).
   Cooldown 300s, AIBrix's default: 4 held until 13:43:10, then 4 → 2, 5 min 7 s after the last [2,4] (`runs/20261118T133619Z-cooldown-300s/`).
   Recovery went 2 → 4 → 6 within one reconcile in both.
   No Warning event named the failed source in any run.
5. **Reproduction command.**
   `hack/aibrix-lane2.sh up`, the host reconciler as in `docs/15`, then `hack/aibrix-lane2.sh replay 0s 90` and `hack/aibrix-lane2.sh replay 300s 420`, then `hack/aibrix-lane2.sh down`.
   Cost: $0, local kind.
6. **Upstream status.**
   Issue open, now labelled `triage/accepted` (docs/15 records it without that label on 2026-11-18).
   [Replay comment](https://github.com/vllm-project/aibrix/issues/3439#issuecomment-6980936845), after an [earlier comment](https://github.com/vllm-project/aibrix/issues/3439#issuecomment-6934865719) with restore-cost data.
   **Comment that changed a decision:** the maintainer [answered](https://github.com/vllm-project/aibrix/issues/3439#issuecomment-6995180316) that it confirms KPA can scale down while the queue metric is unavailable even with the default 5-minute cooldown, and chose the opt-in annotation `autoscaling.aibrix.ai/hold-scale-down-on-metric-failure`.
   Earlier the maintainer had leaned toward keeping best-effort behaviour.

### 6. AIBrix #3509: the opt-in hold for #3439

**Validation of someone else's work.**
Reused: the #3439 kind lab, its simulator images and upstream's overlay.

1. **Problem.**
   [vllm-project/aibrix#3509](https://github.com/vllm-project/aibrix/pull/3509) implements the maintainer's choice from case 5.
   Does it hold scale-downs only, keep scale-ups and bounds, and say which source failed?
2. **Experiment environment.**
   Same kind lab, base main `afdb4791527e` against PR head `cb1a2f3f05d6`, plain Deployment target, cooldown 0s, `maxReplicas` 6, eight phases with the queue source down from phase 2 to 8.
   Branch `feat/aibrix-3509-verify` (pushed), commit `ca5efa9a`; runs under `hack/aibrix-pr3509/runs/`, results in its `docs/15_AIBRIX_AUTOSCALING_LAB.md`, "Verifying #3509".
3. **Baseline.**
   main, KPA and APA: 4 → 2 on the first reconcile, 13 s (KPA) and 10 s (APA) after the first outage sample.
   PR with the annotation off matches main; APA's 15 rescales match main's one for one.
4. **Result after the change.**
   Annotation on: held at 4 for the whole outage phase (KPA 19, APA 17 held passes), scaled up 4 → 5 and 5 → 6 at `maxReplicas`, honoured minReplicas 7 and maxReplicas 5, and released the hold when the queue came back.
   Findings sent upstream:
   - The per-reconcile Warning uses up the object's 25-event budget: PR KPA with the annotation off emitted 54 events and 27 reached the API server; main KPA emitted 12, all delivered.
   - A scale forced by the bounds during a hold names no failed source.
   - A hold is recorded as a failed scaling decision and moves `lastScaleTime`.
   - A hold leaves the outage out of a non-default scale-up window: 4 → 6 took 73 s with the annotation off and 8 s with it on (`runs/20261119T084222Z-pr-KPA-hold-off-upwindow60s`, `20261119T084608Z-pr-KPA-hold-on-upwindow60s`).
   - The regression test depends on the clock: with timestamps pinned across a second boundary it gets 5 replicas instead of 8.
5. **Reproduction command.**
   On the branch: `hack/aibrix-pr3509.sh up`, then `hack/aibrix-pr3509.sh run <main|pr> <KPA|APA> <off|on>` for each of the six cases, `hack/aibrix-pr3509.sh upwindow <off|on>`, and `hack/aibrix-pr3509.sh down`.
   Cost: $0.
6. **Upstream status.**
   Open, not merged.
   [Review comment](https://github.com/vllm-project/aibrix/pull/3509#issuecomment-7004694414) posted 2026-11-19; no reply yet.

### 7. Kubernetes #142885: lowering limits.swap below swap usage

**Validation of someone else's work.**
Reused: the termination sweeper's deadline tag, the evidence layout.
No GPU and no kind: the workstation has swap off and no root, so the cluster ran on EC2.

1. **Problem.**
   [kubernetes/kubernetes#142885](https://github.com/kubernetes/kubernetes/pull/142885) (KEP-5359, WorkloadControlledSwap) adds `limits.swap` and swap-aware in-place resize.
   A reviewer asked what happens when `limits.swap` is lowered below current swap usage.
2. **Experiment environment.**
   EC2 t3.large on demand, Ubuntu 24.04.5, kernel `7.0.0-1017-aws`, cgroup v2, 4 GiB swapfile, containerd 2.2.1, runc 1.3.4.
   Binaries built at PR head `5a0b7d10d74c`; Kubernetes' own `hack/local-up-cluster.sh` with LimitedSwap and the gate on.
   Branch `feat/k8s-142885-swap-drain` (pushed), commit `335653d9`; `hack/k8s-142885/README.md` and `evidence/` there.
3. **Baseline.**
   Control case B, 512Mi → 384Mi (above usage): 3 of 3 `ResizeStarted` → `ResizeCompleted`, 46 to 76 ms apart; `memory.swap.max` 402653184.
4. **Result after the change.**
   Case A, 512Mi → 64Mi with about 256 MiB in swap, sent 10 s after the workload settled: 4 of 4 stuck with `PodResizeInProgress=True`, reason `Error`; `memory.swap.max` stayed 536870912 and the validator error repeated 23 to 24 times in 300 s.
   Case S, the same PATCH sent at once: 5 of 5 completed with `memory.swap.max` 67108864 while `memory.swap.current` was 268431360 (`evidence/instance2/summary-table.md`), which points at stale stats.
   Kernel cases without the kubelet: lowering `memory.swap.max` below usage returns rc 0 and moves nothing (K1, 3 of 3), and touching the pages then OOM-kills the process (K2, 3 of 3).
5. **Reproduction command.**
   On the branch: `SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab bash hack/k8s-142885/ec2-up.sh <outdir>`, then on the node `sudo bash run-all.sh <out-root> <case>...`, then `bash hack/k8s-142885/ec2-down.sh`.
   Cap per instance: 8,100 s at $0.1127/h all in, $0.26 (`ec2-up.sh`, the cost comment); two instances were used.
6. **Upstream status.**
   Open, not merged.
   [Reproduction comment](https://github.com/kubernetes/kubernetes/pull/142885#issuecomment-7009845573) posted 2026-11-19 13:00 UTC.
   The branch's README still says "Nothing here was posted upstream"; that line predates the comment.

### 8. dra-driver-nvidia-gpu #1278: PrepareCompleted entries for deleted claims

**Validation of someone else's work** (an issue reproduction).
Reused: Spot launch with sweeper and cap, the SCP-aware instance choice, offline session test and mutation runner, kind on the GPU instance.

1. **Problem.**
   [kubernetes-sigs/dra-driver-nvidia-gpu#1278](https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/issues/1278): the GPU kubelet plugin never reconciles a deleted ResourceClaim left in `PrepareCompleted` in its checkpoint.
2. **Experiment environment.**
   One g5.xlarge Spot (A10G), ap-northeast-2c, AMI `ami-035e3088f6b7821fb`, kind cluster on the instance, driver at `e775fdb63e59` (`hack/dra-nvidia-gpu/runs/2026-11-19-attempt5-all-phases-ran/session-provenance.txt`).
   Branch `feat/dra-nvidia-gpu-session`; attempts 1 to 5 pushed (`8249d1c9`), attempt 6 and S5 committed locally (`efc3d559`), not pushed.
3. **Baseline.**
   S4, upstream's own bats suite on the real GPU: 15 of 15 ok, 3 of them skipped as mock-NVML only (`dra-run/run/s4/bats.log`).
4. **Result after the change.**
   S1, the control, deletes the pod and claim normally while the plugin is down: 3 of 3 valid repetitions, and in each the entry was `PrepareCompleted` when the plugin returned and absent after the watch (`dra-run/run/s1/out.log`).
   **S1 did not reach the issue's condition.**
   Both objects were still in the API when the plugin returned, kubelet unprepared, and the entry went.
   So S1 shows no leak and says nothing against the issue.
   S5, the issue's own reproducer with a force-delete while the plugin is down, was added after this; attempt 6 failed in the image build (exit 124 after 660 s, a slow Ubuntu archive) before S5 ran.
   **S5 is pending.**
   Attempts 1 to 4 were an SCP refusal of g6, a Spot reclaim, an apt mirror sync failure, and a run where S4 passed but S1 to S3 found no kubelet-plugin DaemonSet.
5. **Reproduction command.**
   On the branch: `SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab DRA_GPU_AMI_ID=ami-... bash hack/dra-nvidia-gpu-session.sh`, offline check `bash hack/dra-nvidia-gpu-session-test.sh`, mutants `bash hack/dra-nvidia-gpu-session-mutate.sh` (26 killed for S5, `db39c4ae`).
   Cap: attempt 5 5,700 s at $1.2575/h, $1.9910; attempt 6 $1.7186 (each `session.log`).
6. **Upstream status.**
   Issue open.
   Nothing posted from this work.

### 9. llm-d-router #4258, #4259 and llm-d-inference-sim #920

**Own PRs.**
Reused: the llm-d-router kind lab, with every image pinned by digest and a drift check that refuses a dirty checkout.

1. **Problem.**
   Found while building the lab on upstream's own dev environment (`docs/14_LLMD_KV_ROUTING_LAB.md`, "Upstream-relevant findings" 3 to 5):
   - Pull mode with the precise prefix producer but without `dataLayer` wiring starts cleanly and indexes nothing.
   - `VLLM_EXTRA_ARGS_D` with two flags reaches the simulator as one argument.
   - llm-d-inference-sim exits 0 on a configuration error.
2. **Experiment environment.**
   One kind node, llm-d-router `3d0b21d51d29`, Istio 1.29.2, kubectl v1.36.3 with kustomize v5.8.1, llm-d-inference-sim v1.2.0 (`docs/14`, pins; `hack/llmd-kv-lab/runs/20261115-setup/extra-args-one-argv.txt`).
3. **Baseline.**
   - Runs `20261115-run2` and `-run3`, arm `precise-pull`: `"subscribers": []`, 0 admissions, every score 0, no warning (`docs/14`, Observation 9).
   - The rendered manifest passes `${VLLM_EXTRA_ARGS_D}` unquoted, and the splitter matches only a quoted item.
   - The simulator then logs "failed to read configuration" and exits with status 0 (`extra-args-one-argv.txt`).
4. **Result after the change.**
   With upstream's e2e wiring, `20261115-run4` held one subscriber per pod and matched push mode (affinity 12/16, warm-up 3/3).
   That is the configuration the fix makes the default, not a run of the fix itself.
   **No after-run of the merged fixes exists in this repository.**
   The lab now builds the simulator from source because no release carries #915 or #920, but no run measures either change.
5. **Reproduction command.**
   `hack/llmd-kv-lab.sh up precise`, `hack/llmd-kv-lab.sh status`, `hack/llmd-kv-lab/observe.sh all` (about 15 minutes).
   Cost: $0.
6. **Upstream status.**
   [llm-d/llm-d-router#4258](https://github.com/llm-d/llm-d-router/pull/4258) merged 2026-11-18.
   [llm-d/llm-d-router#4259](https://github.com/llm-d/llm-d-router/pull/4259) merged 2026-11-18.
   [llm-d/llm-d-inference-sim#920](https://github.com/llm-d/llm-d-inference-sim/pull/920) merged.

## Own pull requests with no experiment in this repository

These were checked with `gh` on 2026-11-19.
No platform run or lab record for them exists here, so they are listed and not written up.

| Pull request | Status | Evidence here |
|---|---|---|
| [kubernetes-sigs/kwok#1816](https://github.com/kubernetes-sigs/kwok/pull/1816) | merged | no experiment in this repository |
| [llm-d/llm-d-inference-sim#915](https://github.com/llm-d/llm-d-inference-sim/pull/915) | merged | used by the llm-d lab's simulator build, not measured |
| [llm-d/llm-d-router#4310](https://github.com/llm-d/llm-d-router/pull/4310) | merged | no experiment in this repository |
| [kubernetes-sigs/kueue#19068](https://github.com/kubernetes-sigs/kueue/pull/19068) | open | no experiment in this repository |
| [kubernetes-sigs/jobset#1411](https://github.com/kubernetes-sigs/jobset/pull/1411) | open | no experiment in this repository |
| [kubernetes-sigs/lws#1341](https://github.com/kubernetes-sigs/lws/pull/1341) | open | no experiment in this repository |
| [kubernetes-sigs/scheduler-plugins#1034](https://github.com/kubernetes-sigs/scheduler-plugins/pull/1034) | open | no experiment in this repository |
| [kubernetes-sigs/karpenter#3651](https://github.com/kubernetes-sigs/karpenter/pull/3651) | open | no experiment in this repository |
| [volcano-sh/volcano#6364](https://github.com/volcano-sh/volcano/pull/6364) | open | no experiment in this repository |
| [kserve/kserve#6613](https://github.com/kserve/kserve/pull/6613) | open | no experiment in this repository |
| [kubernetes-sigs/node-readiness-controller#508](https://github.com/kubernetes-sigs/node-readiness-controller/pull/508) | open | no experiment in this repository |
| [kubernetes-sigs/ai-conformance#121](https://github.com/kubernetes-sigs/ai-conformance/pull/121) | open | no experiment in this repository |
| [kubernetes-sigs/gateway-api-conformance-images#38](https://github.com/kubernetes-sigs/gateway-api-conformance-images/pull/38) | open | no experiment in this repository |
| [sgl-project/sglang#51541](https://github.com/sgl-project/sglang/pull/51541) | open | no experiment in this repository |

## Not yet in this repository

| Item | Why it is not a case here |
|---|---|
| [kubernetes-sigs/inference-perf#913](https://github.com/kubernetes-sigs/inference-perf/issues/913), lost metrics on a clean exit | The reproduction and fix evidence are outside this repository. The issue is open; a [comment](https://github.com/kubernetes-sigs/inference-perf/issues/913#issuecomment-6978977669) was posted on 2026-11-18, and no fix pull request is open. |
| [llm-d/llm-d-router#2881](https://github.com/llm-d/llm-d-router/issues/2881), concurrency detector race | Branch `feat/llmd-2881-repro` has no commit; its files are untracked. Pending. |
| vLLM FLA run 6 | Prepared on `feat/vllm-gdn-run6`, no record yet. Pending. |
| dra-driver-nvidia-gpu #1278, S5 | Added on `feat/dra-nvidia-gpu-session`; attempt 6 failed in the build before S5 ran. Pending. |
