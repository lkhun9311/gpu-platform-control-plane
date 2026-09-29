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

A cell may be discarded **only** for a reason on the list above, by its registered name. A reason worded after
the attempt was seen is a reason chosen from the outcome, however diligent the wording sounds, so the
invalidation reason is a registered enumeration rather than free text and the tool refuses any other value.

An invalid attempt is retained with its reason and is **not** required to carry the full census series.
Demanding a complete series from a failed attempt would push a run operator towards supplying the readings that
are missing rather than recording that the attempt failed — and every attempt is published precisely so a
failed one can be seen to have failed.

Two structural rules follow, and they are checked across the campaign rather than per cell: an attempt that
stands may not be followed by another attempt at the same cell (running a cell again after it produced a figure
is choosing between figures), and a cell whose last attempt is invalid has no replacement left, which ends the
campaign with the attempt history published in place of a comparison.

**The census series accounts for the submissions by identity.** At step `k` the reading must account for exactly
`s1..sk`, across its placed, blocked and unsatisfiable names together. A reading that simply leaves a submission
out is internally consistent and balances, which is why it is compared against the frozen sequence rather than
checked for self-consistency. This campaign registers **no releases**; a released submission would legitimately
appear in none of the three, so if a release is ever registered this check must be **amended on a dated page**
rather than loosened to accommodate it.

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

## The sibling study, which this page should have cited from the start

`2026-09-24-node-level-gpu-fragmentation.md` is a separate registration in this repository, implemented by
`hack/fragmentation.sh`, and **neither page mentioned the other** until this section was added. That is a gap in
this page, not in that one: it was registered first.

The two ask different questions at different layers, and the distinction is worth stating precisely because the
shapes look identical.

| | the sibling study | this campaign |
|---|---|---|
| the headroom distribution | **placed by hand** — holders pinned by `kubernetes.io/hostname` to build `(2,0)` versus `(1,1)` | **left to the scheduler**, which is the thing under test |
| the scheduler configuration | held fixed | it *is* the treatment |
| the question | can the control plane tell quota shortage, aggregate shortage and distribution apart? | does supplying a GPU-aware configuration reduce stranding? |

The sibling's arm `F` — free counts `(1,1)`, `maxF = 1`, a request of 2 — is the same shape as this campaign's
discriminating step `s3`. The difference is the direction of the arrow: that study **constructs** the shape to
see what the control plane says about it, and this one asks **whether the shape arises** under one scheduler
configuration and not the other. Its "what is deliberately not being measured" list does not exclude a scoring
comparison; it simply does not reach one. So this campaign occupies a gap rather than re-treading ground, and a
reader who wants the classification vocabulary — quota-short, aggregate-short, distribution — should read that
page first.

**They must not share a cluster.** The sibling runs against `kind-platform` in namespace `frag` and computes
headroom **across every namespace**, deliberately, so that a pod outside `frag` cannot distort its vector
unseen. This campaign runs against a cluster of its own. Registered consequence: a cell is invalid if any
submission of this campaign exists outside its own cluster, and no cell may be run on a cluster where the
sibling's fixture is installed. Neither is a hypothetical — the sibling's own `CONTEXT` is an environment
variable, so pointing it at this campaign's cluster is one word.

## The qualification probe needs a holder, because this layout ties

Measured 2026-09-29, and recorded here because it constrains the procedure rather than any value the tool
reads. On the registered layout, an empty cluster **cannot** qualify the treatment:

```
$ check-treatment -strategy=MostAllocated -nodes=worker:2:0,worker2:1:0,worker3:1:0 -request=1
the fixture cannot qualify anything: MostAllocated: nodes "worker2" and "worker3" both reach
allocation fraction (0+1)/1 after placement, so MostAllocated scores them equally and the
winner would come from a tiebreak this fixture does not model
```

Both one-device nodes reach `1/1`. A fixture on which the strategies agree — or on which one of them cannot
name a single winner — qualifies nothing, whatever the probe then does.

So the qualification probe is preceded by a **holder** pinned to one one-device node. The candidates become
`worker` with 2 free and `worker2` with 1 free, and the two strategies disagree: `MostAllocated` prefers
`worker2` at `1/1`, `LeastAllocated` prefers `worker` at `1/2`. Measured in all four directions — the
treatment's own strategy accepts the placement it prefers and refuses the other one's, and the same holds with
the strategies swapped.

The holder and the probe are **deleted before the registered sequence begins**. They are qualification
evidence, which this page excludes from the comparison, and leaving them in place would change the cluster the
sequence starts from — the layout `verify-layout` just checked would no longer be the layout `s1` meets.

This was found by getting it wrong: the first cell run reused registered submission `s1` as the probe and fed
the empty layout, and `check-treatment` refused the fixture. The cell was recorded as invalid for
`missing_arm_qualification_evidence` — a registered reason — and retained. That is the apparatus working: a
performer that had judged its own attempt would have counted it.

## Performing and judging are separate programs, on purpose

`hack/stranded-cell.sh` performs a cell: it submits the registered sequence, waits for each step to bind or be
refused, reads the cluster live at each census point, and writes `record.json`. It **judges nothing**.
`cmd/strandedrun`'s `check-cell` and `check-campaign` judge, and they are the only thing that decides whether an
attempt may be counted.

The separation is not tidiness. A performer that could also decide its own attempt was valid would be judging
its own work, and the judgement would stop being re-reachable: as it stands, the verdict follows from
`record.json` alone, so it can be re-reached months later from the same bytes with no cluster. The script prints
`check-cell`'s verdict as a convenience and does not act on it.

Everything the script needs is **read from** `hack/stranded-protocol.yaml` — the submission sequence and its
requests, the layout, the scheduler image, the per-step timeout, the expected census count. A value changed in
the protocol changes the run; a value changed in the script changes nothing, because there is none to change.

**The waits carry no `|| true`, and that is a registered requirement rather than a style.** The sibling
fragmentation study's own notes record a 120-second wait for a Job that could never start, swallowed by exactly
that idiom, whose summary still read *"R: 5/5 reached scheduled"*. A step that neither binds nor produces a
scheduling refusal within the registered timeout invalidates the cell, by that registered name, and the script
has no way to spell a reason the protocol does not list.

Submissions run `registry.k8s.io/pause:3.10`. A container whose entrypoint exits holds no devices, so a census
would read zero while the record said a pod had been submitted — measured the hard way earlier in this study,
when a distroless image died with `StartError` and the census was correctly reporting nothing.

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

Added 2026-09-29, and the most important one to disclose because it *looks* like a cell: `stranded-cell.sh` was
run end to end as `S-gpu-most` repetition 1 attempt 1, and `check-cell` reported **stands, with 6 censuses**.
The qualification probe held `stranded-worker3`, landed on `stranded-worker2`, and `check-treatment` reported
applied; the sequence then bound `s1` and `s2` to the one-device nodes and `s3` — the two-device request — to
the intact `stranded-worker`, with `s4`, `s5` and `s6` refused for want of capacity.

**It is not cell 1 of the campaign and no figure of it enters the comparison.** It was a rehearsal of the
instrument on a cluster that has been created and reconfigured repeatedly today, its arm was never re-verified
from a fresh `render-cluster`, and the reference arm's cluster does not exist yet. Recorded here so that a
reader who finds `record.json` in this session's history cannot mistake a rehearsal for a result — which is
exactly the mistake this section exists to prevent, and it is the first piece of evidence in the list that would
have been tempting to keep.

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
