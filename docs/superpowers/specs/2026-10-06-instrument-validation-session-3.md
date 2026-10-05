# Instrument validation, session 3 — a registration

Date: 2026-10-06 · Registered **before** any card time is bought for it, and frozen from the moment the first cell is bought; later changes are appended as dated amendments.

**Why it exists.** Session 2 (`2026-10-05-instrument-validation-session-2.md`, archive hack/m5c-20261005-135632) stopped after three cells: gate S refused a staggered cell because staggered decoders capped at 512 output tokens stopped at end-of-sequence, 188 of 420 of them early and the shortest after 101 tokens, so the prefill did not always meet sixteen running decoders. Its stopping rule required a further registration before anything else is bought; this is it. Everything here is session 2's registration and amendments **except the changes in section 1**. The design was made by me and, independently, by codex `gpt-6-astra`; section 3 records who decided what.

## 1. What changes

| | Session 2 | Session 3 |
|---|---|---|
| Study id | `instrument-validation-s2-2026-10-05` | `instrument-validation-s3-2026-10-06` |
| Staggered decoders | `max_tokens` 512 | `max_tokens` 512 **and `min_tokens` 512**, in the measured trace and in the warm-up; vLLM v0.27.1 forbids end-of-sequence before `min_tokens` (`vllm/sampling_params.py`, `min_tokens`), so every decoder produces exactly 512 |
| Every other request | unchanged | unchanged — every serial and burst request of session 2 reached its cap |
| Gate S | per measured staggered cell | also on the warm-up's staggered episodes, before the measured replay; and every staggered decoder must report 512 output tokens and finish reason `length` |
| Engine | model and tokenizer revision asserted by the manifest only | `--revision` and `--tokenizer-revision` pinned to the manifest's revision, and refused if the engine does not report them |
| A refused cell | the matrix stopped before recording its outcome, so the accounting of expected files disagreed | its outcome is recorded, then the matrix stops |

The warm-up sequence, trace spans, triggers and jitter, engine configuration, cells and blocks (18, no async controls), the frozen clock, every estimand, gate and bound, the stopping rule and the deadline arithmetic are session 2's.

## 2. Session 2's three cells

They ran under different termination semantics and are not pooled with session 3, replace none of its cells and calibrate nothing. They remain the evidence for session 2's result and a fixture for the instrument's checks.

## 3. Who decided what

| | Me, before astra | astra | Fixed |
|---|---|---|---|
| Mechanism | `ignore_eos` on every request of the study | `min_tokens` = `max_tokens` = 512 on staggered decoders only | **astra's** — the smallest change; serial and burst requests already reached their caps |
| Study id | new | new | agreed |
| The three cells | not pooled | not pooled; diagnostics and fixtures only | agreed |
| Warm-up composition | — | S on the warm-up's staggered episodes, which also violated it (40 of 84 decoders stopped early) | astra's |
| Further defects | — | the refused cell's outcome unrecorded; the engine reported `revision=None` | astra's findings |

Every session-2 number above was recomputed by me from the archive; astra's and mine agree.
