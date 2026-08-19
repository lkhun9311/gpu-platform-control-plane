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

Nine runs. Grace period is the Kubernetes default, 30 seconds.

| dose regime | remaining service | arm | runs | discarded GPU-s | owner waited | preemption effective |
|---|---|---|---|---|---|---|
| self-completing | 20 s (**under** grace) | A-ignore | 2 | **0** | 19.37, 19.38 s | **no** |
| grace-bounded | 40 s (**over** grace) | A-ignore | 2 | **51.5, 51.6** | 30.68, 30.65 s | **yes** |
| self-completing | — | A-honor | 4 | 40.9–41.2 | 2.21–3.04 s | yes |
| grace-bounded | — | A-honor | 1 | 21.5 | 2.72 s | yes |

The ledger shows the mechanism directly. Preemption is issued and the victim stops:

    self-completing, ignoring   Preempted t=44s  ->  AttemptStopped t=1m3s    (19s: its own service ended)
    grace-bounded,  ignoring    Preempted t=24s  ->  AttemptStopped t=54s     (30s: the grace period, exactly)
    either regime,  honouring   Preempted t=T    ->  AttemptStopped t=T       (within the same second)

## What it says

**An unresponsive workload defeats reclaim completely while its remaining service fits inside the grace
period.** It finishes its work — nothing is discarded — and the owner waits the whole of that remaining
service. `preemptionIneffective` is true: the reclamation was issued and reclaimed nothing.

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

## What this does not say

- **Nothing about GPUs.** Pure Python arithmetic against a fake device plugin. These are seconds of
  RESERVATION; `deviceUseEstablished` is false in every record.
- **The magnitudes are still partly the trace's.** 51.5 is 20 s of service plus 30 s of grace plus about 1.5;
  19.4 is the 20 s that remained. What is NOT the trace's is the discontinuity itself — that the same arm
  produces 0 discarded on one side of the boundary and 51.5 on the other.
- **Two runs per cell.** Repeatable, not a distribution.
- **One grace period.** 30 seconds, the default. The boundary was not swept; it was crossed once from each
  side.

## Reproducing

    ./queuelabrun -arm A-ignore -dose self-completing -runid s1 -worker platform-worker -out ./ex/s1.json
    ./queuelabrun -arm A-ignore -dose grace-bounded   -runid g1 -worker platform-worker -out ./ex/g1.json

Every record carries its regime, its verdict, the claims behind it, and the observation resolution beside the
numbers.
