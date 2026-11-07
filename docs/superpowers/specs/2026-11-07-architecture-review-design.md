# Architecture review, 2026-11-07: what a production fleet would change, and what this project proves for free

Status: **recommendations; nothing here is built yet.** Each item names the profile it belongs to, the free proof, and an optional paid demonstration.
Sources: five read-only architecture reviews by gpt-6-astra (high) on `origin/dev` `56519750` — control plane, serving, infrastructure and operations, observability and evidence, and the six AWS Well-Architected pillars — and Claude's independent take written before reading them.
Findings Claude has not re-checked against the code are marked *(astra)*; the rest were checked.

## The rule this page follows

This is a one-person project on rented capacity.
Paying for redundancy that nothing uses is waste, so the design is split into two profiles:

- **lab** — what runs today: single replicas, one AZ, scale-to-zero GPUs, cheapest session shapes.
- **production** — what a fleet of thousands of GPUs across sites would run: replicated control components, failure-domain spread, enforced tenant boundaries, redundant monitoring.

The production profile is a real kustomize overlay whose *behaviour* is proven on kind for free (failover, no limit multiplication, leader handover, policy denials).
How it would be operated at scale, and what that would cost, is written down rather than bought.
A paid run is reserved for a demonstration with clear interview value, short and costed, with the owner's go.

## Where the current design breaks at fleet scale

