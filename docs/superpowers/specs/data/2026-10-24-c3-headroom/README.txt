# C3 headroom calibration: drafts and the pre-registration replay

Written 2026-10-24, before any registration of C3 and before any purchase.

## Order of events

1. `astra-prompt.txt` was sent to codex `gpt-6-astra` (high, read-only) for a cold, independent draft of C3's calibration.
2. `mine-before-reading-astra.txt` was written while it ran, before reading its answer.
3. `astra-independent-draft.txt` is its answer, unedited.
4. The replay below was run after reading both.

## The replay

Traces come from `benchharness gen-trace` with the matrix's stage-F flags: premium 9.25/s, contender 0.375/s, 420,000 ms, 200 characters for the premium prompt and 31,894, 40,000 and 42,579 for the contender's.
The call was first checked against v27's frozen trace checksums for seed 871 at 0.5/s, and reproduced all four.
`trace-checksums.txt` lists the new traces' checksums. They were generated under v27's study id and are not frozen for anything.
An id not registered in `internal/bench` gets no exact-token stamps at all, without an error, and a different checksum for that reason. So v27's id was used for its token table, which C3's registration shares (200, 31,894, 40,000 and 42,579 characters at 68, 6,144, 7,695 and 8,192 tokens).
Once C3's id was registered, its seed-891 traces came out with the same three length checksums as listed here: the id itself does not enter the checksum.

`predict-c3.py` is v27's `predict-main.py` with the trace directory and seeds taken as arguments.
The control, `control-v27-seeds-1.0205.json`, regenerates v27's main-study traces (seeds 881 to 883 at 0.5/s) and is identical to v27's committed `predict-main-1.0205.json`.

- `predict-main-anchor1740-<pace>.json`: seeds 882, 892 and 893, with the fixed arm at v26's 1,740 ms and the size-aware spacings v27's calibration froze.
- `predict-cal891-anchor1740-<pace>.json`: the calibration's seed 891, the same arms.
- `predict-main-derived-<pace>.json` (`predict-c3-derived.py`): seeds 882, 892 and 893, with the fixed spacing S = 1.0533 × the replay's own hold-cap median at the reference length on seed 891, and the size-aware spacings S × d(length) / d(ref), both at that pace.

These lengths lie outside the step model's fitted range, so every figure here is an extrapolation, not a prediction a verdict may rest on.
