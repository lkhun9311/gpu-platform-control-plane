# GitOps on kind: what the Applications actually do when a cluster already exists

`config/argocd/` has held an app-of-apps since M5 — a root Application and six children with sync waves,
`prune: true` and `selfHeal: true`. It had never been run. This is the run.

The interesting result is not that ArgoCD works. It is what GitOps says about a cluster that was deployed by
hand, which is the state every real adoption starts from.

## What was verified

ArgoCD v2.13.2 on kind, all seven Applications applied. Every one resolved its repository, rendered its
path, and enumerated the resources it would own, with **no error conditions**:

| Application | path | resources enumerated |
|---|---|---|
| `gpu-platform-crds` | `config/crd` | 4 CustomResourceDefinitions |
| `gpu-platform-operator` | `config/operator` | Namespace, ServiceAccount, Deployment, ClusterRoles… |
| `gpu-platform-gateway` | `config/gateway` | Service, ServiceAccount, Deployment, RBAC |
| `gpu-platform-observability` | `config/prometheus` | ServiceMonitor |
| `gpu-platform-device-plugin`, `gpu-platform-samples`, `gpu-platform-root` | — | resolved |

So the manifests are not aspirational: the paths build, the waves parse, and the destination resolves.

**Auto-sync was removed before applying them**, deliberately — see the next section for what would have
happened otherwise.

## GitOps wanted to break the running gateway

```
config/gateway (main):   image: gateway:latest      (no imagePullPolicy)
running on the cluster:  image: gateway:fr002       imagePullPolicy: IfNotPresent
```

With `selfHeal: true` ArgoCD would have reverted the Deployment to `gateway:latest`. The kubelet treats
`:latest` as always-pull regardless of what is on the node, so a **side-loaded** image under that tag sends
it to a registry that does not have it — the trap already recorded in `hack/m5b-gateway-path.sh`, which
GitOps would then reproduce automatically and continuously.

This is not an ArgoCD defect. It is the correct behaviour of a system told that Git is the truth, applied to
a cluster whose truth was a `kind load` nobody wrote down. **The fix is to make the repository describe the
kind deployment**, not to disable self-heal.

## A sync can succeed and leave the Application out of sync

`gpu-platform-crds` was synced on its own, as the lowest-risk Application. The result:

```
phase:   Succeeded      message: successfully synced (all tasks run)
sync:    OutOfSync
```

Two of the four CRDs stayed `OutOfSync` after a successful apply. The cause is not a failure anywhere:

- the cluster is running the CRDs from this **branch**, applied by `kubectl`
- the Applications point at `targetRevision: main`
- the branch and main genuinely differ in `config/crd` (description reflowing, mostly)
- server-side apply with `force: false` will not take fields owned by another field manager, so
  `kubectl-client-side-apply` keeps them and the drift survives the sync

`kubectl get crd ... -o jsonpath='{.metadata.managedFields[*].manager}'` shows both managers on the same
object, which is the whole story in one line.

**GitOps was reporting something true**: the cluster is running code that `main` does not contain. An
adoption that saw `OutOfSync` here and reached for `force: true` would have destroyed the evidence of that
rather than the drift.

## What this leaves

Three things are now known that the manifests alone could not tell anyone:

1. every path in the app-of-apps renders, so the design is executable
2. adopting GitOps onto a hand-deployed cluster **reverts the hand deployment**, and here that specific
   revert breaks a running component
3. `Synced` is not reachable while the cluster runs a branch the Application does not track — and that is the
   Application being correct, not broken

Left deliberately undone: enabling `automated`. Doing that against `main` today would revert the gateway,
the webhook overlay and the metrics flags to versions that predate this branch. The honest sequence is to
merge first and enable auto-sync after, which is a decision about the branch rather than about ArgoCD.

## Reproducing

```bash
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# Applied WITHOUT the automated block while a hand-deployed cluster is running.
#
# The comment above described the recorded experiment and the command below did not carry it out. Every
# Application in config/argocd now ships `automated: {prune: true, selfHeal: true}`, so `apply -f` on the
# directory installs exactly what this run removed -- and self-heal would then reconcile over the gateway
# that is running by hand, which is the failure the next section is about. The directory also holds a
# kustomization.yaml, which `apply -f` does not read.
#
# So strip the automated block on the way in, and check that nothing arrived with it:
for f in config/argocd/*.yaml; do
  [ "$(basename "$f")" = kustomization.yaml ] && continue
  python3 - "$f" <<'PY' | kubectl apply -f -
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d.get("spec", {}).get("syncPolicy", {}).pop("automated", None)
print(yaml.safe_dump(d, sort_keys=False))
PY
done
kubectl -n argocd get applications \
  -o jsonpath='{range .items[*]}{.metadata.name}{" automated="}{.spec.syncPolicy.automated}{"\n"}{end}'
# Every line must end in `automated=` with nothing after it. A name showing a value means this cluster is
# now self-healing and the run is no longer the one recorded here.
```

⚠️ This block applied the directory unchanged until 2026-09-30, so anyone following it got automated sync
and a different experiment from the one written up below. The record was right and the reproduction was not.
