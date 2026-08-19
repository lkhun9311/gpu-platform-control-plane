# The tenant GPU quota was a convention, not a boundary

`GPUQuotaPolicy.spec.trainingQuota` makes the Kueue ClusterQueue the single authority over a namespace's GPU
budget, and the controller deliberately stops the namespace `ResourceQuota` from capping GPUs so the same
device is not charged twice. Kueue only sees what enters its queues.

So: what stops a tenant from creating a Pod directly?

## Before: nothing

    kubectl apply -f - <<'EOF'
    apiVersion: v1
    kind: Pod
    metadata: {name: bypass-probe, namespace: serving}
    spec:
      containers:
        - {name: c, image: busybox:1.36, command: ["sh","-c","sleep 30"],
           resources: {limits: {"nvidia.com/gpu": "2"}}}
    EOF

    pod/bypass-probe created
    bypass-probe   Running   platform-worker2   2
    $ kubectl -n serving get workloads
    (none)

Created, scheduled, Running, holding two devices, with no Kueue Workload anywhere. Nothing admitted it and
nothing is counting it. "Multi-tenant GPU quota" was a convention the platform's own controller followed.

## The guard

A validating webhook on Pod CREATE, scoped by namespace label, `failurePolicy: Fail`.

The rule is **not** "the Pod carries a queue label". That was the first design and it is wrong: `BuildJob`
puts the queue label on the JOB's metadata, and the Job controller creates Pods from `spec.template`, which
carries no such label. A Pod-level check would refuse every training Pod this platform creates.

The rule is that the Pod's **controller** is a `batch/v1` Job carrying the queue label. Only a Job, because
in this cluster that is the only shape Kueue governs — its `pod` and `deployment` integrations are not among
the enabled frameworks, so a Pod owned by a ReplicaSet is invisible to Kueue however it is labelled.
Admitting it on a label Kueue never reads would be a guard that checks a string rather than a fact.

An ownerReference naming a Job that does not exist is refused: it is a field anyone can write.

## After: four cases on the live cluster

| case | result |
|---|---|
| bare Pod, 2 GPUs, unlabelled namespace | created — the guard is scoped, and says so |
| bare Pod, 2 GPUs, governed namespace | **Forbidden**, with the remedy in the message |
| Pod from a Job labelled `kueue.x-k8s.io/queue-name` | **admitted**, no warning |
| Pod annotated `quota-exempt` | admitted **with a warning naming the annotation** |

The refusal:

    Error from server (Forbidden): admission webhook "vgpupod.kb.io" denied the request:
    pods "bypass-probe2" is forbidden: this namespace's GPU budget is held by a Kueue ClusterQueue,
    and this Pod asks for 2 nvidia.com/gpu without belonging to a queue, so nothing would charge it:
    submit an MLTrainingJob, or label the owning Job kueue.x-k8s.io/queue-name=<queue>, or annotate
    the Pod platform.lkhun9311.github.io/quota-exempt to take the device outside the budget on purpose

## What it costs

**Availability.** `failurePolicy: Fail` means that while the webhook is down, no GPU Pod can be created in a
governed namespace at all. That is the correct direction for a quota boundary — refusing work is recoverable,
unaccounted GPU consumption is not — but the webhook's availability is now part of the platform's.

**A named hole instead of an unnamed one.** The exemption annotation lets a device plugin, or the serving
path, hold a device outside the budget. It is deliberate: serving genuinely cannot go through Kueue in this
configuration. What makes it different from the bypass is that it is written down, warned about at the moment
it is used, and enumerable with one query.

**Scope.** The webhook is bound to a namespace label rather than applied cluster-wide. A Pod webhook that can
refuse `kube-system` is how a cluster becomes unbootable.

## Found while testing this

The `gpu-premium` ClusterQueue the policy controller creates references a ResourceFlavor named `gpu` that
nothing creates, so it sat `Active=False reason=FlavorNotFound` and admitted nothing. Training admission had
never worked end to end in that namespace. The flavor was created by hand to finish this verification; the
controller not creating it is a separate defect and is not fixed here.
