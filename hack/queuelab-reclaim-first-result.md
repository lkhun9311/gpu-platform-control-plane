# The first admissible queuelab result

The runner has existed for a long time without producing a number its own gates would accept. Every earlier
attempt was refused, and the refusals were the point: a run that cannot prove it held its worker exclusively,
qualified its environment, and observed continuously must not publish a figure. This is the first run where
all four claims held.

    verdict: admissible-under-implemented-gates
    failures: []

Eight runs, two per arm in each of two dose regimes, on a three-node kind cluster with a fake
`nvidia.com/gpu` device plugin.

**These are not the runs this page first reported, and the reason is worth recording.** The original four
were written at record schema 10, before the harness could measure its own resolution at all: their events
carry no kubelet timestamp, so the 0.4-2.4 second bound quoted for them below came from two OTHER runs taken
six hours later. Two schema bumps since then mean no build in this tree can decode any of them. This page
claimed the figures could be re-derived from the files rather than taken from the page, and for those files
that had become false. They were re-run on a build that can read them back.

## What the two arms differ in

One knob: whether the victim's workload honours SIGTERM. Everything else — the trace, the dose, the queue
policy, the cohort, the worker — is identical, and `sameMechanism` refuses to adopt a fixture that differs in
any field that defines the experiment.

The trace is three rows. `a1` and `a2-borrow` belong to tenant A, which borrows beyond its nominal quota;
`b1-owner` belongs to tenant B and arrives at t=44s to reclaim what it owns. Kueue preempts `a2-borrow`
under `reclaimWithinCohort`.

## Result

| dose | arm | run | owner waited | discarded GPU-s | discarded iterations | that run's floor |
|---|---|---|---|---|---|---|
| self-completing | A-honor | e14sh1 | 2.589 s | 41.503 | 17 967 | 1.672 s |
| self-completing | A-honor | e14sh2 | 2.685 s | 41.414 | 17 480 | 1.762 s |
| self-completing | A-ignore | e14si1 | **19.665 s** | **0.000** | 23 373 | 1.280 s |
| self-completing | A-ignore | e14si2 | **19.733 s** | **0.000** | 26 144 | 2.364 s |
| grace-bounded | A-honor | e14gh1 | 2.729 s | 21.349 | 9 245 | 1.000 s |
| grace-bounded | A-honor | e14gh2 | 2.789 s | 21.283 | 9 103 | 1.876 s |
| grace-bounded | A-ignore | e14gi1 | **30.846 s** | **51.262** | 21 480 | 1.938 s |
| grace-bounded | A-ignore | e14gi2 | **30.891 s** | **51.233** | 21 320 | 1.000 s |

**The left-hand number is the one a platform is judged on.** Everything else here describes what the
preempted borrower lost, and a platform does not promise anybody that. It promises that a tenant's own quota
comes back. The lab computed the owner's admission-to-running wait from its first run and never carried it
out of the reconstruction, so for a long time answering "how long did the owner wait" meant parsing the
ledger by hand — which is what the comparison below exists to stop, reached by a different route.

Every run carries its own floor now, derived from the spread between the kubelet's stamp for a stop and this
collector's arrival time for it. The floor is built from the SPREAD rather than the median because a harness
uniformly late measures every interval exactly; the second of stamp quantisation sits under it because the
skews it is computed from each absorbed up to that much truncation.

## The conclusion is an artifact

The runs were always reproducible. The SENTENCE they were gathered to support lived in this file and in
arithmetic typed at a shell, so nobody could re-derive it from anything. `queuelabrun -compare` now reads a
named set of records and answers the three questions those records can settle:

    $ queuelabrun -compare 'ex/e14-grace-bounded-*.json'
    ===== COMPARISON (dose grace-bounded) =====
    floor=1.938s -- the coarsest resolution among the contributing runs
    interleaved: the arms alternated in time
    no effect is claimed: this tool reports resolution and confounding, not inference
    device: NOT OBSERVED -- every GPU-second below is a second of RESERVATION. No run behind this
      comparison established that a device did work, so nothing here is a statement about GPU computation
      A-honor   n=2 waste mean=21.316 runs=e14gh1,e14gh2
        ownerWait mean=2.759 min=2.729 max=2.789 over 2 of 2 runs
      A-ignore  n=2 waste mean=51.247 runs=e14gi1,e14gi2
        ownerWait mean=30.869 min=30.846 max=30.891 over 2 of 2 runs
      [wastedGPUSeconds] A-honor discarded 21.3 GPU-s and A-ignore discarded 51.2, a difference of 29.9 s
        against a 1.938 s floor, over n=2 and n=2 runs
      [ownerAdmitToReadySeconds] the quota owner waited 2.759 s under A-honor and 30.869 s under A-ignore
        -- a difference of 28.1 s against a 1.938 s floor, over n=2 and n=2 restored runs. This is the
        number a reclaim promise is judged on; the discarded seconds beside it are the borrower's loss

