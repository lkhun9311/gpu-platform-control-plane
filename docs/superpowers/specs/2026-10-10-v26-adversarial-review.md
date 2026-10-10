# v26 adversarial review, 2026-10-10

Before building v26 (`2026-10-08-measuring-prospective-admission-design.md`, "v26"), the protocol, the code that produces and judges its numbers, and the paid-session apparatus were attacked independently.
Astra ran cold in three scopes with no hint of where to look: A, the protocol (19 findings); B, the measurement and judging code (24); C, the paid-session apparatus (46).
I wrote my own list (M, 14) before reading astra's.
Astra's raw reports are archived in `data/2026-10-10-v26-adversarial-review/`.

The verified column says what I had checked when this table was first committed: **yes** means I read the cited code or text; **pending** means the row is astra's claim, which I check when I make its change, and the change's test is then the evidence. The column is updated as rows are fixed.
Dispositions:
- **fix**: changed in code with a test that fails without the change;
- **register**: resolved by text in the v26 registration;
- **accept**: true, left as is, with the reason;
- **defer**: true, not on v26's path, recorded for later.

## Where the two reviews met

| Topic | Mine | Astra | Agreement |
|---|---|---|---|
| fixed-spacing mode missing | M1 | B1, C2 | same |
| no v26 scorer | M4 | B2, B4, B5 | same; astra adds precedence (B5) |
| no v26 session stage | M9, M10 | C1, C2 | same |
| spacing's origin and release instant | M2 | A8, B17 | same; astra adds "no sooner than" is only a lower bound |
| gateway post-arrival delay | M7 | A1, B3, B16 | astra found my metric was undefined: "arrival to deciding" includes the hold |
| pooled crossed bounds | M5 | A6, A16, B19 | astra found the reverse comparison picked by point estimate |
| premium failures as outcomes | M6 | A5, B4, C44 | same; astra adds that the wrapper calls an all-failed arm a failed purchase |
| the replay predicts "not established" | M11 | A13 | astra found the prediction underspecified (per seed or pooled, which paces) |
| replay underestimates contender cost | M12 | — | mine only |
| everything else | — | 75 rows | astra only |

Astra found what I did not on three axes: the endpoint arithmetic (infinite p99 compares true, A3/B14), evidence provenance (B6 to B11), and the session's money and evidence safety (C3 to C46).
I found nothing astra missed except the replay's measured bias (M12).

## A: protocol

| id | kind | finding | verified | disposition |
|---|---|---|---|---|
| A1 | ambiguity | the gateway-delay validity interval is undefined; "arrival to deciding" includes the intentional hold (15.8 s p99 in hold-cap) | yes: `decide` delay includes the hold | register: arrival to durable record for every request, and arrival to decision for premium requests, which are never held |
| A2 | defect | the safeguards let a treatment win by losing up to 5% of contender work | yes | register: a directional verdict also needs the winner's contender completion within 1 point of the loser's and shared-window work p and q at least 0.97 of the loser's |
| A3 | defect | `inf <= 0.85 * inf` is true, so two infinite pooled tails give "hold-cap beat" | yes: my own code | fix: an infinite pooled p99 never wins; both infinite is "not established" |
| A4 | ambiguity | unscorable admissibility (a missing preemption scrape) has no verdict | yes | fix: any unscorable admissibility line makes the verdict inconclusive |
| A5 | defect | verdict 3 is favourable without premium protection | yes | register: verdicts 3 and 4 also need hold-cap's pooled crossed upper end against off at most ln 0.85 |
| A6 | defect | the reverse comparison uses the lowest point p99, not every admissible arm's upper bound | reproduced | fix: verdict 5 tests every admissible fixed arm |
| A7 | ambiguity | off's contender completion of at least 95% was dropped from validity | yes | register: kept |
| A8 | ambiguity | "no sooner than" is a lower bound; a slow release satisfies it | yes | register: release at the spacing's end; validity: waited admissions' gaps within the spacing plus 13 ms at p99 |
| A9 | defect | the replay keeps a finite TTFT for a premium request finishing past 30 s | reproduced by astra; mine pending | fix |
| A10 | ambiguity | hold and cancellation clocks start at different instants in replay and gateway | yes | accept: the replay predicts, the card decides; stated |
| A11 | defect | requests without a gateway arrival vanish from the replay | pending: checked when fixed | fix: the replay refuses a cell with any |
| A12 | defect | a successful contender without its first-token stamp is a failure, not untimed | yes | fix |
| A13 | ambiguity | the pre-purchase prediction's paces and pooling are unspecified | yes | register: pooled over the three seeds at 1.000, 1.0205 and 1.0275, every arm scaled alike |
| A14 | ambiguity | a turn and the hold timer ready together are decided at random | yes | fix: the gateway refuses a turn that arrives past the hold, in both admitters |
| A15 | defect | gaps truncated to microseconds end a stream up to 15 µs early | yes | fix: the limit comparison adds one microsecond per gap |
| A16 | ambiguity | equal pooled p99s have no tie-break | yes | fix: the narrower spacing is named |
| A17 | ambiguity | "hashed order" does not freeze an order | yes | register: stage E; the three permutations are printed in the registration |
| A18 | ambiguity | R1's cap and pooling are implicit | yes | register: R1 uncapped, admission off, one cell, not pooled |
| A19 | defect | verdict 2 blames the owner's limits for any inadmissibility | yes | fix: verdict 2 names the first failing line |

