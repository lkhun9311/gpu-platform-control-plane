# GitOps self-heal, actually executed

`docs/11_WHAT_THIS_MEASURED.md` lists four claims this project is not entitled to make. The first is
**"I operated a GPU platform"**, and one component of that refusal is narrow enough to close for nothing:

> Argo CD has been run on kind, and auto-sync was deliberately removed before applying
> (`hack/argocd-kind.md:24`), so seven Applications resolving with no error is evidence that the manifests
> build and the destination resolves — **not** that drift is repaired. Self-heal has never been exercised.

This directory exercises it.

## Why not simply turn auto-sync back on

Because that would be a different, destructive experiment. Measured on the live cluster before writing any
of this:

| fact | consequence |
|---|---|
| All seven Applications are `automated=none` and `OutOfSync`, 37 resources in total | a sync is not a no-op; it is 37 changes |
| `config/gateway` resolves to an ECR digest (`007635145730.dkr.ecr...`) | this kind node has no ECR credentials and cannot pull it |
| The running gateway is a side-loaded `gateway:ttfb-3c68d3a` | a sync would replace a working pod with one that cannot start |
| `config/argocd/root.yaml` declares `prune: true` and `selfHeal: true` | syncing the root would restore automation to all seven at once |

`config/gateway-kind/` looks like the escape hatch and is not. Its `kustomization.yaml` names `newTag:
fr002`, but rendering the overlay shows the base's digest transformer still wins: the only thing the
overlay changes is `imagePullPolicy`. Reading the tag and not the rendered output is how this experiment
nearly pointed at an image the node cannot pull.

So the demonstration uses its own Application, its own project, its own namespace, and a workload whose
image is already on the node.

## What is here

| file | role |
|---|---|
| `workload/deployment.yaml` | the desired state — one `pause` Deployment with `replicas: 1` |
| `bootstrap/project.yaml` | an AppProject that permits one namespace and forbids every cluster-scoped kind |
| `bootstrap/application.yaml` | the Application, pinned to a commit SHA, `selfHeal: true` / `prune: false` |
| `../../hack/argocd-selfheal.sh` | bootstrap, drift injection, measurement and teardown |

## The two drift injections

**Modify** — `spec.replicas` 1 → 3. Tests restoration of a declared field on an object that still exists.
Counting pods is not sufficient evidence: the ReplicaSet controller moves pods on its own. The observation
that counts is `spec.replicas` returning to 1 while the Application's revision is unchanged.

**Delete** — remove the Deployment. Tests recreation. The evidence is a Deployment with the same name and
a **different UID**; deleting a *pod* would not test this, since Kubernetes recreates pods with no Argo
involvement whatsoever.

Pruning is deliberately not exercised. It answers "what happens when a resource leaves Git", which is a
different mechanism from self-heal and carries a real risk of reaching objects outside the experiment.

## Timing, and why there is no pass/fail threshold

The controller's flags were read from the running binary rather than from documentation, because the two
disagree:

| setting | value on this cluster |
|---|---|
| `--self-heal-timeout-seconds` | no default — the fixed-delay path is off |
| `--self-heal-backoff-timeout-seconds` | 2 |
| `--self-heal-backoff-factor` | 3 |
| `--self-heal-backoff-cap-seconds` | 300 |
| `--app-resync` | 180 |
| `--app-resync-jitter` | 0 |

Both `argocd-cm` and `argocd-cmd-params-cm` carry no data, so these defaults are what is in force.

Recovery is therefore governed by an exponential backoff, not by a fixed five-second timer and not by the
180-second resync — a live change to a managed object triggers a refresh directly. The controller states
this itself, and the run keeps its words beside each repetition:

```
Skipping auto-sync: already attempted sync to 416c394... with timeout 0s (retrying in 2m39.584944632s)
```

