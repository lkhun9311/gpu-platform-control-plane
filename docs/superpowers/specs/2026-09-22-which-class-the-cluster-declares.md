# Which class the cluster declares, and why this one

**Written 2026-09-22, after the declaration landed and before any card is bought.** This is not a
pre-registration. `2026-09-22-the-claim-exists-and-the-class-is-named.md:47` deliberately left one thing
unchosen:

> **The operator names the class; this page names no default and the code has none.**
>
> — `2026-09-22-the-claim-exists-and-the-class-is-named.md:49`

That refusal was right at the time: no provisioner for a GPU cluster was recorded anywhere in the tree, and
choosing one from a kind cluster's behaviour is the inference this lab refuses elsewhere. A cluster now
declares one, so the choice exists and has to be written down somewhere a reader will find it. A pull
request body is not that place.

## What was actually missing

`cluster_addons` carried coredns, kube-proxy and vpc-cni and **no CSI driver at all**. So the failure was
not "the wrong class is default" — it was that a claim naming any class would have stayed Pending on a
cluster configured exactly as its code said. The smoke probe would have refused, correctly, and the refusal
would have been read as a storage problem rather than as a missing addon.

## The class

`queuelab-gp3`, in `config/storage/storageclass.yaml`:

| field | value | why |
|---|---|---|
| `provisioner` | `ebs.csi.aws.com` | the only driver the cluster now has |
| `volumeBindingMode` | `WaitForFirstConsumer` | required, not preferred — see below |
| `reclaimPolicy` | `Delete` | required, not preferred — see below |
| `type` | `gp3` | the cheapest current-generation EBS type; no measurement here needs provisioned IOPS |
| `encrypted` | `"true"` | account default; nothing in the lab needs plaintext volumes |

**Two of these five were already forced by the registration page**, which is why they are not open choices:

- `WaitForFirstConsumer` because the lab places its rows on a labelled worker through the flavour's node
  selector and tolerations (`2026-09-22-the-claim-exists-and-the-class-is-named.md:56`). An `Immediate`
  class binds the volume to a zone before the scheduler has picked a node, and the row then cannot be
  placed where the protocol selected.
- `Delete` because `2026-09-22-the-claim-exists-and-the-class-is-named.md:70` records that the
  PersistentVolume and the disk behind it outlive the namespace under `Retain`, and that **nothing in this
  repository ever looks at them**. A `Retain` class running these arms repeatedly accumulates volumes that
  keep costing money invisibly.

`gp3` and `encrypted` are the two genuinely free choices, and neither is load-bearing for any measurement.

## Where the boundary is drawn

**Terraform owns the driver and the permission. Argo owns the object in the cluster.**

The addon is declared at `infra/aws/cluster/eks.tf:60` with `service_account_role_arn` naming a role built
in `iam.tf`. The alternative — attaching `AmazonEBSCSIDriverPolicy` to the node role — would give every
workload on every node the right to create and delete volumes in the account. That is the permission this
cluster is least able to afford, and the lab deliberately runs untrusted-shaped workloads on those nodes.

The trust policy (`infra/aws/cluster/iam.tf:63`) binds **both** the `sub` to
`system:serviceaccount:kube-system:ebs-csi-controller-sa` and the `aud`. Without the `sub` bound, any pod in
the cluster holding a projected token could assume the role.

The role is written directly rather than through the registry's `iam-role-for-service-accounts-eks`
submodule. `make infra-validate` runs `terraform init -backend=false` in CI, and every module it has to
fetch is a network dependency inside a check that is otherwise offline.

## One thing is deliberately not pinned

The other three addons carry `addon_version`. This one does not, and that asymmetry is recorded in the code
rather than left to be discovered: it was added while the AWS credentials were expired, so
`aws eks describe-addon-versions` could not be run and **any version written there would have been a
guess**. A wrong pin fails the apply at the addon, which is the expensive place to find it.

Omitting it makes the module fall back to `data.aws_eks_addon_version` — the version EKS selects for the
cluster's Kubernetes minor. **Pin it from a real `describe-addon-versions` before the next apply.** This is
the one item on this page that is owed rather than done.

## The check that would not have run

`make infra-validate` builds a **hardcoded list** of kustomize directories (`Makefile:391`). A new
`config/storage/` not added to that list is never built, and the build that never runs is indistinguishable
from the build that passes — the failure mode this repository has hit repeatedly. The entry was added in
the same change, and confirmed by removing it and watching the directory drop out of validation entirely.

## What this does NOT establish

**That provisioning works.** `2026-09-22-the-claim-exists-and-the-class-is-named.md:64` already says a class
that exists is not a promise that provisioning succeeds: a broken driver, an exhausted quota or a zone with
no capacity all leave a claim that is accepted and never binds. Declaring the driver removes one knowable
failure and says nothing about the rest.

**That two Pods share the file.** That is the smoke probe's question
(`2026-09-22-the-claim-exists-and-the-class-is-named.md:85`), and the probe has never run against a real
cluster — only against a fake apiserver and a three-role double.

**That the arms can be bought.** `STUDY` still accepts only `reclaim` and `idling`, so there is no form in
which the resume block can be requested, and the campaign budget registered on
`2026-09-22-the-retry-rule-had-nothing-counting-it.md` is unenforceable until artifact paths carry an
attempt ordinal.

**That any of this has been applied.** The cluster is torn down and the credentials are expired. Everything
here is code that a future apply will exercise for the first time.