## B: measurement and judging code

| id | kind | finding | verified | disposition |
|---|---|---|---|---|
| B1 | defect | no fixed-spacing mode, no v26 arms | yes | fix: `internal/gateway/fixedspacing.go`, `-admission-mode fixed-spacing` |
| B2 | defect | no v26 scorer | yes | fix: `pilot_report.py frontier` |
| B3 | defect | gateway delay not bounded | yes | fix, as A1 |
| B4 | defect | validity checked for off and hold-cap only; hold-cap premium loss is validity | yes | fix: apparatus validity for every arm; a treatment's recorded failure is an outcome |
| B5 | defect | an observed failure outranks missing cells | yes | register and fix: v26's order, inconclusive first; observed failures are still published |
| B6 | defect | the frozen load tuple is not enforced at generation | pending: checked when fixed | fix: the three traces' checksums are frozen in the registration and checked before purchase and in scoring |
| B7 | defect | the scorer trusts filenames | pending: checked when fixed | fix: each cell's manifest study, arm, seed and trace checksum are checked |
| B8 | defect | a missing clock anchor becomes [0,0,0] | pending: checked when fixed | fix: the cell is ineligible |
| B9 | defect | priority validation never requires every scheduled request's add record | pending: checked when fixed | fix |
| B10 | defect | = A12 | yes | fix |
| B11 | defect | a truncated JSONL line crashes the scorer | pending: checked when fixed | fix: the cell is invalid, the rest is scored |
| B12 | defect | = A14 | yes | fix |
| B13 | defect | = A9 | reproduced by astra; mine pending | fix |
| B14 | defect | = A3 | yes | fix |
| B15 | defect | gateway metrics omit requests that end in a proxy panic | pending: checked when fixed | defer: the metrics are not in the scoring; the request record is |
| B16 | ambiguity | = A1 | yes | register |
| B17 | ambiguity | live order is mutex entry, not arrival stamp | yes | accept: microseconds against 1.6 s spacings; stated |
| B18 | ambiguity | = A10 | yes | accept |
| B19 | ambiguity | = A6 and A16 | yes | fix |
| B20 | ambiguity | = A7 | yes | register |
| B21 | defect | terminal-count check skipped with zero records | reproduced by astra; mine pending | fix |
| B22 | defect | = A15 | yes | fix |
| B23 | ambiguity | client and gateway see an SSE event at different boundaries | pending: checked when fixed | accept: vLLM writes each event in one write; the difference is not observable on the pilot's logs |
| B24 | defect | an idle replay jumps at least 1 ms | reproduced by astra; mine pending | fix |

## C: paid-session apparatus

