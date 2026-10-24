Raw evidence from the M5-c sharing matrix.

The variable is the SHARING MODE, and every row now carries it as its arm: R1, shared, timeSlicing or mps,
under study sharing-matrix-2026-09-10. Admission was off in every arm, which is a constant of this run
rather than its variable, so it is not what the arm field names.

  for f in /src/m5c-run/raw-*.jsonl; do args="$args --raw $f"; done; benchharness report $args

The study is read from the evidence rows themselves, not passed as a flag, so the arm names above are what
select the readings. That evaluates the pre-registered readings from
docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md, in the registered order, and
prints the first that fires. Do not evaluate them by hand: a run whose readings are read off a table by a
person is not the instrument the pre-registration describes.

This file used to say the opposite -- that these files must never be passed to `benchharness report` --
because every arm was replayed as "off" and pooling would have collapsed three topologies into one row.

EACH ROW NOW CARRIES WHY THE ENGINE STOPPED, and the silences are not pooled.

  finishReason   the engine's own word: "length" when the output cap cut the response, "stop" when the
                 model ended on its own. Added 2026-10-03, and added because it was being DISCARDED: the
                 engine had been sending it on the final SSE frame all along and the parser declared only
                 the content delta, so a run whose cap truncated every answer and one whose model finished
                 early left identical rows. The output cap is one of the five load quantities this study
                 freezes, which made "the cap was not reached" unsupportable in either direction.

Read the absence of the field as its own fact. The report counts three things separately and they license
different sentences: rows that named a reason, rows that answered 200 and named none (a gap in the
instrument), and rows with no successful response at all (unobservable). An empty reason is NOT a stop.

WHAT THE TIMEOUT BOUNDS, and how to tell its two expiries apart in these rows.

The manifest now carries timeoutScope beside timeoutMs. The budget covers the WHOLE request -- connection,
TLS, headers and the entire stream -- so timeoutMs is not a first-token budget, and a response that starts
in time and then stalls expires as well. Both expiries write errorKind "timeout", and one field separates
them:

  firstTokenUnixNanos = 0   nothing arrived before the deadline; httpStatus is 0 too
  firstTokenUnixNanos > 0   the stream stalled mid-response, and the token that did arrive is kept

So "no request was censored by the timeout" needs both the count of timeout rows AND the scope named. An
empty timeoutScope means the manifest predates the field, which is not the same as having no scope.

TWO FILES BESIDE THE ROWS ANSWER "was the budget judgement made on a sane number".

  cell-timings.tsv     one row per cell, completed AND refused, with its own elapsed seconds
  cell-judgements.tsv  one row per deadline boundary, including the ones that CONTINUED

Added 2026-10-03, and added because they were missing: the fifteen-cell run's per-cell duration is nowhere
in its archive, so the 11.61 min/cell figure this project published had to be back-computed from raw request
timestamps. cell_secs is a running total for the projection and nothing wrote the parts.

Read them together. A judgement row carries the remaining minutes, the basis it projected from, the
projected figure and the decision, so a stop can be re-examined against the cell times that produced it.
A refused cell is in the timing file too: it consumed card time and the projection counted it, so a file
that omitted refusals would disagree with the arithmetic that drove the next decision.

Neither file says the judgement was CORRECT. It says the judgement can now be re-examined.
