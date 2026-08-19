# The first admissible queuelab result

The runner has existed for a long time without producing a number its own gates would accept. Every earlier
attempt was refused, and the refusals were the point: a run that cannot prove it held its worker exclusively,
qualified its environment, and observed continuously must not publish a figure. This is the first run where
all four claims held.

    verdict: admissible-under-implemented-gates
    failures: []

Four runs, two per arm, on a three-node kind cluster with a fake `nvidia.com/gpu` device plugin.

## What the two arms differ in

One knob: whether the victim's workload honours SIGTERM. Everything else — the trace, the dose, the queue
policy, the cohort, the worker — is identical, and `sameMechanism` refuses to adopt a fixture that differs in
any field that defines the experiment.

The trace is three rows. `a1` and `a2-borrow` belong to tenant A, which borrows beyond its nominal quota;
`b1-owner` belongs to tenant B and arrives at t=44s to reclaim what it owns. Kueue preempts `a2-borrow`
under `reclaimWithinCohort`.

## Result

| arm | run | discarded GPU-s | unattributed occupancy | owner's readyLatency | preemption ineffective |
|---|---|---|---|---|---|
| A-honor | r001 | 41.0 | 0.0 | 2.234s | false |
| A-honor | r003 | 40.9 | 0.0 | 2.336s | false |
| A-ignore | r002 | **0.0** | 59.3 | **19.373s** | **true** |
| A-ignore | r004 | **0.0** | 59.3 | **19.385s** | **true** |

Both arms reproduce to within 0.1 GPU-seconds and 12 milliseconds across their two runs.

## What is measured and what is arithmetic

The protocol fixes the victim's service at 60 seconds and preempts it 40 seconds in
(`cmd/queuelabrun/spine.go`). So before any run happened, the trace already determined that a responsive
victim would discard about 40 seconds and that an unresponsive one would hold the device about 20 seconds
longer. **Both headline magnitudes are constructed, not discovered.**

Subtracting what the protocol set leaves what the cluster actually contributed:

| quantity | protocol says | observed | residual |
|---|---|---|---|
| A-honor discarded | 40.0 | 40.993, 40.888 | **+0.993, +0.888** |
| A-ignore owner wait | 20.0 | 19.373, 19.385 | **−0.627, −0.615** |

I called the first residual the control plane's own cost — about 0.94 seconds from Kueue deciding to preempt
to the container being gone. **That was wrong, and the harness now says so itself.**

Every time in this ledger is `col.elapsed()`: the collector's clock when a watch event ARRIVED, not when the
event happened. So each interval carries however far behind those arrivals are, and that had never been
bounded. The record now bounds it, by capturing the kubelet's own `finishedAt` beside the collector's
observation time:

| run | discarded | skew min | skew median | skew max |
|---|---|---|---|---|
| res1 | 41.014 | 945.7 ms | 2113.0 ms | 2113.0 ms |
| res2 | 41.232 | 430.1 ms | 2389.2 ms | 2389.2 ms |

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

What survives is what the arms differ in, which is a whole order of magnitude larger than the lag: 41 seconds
against 0, and 19.4 seconds against 2.2. Those differences are real. The sub-second residual inside them is
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
  rate. `measurement.workload.deviceUseEstablished` is false in all four records, with the reason beside it.
  These are GPU-*seconds of reservation*, not of computation.
- **Two runs per arm is two runs per arm.** The reproduction is encouraging and is not a distribution. No
  variance is claimed and none should be quoted, and no arm EFFECT is established: four executions show
  repeatability, not a causal difference. Falsifying the arm difference would need enough randomised,
  interleaved replications for the intervals to overlap — or for one honouring run to show no discarded work,
  or one ignoring run to terminate promptly.
- **The magnitudes are the trace's.** 41 and 19.4 are the dose and the remaining service, to within a second.
- **The residuals are inside the instrument's own uncertainty.** The gap between the kubelet's stamp and the
  collector's arrival runs 0.4 to 2.4 seconds against residuals under one, and the kubelet's field is
  quantised to the second. Nothing sub-second here is resolved, and this harness cannot be made to resolve it
  by running more of the same.
- **One trace, one dose here.** `self-completing`, where an ignoring victim finishes its own service. The
  `grace-bounded` regime has since been run and gives the OPPOSITE answer for the same arm — see
  [queuelab-grace-boundary.md](queuelab-grace-boundary.md). That comparison, not this page's magnitudes, is
  what the experiment turned out to be for.

## Reproducing

    go build -o queuelabrun ./cmd/queuelabrun
    ./queuelabrun -inspect-worker -worker platform-worker        # must print FREE
    ./queuelabrun -preview -arm A-honor -runid pv1 -worker platform-worker -out ./ex/preview.json
    ./queuelabrun -arm A-honor  -runid r001 -worker platform-worker -out ./ex/run-A-honor-r001.json
    ./queuelabrun -arm A-ignore -runid r002 -worker platform-worker -out ./ex/run-A-ignore-r002.json

The preview runs and checks exactly as a real run does and withholds both the ledger and the numbers, so it
is the right way to find out whether the cluster is in a state that can produce evidence before spending a
run on it. Its record can never be admissible.

Each record carries the verdict, the claims that produced it, the ownership window, the qualification and the
full ledger, so the figures above can be re-derived from the file rather than taken from this page.
