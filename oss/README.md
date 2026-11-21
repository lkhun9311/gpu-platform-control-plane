# Upstream contribution work

This directory holds the work done here for upstream open-source projects: validation kits, session scripts, and the raw run records behind each comment or pull request.
The GPUaaS platform itself lives in the rest of the repository.
The narrative write-up of the same cases, with cost caps and what each run showed, is `docs/16_OSS_VALIDATION_CASE_STUDIES.md`.

Upstream status was checked with `gh` on 2026-11-21.

## Index

| Project | Upstream issue or PR | What we did | Status | Evidence |
|---|---|---|---|---|
| vLLM | [#68819](https://github.com/vllm-project/vllm/pull/68819) GPTQ MoE layout copies before the Marlin repack | Own PR. GPU kits that run the PR's tests and full model loads on both sides, plus an out-of-memory sweep | open | `oss/vllm/68819-gptq-moe/` |
| vLLM | [#58420](https://github.com/vllm-project/vllm/pull/58420) SRPF scheduling and its starvation threshold | Validated someone else's PR on one A10G: eight SRPF sweeps, then a seven-arm threshold sweep the author cited when making 3 the default | open | `oss/vllm/58420-srpf/` |
| vLLM | [#67811](https://github.com/vllm-project/vllm/pull/67811) adaptive prefill time budget | Validated someone else's PR on one A10G: the `serve.py` baseline against the opt-in mode, then a traced re-run of the stalled adaptive engine | open | `oss/vllm/67811-prefill-budget/` |
| vLLM | [#68548](https://github.com/vllm-project/vllm/pull/68548) TPOT observed as zero for single-token requests | Own PR. vLLM's metrics pytest before and after the fix in the CI image: before failed as expected, after passed | open | `oss/vllm/68548-tpot/` |
| vLLM | Issues [#68414](https://github.com/vllm-project/vllm/issues/68414), [#68415](https://github.com/vllm-project/vllm/issues/68415), [#68416](https://github.com/vllm-project/vllm/issues/68416) FLA kernel bugs | Own fixes, each confirmed before and after on an A10G. The #68415 and #68416 fixes are filed as [#68835](https://github.com/vllm-project/vllm/pull/68835); no vLLM PR for #68414 yet | issues open, #68835 open | `oss/vllm/68414-gdn/` |
| SGLang | [#51413](https://github.com/sgl-project/sglang/pull/51413) port of the #68414 fix | Own PR. Not run on the platform | open | none here |
| llm-d | [llm-d-router#4258](https://github.com/llm-d/llm-d-router/pull/4258), [#4259](https://github.com/llm-d/llm-d-router/pull/4259), [llm-d-inference-sim#920](https://github.com/llm-d/llm-d-inference-sim/pull/920) | Own PRs, from defects found while building the llm-d-router kind lab | merged | `hack/llmd-kv-lab/`, `docs/14_LLMD_KV_ROUTING_LAB.md` |
| AIBrix | [#3439](https://github.com/vllm-project/aibrix/issues/3439) a failed metric source lets the rest scale down | Replayed the issue on a kind lab; the maintainer chose an opt-in hold after the replay | open | `hack/aibrix-lane2/`, `docs/15_AIBRIX_AUTOSCALING_LAB.md` |
| AIBrix | [#3509](https://github.com/vllm-project/aibrix/pull/3509) the opt-in hold for #3439 | Validated someone else's PR on the same lab; review comment posted | open | branch `feat/aibrix-3509-verify`, [runs at `ca5efa9a`](https://github.com/lkhun9311/gpu-platform-control-plane/tree/ca5efa9ac4ce07b833e54af4f1e722ff2d6ac69c/hack/aibrix-pr3509/runs) |
| Kubernetes | [#142885](https://github.com/kubernetes/kubernetes/pull/142885) lowering `limits.swap` below swap usage | Reproduced the reviewer's question on EC2; reproduction comment posted | merged | branch `feat/k8s-142885-swap-drain`, [README at `335653d9`](https://github.com/lkhun9311/gpu-platform-control-plane/blob/335653d9d051777bab71e9ec0229b55fae0fa6b9/hack/k8s-142885/README.md) |
| dra-driver-nvidia-gpu | [#1278](https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/issues/1278) PrepareCompleted entries for deleted claims | Issue reproduction on an A10G; the control case did not reach the issue's condition, the issue's own reproducer is pending | open, nothing posted | branch `feat/dra-nvidia-gpu-session` |

Own pull requests with no experiment in this repository, Kueue's included, are listed in `docs/16_OSS_VALIDATION_CASE_STUDIES.md`.

## Why some upstream-related work is not under oss/

Some labs run upstream software but exist to test this platform, so they stay with the platform's own code.

| Path | Why it stays |
|---|---|
| `hack/aibrix-lane2/` | It runs this repository's InferenceDeployment reconciler against AIBrix to test the `External` replica owner (issue #654). The #3439 replay is one of its uses |
| `hack/llmd-kv-lab/` | The platform's serving deep dive (issue #598), wired into `make` and `hack/test/check-llmd-kv-lab-guards.sh`. Its findings became the llm-d PRs above |
| `hack/prefix-route/` | Runs of the platform's own prefix-aware routing study |
| `hack/vllm-plugins/` | The platform's step-logging instrument for vLLM; archived runs pin its hashes |
| `hack/kueue-gitops-rehearsal-*` | Rehearsals of the platform's own Kueue and Argo CD set-up |
| `internal/bench/srpf_sweep.go` | Go code of the benchmark harness the #58420 session drives; moving it would change a package path |

## Layout for new work

```
oss/<project>/<number>-<topic>/
  README.md        what the upstream thread asks, what was run, and where each number comes from
  kit/             what runs on the instance or the lab
  runs/<date>/     one directory per run, committed as it came back
```

The items moved here on 2026-11-21 keep the layout they were built with, because their run records, test fixtures and pins name those files.
The session scripts still write a new run to a git-ignored directory under `hack/`; move a run into the item's directory before committing it.
