# Whether graceful termination can defeat a quota guarantee

The reclaim experiment had been run in one regime, and the write-up said so: `self-completing`, where the
preempted victim has less service left than the termination grace period. The other regime existed in the
code — `graceBoundedDoseSec = 20` — and had never been run.

It turns out to be the more interesting half, because the two regimes give **opposite** answers for the same
arm.

## The question

A tenant borrows beyond its nominal quota. The owner returns and Kueue preempts the borrower. The borrower's
workload ignores SIGTERM.

Does the owner get its capacity back, and when?

The answer depends on one comparison the platform never states out loud: **is the victim's remaining service
longer than the Pod's termination grace period?**

## Result

Twelve runs at record schema 16, on two worker nodes with the cluster's occupancy held fixed, arm and regime
and node all interleaved. Grace period is the Kubernetes default, 30 seconds — verified per node by a
termination canary rather than assumed.

**The quantity below is the DEVICE HOLD**: from the moment Kueue admitted the owner to the moment the
victim's Pod reached a terminal phase. That is the interval this page is about — how long the borrower keeps
the device after the platform has committed it to someone else — and it is not the same as the owner's wait,
which adds scheduling and container start on top. An earlier version of this page reported the wait.

| dose regime | remaining service | arm | runs | device hold | within-cell spread |
|---|---|---|---|---|---|
| self-completing | 18.9 s (**under** grace) | A-ignore | 2 | **18.496, 18.512 s** | 16 ms |
| grace-bounded | 38.8 s (**over** grace) | A-ignore | 4 | **30.044 – 30.062 s** | **17 ms** |
| either | — | A-honor | 6 | 0.036 – 0.050 s | 14 ms |

    $ queuelabrun -compare 'ex/e16-self-completing-*.json,ex/e16-grace-bounded-*-e16g??.json' -mode model
    grace-bounded    binds on termination grace  predicted=30.000 observed=30.059 residual=+0.059 INSIDE
    self-completing  binds on remaining service  predicted=18.883 observed=18.504 residual=-0.378 INSIDE
    CONTRAST self-completing -> grace-bounded: predicted=11.117 observed=11.555 residual=+0.438 INSIDE

**The grace-bounded hold is the grace period to within seventeen milliseconds, four times, on two machines.**
The honouring arm holds the device for forty-five milliseconds, which is what makes the other figure the
borrower's rather than the scheduler's: nothing is subtracted from anything.

Note that "remaining service" above is 18.9 and 38.8 rather than the declared 20 and 40. The schedule gates
the owner on a two-second poll, so every run overran its declared dose by about 1.2 seconds. The prediction
uses what the run achieved; the page used to use what it declared.

The ledger shows the mechanism directly:

    self-completing, ignoring   owner admitted  ->  victim stopped   18.5 s  (its own service ended)
    grace-bounded,  ignoring    owner admitted  ->  victim stopped   30.1 s  (the grace period, exactly)
    either regime,  honouring   owner admitted  ->  victim stopped   0.045 s (it stopped when asked)

## What it says

**An unresponsive workload defeats reclaim completely while its remaining service fits inside the grace
period.** It finishes its work — nothing is discarded — and the owner waits the whole of that remaining
service. The reconstruction derives this as `preemptionIneffective` by pairing the preemption decision with
the attempt that was supposed to end and checking whether it did — a field on the reconstruction, not on the
record, so a reader checks it by replaying the ledger the record carries rather than by reading a key out of
the file.

**The grace period is the cap on how long it can do that.** Once remaining service exceeds grace, the victim
is SIGKILLed at exactly the grace boundary. The owner waits 30 seconds rather than however long the victim
had left, and the victim's work is discarded.

So `terminationGracePeriodSeconds` is not only a shutdown courtesy. On a platform that promises quota owners
their capacity back, **it is the bound on how badly that promise can be broken**, and it is set per Pod — by
the tenant being preempted.

That is worth stating plainly because it inverts the usual reading. A longer grace period is normally the
considerate setting; here it is the one that lets a borrower hold a device longer against its owner's claim.

## Why this experiment is resolvable and the previous residual was not

Everything above is 19 to 51 seconds, and the two regimes differ by 20 to 30 seconds. The harness's own
observation uncertainty — the gap between the kubelet's stamp and the collector's arrival — runs 0.4 to 2.4
seconds and is recorded in every one of these records.

