# The stranded-GPU campaign's frozen protocol — pre-registered

**Written 2026-09-29, before any comparative run exists.** The instrument is built and demonstrated; nothing has
been compared. This page freezes the things that a campaign can otherwise drift on — how many cells, what is
submitted, when a census counts, what invalidates a cell and what explicitly does not — and it does so while the
comparative numbers are still unseen.

It supersedes one section of the original registration and leaves the rest standing. The original
(`2026-09-23-what-a-stranded-gpu-is-and-what-kind-can-say-about-it.md`) registered **"One submission sequence,
three arms, three repetitions each — nine runs"**. Two of those three arms are gone: the amendment
(`2026-09-28-what-the-stranded-gpu-registration-got-wrong.md`) deferred `S-tas` to its own page, and its
2026-09-29 correction established that the original's `S-least` is not the untouched reference it was offered
as. The campaign is therefore **two arms, three repetitions, six cells**, and this page states that as the
registered matrix rather than leaving a reader to subtract.

## The research question, stated so the answer can be no

**Does supplying a GPU-aware packing configuration to the scheduler reduce stranded devices, on a fixed
submission sequence against a fixed heterogeneous layout, compared with the scheduler an operator gets without
supplying anything?**

Three things about that sentence are deliberate.

It compares against **what an operator actually has**, not against a second deliberate configuration. That is
the amendment's chosen interpretation, and its price is stated in the next section.

It names **stranded devices** as the outcome, with peak reserved beside it as the control the original
registered: an arm that stranded nothing by admitting less has not won.

It admits **no** as an answer. An identical figure in both arms, with the treatment independently qualified as
having applied, is a null result this page will publish as one.

## What the whole-configuration comparison can and cannot attribute

The treatment is the mount, the resource list and `MostAllocated` **together**. A difference between the arms is
therefore attributable to *supplying that configuration*, and **not** to the scoring type alone.

This is not a limitation to be apologised for; it is the question an operator asks. But the page must not later
be read as evidence about `MostAllocated`, so: any claim narrower than "supplying this configuration" requires a
second campaign whose arms are two deliberate configurations, and the GPU-aware `LeastAllocated` profile the
instrument still builds exists for that and for instrument controls, not for this campaign.

## The layout, frozen and measured rather than assumed

| what | value | how it is held |
|---|---|---|
| workers | 3 | `render-cluster` emits one `JoinConfiguration` patch per worker |
| advertised devices | 2, 1, 1 | read back from each node's `allocatable` by `verify-layout`, never trusted from the manifest |
| control-plane devices | none | it runs no device plugin and must advertise nothing |
| node image | `kindest/node:v1.31.0` | pinned per node; this host also has 1.35.8 installed, so an unpinned image could move between cells and masquerade as the treatment |
| scheduler image | `registry.k8s.io/kube-scheduler-amd64:v1.31.0` | whatever the pinned node image ships, recorded per cell and required identical across cells |

Measured on the standing cluster on 2026-09-29: `stranded-worker` advertises 2, `stranded-worker2` and
`stranded-worker3` advertise 1 each, `stranded-control-plane` advertises none, all four Ready, the scheduler at
restart count 0, reserved devices 0 and no unbound demand. That is the state a cell begins from.

Four devices total is small on purpose. The phenomenon needs a node that can hold a large request and a way for
that node to be eaten by small ones; it does not need a large cluster, and the amendment already corrected the
original's claim that it did.

## The submission sequence, identical in every cell

Six submissions, each a single pod with an integer device request, submitted in this order and never reordered
per arm. A census is taken after every submission settles, so six submissions and six censuses — the counts this
campaign expects are **6 submission attempts and 6 accepted censuses per cell**, and they are expected as
*ledger membership per step*, not as totals at the end.

| step | request | what it is for | the disposition it may legitimately end in |
|---|---|---|---|
| `s1` | 1 | fills one slot, arm-dependently | `bound` |
| `s2` | 1 | fills a second slot; after this the arms' free shapes can already differ | `bound` |
| `s3` | **2** | **the discriminating request** — it fits only if a two-device node survived the first two | `bound`, or `queued-unadmitted` with a stranding witness |
| `s4` | 1 | resumes small demand against whatever remains | `bound` or `queued-unadmitted` |
| `s5` | 1 | drives the cluster towards saturation | `bound` or `queued-unadmitted` |
| `s6` | 2 | runs past saturation on purpose | `queued-unadmitted`, and classified as shortage rather than stranding once the total free falls below 2 |

