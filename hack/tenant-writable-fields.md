# Every guarantee is bounded by the fields the tenant can write

Three separate defences in this platform were broken the same way, and each was found by attacking it rather
than by reading it. They are collected here because the pattern is the finding, not any one of them.

| the guarantee | the field the tenant writes | what it bought the attacker | measured |
|---|---|---|---|
| GPU quota is enforced | `ownerReferences` | 2 devices, unaccounted | one `kubectl apply` |
| GPU quota is enforced | `quota-exempt` annotation | any number of devices | one annotation |
| a reclaimed device comes back | `terminationGracePeriodSeconds` | 301 s of a reclaimed device | 30 s → 32 s held; 300 s → 301 s |

## 1. An ownerReference is a claim, not a fact

The first quota guard admitted a Pod whose controller was a Job carrying the queue label. It passed ten unit
specs and four live cases.

    kubectl apply -f (Job "decoy", labelled kueue.x-k8s.io/queue-name: gpu-premium)
    kubectl apply -f (Pod, ownerReferences: [{kind: Job, name: decoy, uid: <decoy's uid>, controller: true}],
                      limits: {"nvidia.com/gpu": "2"})
    pod/forged-owner created
    forged-owner   1/1   Running

`ownerReferences` is supplied by whoever creates the object, and Kubernetes does not check that the named
owner had anything to do with it.

**Fix.** Believe the reference only when the Job controller presents it — `req.UserInfo.Username` is the one
field in an admission request a tenant cannot write. That required a raw `admission.Handler`; the typed
`Validator` interface is handed only the object, and the object is exactly what cannot be trusted.

## 2. An exemption anyone can grant is not an exemption

The same guard honoured `platform.lkhun9311.github.io/quota-exempt` on any Pod. Infrastructure needs it —
a device plugin holds a device outside any tenant budget — but a tenant can annotate its own Pod, so it was
the bypass with an extra step.

**Fix.** Honour it only for `kube-system` service accounts, which a tenant cannot assume. Admitted Pods
still emit a warning naming the annotation, so a device leaving the budget announces itself.

## 3. The reclaim guarantee is bounded by a number the victim chooses

Quota reclaim works by preemption, and preemption waits for termination. Termination waits for
`terminationGracePeriodSeconds`, which is set by the Pod being preempted.

Measured directly: a device-holder deleted with grace 30 held its device for 32 seconds; the same Pod with
grace 300 held it for 301. Sweeping the parameter against a fixed 43 seconds of remaining work gives the
model, and it holds — `held = min(remaining, grace)`, with the knee where predicted
([grace-holds-the-device.md](grace-holds-the-device.md)).

The queuelab measured the same boundary from the other side: an unresponsive workload defeats reclaim
entirely while its remaining service fits inside grace, and is cut off at exactly grace once it does not
([queuelab-grace-boundary.md](queuelab-grace-boundary.md)).

**Fix.** Cap it at 120 s for device holders. Not 30, because a training step that checkpoints on SIGTERM
needs longer, and refusing that pushes tenants to ignore SIGTERM — which the measurement shows is what costs
the owner most.

## What the three have in common

Each guarantee was expressed in terms of a value the adversary supplies. Not a bug in the check — the checks
were correct about what they read. The mistake was reading something the tenant writes and treating it as
evidence about the tenant.

The three fixes take different forms, and the difference is instructive:

- **1** replaced the untrusted input with a trusted one. The requester is authenticated; the object is not.
- **2** restricted who may supply the input, to a set the tenant cannot join.
- **3** could do neither — the grace period genuinely belongs to the workload — so it **bounded** the damage
  instead. That is the weakest of the three and the honest one: reclaim is still not immediate, and no
  Kubernetes mechanism makes it so.

## What is still open

**Kueue holds quota for a Workload whose Pods can never be created.** Found while testing the grace cap: a
Job carrying `terminationGracePeriodSeconds: 300` had its Workload admitted and holding quota while the
webhook rejected every Pod the Job controller made. `used=2 admitted=2`, one of them a Job that could not
run. A rejected Pod does not release the reservation, so a tenant submitting Jobs that fail admission can
hold a budget indefinitely without running anything.

Same shape as the three above — a guarantee bounded by what a tenant may submit — and not fixed.
