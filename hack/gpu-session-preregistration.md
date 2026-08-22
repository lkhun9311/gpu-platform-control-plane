# What the real-GPU session will measure, decided before it runs

This is written before any GPU exists, and that is the point. Everything below — the quantity, the baseline,
the resolution the instrument has, and the result that would refute the model — is fixed here so that the
session cannot be read backwards into whatever it happens to produce.

The lab has retracted two claims this month. Both were retracted after the numbers were in hand, which is the
most expensive moment to discover you were measuring the wrong thing.

## The one quantity

**How long the quota owner waits between Kueue admitting it and its Pod running**, in the arm where the
borrower honours SIGTERM.

Not the borrower's discarded seconds. Those are dose-determined — the protocol fixes the victim's service and
preempts it partway in, so the magnitude is arithmetic the trace already did — and they describe a loss the
platform never promised anybody anything about. The owner's wait is what a reclaim promise is judged on.

## The baseline, already measured

**This section was wrong once, and the correction is the reason to trust the rest of the page.** It fixed the
baseline at "2.690 s mean, 2.534-2.792 s, spread 258 ms, 8 observations" — a table assembled at a shell from
four records that were then deleted, sitting beside machine-generated figures in the same document that
reproduce to the digit. The value 2.534 appears in no record that exists. It was the last hand-typed number
in this lab and it was the one an entire session is defined against.

It is emitted by the harness now, and the whole point is that the reader can run the command:

    $ queuelabrun -compare 'ex/e17-*-A-honor-e17?h?.json' -mode baseline
    ===== BASELINE (arm A-honor) =====
    under A-honor the quota owner was running 2.604 s after admission, over 6 runs spanning 2 dose
    regime(s) and 2 node(s), with a spread of 1488 ms against a worst-run floor of 3.514 s. A session
    differencing against this must add its own floor to that one; the difference of two independently
    measured means carries both of their errors
      ownerWait mean=2.604 min=1.937 max=3.425 spread=1488ms n=6
      runs=e17gh1,e17gh2,e17wh1,e17wh2,e17sh1,e17sh2
      doses=grace-bounded,self-completing
      nodes=platform-worker,platform-worker2
      device: NOT OBSERVED -- this baseline was taken where no run established that a device did work, so
      it is a control-plane figure and not a statement about hardware

**The spread is 1488 ms, not the 258 ms the deleted table claimed.** That figure was not merely
unreproducible, it was optimistic — two runs per cell could not show the variation six runs show, which is
exactly what a reviewer said two-run means would hide. It grew again when the workload was replaced: the
same six cells under a workload that reaches for a device before falling back to the CPU spread half a
second wider than under one that never tried, which is the kind of movement a two-run mean cannot report at
all.

**These twelve runs interleave all three factors**, so no line above carries a confounding warning. The set
before them blocked the regimes, and the one before that also varied the cluster's occupancy alongside the
node — the second worker could not be held exclusively until the platform's own serving workload was scaled
away, so a node result and an occupancy result were the same number. This set holds the occupancy fixed on
both workers for its whole duration and alternates arm, regime and node.

### The same interval, read off the components' own clocks

The record carries the owner's wait twice: as a difference of watch ARRIVAL times, and as a difference of the
two components' own transition stamps — Kueue's Admitted and the kubelet's Ready. The pair bounds different
error sources, and it earned its place immediately:

| run | node | arrival | component stamp |
|---|---|---|---|
| e17gi1 | worker | 31.477 s | **32.000 s** |
| e17gi2 | worker | 31.487 s | **32.000 s** |
| e17wi1 | worker2 | 30.913 s | **31.000 s** |
| e17wi2 | worker2 | 30.944 s | **31.000 s** |

The arrival figure scatters across 574 ms and the stamp figure does not move at all WITHIN a node. That
scatter is watch delivery jitter, and an earlier version of this page was about to attribute a smaller
version of it to the machine.

This set also shows the stamp's other half in one table. The two nodes differ by about half a second in
arrivals, and that half second happens to straddle a second boundary — so the stamps differ by a full one.
A node comparison run on the stamp figure would have read a 550 ms difference as 1000 ms, which is why the
one below uses arrivals.

The stamp figure is quantised to the second, so it flips between 2 and 3 where the true value sits near a
boundary — which the honouring runs do. What it cannot carry is watch lag; what it carries instead is a
second of truncation at each end plus the offset between two components' clocks, constant for a pair of
machines and cancelling in an arm difference taken on ONE node. **It does not cancel between nodes**, so the
node comparison below uses the arrival figure only.

### It does not move with the dose, or with the node

