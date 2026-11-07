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

Before the session creates anything, and before its watchdog is armed (so that a refusal here leaves no watchdog to destroy the shared state's cluster), it refuses a cluster that already exists under its name, then writes a Parameter Store String `/gpu-platform/session-lease/<cluster>` holding JSON:

```json
{"cluster": "gpu-platform", "session": "<EXDIR basename>", "deadline": "2026-11-07T15:55:00Z",
 "gpu_deadline": "2026-11-07T13:40:00Z", "gpu_nodegroups": ["gpu"], "vpc_id": "vpc-…", "efs_id": "fs-…"}
```

- `deadline`: the watchdog's TTL **plus** its 40-minute destroy allowance **plus** 15 minutes. The laptop's own destroy always has its turn first; the reaper acts only when that turn never came.
- `gpu_deadline` and `gpu_nodegroups`: written before each GPU scale-up, beside the existing schedule, with the same deadline; a later GPU phase replaces the deadline (or the reaper would scale down a group the session just bought) and adds its group.
- `vpc_id`, `efs_id`: recorded once known, so the reaper does not have to find them.
- `hack/lib/session-lease.sh` writes every field, reads it back and compares, and refuses to arm when a lease for the cluster already exists (a session still running, or one the reaper is still clearing), when the reaper function is not `Active`, or when the reaper has recorded no clean pass in the last 15 minutes (`/gpu-platform/session-reaper/last-ok`, written by a run that processed every lease without error): `Active` says the function exists, not that its role can read the leases.
- A session that dies after arming its lease and before building anything leaves the lease; the next session is refused until it is removed by hand (after confirming nothing of the cluster exists) or the reaper clears it at its deadline.
- The lease is removed by the session only in the branch where its teardown is **verified** (destroy returned zero and every residue query answered empty), beside the watchdog's disarm. An unverified teardown leaves both armed.

### The reaper

`infra/aws/bootstrap/reaper/reaper.py`, run every five minutes by an EventBridge rule, with its own role (so it needs none of the laptop's credentials), one concurrent execution, and a 120 s timeout. Each run reads every lease, then:

- **before both deadlines:** nothing.
- **after `gpu_deadline` (P2):** each named node group carrying the project tag is set to `minSize 0, desiredSize 0` (an update already in progress is retried next run), and counted as done only when its Auto Scaling groups hold no instance. "Accepted" is not "done": the run that sees desired 0 with an instance left reports it pending and looks again five minutes later. The lease stays; nothing is deleted.
- **after `deadline` (P1):** a step per run, in dependency order, asking and never waiting:
  1. every node group of the cluster is deleted; nothing else is touched while one exists, because the NAT carries the nodes' traffic and EFS their checkpoints;
  2. then the cluster;
  3. then the session's EFS: exactly the recorded id when there is one; otherwise the one project file system named `<cluster>-restart`, searched over every page, two of that name being a refusal. Its mount targets, then the file system;
  4. then the NAT gateways of the session's VPC that carry the project tag;
  5. then the addresses, found by their own tags (project, and `Name` exactly `<cluster>-vpc-<zone>` for each zone of the Region, the VPC module's naming; never a prefix, which would match a cluster named `<cluster>-vpc-…`), so one allocated by an apply that died before its gateway, or one whose deleted gateway has aged out of the API, is found too; none is released while a gateway of the session is still deleting or the address is associated;
  6. once the cluster is gone (it writes to the one and decrypts with the other while being deleted): the log group `/aws/eks/<cluster>/cluster`, and the cluster's key (the EKS module creates one per cluster, at $1 a month), scheduled for deletion in 7 days. The key is found by its alias `alias/eks/<cluster>`, or, when an interrupted apply or destroy left it without one, by the module's exact description `<cluster> cluster encryption key` among the account's customer keys; both require the project tag.
  A refused EFS step does not stop steps 4 and 5: the network is asked for, then the EFS failure fails the run. The state bucket's key also carries the project tag; the role denies scheduling it by ARN, whatever the code asks.
  A released address is counted as left until a later run no longer lists it; the lease is removed when a run finds nothing left.
- **A lease replaced during a run.** Before reaping, and again immediately before removing the lease, the run reads the lease and acts only if its `session` and deadline are still the ones it read: a session whose verified teardown removed its lease may be followed by another of the same cluster name, and a run still holding the old copy must not reap for it or remove the new lease. Parameter Store has no conditional delete, so the window left is the duration of the call itself.
- **A renewal during a run.** The GPU phase reads the lease again immediately before each scale-down and skips a group whose lease has been renewed; and a session that renews a GPU deadline that has already passed waits 130 s, longer than a reaper run's 120 s timeout, before it scales the group up, so no run that read the expired copy is still going.

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

- Anything not in the classes above: an ELB a Service created, an instance launched outside a node group (the sweeper covers tagged Spot instances), a volume left by a deleted node (EKS deletes the root volumes it created).
- Whether a KMS key pending deletion is still charged during its 7-day window was not checked against AWS's price list here.
- A session that writes no lease: only `hack/eks-gitops-session.sh` writes one. The Spot runners are covered by the sweeper.
- A deadline the session itself sets too late: the lease's deadline is derived from `TTL_MINUTES`, which the runner bounds by its credential lifetime.
- The free resources: the VPC, security groups and IAM stay until the next terraform run.

## P3: every root refuses another account

`allowed_account_ids = ["007635145730"]` in the AWS provider of `infra/aws/cluster`, `infra/aws/argo-bootstrap` and `infra/aws/bootstrap`, as a variable with a validation that refuses an empty list.
A plan or apply with credentials for any other account then fails before it reads or changes anything.
The Argo root's only resource is a Helm release, and terraform does not configure a provider nothing uses, so it gains a `data "aws_caller_identity"` read whose only job is to make the pinned provider configured; the Helm provider's own token comes from the AWS CLI with the same profile.
The nightly destroy and the CI plan/apply workflows assume roles created by `infra/aws/bootstrap` in that same account (`oidc.tf`), so they are inside the pin; the main session confirms this at the first plan, which fails at once if not.

## P4: the region SCP allows one Region

`infra/aws/org/scp/deny-region.json` drops `us-east-1` from `aws:RequestedRegion`, leaving `ap-northeast-2`, and adds `cloudtrail:LookupEvents` to the `NotAction` exemptions so `simulate.sh` can still read the `us-east-1` trail where global services record.
Every call this repository makes in `us-east-1` is already exempt by action (`pricing`, `ce`, `freetier`, `organizations`, `sts`, `iam`, `budgets`); `hack/test/check-scp-eval.sh` pins that and that a launch, a KMS key use, an EKS cluster and a Lambda in `us-east-1` are now denied.
SCPs never apply to the management account, which stays the recovery path: a policy that breaks a call nobody listed is detached or reverted from there.

## Apply order and rollback

All in `ap-northeast-2`, profile `gpu-lab` unless noted, each step only after its plan is read.

1. **P3 and P1/P2 in `infra/aws/bootstrap`** (one plan). Expected: 7 to add (reaper role, role policy, log group, Lambda function, event rule, event target, Lambda permission; the archive is a data source), 0 to change, 0 to destroy; the provider pin adds no resource. Rollback: `git revert` and apply, which removes the eight; no lease can exist yet.
2. **P3 in `infra/aws/cluster` and `infra/aws/argo-bootstrap`**: a plan only, with the cluster not built. Expected: the cluster root's usual plan of a full build (it is applied only by a session), nothing destroyed; the Argo root cannot plan without a cluster and is checked by the first session that builds one; the plan's success with `gpu-lab` and its failure with `gpu-lab-ro` reaching another account, if any, is the check. Rollback: revert the variable.
3. **Exercise the reaper without money**: wait for one scheduled run and read `/gpu-platform/session-reaper/last-ok` (it proves the role can read the lease path); then write a lease by hand for a cluster name that does not exist with a deadline in the past (`aws ssm put-parameter --name /gpu-platform/session-lease/reaper-exercise --type String --value '{"cluster":"reaper-exercise","deadline":"2026-01-01T00:00:00Z"}'`), invoke the function once (`aws lambda invoke --function-name gpu-platform-session-reaper out.json`), and read that it reported the lease REAPED and removed it, with no other call. Then a lease with an unreadable deadline must fail the invocation and be left.
4. **P4 in the organization** (profile `gpu-mgmt`): first an inventory of `us-east-1` in `gpu-lab`, because once attached the member account can no longer delete what is there: `aws resourcegroupstaggingapi get-resources --region us-east-1`, `aws ec2 describe-instances`, `describe-volumes`, `describe-addresses`, `describe-nat-gateways`, `aws kms list-keys` (customer keys only), `aws eks list-clusters`, `aws lambda list-functions`, `aws logs describe-log-groups`, each with `--region us-east-1`, every one empty or cleaned up first; `aws efs describe-file-systems`, `aws ec2 describe-network-interfaces` and `aws ssm describe-parameters` (services the tag API does not list when untagged), and Cost Explorer's last two months grouped by Region (`aws ce get-cost-and-usage --group-by Type=DIMENSION,Key=REGION`), whose `us-east-1` line may hold only the global services exempted by action; then `bash infra/aws/org/scp/simulate.sh` against the last week of recorded calls from `gpu-lab`, which must report no denial; then `aws organizations update-policy` of the region policy with the new document, read back; then from `gpu-lab` a dry run (`aws ec2 run-instances --dry-run --region us-east-1 …`) must answer an SCP denial and the same in `ap-northeast-2` `DryRunOperation`, and `aws pricing get-products --region us-east-1` must still answer. Rollback: `update-policy` with the previous document (kept in git) from `gpu-mgmt`.
5. The next paid session is the first to write a lease; its session log carries `session lease armed` and, after a verified teardown, `session lease removed`.

## What was tested here, and by which engine

- `infra/aws/bootstrap/reaper/test_reaper.py` (18 cases, fake clients holding a small account): every branch above, including the refusals (unreadable deadline, a lease naming another cluster, an untagged cluster or group, two VPCs of the name) and the order (nothing past the node groups while one exists; an address only after its gateway is deleted).
- `hack/test/check-session-lease.sh` (13 checks, a stub Parameter Store): arm, refusal over an existing lease, an unreadable store, a read-back mismatch, the GPU deadline replaced and groups accumulated, disarm; and in the runner, the arm before the first cluster apply, the disarm only in the verified branch, a GPU lease beside every GPU schedule.
- `hack/test/check-train-session-refusals.sh`: the runner's stub now answers the lease calls, and a session that reaches the cluster's init wrote its lease first.
- `hack/test/check-scp-eval.sh`: the P4 cases above.
- `terraform fmt`, `init -backend=false` and `validate` of all three roots; the cluster root's 11 Terraform tests.
- Claude wrote and ran all of these. gpt-6-astra's reviews are recorded below.

## Revisions

### Round 1 (gpt-6-astra, high, read-only, asked only "can these changes destroy something they should not, fail to clean up what they should, or lock the owner out of the account?")

Nine findings; each was checked against the code by Claude, eight confirmed and fixed, one fixed by an added step.

| # | finding | verdict | change |
|---|---|---|---|
| 1 | a refused lease left the watchdog armed, which would destroy the shared state's cluster | confirmed | the lease is armed before the watchdog, after the existing-watchdog refusal and a new existing-cluster refusal |
| 2 | a recorded EFS id did not restrict deletion: a copy with the same Name went too | confirmed (reproduced by astra with the fakes) | the recorded id is used alone; without one, two of the name is a refusal |
| 3 | a run's old copy of the lease could scale down a group the session had just renewed and bought | confirmed | the lease is read again before each scale-down, and renewing a passed GPU deadline waits 130 s |
| 4 | addresses were found only through deleted NAT records, which age out after about an hour or never existed | confirmed | addresses are found by their own tags and name |
| 5 | EFS discovery read one page | confirmed | the recorded id is described directly; discovery is paginated |
| 6 | the SSM path requested and the path granted differed; and `Active` did not show the role could read | partly: the exact authorisation rule was not checked against AWS | the request drops the trailing slash and both spellings are granted; a clean pass writes a heartbeat, and a session requires one from the last 15 minutes |
| 7 | the EKS module's per-cluster KMS key (and log group) were left billing | confirmed (`create_kms_key` defaults to true in v20.24.0) | both are removed once the cluster is gone; the state key is denied by ARN |
| 8 | the Argo root's account pin was never evaluated, since no AWS resource there uses the provider | confirmed | a `data "aws_caller_identity"` read configures it |
| 9 | the SCP rollout did not show that what already exists in `us-east-1` can still be deleted | confirmed as a step | apply step 4 now inventories `us-east-1` first |

astra could not verify live IAM evaluation, EventBridge delivery or the effective SCP attachments; neither could this branch.

### Round 2 (the same question, on the branch after round 1's fixes)

Five findings; all confirmed by Claude against the code.

| # | finding | change |
|---|---|---|
| 1 | a run holding an old copy of a lease could reap for, or remove, a newer session's lease of the same cluster name (reproduced by astra with the fakes) | the lease's session and deadline are read again before reaping and before removing it |
| 2 | the address filter `<cluster>-vpc-*` was a prefix, matching a cluster named `<cluster>-vpc-test` (reproduced) | exact names, one per zone the Region lists; the fake refuses a pattern |
| 3 | a key left without its alias by an interrupted apply or destroy was missed and the lease removed | the key is also found by the module's exact description among customer keys, with the project tag required |
| 4 | the `us-east-1` inventory before P4 missed untagged EFS and other untagged resources | apply step 4 lists EFS, network interfaces and parameters by service, and reads Cost Explorer by Region |
| 5 | deleting a mount target needs `ec2:DeleteNetworkInterface`, which the role lacked, and a refused EFS step stopped the NAT and address steps | the permission is granted (the interface carries no tag to scope it by; the reaper never calls it directly) and a refused EFS step no longer stops the network steps |

Accepted residual: whether EFS's service-linked role makes the interface permission unnecessary, and whether IAM evaluates every grant as written, are shown only by the apply-time exercise, not here.
