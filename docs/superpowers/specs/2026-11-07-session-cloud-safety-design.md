# Paid sessions that clean up without the laptop: the session reaper, the account pin and the one-Region SCP

Written 2026-11-07.
Status: **built and tested offline; not applied.** Nothing here has been run against AWS.
These are proposals P1 to P4 of `docs/superpowers/specs/2026-11-07-review-r5-paid-session-safety.md`, approved by the owner on 2026-11-07 after adversarial review ("r5에서 나온 변경에 대해서도 적대적 검토 후 권장안 진행").
The apply order, the expected plans and the rollback are at the end; each apply is the main session's, after reading its plan.

## The gap

Every cleanup of a paid session runs on the machine that started it: the session's own teardown, and the TTL watchdog (`killswitch_program`, `hack/lib/session-teardown.sh`) that destroys the cluster at the session's deadline.
If that machine loses power, sleeps or loses its credentials, neither runs.
What is left in the account then:

| what | covered today | by |
|---|---|---|
| GPU instances of an EKS node group | once | the per-session EventBridge schedule (`hack/lib/gpu-ttl.sh`) asks for `desiredSize=0` a single time and is deleted after it; nothing follows the update (r5 finding 5) |
| Spot instances launched by the older runners | yes | the study sweeper, by `study-deadline` tag (since r5 finding 4, every launch carries one) |
| EKS control plane ($0.10/h), CPU node group, NAT gateway and its address, EFS | **no** | — (r5 finding 3) |
| nightly destroy workflow | sometimes | it is disabled by hand for the long restart stages |

So a laptop lost during a restart stage leaves about $0.25/h billing until somebody notices (EKS $0.10, NAT $0.059, a t3.large $0.104, EFS by size), and the GPU group depends on one API call having succeeded.

## P1 and P2: one Lambda, the session reaper, acting on a lease

### The lease

Before the session creates anything (directly after its watchdog is armed, before the first `terraform apply`), it writes a Parameter Store String `/gpu-platform/session-lease/<cluster>` holding JSON:

```json
{"cluster": "gpu-platform", "session": "<EXDIR basename>", "deadline": "2026-11-07T15:55:00Z",
 "gpu_deadline": "2026-11-07T13:40:00Z", "gpu_nodegroups": ["gpu"], "vpc_id": "vpc-…", "efs_id": "fs-…"}
```

- `deadline`: the watchdog's TTL **plus** its 40-minute destroy allowance **plus** 15 minutes. The laptop's own destroy always has its turn first; the reaper acts only when that turn never came.
- `gpu_deadline` and `gpu_nodegroups`: written before each GPU scale-up, beside the existing schedule, with the same deadline; a later GPU phase replaces the deadline (or the reaper would scale down a group the session just bought) and adds its group.
- `vpc_id`, `efs_id`: recorded once known, so the reaper does not have to find them.
- `hack/lib/session-lease.sh` writes every field, reads it back and compares, and refuses to arm when a lease for the cluster already exists (a session still running, or one the reaper is still clearing) or when the reaper function is not `Active`.
- The lease is removed by the session only in the branch where its teardown is **verified** (destroy returned zero and every residue query answered empty), beside the watchdog's disarm. An unverified teardown leaves both armed.

### The reaper