| id | kind | finding | verified | disposition |
|---|---|---|---|---|
| C1 | defect | no v26 stage | yes | fix: stage E |
| C2 | defect | no fixed arms in the helpers; unknown arms get cap 0 | yes | fix: every helper refuses an unknown arm |
| C3 | defect | uploads only warn; DONE follows the matrix alone | yes: `upload ... \|\| true` | fix: the instance proves it can write before the first cell, and DONE needs the archive's upload |
| C4 | defect | a reused OUT can supply an old session's evidence | pending: checked when fixed | fix: a pilot session refuses a non-empty OUT |
| C5 | defect | seeds, rates and duration are not checked against the registration | pending: checked when fixed | fix: the plan check compares trace checksums with the frozen ones |
| C6 | defect | the stage's arm set is computed and never used | yes: `_pp_arms` unused | fix |
| C7 | defect | the pre-purchase replay is not run by the session | pending: checked when fixed | register: run and recorded by me before launch; the session checks the checksums it was run on |
| C8 | defect | PLAN_ONLY renders neither engine nor gateway arguments | pending: checked when fixed | fix: the plan renders both for every arm |
| C9 | ambiguity | = A17 | yes | register |
| C10 | defect | instance type and card are the caller's | pending: checked when fixed | fix: a pilot session requires g5.2xlarge and an A10G in preflight |
| C11 | defect | the dirty-tree waiver splits source and binaries | pending: checked when fixed | fix: refused for pilot studies |
| C12 | defect | credentials are checked before the build, not at launch | pending: checked when fixed | fix: rechecked immediately before launch |
| C13 | defect | the credential fallback can pick another session's expiry | pending: checked when fixed | fix: refused for pilot studies |
| C14 | ambiguity | code requires H+40, the registration H+50 | pending: checked when fixed | fix: H+50 |
| C15 | ambiguity | sweeper region not tied to launch region | pending: checked when fixed | fix: a pilot launch requires the sweeper's region |
| C16 | ambiguity | deadlines start at different instants | pending: checked when fixed | fix: the backstop is passed as an absolute epoch |
| C17 | defect | no refusal of an expired deadline immediately before purchase | pending: checked when fixed | fix |
| C18 | defect | cleanup termination is unbounded | pending: checked when fixed | fix: bounded by timeout |
| C19 | defect | `LAUNCH_UNCERTAIN` cleared before reconciliation succeeds | pending: checked when fixed | fix |
| C20 | defect | `RUN_NONCE` can be overridden | pending: checked when fixed | fix: refused for pilot studies |
| C21 | defect | unescaped sed substitution of OUT | pending: checked when fixed | fix: OUT's basename restricted to `[A-Za-z0-9._-]` |
| C22 | defect | a failed preflight download aborts recovery | pending: checked when fixed | fix |
| C23 | defect | completeness accepts extra cells and missing records | pending: checked when fixed | fix: stage E's exact 19-cell inventory with its records |
| C24 | defect | `raw-hold-*` matches `raw-hold-cap-*` | yes | fix: the repetition is matched as digits |
| C25 | defect | pilot evidence counted as conditional | pending: checked when fixed | fix: required per cell for pilot studies |
| C26 | defect | namespace deletion errors ignored | pending: checked when fixed | fix: the namespace must be gone before it is created |
| C27 | defect | helper port-forwards do not prove ownership | pending: checked when fixed | fix: each refuses a port already listening |
| C28 | defect | capture's five minutes is not an enclosing bound | pending: checked when fixed | fix: curl's budget never falls below one second, and the loop stops at the deadline |
| C29 | defect | a failed record read can overwrite the last good snapshot | pending: checked when fixed | fix: read to a temporary file, upload only a complete one |
| C30 | defect | sidecar and sampler are not waited for | pending: checked when fixed | fix |
| C31 | defect | the sweeper crashes on an overflowing date | reproduced by astra; mine pending | fix |
| C32 | defect | the sweeper reports failed terminations as terminated | reproduced by astra; mine pending | fix |
| C33 | defect | the sweeper's calls have no per-call timeout | pending: checked when fixed | fix: client timeouts |
| C34 | defect | the exercise's cleanup can miss its instance | pending: checked when fixed | fix |
| C35 | defect | the exercise's identity has second resolution | pending: checked when fixed | fix |
| C36 | ambiguity | the exercise infers causality from timing | pending: checked when fixed | accept: stated in the exercise's output |
| C37 | defect | the rehearsal accepts any PILOT value | pending: checked when fixed | fix |
| C38 | defect | the diagnostic rehearsal accepts any inconclusive verdict | pending: checked when fixed | fix: stage E's rehearsal requires every cell eligible |
| C39 | defect | goldens erase absolute deadlines | pending: checked when fixed | fix: the session asserts their order at run time |
| C40 | defect | cap verification is per arm, not per cell | pending: checked when fixed | fix |
| C41 | ambiguity | sidecar cadence is 30 s after the last upload | pending: checked when fixed | register: stated as such |
| C42 | defect | phase stamps incomplete; replay-done after the scrape | pending: checked when fixed | defer: not in v26's scoring |
| C43 | defect | DONE precedes the final log upload | pending: checked when fixed | fix |
| C44 | ambiguity | an all-failed arm reads as a failed purchase | pending: checked when fixed | fix: for pilot studies a recorded failure is evidence |
| C45 | defect | the archive's instructions name the sharing study | pending: checked when fixed | fix |
| C46 | defect | user-data size limit wrong | pending: checked when fixed | fix: 16,384 raw bytes |

## Mine

| id | finding | met by | disposition |
|---|---|---|---|
| M1 | fixed-spacing mode absent | B1, C2 | fix |
| M2 | spacing's origin | A8, B17 | register |
| M3 | fixed arms' hold origin | A10 | register: from the gateway's reservation, as serial-prefill |
| M4 | no v26 scorer | B2 | fix |
| M5 | pooled crossed bounds | A6 | fix |
| M6 | premium failure as outcome | B4 | fix |
| M7 | gateway delay | A1 | register and fix |
| M8 | helpers for fixed arms | C2 | fix |
| M9 | session stage | C1 | fix |
| M10 | study registration | B1 | fix |
| M11 | predicted "not established" | A13 | register: recorded before purchase |
| M12 | replay underestimates contender cost by 3% to 7% | — | register: stated beside the prediction |
| M13 | "every complete block" wording | — | register |
| M14 | which off is the reference | — | register: the same block's off |
