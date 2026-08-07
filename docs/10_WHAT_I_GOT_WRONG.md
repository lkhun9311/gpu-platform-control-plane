# What I Got Wrong

> **Status (2026-08-07).** This document is a record, not a design. Everything in it is a mistake I made in
> this repository and what I changed because of it. The events are reconstructable from the git history,
> the evidence logs under `hack/`, and the specs under `docs/superpowers/specs/`.

On 2026-08-02 I published a measurement of Kueue quota-reclaim preemption. It was wrong. I found it the same
day, retracted it, and then spent the following days discovering that the thing I had built to replace it
was also wrong, in a different way, twice. This is that list.

I am writing it down because the corrections are the only part of this project I would defend without
qualification, and because every one of them came from the same root cause: **I recorded evidence and then
did not read it.**

---

## 1. I published a number whose refutation was already in my own ledger

The claim was that switching `reclaimWithinCohort` from `Never` to `Any` admitted the quota owner about
120 ms after submission, at a cost of roughly 39 GPU-seconds of the borrower's discarded work.

The ledger I built for that experiment recorded, for every attempt, the reason it stopped. The borrower's
reason was `Succeeded`. My accounting never looked at it. The rule I had written was, in effect:

> a preemption decision happened, and later an attempt stopped, therefore the preemption destroyed that work

That is not a measurement. It is an inference from adjacency, and the field that would have refuted it was
sitting in the same row. The arithmetic is embarrassing in hindsight: the borrower became Ready at t≈3 s and
ran a 40-second workload, so a stop at t≈43 s is exactly what finishing looks like.

**What changed:** waste is never charged without an observed *failed* terminal phase. A `Succeeded` stop is
reported as unattributed occupancy plus an explicit "the platform decided to reclaim and the workload did
not comply" flag. No terminal phase at all is `AttributionUnknown`, not zero.

## 2. I assumed a container stops when you send it SIGTERM

The lab's workload was `sh -c "sleep N"`, so `sleep` became PID 1. **A container's PID 1 does not get the
default SIGTERM handler.** Without an explicit trap it ignores the signal entirely and dies only to SIGKILL
when the grace period expires.

I did not reason my way to this. I ran it:

| workload command | outcome |
|---|---|
| `trap 'exit 143' TERM; sleep N & wait` | terminated in **1 s**, `phase=Failed`, exit code 143 |
| `sleep N` | survived the full 30 s grace, **SIGKILL at 34 s** |

So nothing in that experiment was ever preempted. The workloads ran to completion and were re-executed from
scratch, which is where the discarded GPU-seconds actually came from — real waste, opposite mechanism.

**What changed:** the termination contract became an experimental variable instead of an assumption. The
honoring and ignoring commands are now two arms of the design, not an accident of how I wrote a fixture.

**The generalizable part:** a platform cannot preempt a workload that has no termination contract. That is
true of every real training job that does not trap SIGTERM, not just my fixture.

## 3. I fixed the measurement and left the experiment confounded

Having corrected the accounting, I re-ran and got a clean-looking result. Adversarial review then pointed at
the trace itself.

The fixture is three jobs: the borrower meant to be reclaimed, the quota owner whose admission is the
endpoint, and `a1`, a co-tenant that is supposed to hold its own unit throughout. **I had given all three
the same duration.** So:

```
42.607s  a1        stopped   <- the co-tenant released a GPU on its own
42.638s  a2-borrow stopped   <- the alleged victim, 31 ms later
43.550s  b1-owner  Ready
```

31 milliseconds. Nothing in that run can say whether the owner ran because the victim was reclaimed or
because `a1` happened to finish. The endpoint the whole experiment rests on was not attributable, and a
perfectly instrumented run of a confounded trace is still a confounded run.

**What changed:** `a1` now outlives the entire owner-restoration window, so the victim's release is the only
release that can place the owner. `a1` is still running at the horizon and is reported as unfinished; that
is expected and the report says so rather than treating it as a defect.

## 4. I stated a dose I never delivered

