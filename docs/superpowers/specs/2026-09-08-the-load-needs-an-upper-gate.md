# The load needs an upper gate — an amendment, written after the pilot

Date: 2026-09-08 · **Written with the pilot's results in hand.** That is the thing to know about this page
before reading it, and the reason it is a separate document.

`2026-09-05-the-price-of-protection.md` says in its own header that nothing may be edited from the moment
the pilot is bought. The pilot was bought on 2026-09-07. So that document is closed, and this one amends it
in the open rather than editing it quietly — which is exactly the post-hoc revision the freeze rule exists
to prevent.

## What the pilot showed

Its reading 4 asks whether the load produced contention, and fires INVALID when the control's premium TTFT
p99 is under 5x R1's. On the pilot it was **194x**, so reading 4 passed comfortably.

It passed on a run where the control completed **17 of 555** premium requests and **26 of 544** of the
contending tenant's, everything else timing out at 30 s. Every reading below reading 4 is a ratio of tails
and output shares. On that evidence they are ratios over a remnant, and nothing in the pre-registration
would have said so — reading 4 guards only the side where there is too little contention.

The pilot's own numbers do not appear anywhere below this section, and none of them set the threshold.

## The amendment: reading 4b

> **4b. The load was too high to measure — INVALID, and the trace's rate is what changes.**
>
> If the control completed fewer than `MinTailSamples` premium requests, or fewer than `MinTailSamples` of
> the contending tenant's, the run is INVALID. It is evaluated immediately after reading 4 and, like reading
> 4, it stops the readings rather than being one of the outcomes they choose between.

It sits beside reading 4 rather than at the end because the two are the same axis. Reading 4 says the load
was too gentle to create the problem; 4b says it was too violent for the instrument to see the problem. Both
mean the trace, not the configurations, is what has to change.

## Where the threshold comes from, and where it does not

`MinTailSamples` is **100**, and it was not chosen for this amendment. It is derived in
`internal/bench/report.go` from the percentile the report uses: nearest-rank puts the p99 at index
`ceil(0.99*n)-1`, clamped to `n-1`, and solving `ceil(0.99*n)-1 < n-1` gives 100 as the smallest integer
where the p99 stops being simply the largest observation. Below it, a "p99" is the slowest request wearing a
percentile's authority.

Three things follow, and they are why this is an amendment I am willing to write after seeing data:

- The constant predates the pilot and predates this document. `EvaluateChecks` has invalidated the M5-b
  study's arms on it since it was written. This amendment applies an existing floor to a second study; it
  does not introduce a number.
- It is derived from the arithmetic of the statistic, not from a judgement about what a good completion rate
  looks like. There was no freedom to place it above or below what the pilot happened to produce.
- It is applied to the **control** only, because the control is what every ratio in readings 1, 1b, 2 and 3
  is taken against. A cell that collapses is a result about that cell. A control that collapses is a missing
  denominator.

The contending tenant gets the same floor for the same reason: readings 1 and 1b compare that tenant's
output share against **its share under the control**, and reading 2 asks what became of the work it lost.
A share computed over a dozen completions is not a share, and the pre-registration's own text for reading 2
insists that a share loss must be explained by the ledger rather than assumed.

## What this does NOT change

No bar in readings 1, 1b, 2, 3 or 4 moves. Not the 2x tail, not the 1.25x TPOT, not the 75% share, not the
95% throughput, not the 5x contention floor. This amendment adds one INVALID outcome and touches nothing
that decides between the others — because those are the thresholds the pilot's numbers could actually
inform, and are therefore the ones I have no business adjusting now.

The pilot itself is INVALID under this amendment, which is the honest reading of it: it bought three harness
defects and this gap, and it did not buy a measurement of protection.

## What has to happen before the confirmatory run

1. **Set the trace's rate from a completion target, not from the stub calibration.** The generator's default
   is 20/s, and `cmd/benchharness/main.go` already warns in its own flag help that this figure is calibrated
   against a stub backend that costs nothing to serve. Nothing in the pilot's configuration read that
   warning. The rate must be chosen so the control clears reading 4b with margin, and 4b is what refuses the
   run when it was not.
2. **B₀ must resolve.** The original pre-registration's pilot gate is still unmet, and
   `hack/m5b-price-of-protection.sh` now keeps the whole engine log and says loudly when the control's batch
   budget cannot be read from it.
3. **Both gates are the confirmatory run's precondition**, and neither is satisfied by the 2026-09-07
   evidence.

This page may not be edited once the confirmatory run is bought, on the same terms as the document it
amends.
