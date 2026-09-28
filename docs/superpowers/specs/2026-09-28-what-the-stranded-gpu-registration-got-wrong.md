# What the stranded-GPU registration got wrong — amendment

**Written 2026-09-28, still before any instrument exists.** This page amends
`2026-09-23-what-a-stranded-gpu-is-and-what-kind-can-say-about-it.md`, which was written five days earlier and
committed only to an unpushed local branch. The original text is published unchanged beside this page; nothing in
it was edited to match what is written here, so a reader can see both what was registered and what adversarial
review found in it.

**What this amendment cannot do.** Publishing today establishes this protocol publicly now. It does not
authenticate the 23rd: author and committer dates are editable, and the original page sat in one local branch
with no remote copy until today, so its date is a claim about when it was written and not evidence of it. The
honest reading is that both pages predate the instrument, which is the property the study actually needs.

## The definition and the measurement did not agree

The original states the definition in prose and then measures something else.

The prose requires that **no pending workload fits anywhere**: with `f_i` the free devices on node `i` and
`q_min` the smallest pending request, that is `max(f_i) < q_min`. The measurement table instead sums the free
devices on every node whose own free count is below `q_min` — `Σ_{f_i < q_min} f_i`.

Those differ. With free counts `[1, 4]` and a pending request of 2, the table reports one stranded device while
the workload can in fact be placed on the second node. A sum of unusable gaps is a defensible figure, but it is
not the cluster-wide blockage the definition names, and reporting one under the other's definition is the shape
of error this project keeps finding in its own work.

**Amended:** the registered figure is the cluster-wide one, `max(f_i) < q_min`, stated as a formula rather than
as prose. The per-node gap sum is retained as a **separate** diagnostic under its own name, never as the
headline.

Two boundary cases the original left open:

- **No pending demand.** "Below every pending request" is vacuously true of an empty pending set, so an idle
  cluster would report stranding. Amended: no pending demand means **no demand-relative stranding**, and that
  is a distinct outcome from *demand observations missing*, which invalidates the census instead.
- **Aggregate shortage is not fragmentation.** With `[1, 1]` free and a request of 3, the request is blocked
  because the cluster does not have three devices at all. To isolate fragmentation the census requires a
  **witness request** `q` with `max(f_i) < q ≤ Σ f_i` — a request that the cluster could satisfy if the free
  devices were on one node and cannot satisfy as they lie. Requests that would not fit on an empty node of the
  largest size are counted separately again, as unsatisfiable rather than stranded.

**"Contiguous" is withdrawn.** The original says a workload "needs more contiguous devices on one node". The
instrument measures neither device adjacency nor interconnect topology. The requirement is **"on the same
node"**, and nothing here can say anything about which devices those are.

## The census needs a demand ledger, and `FailedScheduling` is not one

The original's validity rule — a run is invalid if any pod is pending for a reason other than GPU capacity —
cannot see the cases that matter most. A suspended Job has no pod. A submission the API rejected has no object
at all. A collector that missed every pod sees an empty pending set. **All three satisfy the rule**, and all
three are "did not run" wearing the face of "passed".

**Amended:** every registered submission carries an **observed disposition** — API-rejected, queued and
unadmitted, topology-assigned, bound, or released — and a census with any submission whose disposition was not
observed is invalid. An empty pending set is a result only when the demand ledger accounts for every submission.

`FailedScheduling` events are demoted to **diagnostic evidence**. They are best-effort, scheduler retries emit
the same blockage repeatedly, and `ResourceQuota` can reject a pod before one exists to fail scheduling. Blocked
workloads are counted from the demand ledger at defined census steps; the events explain a count, they do not
produce it.

Reservations are computed from **bound** pods, with one pod per workload and a fixed integer GPU request for the
first study, and terminating pods and in-flight bindings resolved before a census is accepted. Foreign consumers
of `nvidia.com/gpu` are either included explicitly or their presence invalidates the census.

**Kueue admission is a separate layer from placement.** A quota reservation is not a reservation on any
particular node, and topology-aware scheduling assigns topology to an admitted workload before all of its pods
are bound — Kueue's own capacity calculation counts admitted TAS workloads. Amended: topology assignments are
recorded separately from bound pods and reconciled against them, so neither is counted twice.

## The treatment could silently not apply

The original's one guard against a null result from an unapplied treatment was a check that the requested
scoring strategy is the one the cluster runs. That is necessary and not sufficient.

`NodeResourcesFit` scores **CPU and memory** by default. Selecting `MostAllocated` without naming
`nvidia.com/gpu` in its resource list activates the named strategy and does not pack GPUs — the strategy check
passes, the treatment does nothing, and three arms report the same number. Other scoring plugins and their
weights also move the final choice.

**Amended:** the registration freezes the complete scoring resource list and weights, the relevant plugins, the
scheduler version and the pods' `schedulerName`; and a **separate qualification fixture** with a known unequal
placement preference must demonstrate that the treatment acts, before any comparative run.

