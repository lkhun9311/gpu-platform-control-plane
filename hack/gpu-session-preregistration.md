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

Eight observations, on a three-node kind cluster with a fake `nvidia.com/gpu` device plugin: two dose
regimes, two runs per arm, across two separate sessions on different binaries with independently re-taken
termination canaries.

| | |
|---|---|
| range | 2.534 – 2.792 s |
| mean | 2.690 s |
| spread | 258 ms |
| dose varies across these by | 2× (20 s vs 40 s of remaining service) |

**It does not move with the dose**, and that is checked by the harness rather than asserted here:

    $ queuelabrun -compare 'ex/e14-*-A-honor-*.json' -dose-sensitivity
    ===== DOSE SENSITIVITY (arm A-honor) =====
    the owner's wait under A-honor moves 0.122 s across 2 dose regimes, INSIDE the 1.876 s floor. The
    harness cannot see it responding to the dose -- which is not proof that it does not, and is the
    condition a baseline needs: a quantity the dose determines could not be differenced against a session
    whose workload has a different service time
      grace-bounded    n=2 ownerWait mean=2.759 over 2 restored runs=e14gh1,e14gh2
      self-completing  n=2 ownerWait mean=2.637 over 2 restored runs=e14sh1,e14sh2

A check that can only ever return "no response" establishes nothing, so the other arm is the control:

    $ queuelabrun -compare 'ex/e14-*-A-ignore-*.json' -dose-sensitivity
    the owner's wait under A-ignore moves 11.170 s across 2 dose regimes, which EXCEEDS the 2.364 s floor:
    this quantity responds to the dose and cannot serve as a baseline for a session whose workload has a
    different service time

That contrast is the whole argument. Under the ignoring arm the owner's wait IS the dose-dependent quantity
-- whatever the victim had left, bounded by grace -- and the check sees it move by eleven seconds. Under the
honouring arm the victim stops when told to, what remains is the platform's own mechanics, and the check
cannot see the dose in it at all. The tool holds the arm fixed and refuses to pool the two, because pooling
them would measure the arm difference and report it as a dose response.

This is a statement about what the harness can SEE, not a proof of independence. The honest reading is that
any dose response is smaller than 1.876 seconds, which is the condition a baseline needs and is not the same
claim as there being none.

It decomposes, in principle, into the kubelet releasing the device allocation, the device plugin
re-advertising, the scheduler binding, and the container starting. **This harness cannot separate those**,
and the pre-registration does not pretend it will: see the resolution section.

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
   IS checkable is that a difference resolved at 28.1 s against a 1.938 s floor in the baseline stops
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