The design says the owner is submitted 40 seconds after the borrower becomes Ready. The executable derived
that interval by subtracting two trace offsets that were never meant to encode it, and produced **49
seconds**. Nobody typed 49 anywhere. It fell out of arithmetic on numbers that meant something else.

**What changed:** the dose is a stated constant that the schedule builder validates, and both the trace and
the schedule now refuse inputs that could reproduce the original confound. It is still not *delivered*
correctly — the delay is measured from a two-second poll of a derived phase rather than authoritative Pod
Ready, and the realized dose is not recorded — and the runner says so rather than pretending otherwise.

## 5. I designed three arms and shipped two

The experiment compares an honoring victim, an ignoring victim, and a no-reclaim reference. The runner
called a helper that always rendered the SIGTERM-ignoring command. **The honoring arm did not exist in the
executable.** It existed in the design document, in the tests of the pure layer, and nowhere a run could
reach it.

**What changed:** the arm is a closed enum with a per-row termination contract, and there is a test that
fails against any implementation that applies one contract arm-wide.

## 6. I wrote an evidence document containing a command I never ran

This one is not about the queuelab, and I found it while repairing the public record.

`hack/m6-kind-e2e.md` — my only public evidence document — presented this as a transcript:

```
$ kubectl get resourcequota -A | grep gpuquota
# (nothing — the GPU ceiling is enforced only by Kueue, not double-counted)
```

That command appears in neither the script nor the captured log. And the log it sat beside came from a
cluster the script had *reused*: line 3 reads `cluster platform already exists; reusing it`. That log
contains 27 `exceeded quota: gpuquota-tenant-a-quota` events — flatly contradicting the claim.

I re-ran the whole thing on a cluster created from scratch. **The claim was true**: zero `exceeded quota`
events, `kubectl get resourcequota -A` returns `No resources found`. The conclusion had been right and the
evidence had been contaminated, which is the worse of the two failures to have, because the conclusion
survived by luck.

The re-run also falsified a smaller claim I had made with more confidence than I had earned. The document
said Kueue "preempted the borrowed `tenant-a` job" and showed `a2` going Pending. The fresh run preempted
`a1`. Both are correct — quota inside a ClusterQueue is fungible, so **there is no such object as "the
borrowed job."** Reading a specific victim as designed behaviour attributes an identity to fungible quota.
It is the same error as §3, in a different subsystem, and I made it while writing up a run rather than while
designing one.

**What changed:** the evidence log is committed rather than gitignored, the check is captured by the script
instead of asserted in prose, and the document quotes only what the log contains.

---

## What I would do differently

**Record-and-never-read is the failure mode, not any individual bug.** Every item above is the same shape: a
field written to a ledger and consulted by no rule; a signal contract assumed instead of exercised; a
duration set without asking what it makes indistinguishable; a transcript written from memory instead of
capture. The fix that generalizes is not "be more careful." It is: **for every claim, name the observation
that would refute it, and make something check for it.**

That is why `queuelabrun` currently exits non-zero and names four validity gates it does not have. The
earlier result counted because a run that looked fine was allowed to count. A tool that refuses is less
impressive than a tool that produces a number, and it is the only version of this I am willing to publish a
figure from.

**I also hardened the wrong thing.** The lab runner — which runs on my own single-user kind cluster — has a
resource-version-preconditioned ownership transaction with crash recovery. The operator, which is the part
that would run on a real multi-tenant cluster, has no conflict handling at all. I built where review
pointed, not where failure would cost most. That is a prioritization error, and naming it here is the
cheapest way to stop repeating it.

**On tooling:** the corrections above were mostly found by adversarial review, including automated
reviewers, not by me on a first pass. Two of them I found only by executing something rather than reasoning
about it — the SIGTERM behaviour in §2, and a data race that `go test -race` reported clean because no test
exercised the concurrent path. Twice, two independent reviewers agreed on a finding that turned out to be
false, and only running the code settled it. **Agreement is not evidence. Execution is.**