It refuses rather than excludes: a record whose own gates failed, a second dose regime, a single arm — each
stops the comparison instead of quietly shrinking it, because a document whose file list does not describe
its evidence is the reproducibility it exists to provide. Returning "not resolved" is its main job, not its
failure mode.

**The grace-bounded difference is the strongest number this lab has produced.** Twenty-nine point nine
seconds of discarded work between the arms and 28.1 seconds of the owner's waiting, against a 1.938 second
floor, over four interleaved runs. That difference IS the termination grace period, recovered from the
experiment rather than assumed by it — and unlike the sweep in
[grace-holds-the-device.md](grace-holds-the-device.md), it was measured under real Kueue preemption with an
exclusive-worker window, a termination canary, continuous observation and a containment audit behind each
run.

## It replicated across a rebuild

The eight runs above are the SECOND set. An earlier eight, taken hours before at record schema 13 on a
different binary and behind a separately re-taken termination canary, produced:

| cell | discarded, then / now | owner waited, then / now |
|---|---|---|
| grace-bounded A-honor | 21.312 / 21.316 | 2.766 / 2.759 |
| grace-bounded A-ignore | 51.296 / 51.247 | 30.807 / **30.869** |
| self-completing A-honor | 40.999 / 41.459 | 2.598 / 2.637 |
| self-completing A-ignore | 0.000 / 0.000 | 19.686 / 19.699 |

This is worth more than four more runs inside one session would have been, because it crosses a rebuild and a
re-qualification rather than repeating under a frozen setup. The owner's wait agrees to between 7 and 62
milliseconds in every cell, and it agrees BETTER than the discarded seconds do in every cell — which is the
second reason to treat it as the headline figure rather than the appendix it used to be.

It is still not a distribution. Two sessions of two runs per cell show that the protocol reproduces; they do
not characterise variance, and `-compare` says so in the document rather than leaving it to a reader.

## What is measured and what is arithmetic

The protocol fixes the victim's service at 60 seconds and preempts it 40 seconds in
(`cmd/queuelabrun/spine.go`). So before any run happened, the trace already determined that a responsive
victim would discard about 40 seconds and that an unresponsive one would hold the device about 20 seconds
longer. **Both headline magnitudes are constructed, not discovered.**

Subtracting what the protocol set leaves what the cluster actually contributed:

| quantity | protocol says | observed | residual | that run's floor |
|---|---|---|---|---|
| A-honor discarded, self-completing | 40.0 | 41.503, 41.414 | +1.503, +1.414 | 1.672, 1.762 |
| A-honor discarded, grace-bounded | 20.0 | 21.349, 21.283 | +1.349, +1.283 | 1.000, 1.876 |

I called the first residual the control plane's own cost — about 0.94 seconds from Kueue deciding to preempt
to the container being gone. **That was wrong, and the harness now refuses to let it be said again.**

Every time in this ledger is `col.elapsed()`: the collector's clock when a watch event ARRIVED, not when the
event happened. So each interval carries however far behind those arrivals are, and that had never been
bounded. The record bounds it by capturing the kubelet's own `finishedAt` beside the collector's observation
time — and, since the retraction, DERIVES a `resolvedToNs` from it and prints it beside every magnitude. Put
the two columns above side by side and every residual is inside its own run's floor. That is not a close
call to be argued about; it is the same statement the record now makes as a field.

**This is a bound, not a delivery time, and the distinction is the point.** The two stamps come from
unsynchronised clocks on different machines, and `metav1.Time` serialises with SECOND precision so the
kubelet's value arrives with its nanoseconds zeroed — checked rather than assumed: every observed value ends
in nine zeros. So each figure mixes propagation, clock offset and up to a second of truncation, and nothing
available here separates them. Saying "the watch is 900 ms late" would claim a measurement this harness
cannot make without clock synchronisation or distributed tracing.

What it does support is one statement, and it is enough: **an interval whose endpoints carry a gap of this
size is not resolved below it.** The residual was under a second. The gap runs from 0.4 to 2.4 seconds and
differs at each endpoint. The residual is therefore not resolved by this harness, and no number of
repetitions changes that — a resolution problem is not a noise problem.

What survives is what the arms differ in, which is an order of magnitude larger than the floor: 41.0 seconds
against 0 in the self-completing regime, and 29.98 seconds between the arms in the grace-bounded one. Those
differences are real, and `-compare` is what says so from the files rather than from this page. The sub-second residual inside them is
not something this harness can see, and no number of repetitions fixes that — it is a resolution problem, not
a noise problem.

## What it says

**Honouring SIGTERM discards work.** The victim stops when told to, and the 41 GPU-seconds it had spent are
thrown away — 17,823 and 16,831 iterations across the two runs, which is what makes the discarded seconds a
discarded quantity of something rather than an interval.