The differences here are an order of magnitude above that. The sub-second residual the earlier write-up
tried to quote was not, which is why it was withdrawn. Same instrument, different question, and only the
second one is answerable with it.

## The attack this implies, and the fix

If grace is the bound and the tenant sets it, the obvious question is what stops a tenant setting it to an
hour. Nothing did. Measured directly on the cluster, deleting a running device-holder and timing how long it
kept the device:

| terminationGracePeriodSeconds | device held after deletion |
|---|---|
| 30 (the default) | **32 s** |
| 300 | **301 s** |

A borrower could therefore keep a device for as long as it liked against the owner that had already reclaimed
it, and every part of that is a supported Kubernetes API a tenant is allowed to use.

The admission guard now caps it at **120 seconds** for Pods that request a device, in namespaces where the
quota is enforced. Re-attacked after deploying:

    terminationGracePeriodSeconds: 300  ->  admission webhook "vgpupod.kb.io" denied the request:
                                            terminationGracePeriodSeconds is 300 ... the cap here is 120
    terminationGracePeriodSeconds: 90   ->  admitted, Pod Running

120 rather than the 30-second default because the cap has to leave room for the workloads this platform is
for. A training step that checkpoints on SIGTERM needs longer than 30 seconds, and refusing that would push
tenants to ignore SIGTERM instead — which is the behaviour the measurement above shows produces the worst
outcome for the quota owner. The number is a policy choice, stated rather than derived: there is nothing to
derive it from until real workloads say how long their checkpoints take.

## Found while testing the cap

Kueue admitted a Workload whose Pods can never be created. The Job carrying `terminationGracePeriodSeconds:
300` had its Workload admitted and holding quota, while the webhook rejected every Pod the Job controller
tried to make — `FailedCreate ... x5`. The quota read `used=2 admitted=2 pending=1` with one of those two
admissions belonging to a Job that could never run.

A rejected Pod does not release the Kueue reservation, so a tenant submitting Jobs that fail admission can
hold quota indefinitely without running anything. That is a second, different denial-of-service on the same
budget and it is **not fixed here**; it is recorded because it was found by running the test rather than by
reading the code.

## What this does not say

- **Nothing about GPUs.** Pure Python arithmetic against a fake device plugin. These are seconds of
  RESERVATION; `deviceUseEstablished` is false in every record.
- **The magnitudes are still partly the trace's.** 51.5 is 20 s of service plus 30 s of grace plus about 1.5;
  19.4 is the 20 s that remained. What is NOT the trace's is the discontinuity itself — that the same arm
  produces 0 discarded on one side of the boundary and 51.5 on the other.
- **Two runs per cell.** Repeatable, not a distribution.
- **One grace period, and the boundary cannot be swept with this harness.** 30 seconds, the default.

  `TerminationContractTrace` refuses any dose whose remaining service does not match the declared regime:
  `self-completing` errors if remaining is at or above the grace period, `grace-bounded` errors if it is
  below. The guard is right to exist — it stops a run silently sitting in a regime other than the one it
  claims — but it also writes `terminationGraceSec = 30` into the harness as an AXIOM and refuses every
  configuration that would test it. Remaining service of 28 or 32 seconds cannot be run under either regime.

  So what is established is that a victim with 20 s left finishes on its own and one with 40 s left is
  stopped at 30 s — the latter observed twice, `Preempted t=24s -> AttemptStopped t=54s`. What is NOT
  established is that the switch happens at exactly 30 rather than at 27 or 33. An earlier draft of this page
  said the boundary "was not swept", which understates it: it cannot be, without changing the guard.

  The sweep was done outside the lab instead, on plain Pods where the parameter is free, and the model it
  implied holds: [grace-holds-the-device.md](grace-holds-the-device.md).

## Reproducing

    ./queuelabrun -arm A-ignore -dose self-completing -runid s1 -worker platform-worker -out ./ex/s1.json
    ./queuelabrun -arm A-ignore -dose grace-bounded   -runid g1 -worker platform-worker -out ./ex/g1.json

Every record carries its regime, its verdict, the claims behind it, and the observation resolution beside the
numbers.