`s3` is where the question lives. On this layout a packing configuration that scores post-placement allocation
fractions prefers to fill the one-device nodes completely, because `1/1` is a higher fraction than `1/2` — so it
can leave the two-device node intact for `s3`. An unconfigured scheduler has no reason to protect it. The
instrument's own scoring model predicts this for the treatment; it deliberately predicts **nothing** for the
reference, for the reasons the amendment's 2026-09-29 correction measured.

Total demand is eight devices against four advertised, which is more than the cluster can hold. That is
registered, not accidental: every cell must exercise the separation between **stranded** (`max(f_i) < q` with a
witness, and `q ≤ Σf_i`) and **shortage** (`q > Σf_i`, or a request larger than the largest node). A protocol
that stopped at saturation would never test the classification that the amendment insists on.

## Census barriers, and why a boolean is not one

A census is accepted only when every submission so far carries an **observed** disposition. The zero value
`Unobserved` invalidates a census; that is already enforced by `Census.Validate()`.

The barrier this page adds is that settledness must be **observed rather than asserted**. The instrument's
`take-census` currently takes a `-settled` flag, and a flag is the run operator's claim, not an observation: a
submission omitted from the ledger entirely is not caught by the reservation balance, because a ledger missing a
row balances perfectly well. So each cell is bound to this file's submission list, and a census is refused
unless the ledger's membership at step `k` is exactly `s1..sk` — identity by identity, not six at the end.

Each step also retains, as evidence rather than as a claim: the API's response to the submission, the pod's
`nodeName` if it bound, and the `FailedScheduling` events with their reasons if it did not. "Pending for a
non-GPU reason" is a judgement about those events; without them retained it is an opinion.

Timeouts are per step: a submission that has neither bound nor produced a scheduling refusal within 120 seconds
invalidates the cell. It does not get a longer wait, because a wait extended until the outcome looks right is
the outcome selecting the method.

## The matrix, the stopping rule, and the replacements

| | `S-default` | `S-gpu-most` |
|---|---|---|
| repetition 1 | cell 1 | cell 4 |
| repetition 2 | cell 2 | cell 5 |
| repetition 3 | cell 3 | cell 6 |

- **Six cells.** Three repetitions stands as a bounded campaign, as the amendment restated — not because the
  scheduler is deterministic, which it is not.
- **One replacement per invalid cell**, and **at most twelve attempts** across the whole campaign. A second
  invalidation of the same cell ends the campaign, and the attempt history is published in place of the
  comparison.
- **Every attempt is retained and published**, including the invalid ones and the reason each was invalidated.
  Retaking until the numbers agree selects on the outcome; publishing the retakes is what makes it visible that
  this did not happen.
- **No reporting threshold.** Every valid cell is published with its figures. What size of difference would be
  worth acting on is not decided here and not decided after the arms are compared.

### What invalidates a cell

1. A submission whose disposition was not observed, or a census whose ledger membership is not exactly `s1..sk`.
2. A pod pending for a reason other than GPU capacity at the moment a census is taken, judged from retained
   `FailedScheduling` events.
3. A scheduler restart during the cell, or a scheduler image that differs from any other cell's.
4. Missing arm qualification evidence — for `S-gpu-most`, `check-treatment` not returning applied; for
   `S-default`, `--config` present in the scheduler's process arguments, or a supplied profile file present.
5. Advertised capacity that is not 2, 1, 1 at the start of the cell, read back per node by name.
6. A render directory whose previous contents were not removed by the renderer itself.
7. A step that neither bound nor refused within 120 seconds.

### What does not invalidate a cell

- **A tie.** Two nodes scoring equally and the choice falling either way is the scheduler this study measures.
- **An identical outcome across arms**, or across repetitions. That is a result.
- **A stranding figure of zero.** The instrument has already reported zero on a free cluster where the author
  expected three; the expectation was wrong, not the instrument.
