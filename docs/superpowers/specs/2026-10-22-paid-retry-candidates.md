# Paid retry candidates: readiness and drafts

Written 2026-10-22.
**DRAFT. Nothing here is registered or bought; each section needs its own registration page and the owner's explicit approval before any card is launched.**
No past verdict changes: each section re-asks a question with a new design, and the earlier result stands as recorded.

## C1. Can MPS engage on this card at all: is the runner ready?

**The question** is the capability one registered on 2026-09-25, bars B0 to B5 with three outcomes, INVALID, REFUSED and INCONCLUSIVE, and a 40-minute stop (`2026-09-25-can-mps-engage-on-this-card-at-all.md`, the bar table and its amendment of 2026-10-03).
Its known blocker, `using MPS requires --mps-root to be specified`, was fixed in `72bfed3` on 2026-09-24 and has never been retested; the honest status is "fixed and never retested" (the same page's amendment).

**What exists, read from the code at `5f2e2db5`:**

| bar | instrument | where |
|---|---|---|
| B1, exactly 2 advertised | the kept plugin's rollout awaited, then allocatable read until it equals 2, with `plugin_diagnosis` on failure | `hack/m5c-matrix.sh:1616-1637` |
| B2, both engines Running, no `no healthy devices` | the matrix's engine wait and its refusal path | `hack/m5c-matrix.sh:2187-2234` |
| B3, a real client | `mps_clients_connected`: hostIPC required, `CUDA_MPS_PIPE_DIRECTORY` set, the directory present, the control endpoint a socket (`-S`) | `hack/m5c-matrix.sh:1797-1882` |
| B4, the daemon holds both | `nvidia-smi --query-compute-apps` per engine namespace, written and not judged | `hack/m5c-matrix.sh:1883-1892` |
| B5, the replay completes | the matrix's own `raw-mps-1.jsonl` | the matrix |
| the control daemon | its rollout awaited, a refusal if it never becomes ready | `hack/m5c-matrix.sh:1643-1650` |

**What is missing before a purchase:**
1. **B0 has no check.** The registration requires the MPS plugin Pod and the control daemon Pod `Running` with 0 restarts when the advertisement is read; the matrix waits for rollout status only, and the restart counts it reads elsewhere are the engine's (`hack/m5c-matrix.sh:3149`, the instrument-validation study's). A crash-looping plugin between restarts can pass a rollout wait.
2. **No runner implements the page's stop contract**: an absolute deadline of 2,400 s from the instance's `LaunchTime`, per-step budgets of 12, 8 and 12 minutes with 8 reserved for upload and teardown, and B0 to B5 written to a structured file as each is decided. The MPS arm exists only inside the sharing matrix, after R1 and `shared` by default (`ARMS`, `hack/m5c-gpu-session.sh:178`), whose session limits are sized for those cells.
3. **The AMI is resolved from the SSM `latest` parameter at launch and not recorded** (`hack/m5c-gpu-session.sh:793-794`; `$AMI` is used once, at `:1636`); the page requires the AMI ID, the driver and container-toolkit versions, the engine digests and the manifest SHA in the run record. The driver version is recorded (`hack/m5c-gpu-session.sh:927`); the toolkit version is not.
4. **B4 reads only the CSV query.** The page also names the plain `nvidia-smi` process table, whose type column distinguishes the server from the clients; it is not captured.
5. **The device plugin is pinned at v0.16.2**, before `mps.enableHostPID` (v0.18.0), which the page records as a candidate not taken; that stays a decision for after a failure's `[previous]` log, not a change to make now.

**Build, free:** a `STUDY=mps-capability` mode of the session that runs one MPS cell with no other arm, enforces the 2,400 s deadline from `LaunchTime` with the per-step budgets, writes a structured file of bars, to be built, as each bar is decided, records the AMI ID and toolkit version, adds B0's restart check and the plain `nvidia-smi` table, and a characterisation scenario under `hack/test/spot-lifecycle` pinning the stop.

**Cost and time:** one g5.2xlarge Spot for at most 40 minutes of instance time by the registered stop, about **$0.5** at the expected $0.6824/h and at most about $0.8 at the $1.1324/h cap (`2026-10-08-measuring-prospective-admission-design.md`, pilot "Cost"); bring-up dominates, measured at 2 min 43 s for driver, toolkit and kind on a warm AMI (`hack/m5c-gpu-session.sh:665`).

**What it licenses:** REFUSED or a pass about this AMI, driver and plugin version; never a latency or throughput claim.

## C2. The fifteen-cell run's open confound: prompt length against the client

**What was left open.** Finding 3b's isolated baseline was 69.5 ms in the ninth pilot and 174 ms under the frozen contract, on the same card and engine, with premium prompts of 200 against 1,174 characters, different repetition counts, and timeouts of 30 against 60 s (`docs/11_WHAT_THIS_MEASURED.md`, Finding 3b).
Raising the timeout censored nothing, which is measured; its other effect is not: `PoolSizeForTrace` sizes the sender's idle pool as `ceil(rate × timeout)` (`internal/bench/httpsender.go:160`), so the two runs replayed through clients of different sizes, and "ruling the timeout out entirely needs a comparison that holds the client fixed, and no run has done that" (the same paragraph).
The fifteen-cell run's own verdict, INCONCLUSIVE because the evaluator floors the best improvement at zero while `timeSlicing` was 3.72x worse than `shared`, stands.