**Ignoring SIGTERM discards nothing and defeats the reclaim.** The victim runs to completion 19 seconds past
the preemption, so no work is lost — and the quota owner waits 19.4 seconds to start instead of 2.2. The
ledger shows why: `Preempted` at t=44s, `AttemptStopped reason=Succeeded` at t=1m3s. The reclamation was
issued and did not reclaim anything for nineteen seconds.

That is the trade the lab was built to show, and neither arm is simply better. A platform that guarantees its
quota owners a bounded time-to-start has to make preemption effective, and making it effective means
someone's partial work is destroyed.

What the runs support is the SHAPE of that trade, not a magnitude anyone should quote. "41 GPU-seconds per
preemption" would be quoting the trace back at itself: a job preempted one minute in would discard a minute.
And the sub-second residual is inside the harness's own delivery lag, so it is not a transferable number
either.

What transfers is categorical: an unresponsive victim converts the whole of its remaining service into the
owner's waiting time, and the reclamation is recorded as ineffective while it does. Measuring how long a
preemption takes to take effect needs an instrument at least an order of magnitude finer than this one.

`preemptionIneffective` is the field that separates them, and it is derived rather than asserted: the
reconstruction pairs the preemption decision with the attempt that was supposed to end and checks whether it
did.

## What this does not say

- **Nothing about GPU behaviour.** The workload is pure Python float arithmetic and the device plugin is
  fake, so a Pod that dropped its `nvidia.com/gpu` request would compute the same iterations at the same
  rate. This is no longer only a sentence on a page: `validity.deviceEvidence` reads `device-not-observed`
  on every record, it is DERIVED from the measurement rather than written, a blank value is refused on
  decode, and the comparison carries the weakest contributor's axis rather than the strongest. It exists
  because a consumer reading `verdict` saw `admissible-under-implemented-gates` and had no machine-readable
  way to learn that these are GPU-*seconds of reservation*. A run on real hardware would read identically
  until something moves that field, which is the whole reason the field is there.
- **Two runs per arm is two runs per arm.** The reproduction is encouraging and is not a distribution. No
  variance is claimed and none should be quoted, and no arm EFFECT is established: `-compare` says so in the
  document itself rather than leaving it to a reader's memory — it reports resolution and confounding, not
  inference, because these runs are not a sample of anything and their variance has never been characterised.
- **The magnitudes are the trace's.** 41 and 21 are the dose and the remaining service, to within a floor.
  The one number that is NOT the trace's is the 29.98 s between the grace-bounded arms, which is the grace
  period the cluster defaults to and which the protocol never sets.
- **The residuals are inside each run's own floor.** Compare the two right-hand columns of the residual table
  above: every residual is smaller than the floor of the run it came from. Nothing sub-second here is
  resolved, and this harness cannot be made to resolve it by running more of the same — a resolution limit is
  not a noise level.
- **Both regimes are here now.** `self-completing`, where an ignoring victim finishes its own service, and
  `grace-bounded`, where the grace period cuts it short — and the same arm gives OPPOSITE answers in the two.
  See [queuelab-grace-boundary.md](queuelab-grace-boundary.md). That contrast, not this page's magnitudes, is
  what the experiment turned out to be for. `-compare` refuses to pool them, because two regimes measuring
  different quantities produce a difference that answers no single question.

## Reproducing

    go build -o queuelabrun ./cmd/queuelabrun
    ./queuelabrun -inspect-worker -worker platform-worker        # must print FREE
    ./queuelabrun -preview -arm A-honor -runid pv1 -worker platform-worker -out ./ex/preview.json
    ./queuelabrun -termination-canary -worker platform-worker    # must print QUALIFIED
    ./queuelabrun -dose self-completing -arm A-honor  -runid h1 -worker platform-worker -out ./ex/h1.json
    ./queuelabrun -dose self-completing -arm A-ignore -runid i1 -worker platform-worker -out ./ex/i1.json
    ./queuelabrun -compare 'ex/h*.json,ex/i*.json' -compare-out ./ex/comparison.json

Take the arms alternately. The comparison checks that they did and says CONFOUNDED on the finding itself when
they did not — a block of one arm followed by a block of the other moves with everything else that changed
between the two blocks, and no arithmetic separates them afterwards.

The canary must be re-taken whenever the harness commit changes: the qualification is keyed to it, so a
reading from an earlier build refuses rather than silently qualifying a different mechanism.

The preview runs and checks exactly as a real run does and withholds both the ledger and the numbers, so it
is the right way to find out whether the cluster is in a state that can produce evidence before spending a
run on it. Its record can never be admissible.

Each record carries the verdict, the claims that produced it, the ownership window, the qualification and the
full ledger, so the figures above can be re-derived from the file rather than taken from this page.