`infra/aws/bootstrap/reaper/reaper.py`, run every five minutes by an EventBridge rule, with its own role (so it needs none of the laptop's credentials), one concurrent execution, and a 120 s timeout. Each run reads every lease, then:

- **before both deadlines:** nothing.
- **after `gpu_deadline` (P2):** each named node group carrying the project tag is set to `minSize 0, desiredSize 0` (an update already in progress is retried next run), and counted as done only when its Auto Scaling groups hold no instance. "Accepted" is not "done": the run that sees desired 0 with an instance left reports it pending and looks again five minutes later. The lease stays; nothing is deleted.
- **after `deadline` (P1):** a step per run, in dependency order, asking and never waiting:
  1. every node group of the cluster is deleted; nothing else is touched while one exists, because the NAT carries the nodes' traffic and EFS their checkpoints;
  2. then the cluster;
  3. then the session's EFS (by recorded id, or by `Name = <cluster>-restart` and the project tag): its mount targets, then the file system;
  4. then the NAT gateways of the session's VPC that carry the project tag;
  5. then the addresses of NAT gateways that are already `deleted`, only when they carry the project tag and are no longer associated.
  The lease is removed when a run finds nothing left.

**Why API deletion and not `terraform destroy`.** A Lambda running terraform would need the state bucket, its KMS key, the provider plugins in a layer, and a role able to destroy everything the cluster root creates (IAM roles and policies included); it would race the laptop's own destroy for the state lock; and a failure halfway leaves a state that no longer matches the account. Deleting the five billing resources by API needs a role scoped to delete only resources carrying the project tag, and leaves the free ones (VPC, subnets, route tables, security groups, IAM roles, the KMS key of the cluster) for the next `terraform apply` or `destroy` to reconcile; terraform reads a deleted resource as gone and plans to recreate it.

### Ownership, not uniqueness

The reaper acts only on what the lease names **and** what carries `project = gpu-platform-control-plane`:

- the cluster of the lease's own name (a lease stored under one name and naming another cluster is refused), and the cluster must carry the project tag or nothing of it is touched;
- that cluster's node groups (each checked for the tag in the GPU phase);
- the EFS file system of the recorded id or the cluster's `<cluster>-restart` name;
- NAT gateways in the session's VPC: the recorded `vpc_id`, else the cluster's own VPC while the cluster exists, else the single project VPC named `<cluster>-vpc` (two of that name is a refusal, never a choice);
- addresses only of those NAT gateways.

The IAM policy repeats the tag condition on every mutating action, so a code defect cannot reach an untagged resource. The reads (`Describe*`, `List*`) cannot be scoped by tag and are not.

### Failure modes

| failure | what happens |
|---|---|
| a lease is unreadable or its deadline has no zone | that lease fails, the run raises, Lambda's Errors metric counts it; nothing is deleted on its word; other leases are still processed |
| the reaper's role is refused a call | that lease fails the run the same way; the next run tries again |
| the Lambda itself is broken or deleted | `lease_arm` refuses to start a session when the function is not `Active`; a function that breaks mid-session leaves the watchdog and the nightly destroy, as today |
| a partial deletion | the next run continues from what is left; the lease is removed only when nothing is |
| the laptop's destroy and the reaper overlap | the reaper's deadline is 15 minutes after the watchdog's destroy allowance; if the destroy is still running then, both delete the same resources and the loser sees NotFound, which the reaper reads as gone. Terraform can then fail on a resource the reaper deleted first; its retry or the next destroy completes |
| a session restarted under the same cluster name while an old lease is still being reaped | `lease_arm` refuses until the lease is gone |

### Cost

One invocation every five minutes of about a second (8,640 a month, inside Lambda's free tier), a log group with 30-day retention, and Parameter Store standard parameters (free). About $0.

### What it does not protect

- Anything not in the five classes above: an ELB a Service created, an instance launched outside a node group (the sweeper covers tagged Spot instances), a volume left by a deleted node (EKS deletes the root volumes it created).
- A session that writes no lease: only `hack/eks-gitops-session.sh` writes one. The Spot runners are covered by the sweeper.
- A deadline the session itself sets too late: the lease's deadline is derived from `TTL_MINUTES`, which the runner bounds by its credential lifetime.
- The free resources: the VPC and IAM stay until the next terraform run.

## P3: every root refuses another account

`allowed_account_ids = ["007635145730"]` in the AWS provider of `infra/aws/cluster`, `infra/aws/argo-bootstrap` and `infra/aws/bootstrap`, as a variable with a validation that refuses an empty list.
A plan or apply with credentials for any other account then fails before it reads or changes anything.
The nightly destroy and the CI plan/apply workflows assume roles created by `infra/aws/bootstrap` in that same account (`oidc.tf`), so they are inside the pin; the main session confirms this at the first plan, which fails at once if not.

## P4: the region SCP allows one Region

`infra/aws/org/scp/deny-region.json` drops `us-east-1` from `aws:RequestedRegion`, leaving `ap-northeast-2`, and adds `cloudtrail:LookupEvents` to the `NotAction` exemptions so `simulate.sh` can still read the `us-east-1` trail where global services record.
Every call this repository makes in `us-east-1` is already exempt by action (`pricing`, `ce`, `freetier`, `organizations`, `sts`, `iam`, `budgets`); `hack/test/check-scp-eval.sh` pins that and that a launch, a KMS key use, an EKS cluster and a Lambda in `us-east-1` are now denied.
SCPs never apply to the management account, which stays the recovery path: a policy that breaks a call nobody listed is detached or reverted from there.

## Apply order and rollback

All in `ap-northeast-2`, profile `gpu-lab` unless noted, each step only after its plan is read.

1. **P3 and P1/P2 in `infra/aws/bootstrap`** (one plan). Expected: 8 to add (reaper role, role policy, log group, Lambda function, event rule, event target, Lambda permission; the archive is a data source), 0 to change, 0 to destroy; the provider pin adds no resource. Rollback: `git revert` and apply, which removes the eight; no lease can exist yet.
2. **P3 in `infra/aws/cluster` and `infra/aws/argo-bootstrap`**: a plan only, with the cluster not built. Expected: no changes (the pin is provider configuration); the plan's success with `gpu-lab` and its failure with `gpu-lab-ro` reaching another account, if any, is the check. Rollback: revert the variable.
3. **Exercise the reaper without money**: write a lease by hand for a cluster name that does not exist with a deadline in the past (`aws ssm put-parameter --name /gpu-platform/session-lease/reaper-exercise --type String --value '{"cluster":"reaper-exercise","deadline":"2026-01-01T00:00:00Z"}'`), invoke the function once (`aws lambda invoke --function-name gpu-platform-session-reaper out.json`), and read that it reported the lease REAPED and removed it, with no other call. Then a lease with an unreadable deadline must fail the invocation and be left.
4. **P4 in the organization** (profile `gpu-mgmt`): first `bash infra/aws/org/scp/simulate.sh` against the last week of recorded calls from `gpu-lab`, which must report no denial; then `aws organizations update-policy` of the region policy with the new document, read back; then from `gpu-lab` a dry run (`aws ec2 run-instances --dry-run --region us-east-1 …`) must answer an SCP denial and the same in `ap-northeast-2` `DryRunOperation`, and `aws pricing get-products --region us-east-1` must still answer. Rollback: `update-policy` with the previous document (kept in git) from `gpu-mgmt`.
5. The next paid session is the first to write a lease; its session log carries `session lease armed` and, after a verified teardown, `session lease removed`.

## What was tested here, and by which engine

- `infra/aws/bootstrap/reaper/test_reaper.py` (18 cases, fake clients holding a small account): every branch above, including the refusals (unreadable deadline, a lease naming another cluster, an untagged cluster or group, two VPCs of the name) and the order (nothing past the node groups while one exists; an address only after its gateway is deleted).
- `hack/test/check-session-lease.sh` (13 checks, a stub Parameter Store): arm, refusal over an existing lease, an unreadable store, a read-back mismatch, the GPU deadline replaced and groups accumulated, disarm; and in the runner, the arm before the first cluster apply, the disarm only in the verified branch, a GPU lease beside every GPU schedule.
- `hack/test/check-train-session-refusals.sh`: the runner's stub now answers the lease calls, and a session that reaches the cluster's init wrote its lease first.
- `hack/test/check-scp-eval.sh`: the P4 cases above.
- `terraform fmt`, `init -backend=false` and `validate` of all three roots; the cluster root's 11 Terraform tests.
- Claude wrote and ran all of these. gpt-6-astra's reviews are recorded below.

## Revisions

*(filled after the adversarial review)*