**The question.** Under the frozen contract's rates and contender, how much of the isolated baseline's and the shared ratio's difference between the two runs follows the premium prompt's length, and how much the client's timeout and pool size, each held fixed while the other moves?

**Design, one session:**
- Factor L, premium prompt: 200 and 1,174 characters, each frozen at the engine's token count on the serving image.
- Factor K, client: K1 timeout 30 s with its derived pool (the pilot's client); K2 timeout 60 s with K1's pool, fixed through `SenderPoolSize` (`internal/bench/study.go:66`); K3 timeout 60 s with its own derived pool (the frozen contract's). K1 against K2 moves only the timeout; K2 against K3 moves only the pool.
- Arms: R1 and `shared` in all six L × K cells, and `timeSlicing` at K3 for both lengths, so its comparison with `shared` is made again with a reading that does not floor at zero: "worse than shared" is its own verdict, not an inconclusive one.
- Two blocks of 14 cells, each block in the matrix's hashed order; one trace per length, so the arms of a cell differ only as registered.
- Estimands, per block: R1's premium TTFT p99 and `shared`/R1, at each L × K; the effect of a factor is the log ratio between its levels with the other held, block by block.
- Reading, fixed before any cell: an effect is **detected** when both blocks agree in sign and the smaller magnitude exceeds the largest difference between the two blocks' values of the same cell, the range check Finding 3 used; otherwise **not detected at this size**; never "absent".

**Predictions, for the record:** L moves R1's p99 by most of the 69.5-to-174 ms difference, because the premium's own prefill grows from about 68 to 256 tokens; neither K step is detected.

**Build, free:** the three client levels as registered studies; the pool override checked in every row's sender record; per-length exact-token verification on the image; a kind rehearsal of all 28 cells.

**Cost and time:** cells of this matrix ran 10 to 16 minutes (Finding 3b's ten cells for $1.44; the 2026-10-01 run's cell took 15.7 minutes against an assumed 10), so 28 cells take about 5 to 7.5 hours, about **$3.5 to $5** at the expected Spot rate and under $9 at the cap, in one session under the 12 h rule.

**What it licenses:** which of the two named differences moves the baseline on this card; not a statement about other loads, and nothing about splitting the card beyond the `timeSlicing` reading at K3.

## C3. v27 asked again as a new question: a load with headroom for the contender

**What stands.** v27's calibration measured the capped prefill lengthening past the tuned 1,740 ms at 8,192 tokens while hold-cap stayed inside every limit on seed 871; its main study was not bought because the replay predicted, on seed 882, hold-cap's contender p95 past 25 s at the long length (`2026-10-08-measuring-prospective-admission-design.md`, "v27 main study"). The owner's record says a study measuring both at once "needs a load with more headroom for the contender, and that would be a new registration starting from a new calibration".

**The lighter load, motivated before any replay.** Hold-cap serves contenders one capped prefill at a time, so its utilisation is the contender rate times that prefill.
At the long length the calibration measured a prefill p95 of 1,851 ms (the same page, "v27 calibration's result"), so at 0.5/s the long arm runs at `0.5 × 1.851 = 0.93`, where any heavy draw queues.
The rule fixed here, before any trace at a new rate exists, is utilisation at most 0.70 at the long length's measured p95: `0.70 / 1.851 = 0.378/s`, rounded down to **0.375 contenders a second**, with the premium unchanged at 9.25/s.
The rate is not chosen by replaying candidates and keeping one that passes; the replay is run once, at this rate, and recorded.

**Stages:**
1. **A new calibration**, stage F's shape at the new rate: R1, then off and hold-cap at 6,144, 7,695 and 8,192 tokens, 7 cells on **seed 891**, with v27's gate as revised (feasible, not feasible, challenge not achieved), and the size-aware spacings re-derived by v27's formula from this card's engine prefill.
   The fixed control is re-derived by a rule fixed now: the reference length's median engine prefill times 1.0533, the ratio v26's tuned 1,740 ms bore to the 1,652 ms v27 measured at that length.
2. **A main study**, only if the calibration reads feasible: astra's v27 arms (off, cap-only, hold-cap, fixed, size-aware at each length) on three cards, one block each, **seeds 882, 892 and 893**.
   **Seed 882 is in the design and is never dropped or replaced, whatever its replay predicts.** 892 and 893 have never been generated or replayed. The purchase gate replays the frozen seeds once; if it predicts hold-cap inadmissible anywhere, the study stops under this registration and no seed is swapped, as v27's gate stopped.

**Cost and time,** from measured sessions: the calibration took 1 h 15 m for 7 cells (launch 08:01:21Z, matrix return 09:16:03Z), about **$1**; each main card has 16 cells at about 560 s after a cold 881 s, about 2 h 40 m, so three cards are about 8 hours and **$5.5** expected, at most about $18 at the cap over three hard stops.

**What it licenses:** at a load with contender headroom fixed by a rule, whether a fixed spacing tuned at one length fails at another while hold-cap stays inside the owner's limits; not anything about the old load, where v27's predictions stay predictions.

## Order, if any is bought

C1 first: it is the cheapest, it answers a question three documents carry wrongly, and it needs the least new apparatus. C3's calibration next, because it is one session and its gate decides whether C3's main study exists. C2 last: it is the longest session and answers a confound, not a capability.
That order is a recommendation; the purchase decision is the owner's.