Both are checked by the harness rather than asserted here:

    $ queuelabrun -compare 'ex/e17-grace-bounded-A-honor-e17gh?.json,\
        ex/e17-self-completing-A-honor-*.json' -mode dose
    the owner's wait under A-honor moves 0.420 s across 2 levels of dose, INSIDE the 6.717 s floor

    $ queuelabrun -compare 'ex/e17-grace-bounded-A-honor-*.json' -mode node
    the owner's wait under A-honor moves 0.481 s across 2 levels of node, INSIDE the 6.686 s floor
      platform-worker  n=2 ownerWait mean=2.905
      platform-worker2 n=2 ownerWait mean=2.424

The ignoring arm agrees on the node (0.553 s against a 6.409 s floor) and disagrees on the dose, which is the
control: there the owner's wait IS the dose-dependent quantity, and the same check reports 12.003 s and says
EXCEEDS. A check that can only ever return "no response" establishes nothing.

Neither is a demonstration of independence. What they support is that any response is smaller than about six
seconds, which is what a baseline needs and is a weaker claim.

## What the session adds, and where the interval actually ends

The same protocol with a workload that touches the device. The restoration figure becomes

    baseline  +  driver and runtime cleanup after container exit
              +  device plugin re-advertisement of a real card

and the SESSION'S RESULT IS THAT SUM MINUS THE BASELINE.

**An earlier draft of this page added a third term — the replacement container's CUDA initialisation — and
that was wrong in a way worth spelling out, because it would have manufactured a false result rather than a
wrong one.** The interval ends at `EventPodReady`, which is `PodRunning` plus the Pod's `Ready` condition
(`internal/queuelab/provenance.go`). `BuildJob` renders a container with no readiness probe and no startup
probe (`internal/controller/mltrainingjob_controller.go`), so `Ready` fires when the container STARTS.
Initialisation happens inside the running process, after the endpoint. The first two terms land inside the
interval; the third — plausibly the largest of the three — lands structurally outside it.

Left uncorrected, the most likely session outcome was: measured term small, reported as "not resolved", and
this page had already blessed that null as a finding worth having. It would have been a sentence about a
device manufactured by an endpoint that never contained the term it named.

So the sum has two terms, and the "not resolved" outcome below means something narrower and true: the
device's SCHEDULING-side return is fast relative to the control plane's. It says nothing about
initialisation.

**If the session wants the initialisation term, it cannot simply add a readiness probe and subtract.** A
probe gated on device readiness changes what `Ready` means, and a difference between two intervals is only a
measurement when both ends are alike. Adding one requires re-taking the baseline under the same probe, on
both arms, and saying so — at which point the number below is superseded rather than differenced.

## The resolution this instrument has, stated in advance

Every interval here is a difference of watch ARRIVAL times, and the records bound how far those lag the
events they describe. Across the eight baseline runs the per-run floor ran **1.000 – 2.364 s**.

So:

- a GPU-specific term **larger than about 2.4 s** will be resolved
- a term **smaller than that will not be**, and the session must report "not resolved" rather than a number

That second outcome is a legitimate result and is pre-registered as one. It would say the device's own return
is fast relative to the control plane's, which is worth knowing and is not a failed experiment. What it must
not become is a small number quoted as if it were measured — that is precisely the retraction this lab has
already made once, when 0.94 s of residual was published as the control plane's cost while the instrument's
own spread ran to 2.4 s.

If a finer figure is wanted, the instrument has to change before the session, not after. Kubernetes Events on
this cluster carry no `eventTime` — the kubelet writes the legacy `firstTimestamp`, quantised to the second —
so the API surface offers nothing better. A node-side clock would, at the cost of a dependency the lab does
not currently have and that does not survive a managed cluster.

## Three limits that survive, and what each would actually take

These are named here rather than fixed, because the fix for each is either impossible with what is recorded
or costs more than it buys before the session.

**The instrument cannot be sharpened from the existing ledger.** The device hold reproduces to 8-17 ms within
a cell and is judged against a floor of about 3 s. That is a precision figure against a conservative accuracy
bound, not evidence the bound is 200x too large -- and nothing recorded can calibrate the difference. The
hold's endpoints come from two watches, so its error is their differential delivery lag, and there is no
interval in this system with independently known truth that spans the same two streams. The one same-watch
interval with a declared truth, the owner's Pod Ready to its Succeeded against a 60 s service, tests the Pod
watch against itself and identifies nothing about the Workload watch.

Reading the hold on the components' own clocks does not close it either, and the data says so: across the
twelve records the two readings differ by 36 to 512 ms, a range the second-truncation of two stamps explains
entirely. The lag is inside it and cannot be separated. What that second reading DOES buy is a check -- if
the two ever describe different intervals, neither is publishable -- and that check now exists rather than
being promised in a comment.

Closing this needs a new causal timing reference: one API transaction producing two independently watched
objects with a common reference instant, or trace timestamps at the watch boundary. Both are new instruments,
not more runs.