| # | Pillar | Finding | Checked |
|---|---|---|---|
| 1 | Security | `fenced-nodes` on the MLTrainingJob is trusted by the restart barrier, and the MLTrainingJob editor role can patch it: a tenant can declare an unreachable machine fenced while its rank still writes checkpoints | yes: `internal/controller/mltrainingjob_restart.go` reads the annotation; `config/rbac/mltrainingjob_editor_role.yaml` grants patch |
| 2 | Security | Every generated ClusterQueue has an empty `namespaceSelector`, so a LocalQueue in any namespace can point at any tenant's ClusterQueue | *(astra)* `internal/controller/kueue_quota.go:68` |
| 3 | Security | The Pod and Job guards run on CREATE only; removing a scheduling gate or unsuspending later escapes admission (also review r8 #4, being fixed) | yes (r8) |
| 4 | Security | Engines and gateway metrics are reachable by Pod IP from any tenant: there is no default-deny NetworkPolicy for serving, so the gateway's authentication, rate limits and priority binding can be bypassed | *(astra)* |
| 5 | Security | The gateway's Secret watch covers every Secret in the operator namespace, including the webhook TLS key | *(astra)* |
| 6 | Reliability | Gateway `replicas: 1` by design (`config/gateway/deployment.yaml:11-17`): token buckets, prefill reservations and routing counts are process-local; a second replica multiplies limits, and even a default rolling update overlaps two | yes |
| 7 | Reliability | Operator `replicas: 1` with `--leader-elect`; the three webhooks (`failurePolicy: Fail`) live in the same Pod, so an operator outage blocks MLTrainingJob writes and every Pod/Job create in governed namespaces | yes |
| 8 | Reliability | Kueue, Prometheus, Alertmanager, Argo CD and cert-manager run single and without an independent dead-man alert | *(astra)* |
| 9 | Performance | The GPU fault path scrapes every node's exporter from the operator and waits for the slowest: a few slow exporters age every other node's fault signal | *(astra)*, consistent with `internal/controller/gpufault_source.go` |
| 10 | Performance | KV-aware admission and prefix affinity key on a Service, not on the engine Pod that serves the request; with several engines behind a Service the pressure read is not the pressure met | *(astra)* `internal/gateway/kvguard.go:395` |
| 11 | Reliability | The gateway bounds neither queued bytes nor queued requests, and its HTTP servers have no read timeouts: aggregate memory is unbounded under many compliant tenants | *(astra)* `cmd/gateway/main.go:328` |
| 12 | Operability | `config/default` (what `make deploy` applies) omits the webhooks, so the default install does not enforce the quota boundary it reports | *(astra)* |
| 13 | Operability | Gateway metrics carry tenant/model labels forever (cardinality grows with turnover) and expose other tenants' activity | *(astra)* |
| 14 | Operability | The evidence verifier checks the checksums an archive carries, not a repository-owned manifest of what was published | *(astra)* |
| 15 | Cost | Budgets notify, they do not enforce; session teardown depends on the launcher (review r5 P1–P4 in progress) | yes |

## Recommendations

### A. Fix in both profiles now (code and config defects, free)

| Item | Change | Proof (free) |
|---|---|---|
| A1 fencing authority (1) | The validating webhook allows changes to `fenced-nodes` only from a platform-operator identity (a group named in the manager's config, plus the session runner's identity); everyone else is refused | envtest as a tenant identity: patch refused; as the operator group: accepted |
| A2 queue binding (2) | Each generated ClusterQueue gets a `namespaceSelector` for its tenant's namespaces; LocalQueues are platform-owned | envtest: a LocalQueue in another namespace cannot admit into it |
| A3 UPDATE guards (3) | r8 #4 fix (in progress) | its own tests |
| A4 serving network boundary (4) | Default-deny NetworkPolicy for engine Pods except from the gateway; metrics ingress only from the monitoring namespace | kind with a NetworkPolicy-enforcing CNI: direct engine call from a tenant Pod refused, through the gateway accepted |
| A5 gateway Secret scope (5) | Name-filtered Secret watch with `resourceNames` RBAC, or the gateway in its own namespace | envtest/RBAC check: the gateway SA cannot read the webhook TLS Secret |
| A6 gateway bounds (11) | Global and per-tenant caps on queued requests and queued bytes, reject before buffering; header/body read deadlines | unit tests and a kind load probe: memory stays under the cap, the excess is refused with a stated reason |
| A7 engine identity (10) | Until per-endpoint routing exists, refuse engine-aware modes (KV-aware, prefix affinity) on an InferenceDeployment with more than one replica, as HoldCap already does | webhook test |
| A8 fault-scrape isolation (9) | Per-node scrape deadline and per-node freshness, so one slow exporter ages only its own node | unit test with one stalled fake exporter among many |
| A9 enforced default (12) | `config/default` includes the webhooks, or `make deploy` refuses without them | rendered-manifest test |
| A10 metrics cardinality (13) | Retire series of deleted backends/tenants; keep tenant labels off histograms or behind a bounded class label | unit test on the registry after deletions |

### B. The production profile (a kustomize overlay to be added beside `config/default`), proven on kind

| Component | lab | production | Free proof on kind |
|---|---|---|---|
| Operator | 1 replica, leader election | 2 replicas (one leader, one hot standby that also serves webhooks), PDB `minAvailable: 1`, spread across zones, webhook `objectSelector` narrowed to GPU/queue objects, short timeouts | kill the leader: measure the time until reconciles resume and show webhook writes kept succeeding through the standby |
| Gateway | 1 replica | **Step 1: active/passive.** 2 replicas; a Kubernetes Lease elects the one that admits, the other is not Ready, so the Service only reaches the leader. Correct limits, simple failover, no new datastore. **Step 2 (only if throughput needs it): active/active** with partitioned allowances (each live replica gets limit / N from Lease-based membership; shrink before grow on membership change, so a partition can under-admit but never overshoot) and consistent-hash routing by tenant so prefill reservations stay local | Step 1: kill the leader mid-load, measure the gap and show a tenant's admitted rate never exceeds its limit; Step 2: the same with N = 3 and a replica partitioned |
| Kueue | 1 replica | 2 replicas with leader election, PDB | kill the leader during admissions |
| Monitoring | single Prometheus, test receiver | two Prometheus replicas (or a managed backend), Alertmanager cluster of 2–3, an external dead-man's switch | kill one Prometheus and one Alertmanager: an alert still arrives once (Alertmanager deduplicates) |
| System node pool | one AZ | multi-AZ system node group; GPU pools stay per-AZ for NCCL | — (documented) |

No quorum system of our own: Kubernetes (etcd) is already the consensus layer, and Leases give leader election and membership on top of it.
Quota under partition is chosen consistent over available: a gateway that cannot see membership keeps its last allowance and decays it rather than overshoot.

### C. Documented only: how a real fleet would run it

- One control plane per site (managed EKS within a region; three or five etcd voters across local failure domains where self-managed), no cross-site admission state; a site's loss is a capacity loss, not a quota corruption.
- Checkpoint storage multi-AZ (EFS mount targets in each AZ, or a parallel filesystem per site); restart contract unchanged.
- Release promotion through a canary cell with additive CRD changes; rollback only while persisted state stays readable.
- Managed observability (AMP/AMG or equivalent) with remote-write from per-site Prometheus.
- The cost of each, against the lab profile's, in `docs/09_AWS_INFRA_ARCHITECTURE.md`.

### D. A paid demonstration worth its cost

**Production-profile failover on EKS across two AZs with CPU nodes only** (no GPU: the components being failed over are control-plane services): operator leader kill, gateway leader kill under replayed load, one AZ's system nodes cordoned and drained.
Shape: the existing cluster root with t3 system nodes in two AZs, about an hour; at the repository's recorded rates roughly a few dollars (to be priced by the session's price gate before any purchase).
It needs the owner's go; it is the one paid item here.

### E. Not built here

A consensus system of our own, a service mesh only for mTLS, multi-region active/active admission, Slurm HA/federation, and a generic remediation platform (NVSentinel exists).

## Order

1. A1–A3 and A5 (tenant boundary) and A9 — small, closes the security findings.
2. A6, A8, A7 — bounds and isolation that matter before any scale test.
3. B: operator and gateway Step 1 in the production overlay, with the kind proofs.
4. A4, A10, B monitoring.
5. D, if approved; C as the written operating model.
