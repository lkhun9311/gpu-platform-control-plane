# Pre-registration: the GitOps path, rehearsed on a clean cluster before it is paid for

Written 2026-09-25, before the rehearsal ran. It fixes what counts as a pass so the result cannot be decided
after seeing it.

## The question

A paid EKS session is meant to establish that this repository's GitOps path deploys the platform. Two
pre-spend reviews found that nothing in the repository applies `config/argocd/root.yaml`, so the session
could have finished with Terraform green, Argo CD running and zero Applications deployed.
`hack/eks-gitops-runbook.sh` now closes that, and its verdicts have been rehearsed against a stubbed
cluster. A stub is not a cluster. **Does the runbook work against a real Kubernetes API, on a cluster that
starts with nothing?**

## Why kind is the right instrument for this, and where it stops

The root Application points at `https://github.com/lkhun9311/gpu-platform-control-plane.git`,
`targetRevision: main`, path `config/argocd`. None of the 42 unmerged commits on the working branch touch
`config/argocd`, so the tree Argo CD pulls here is the tree a paid EKS session would pull. The repository is
public, so the repo-server clones it anonymously, exactly as it would there.

Argo CD is installed from the same chart the paid path uses: `argo-cd` **7.7.0** from
`https://argoproj.github.io/argo-helm`, the version pinned in `infra/aws/argo-bootstrap/variables.tf`.

## Arms

One arm. This is a rehearsal, not a comparison: the cluster is new, the steps are the paid session's steps in
the paid session's order.

1. `kind create cluster` — one control plane, one worker, no GPU
2. `helm install argo-cd argo/argo-cd --version 7.7.0 -n argocd`
3. `hack/eks-gitops-runbook.sh apply`
4. `hack/eks-gitops-runbook.sh seed-key`
5. `hack/eks-gitops-runbook.sh verify`

## Bars, fixed now

| # | Bar | Passes when |
|---|---|---|
| B1 | the root produces the declared set | all 10 Applications `config/argocd` declares exist |
| B2 | the automated ones converge | every Application carrying `syncPolicy.automated` is `Synced/Healthy` |
| B3 | the credential step works on a cluster that has none | `seed-key` creates `gateway-api-keys` and records the key |
| B4 | readiness is reached | `/readyz` answers 200 |
| B5 | a key that is not in the Secret is refused | the bad-key request answers **401** |
| B6 | a key from the Secret reaches the key store | the real-key request answers **403 or 404**, never 401 or 503 |

B6 is deliberately not "200". Serving needs a backend and this cluster deploys none; 404 on model resolution
is the furthest the evidence reaches, and the runbook's header says so.

## What must NOT be read as an EKS failure

These are kind's limits, not the repository's. If one of them is the reason a bar misses, the result is
recorded as **inconclusive for that Application**, and the bar is judged on the rest.

- **`gpu-platform-gateway` and any other image pinned to an ECR digest.** kind has no AWS credentials; EKS
  pulls with the node role. The images are pulled with `aws ecr get-login-password` and `kind load` before
  step 3, and if that fails the Application is inconclusive rather than failed.
- **`gpu-platform-storage`.** Its StorageClass names `ebs.csi.aws.com`. The object is created on any
  cluster, so it should still reach `Synced/Healthy`; a PVC against it would not bind, and nothing here
  creates one.
- **`gpu-platform-device-plugin` and `gpu-platform-samples`.** Neither carries `syncPolicy.automated`, by
  design, so neither is waited on. They must still exist (B1).
- Anything that fails **only** for want of a GPU node.

## Invalidation rules

- If the runbook is edited while a step is running, the run is void. (An edited-while-running script has
  already corrupted one result in this project.)
- If `CONTEXT` is anything other than `kind-gitops-rehearsal`, the run is void.
- If a bar is missed and the cause is not established, it is recorded as missed, not excused.

## Stopping rule

The rehearsal ends when steps 3–5 have each run once to completion. A failing bar is the finding; it is not
retried with different settings until it passes. Anything fixed in response is followed by a full re-run on a
cluster created from scratch, and both runs are reported.

## What this licenses

A pass licenses spending on the EKS session. It does not license any claim about serving, GPU scheduling,
LoadBalancer or EBS behaviour, or Argo CD self-heal, none of which this rehearsal exercises.
