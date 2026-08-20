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

    $ queuelabrun -compare 'ex/e15-self-completing-A-honor-*.json,ex/e15-grace-bounded-A-honor-e15gh?.json' \
        -mode baseline
    ===== BASELINE (arm A-honor) =====
    under A-honor the quota owner was running 2.304 s after admission, over 4 runs spanning 2 dose
    regime(s) and 1 node(s), with a spread of 931 ms against a worst-run floor of 3.634 s. A session
    differencing against this must add its own floor to that one; the difference of two independently
    measured means carries both of their errors
      ownerWait mean=2.304 min=1.688 max=2.619 spread=931ms n=4
      runs=e15gh1,e15gh2,e15sh1,e15sh2
      doses=grace-bounded,self-completing
      nodes=platform-worker
      NOT INTERLEAVED: the dose regimes did not alternate in time
      device: NOT OBSERVED -- this baseline was taken where no run established that a device did work, so
      it is a control-plane figure and not a statement about hardware

**The spread is 931 ms, not the 258 ms the deleted table claimed.** That figure was not merely
unreproducible, it was optimistic — two runs per cell could not show the variation four runs show, which is
exactly what a reviewer said two-run means would hide. One of the four (`e15gh2`, 1.688 s) sits most of a
second below the other three.

**And the regimes were run in blocks, so this baseline is not interleaved.** The runner took both
self-completing runs before both grace-bounded ones, so anything that drifted over that half hour moves with
the regime. The tool says so rather than leaving it to be noticed. A session that wants a tighter baseline
should interleave the regimes and take more than two runs per cell; this page states what the current one is
rather than what it should be.

### It does not move with the dose, or with the node

Both are checked by the harness rather than asserted here:

    $ queuelabrun -compare 'ex/e15-grace-bounded-A-honor-e15gh?.json,\
        ex/e15-self-completing-A-honor-*.json' -mode dose
    the owner's wait under A-honor moves 0.302 s across 2 levels of dose, INSIDE the 6.686 s floor

    $ queuelabrun -compare 'ex/e15-grace-bounded-A-honor-*.json' -mode node
    the owner's wait under A-honor moves 0.105 s across 2 levels of node, INSIDE the 6.443 s floor
      platform-worker  n=2 ownerWait mean=2.153
      platform-worker2 n=2 ownerWait mean=2.259
    NOT INTERLEAVED: the node levels did not alternate in time

A check that can only ever return "no response" establishes nothing, so the other arm is the control — and
under A-ignore the same check reports 11.167 s across the dose levels against a 5.410 s floor, which it calls a response. Under the
ignoring arm the owner's wait IS the dose-dependent quantity; under the honouring arm what remains is the
platform's own mechanics, and neither factor shows in it.

The node check is qualified twice over and both qualifications are in the output. The levels are blocked in
time, because the second worker had to be freed before it could be used at all — the platform's own serving
workload held one of its two devices, and the run refused to measure there rather than measure on a node it
could not hold exclusively. And "cannot see a response" is not "there is none": what it supports is that any
node response is smaller than 6.443 s, which is what a baseline needs and is a weaker claim than independence.

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
   IS checkable is that a difference resolved at 28.6 s against a 5.252 s floor in the baseline stops
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

That observer does not exist yet. Building it is the first task of the session, before any measurement, and
no figure taken before it exists may be published as a GPU result.
