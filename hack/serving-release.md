# Serving release on a CPU stub: verify a candidate, restore the last known good spec

`hack/serving-release.sh` deploys an `InferenceDeployment` candidate in kind, checks it through the gateway, and
when it fails puts back the CR spec that last passed the same check.
`.github/workflows/serving-release.yml` runs it.

## What this claims, and what it does not

It claims a **CPU-stub release pipeline**: deploy, verify through the gateway, restore by re-applying a saved CR
spec, verify the restore the same way.
The backend is the benchharness stub (`Dockerfile.benchharness`), whose latency and readiness are configuration.

It does not claim:

- vLLM deployment automation. No vLLM image runs here, and nothing about a GPU engine's start-up or latency is
  measured. A controller-rendered vLLM engine answered through the gateway once, on EKS on 2026-10-12
  (`hack/eks-serve/runs/20261012T095840Z/README.md`), and that is a separate, single record.
- GitOps rollback. The restore is `kubectl replace` of a saved spec, not an Argo revert.
- Zero downtime. A never-Ready candidate leaves the old Pod serving only because of the Deployment's rolling
  update defaults, and nothing here measures the gap.
- A restore time for real engines. CPU stub timings say nothing about GPU restore times.

The controller does not roll back by itself, on purpose: with Argo `selfHeal` on, a controller that reverted
specs would fight the reconciler that applied them.

## How one release is judged

The same check runs on v1, on each candidate and on each restore:

1. **Ready at its own generation.** `status.observedGeneration` reaches the generation the replace produced,
   `phase` is `Ready`, the Deployment renders `--model <name> --model-path <storageUri>` from this spec, and its
   replicas, updated replicas and ready replicas all equal the target.
   The wait is bounded at 180 s (`WAIT_S`), well under the 600 s `ProgressDeadlineSeconds` the controller sets,
   so `Degraded` is never what decides it.
2. **A gateway smoke** (`hack/serving-release/smoke.py`), three streamed requests as tenant `tenant-a`: HTTP
   200, every data chunk's `model` is the spec's `model.name`, the stream ends with `[DONE]`, and the first
   content chunk arrives within 1000 ms (`TTFT_BOUND_MS`).

The model check is what catches a never-Ready candidate on the wire: the old Pod keeps answering through the
rolling update, so its responses are 200 and fast, but they name the old release's model.
It works because each release serves its own model name and the stub now puts `--model` into every chunk.

v1 is saved as last known good only after it passes this check, because a running release is not by that fact
a good one.
A restore counts only when the restored spec passes the same check.

## Modes

| mode | candidates | green when |
|---|---|---|
| `self-test` (PRs touching serving paths) | `healthy`, `ttft-regression` (2.5 s TTFT), `never-ready` (`/health` 503 for an hour) | the healthy one passes, both bad ones fail, and every restore passes |
| `self-test` with `CORRUPT_LKG=1` | the same, after the saved spec is rewritten to a 2.5 s TTFT profile | never; the workflow job asserts exit 1, every candidate as expected, every restore failed |
| `gate` (`workflow_dispatch`, input `candidate`) | one spec file | the candidate passes; a failed candidate stays red even when its restore passes |

In the self-test every candidate starts from v1, so a healthy candidate is reset to the saved spec too.
In a gate a passing candidate is the new release and stays.
A gate's `summary.json` separates `candidate-failed-restored` from `candidate-failed-restore-failed`.
A setup failure exits 2 with `verdict: setup-failed`, apart from a verdict's 1, so the must-fail job cannot pass
on a broken cluster.

A gate candidate must be `InferenceDeployment serving/stub` and use an image already loaded on the kind node
(`benchharness:serving-release`); this is a stub pipeline, not a registry pull.

## Artifacts

Each run writes, under `OUT`: `log.txt`, `summary.json`, `last-known-good.json`, `v1/`, and per candidate
`before.yaml`, `candidate.yaml` (the file as given), `candidate-cr.yaml` (the CR as the API server held it),
`after.yaml`, and for both the candidate and the restore `wait.json`, `smoke.json`, `smoke-raw.txt` (every
response byte the gateway sent) and `verdict.json`.

## Running it

```
hack/serving-release.sh                                   # self-test
CORRUPT_LKG=1 hack/serving-release.sh                     # must exit 1
MODE=gate CANDIDATE=hack/serving-release/candidates/ttft-regression.yaml hack/serving-release.sh
```

It builds the operator, gateway and stub images, creates a throwaway kind cluster named `serving-release` with
the gateway on host port 31090, and deletes it afterwards unless `KEEP=1`.