**Two runs per cell is not fixed by more runs.** Under an uncalibrated instrument, repetition improves an
estimate of repeatability and does not turn a sub-floor result into an accuracy-established one. What IS
worth changing is the allocation: the current set is four runs in each grace-bounded arm and two in each
self-completing one, which is weakest exactly where the model's kink is tested. Three complete arm x dose
blocks, with worker and ordering balanced across them and one block held out of any parameter fitting, would
extract more from the same twelve runs -- and would give the model an out-of-sample test it does not have.

**Cluster diversity cannot be had here at all.** kind runs three containers on one host: the two workers share
a kernel and a clock, so the inter-component offset the two-clock design reasons about is zero by
construction and untested exactly where it will matter. A second cluster on the same machine is a
contamination check, not diversity. The real answer is a second host -- which the GPU session on EKS is, with
a different kernel, a different clock and real hardware. This limit is therefore answered BY the session
rather than before it, and the session's first result should be read with that in mind: the first time these
figures are taken anywhere but one laptop is the first time the offset assumption is exercised.

## What would refute the model

The model this lab arrived at is that a preempted workload holds its device for
`min(remaining service, termination grace period)`, and that the owner's wait tracks it.

Each condition names the command that decides it, because a refutation nobody can evaluate is not one. Two
of these were unfalsifiable as first written — "stops tracking" had no arithmetic anywhere in the repository
and no tolerance, and "stop differing" asked the harness to assert an equality its own rules forbid it to
assert.

1. **The honouring arm's restoration stops being node- or dose-independent.**

       queuelabrun -compare '<session records>' -mode dose
       queuelabrun -compare '<session records>' -mode node

   Refuted when either reports the wait moving by more than the summed floor. The baseline's usefulness
   rests on it, and a real workload's shutdown may not be prompt the way a Python loop's is: a training step
   with a kernel in flight cannot stop the way the termination canary's probe stopped in 1.2 seconds.

2. **The ignoring arm's owner wait stops matching `min(remaining service, grace)`.**

       queuelabrun -compare '<session records>' -mode model

   Refuted when it prints REFUTED — that is, when either regime's residual falls outside the floor, after
   the honouring arm's own restoration cost is subtracted. The two regimes put the victim on opposite sides
   of the grace period, so one rule has to predict a 30-second hold in one and a 20-second hold in the other;
   a model fitted to either alone misses the other by ten seconds. If the device is returned at some later
   driver event rather than at container exit, this is where it shows.

3. **The arm difference falls below the session's own floor.**

       queuelabrun -compare '<session records>'

   Stated this way rather than as "the arms stop differing", because the harness is built to refuse the
   second: an unresolved difference is not a demonstrated equality, and every other page here says so. What
   IS checkable is that a difference resolved at 28.1 s against a 5.387 s floor in the baseline stops
   clearing the session's floor. If driver cleanup dominates and both arms converge, the termination
   contract stops mattering and the 120-second cap loses the justification it was given — the single most
   useful thing this session could discover.

Any of the three is a better outcome than a confirmation, because all three change what the platform should
do and a confirmation changes nothing.

## What makes the session count at all

`validity.deviceEvidence` must read `device-work-observed`.

Every record this lab has produced reads `device-not-observed`, derived rather than asserted and refused when
blank. A GPU run that comes back with the same value has bought nothing: it is a CPU run that cost money, and
the harness will say so in the field a consumer classifies on rather than in a footnote. The observer that
moves it has to be something the workload cannot write to — a Pod reporting its own device use is evidence of
nothing, for the same reason a Pod carrying a `quota-exempt` annotation is not evidence of exemption.

The observer's CONTRACT now exists, in `internal/queuelab/device.go`, and the path from an observation to the
axis is derived rather than hardcoded — so a session plugs a scraper in instead of editing a boolean. What it
requires, per Pod attempt and across the interval being measured:

| requirement | why it refuses without it |
|---|---|
| an admissible observer (DCGM exporter, or a node-local nvidia-smi poll) | the workload is not a witness: a Pod reporting its own device use is a claim by the party the check exists to constrain |
| the observer's own build identity | "DCGM said so" is not provenance if nobody can say which DCGM |
| the physical device UUID, and only one of them | an observation that cannot say which card it watched cannot establish that the card this Pod held did anything |
| attribution by Pod UID, not name | the UID is what the API guarantees unique across time; a name is free for reuse the moment its Pod is deleted, and an observer labelling by name is read against whatever holds that name when the mapping is resolved |
| coverage of the whole interval, no gap over 2 s | a gap that size can hide an entire preemption |
| at least two samples showing the card working | one non-zero reading is what a driver reports while another process initialises; an allocated idle card is the exact state this axis exists to distinguish |

**What does not exist yet is the scraper** that fills it in — the DaemonSet, the endpoint, and the collector
step that samples it across a run. That is the session's first task, before any measurement, and no figure
taken before it exists may be published as a GPU result.

Every refusal above is under test today, on a cluster with no GPU. That is the half that can be validated
without hardware, and it is the half that decides whether the hardware buys anything.
