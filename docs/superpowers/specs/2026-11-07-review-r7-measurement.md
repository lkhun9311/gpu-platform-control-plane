# Review r7, 2026-11-07: the measurement code whose numbers are published

gpt-6-astra (high) read `origin/dev` read-only, area "measurement code": `internal/bench`, `internal/gpufault` scoring, the four-GPU analyzer and the numbers in `docs/11_WHAT_THIS_MEASURED.md` they produce.
Every finding was checked against the code and the archives by Claude; every fix, test, mutation and re-score is Claude's.

## Findings

| # | finding (astra) | verdict (Claude) | where it is handled |
|---|---|---|---|
| 1 | the restart barrier treats Ready plus absent Pods as stopped | duplicate of r1 | PR #520 (rank-stopped finalizer) |
| 2 | fence acknowledgements stay valid on the same machine | duplicate of r1 | PR #520 (`fencedBy`, `name#N`) |
| 3 | ordinary Kueue eviction bypasses the attempt | duplicate of r1 | PR #520 (trigger `Evicted`) |
| 4 | the fault handoff can override an operator's stop | duplicate of r1 | PR #520 (optimistic-lock patch) |
| 5 | the watchdog can force-unlock another live terraform | duplicate of r5 | PR #522, `e425ff88` and `c14cb35e` |
| 6 | a stream that closes before `[DONE]` counts as a completion | **confirmed**: the sender recorded only `StreamTerminated`, which no reader of `Summarize` used; a truncated row with a first token was `Completed` and entered the premium tail and TPOT | this branch, `95e93648` |
| 7 | the gpu fault scorer accepts a control window shorter than the registered 120 s | **confirmed**: only "ends after the injection" was checked, and a sentinel injected inside the window was not refused | this branch, `d6305919`, `5af7eee9` |
| 8 | the four-GPU analyzer trusts summaries, not raw samples | **confirmed**: `busbw`, `synced_ms_median` and `local_ms_median` were read as written, with no check against `times_s_by_rank`, `synced_s_by_rank`, `local_s_by_rank`, and the correctness counters were not read | this branch, `a5837400`, `f540db88` |
| 9 | the state-volume webhook omits the Bound check | duplicate of r1 | PR #520 (Lost and deleting refused, Pending accepted) |

## What changed

- **6.** The sender now names a stream that ended without `[DONE]` as `ErrorKind` `stream`, with a fixed `StreamError`.
  `ReadRawRows` derives per file whether termination was recorded (`omitempty` wrote the key only when true, so in a file where any row carries it, an absent key is false), and `Summarize` reclassifies a recorded-but-unterminated row as a stream failure and counts it (`TruncatedStreams`).
  A completion from a file that never recorded termination (rows before 2026-10-04) stays a completion and is counted as `TerminationUnknown`; the report prints both.
- **7.** A cell whose stated window is shorter than 120 s (to 1 ms of rounding) is invalid under V3; a no-injection cell whose sentinel was injected before the window ended is invalid under V7.
- **8.** Each size record's bus bandwidth and each steps record's medians are recomputed from the raw matrix, which must be 4 ranks by the registered sample count of positive finite times; `local_mismatched_iterations` and the three step correctness counters must be zero.

## Tests and mutations

New tests: two report tests and one sender assertion (`internal/bench/stream_termination_test.go`), three validity cases (`internal/gpufault/score_test.go`), eight analyzer cases (`experiments/multi-gpu-throughput/test_analyze.py`; the analyzer fixture now writes raw times consistent with its figures, as the benches do).
Each new check was broken once on the committed fix: 5 for finding 6, 2 for finding 7, 6 for finding 8, all red.
Two first survived and their tests were corrected before being red: the sentinel-order check (the fixture's reading did not move with the sentinel, so "never read" refused it first) and the per-rank sample count (no test had a short row; `zip()` hides it).
`go test` on `internal/bench`, `internal/gpufault`, `cmd/benchharness`, the holdcap and prefix-route scorer tests, and `make lint`: green.

## Re-scores, from a clean detached checkout of `f540db88`

- **Raw-row archives** (holdcap runs 20261015T050622Z, 20261015T225425Z, 20261021T021149Z; prefix-route run 2; MPS runs 2 and 3): every file recorded termination, and no row is an unterminated completion.
  So no published completion count, tail or TPOT changes, and no published figure rests on unknown termination.
  The Python scorers of the holdcap and prefix-route studies already required `streamTerminated` true for a success.
- **GPU fault** (both rehearsals, runs 1, 2 and 3): output byte-identical to dev's scorer on all five; every archived window is 120.000 s and every archived sentinel follows its window end by 5–6 ms.
  The committed `verdict.txt` files differ from today's dev output (the session appends `termination=`, and runs 2 and the first rehearsal predate the recovery check); that drift predates this branch and was recorded by review r3.
- **Four-GPU** (runs 2–5): output identical to dev's analyzer on all four; run 5's committed verdict is reproduced.
  Runs 2–4's committed verdicts differ from today's analyzer on smoke jobs only (smoke, not counted), which is older drift and not this branch's.

No published verdict or number changes.

## Not done

- Rows written by the old sender between 2026-10-04 and 2026-11-07 outside the committed archives are classified by the per-file rule; a file in which every row was truncated would read as never recorded and be counted as unknown, not as failures.
- The analyzer does not recompute the nccl-tests arm's figures, which are read from nccl-tests' own table.