**The backoff is keyed to the revision, not to the drift.** Because every injection in a run targets the
same pinned commit, the controller counts them as repeated attempts at one revision and pushes each retry
further out: 2s, then ~6s, then ~18s, then ~54s, capped at 300s. Measured here as 0.317s, 15.395s and
51.806s for three consecutive `replicas` injections — the cluster did not get slower, the backoff got
longer.

**It does not reset when the Application goes back to `Synced`.** That was assumed here and is wrong. After
a run ended and the app returned to `Synced/Healthy` for several minutes, the next injection was still met
with `retrying in 1m44s` against the same commit — the counter had survived the healthy interval. Detection
was immediate either way: the Application reported `OutOfSync` within a second while `spec.replicas` sat at
3, waiting. So a run's repetitions are not independent samples, and the first figure in a run is the only
one measured from a rested controller.

**Why that matters beyond this experiment.** The Application's own status never says any of this. It reports
`OutOfSync` and stays there; nothing in `status` carries the retry delay, so an operator watching the API —
or a dashboard built on it — sees a platform that has noticed the drift and is not fixing it, with no
indication that it is deliberately waiting or for how long. The number exists only in the controller's log,
which is why this run captures that log beside every repetition.

This is the substantive result of the timing work, and it contradicts the reading the documentation invites.
"Argo repairs drift in about five seconds" is true only for the first drift after a settled period. A
platform that drifts repeatedly against an unchanged desired state waits minutes, and nothing in the
Application's own status says so — the reason appears only in the controller's log.

A run is therefore reported as the raw observed durations across repetitions **with the backoff stated**,
never as a comparison against a threshold this experiment did not pre-register.

Times are recorded from a `kubectl --watch` client. That includes delivery delay and is not a server-side
timestamp; sub-second digits in the log are not a precision claim.

## The run

`REPS=3`, single runner, Argo CD v2.13.2 at its default settings, Application pinned to commit `416c394`.
**Six injections, six repairs, no manual sync.** Raw evidence in `ex/selfheal-final/` (gitignored; the
curated figures are here).

| injection | rep 1 | rep 2 | rep 3 |
|---|---:|---:|---:|
| `spec.replicas` 1 → 3 | 105.239 s | 159.834 s | 159.874 s |
| Deployment deleted | 159.767 s | 156.828 s | 156.715 s |

Every deletion came back under a **new UID** — `e467fdb1` → `a8d3d597` → `543fc0e1` → `fc2a3f35` — so what
was observed is recreation of the object, not a ReplicaSet replacing pods beneath a surviving Deployment.

**The recovery time is the backoff, and the controller says so to within a second.** Each repetition's
captured log carries the interval the controller had chosen at that moment, and it matches the measurement:

| repetition | controller's reported retry | observed repair |
|---|---:|---:|
| modify 1 | `1m44.8s` | 105.239 s |
| modify 2–3, delete 1–3 | `2m39.5s` | 156.7 – 159.9 s |

Nothing here measures detection latency, which was under a second throughout: the Application reported
`OutOfSync` almost immediately and then waited. A reader who takes these figures as "Argo CD needs 160
seconds to notice" has the mechanism backwards.

**One rested measurement exists, from an earlier run**: the very first injection after the Application had
been idle returned `spec.replicas` to 1 in **0.317 s**, and the second in 15.395 s. That run is not reported
in full — a later repetition was corrupted when a second runner was started against the same evidence
directory, which is the defect the lock in `hack/argocd-selfheal.sh` now prevents. The two figures above it
were taken while only one runner existed.

**The seven platform Applications were untouched**, checked rather than asserted: `platform-apps-before.txt`
and `platform-apps-after.txt` are byte-identical, all seven still `automated=<none>`.

## What a successful run does and does not license

**Does:** on this kind cluster with Argo CD v2.13.2 at its default settings, a change to a declared field
and a deletion of a declared object were both repaired automatically from a pinned Git commit, with no
manual sync.

**Does not:** anything about the seven platform Applications, about the app-of-apps path, about Application
objects being themselves GitOps-managed, about EKS, ECR or GPU nodes, or about recovery time under load.