- **A shortage classification.** Steps `s5` and `s6` are expected to produce one.

## Enforcement, so that this page is not decorative

Every value above is also written, once, in a machine-readable file — `hack/stranded-protocol.yaml` — and the
tool refuses to run a cell whose arm, layout, node image, submission sequence or expected counts disagree with
it. `cmd/strandedrun/protocol.go` reads the YAML rather than restating it, so the page and the code cannot drift
into two statements of one fact: every derived quantity this page states in prose — six cells, twelve attempts,
six submissions and six censuses — is **recomputed** from the file rather than typed into Go, and a protocol
whose arithmetic contradicts itself does not load.

`take-census` takes `-protocol` and `-step-number` together, and refuses a census whose ledger is not exactly
the protocol's first `k` submissions by identity, order and request. That is the check `-settled` cannot make:
`-settled` is the run operator's assertion that bindings had resolved, and a ledger missing a row balances the
reservation check perfectly well.

That refusal must itself be shown to discriminate: the protocol file is mutated — a request changed, a step
removed, the layout altered — and the tool must refuse each time, with the refusal naming the disagreement. A
gate whose failure has never been observed is not a gate, and this repository has produced three false greens
from exactly that.

## Limits of generalization, stated before the numbers

- **Fake devices.** The plugin advertises a count; nothing computes. Nothing here measures GPU performance,
  sharing, or memory pressure, and a stranded device in this study is an *unschedulable* device.
- **One layout, one sequence, one host.** Four devices across three workers on a single machine. A different
  shape can reverse the sign of a packing policy's benefit, and this campaign says nothing about which shapes.
- **The reference's internals are unread.** The default plugin set and weights of the v1.31 scheduler were not
  enumerated, because `k8s.io/kubernetes` is not available in this repository and `/configz` is unreachable
  without a credential this study has not registered. The reference is qualified behaviourally, not by
  configuration readback.
- **No topology-aware scheduling**, no Kueue admission, no quotas. The comparison is placement only.
- **Six cells is not a sample.** No inferential statistic is computed from six cells, and none will be reported.

## Qualification evidence is excluded from the comparison

The checks run on the standing cluster on 2026-09-28 and 2026-09-29 — `verify-layout` refusing `0,0,0` by node
name and accepting `2,1,1`, `check-treatment` returning applied for `MostAllocated` and refusing the same
observation as `LeastAllocated`, and `take-census` reporting 0 stranded on a free cluster and 3 after the
two-device node was occupied — are **qualification evidence**. They were taken by hand, before this protocol
existed, on a cluster that has been created and reconfigured repeatedly.

Added 2026-09-29, after the qualifier was built: `qualify-arm` was run against the standing cluster's own
readings — the scheduler's arguments, its image and restart count from the pod's status, and whether a profile
volume is mounted. The same evidence **qualified** the cluster as `S-gpu-most` and was **refused** when claimed
as `S-default`, naming the `--config` it carries; and with `check-treatment`'s verdict omitted the treatment was
refused too, on the ground that an absent reading means nobody looked rather than no.

That last refusal is why the readings are three-valued rather than booleans. The reference arm *passes* on the
absence of a profile file, so a `flag.Bool` an operator never set would have read as evidence of absence and
satisfied the check it exists to make.

It also corrects this page's own qualification table above, which said the effective configuration is
unreadable without a credential. That is true and beside the point: what the check needs is what was
**supplied**, and the API states that in plain text — no credential beyond read access, and no entering the
node. `/configz` would say what the scheduler *loaded*, which is a different and unnecessary question.

None of them is a cell. None contributes a figure to the comparison. They are cited as evidence that the
instrument discriminates, which is the thing the amendment required to be established independently of the
result, and they are disclosed here so that no reader later finds a number in the repository's history and
wonders whether it was quietly counted.

## What this page refuses

It refuses to name an expected winner. The treatment's scoring preference is predictable and is predicted; the
reference's is not, and the difference between them is the measurement.

It refuses to choose a threshold, to add a seventh cell, or to extend a timeout — each of those is a decision
that would be made while looking at the outcome, and this page exists to make such a decision visibly a change
to a registration rather than an adjustment to a run.