This exposes a design choice the original did not acknowledge. A GPU-aware `LeastAllocated` isolates the
strategy change but is **no longer the untouched default**, so it cannot be described as the reference. Either
the reference is the untouched default and the treatment is *the whole configuration change* including the
resource list, or both arms are GPU-aware and the comparison is between two deliberate configurations. This
study takes the first and says so.

**`S-tas` is not a third scoring strategy.** Topology-aware scheduling adds admission and topology assignment,
and its API existing in the pinned 0.18.3 does not show that any workload used it. Amended: `S-tas` is either
described as a complete placement policy — topology levels, request mode, quota and queue policy all frozen —
or it is separated from the controlled scoring comparison entirely. Without that, a difference could come from
admission ordering rather than from packing. The first campaign compares the two scoring configurations only,
and TAS gets its own page.

## Peak reserved does not control what it was supposed to

The original offers peak reserved devices as the control that stops an arm from winning by admitting less.

It does not. The traces `[8, 8, 8]` and `[8, 2, 2]` share a peak of 8 and describe very different occupancy, and
a peak conceals which workloads were admitted and whether the large requests starved.

**Amended:** reserved devices, outstanding demand, and the identities of placed workloads are recorded **at
every matched census step**; peak reserved survives only as a summary of that series. If releases occur their
sequence is registered in advance.

And the premise was wrong in a second way: refusing admission does not make correctly measured stranding zero,
because the refused requests are still outstanding demand. Refusal only hides the metric if the collector drops
those requests from the pending set — which is the demand-ledger failure above, not a property of the metric.

## Corrections to the original's own claims

- **Heterogeneous nodes and more than two workers are not prerequisites.** The original says the study needs
  more than the two workers in `hack/kind-config.yaml`. Two identical two-GPU nodes each holding one device
  already block a two-device request with two devices free. A larger, uneven layout is useful for richer shapes;
  it is not what makes the phenomenon possible, and the original overstated it.
- **The threshold paragraph reasons wrongly.** It declines to choose a reporting threshold now on the ground
  that choosing one while knowing which policy the literature favours is what pre-registration prevents. It is
  not: pre-registration prevents *adapting* a threshold to observed outcomes. A descriptive study may publish
  every valid result with no reporting threshold at all, which is what this campaign does. Any later decision
  threshold is frozen before comparative outcomes are inspected, with qualification data kept separate.
- **Three repetitions need a better reason.** "A deterministic scheduler" is not one — ties and asynchronous
  processing vary placement. Three stands as a bounded campaign, registered as such.
- **An identical result across arms remains an admissible null result**, provided the treatment verification
  above passed independently.

## Two citations in the original had already drifted

Both were correct when written and are not corrected in place, because the original is published as written:

| the original cites | what is there now |
|---|---|
| `cmd/gpu-simulator/main.go:141` for registering a fixed number of always-healthy fake devices | `:141` is now a comment about `ListAndWatch` and `GracefulStop`; the claim lives at `:26` (the package comment) and `:170`–`:180` (`fakeDevices`, `Health: pluginapi.Healthy`) |
| `2026-08-02-queuelab-latency-decomposition-design.md:216` for "fragmentation beyond a two-unit pool" being out of scope | that sentence is at `:220`; the "Out of scope" heading is at `:214` and `:216` is the first line of its body |

The three remaining citations hold: `cmd/queuelabrun/qualify.go:98` on `AllocatableGPU` being the advertised
total rather than the free amount, `config/device-plugin/daemonset.yaml:59` on `FAKE_GPU_COUNT` being `"1"`, and
`hack/kind-config.yaml:6`–`7` on the two workers.

## What must exist before the first run, amended

The original's three prerequisites stand — a kind cluster under its own name, per-node counts verified by
reading `allocatable` back from each node rather than trusting the manifest, and a scheduler configuration
whose effect is confirmed before anything else. `kubeadmConfigPatches` and `KubeSchedulerConfiguration` still
have no precedent in this repository. Added to them:

1. **Qualification fixtures**, each with its expected verdict registered here rather than derived later:
   positive stranding, schedulable demand that must not count as stranded, aggregate shortage, empty demand, and
   a deliberately missing observation that must invalidate rather than pass.
2. **The frozen protocol**: node capacities, the submission and release sequence, census barriers and timeouts,
   and the expected census and submission counts alongside the nine-run matrix.
3. **Treatment verification independent of the main result**, so that three identical arms can be reported as a
   null result instead of read as a broken instrument — or as a working one.

The study is implemented in its own tool rather than inside `internal/queuelab`, for the reason the original
gives: an `Arm` there must answer `PolicyVariant`, `StateFor`, `ContractFor`, `DutyFor` and `AssertCardinality`,
and a placement study has no victim, no termination contract and no duty, so four of those five would carry
values that mean nothing and would then flow into the record schema and its refusals.
