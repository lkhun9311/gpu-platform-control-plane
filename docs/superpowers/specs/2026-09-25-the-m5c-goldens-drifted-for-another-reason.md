# The m5c goldens were already red, and not for the reason I was working on

Recorded 2026-09-25 while gating termination. It exists so the next person can tell a suite left red
deliberately from a suite nobody looked at.

## What happened

Termination was made a gate: `spot_terminate` now polls for the instance state after a call the API accepted,
and the three session wrappers `exit 1` from their EXIT trap when termination cannot be confirmed. Those
changes alter three lines of every spot-lifecycle transcript — one `describe-instances`, one
`== i-0stub is terminated`, and the `./termination.txt` the wrappers write — so the goldens had to be
re-recorded.

Three suites were re-recorded and verified green:

| suite | after |
|---|---|
| `m5b-scheduler-microtest` | 12 passed, 0 failed (including the new scenario) |
| `m5b-price-of-protection` | 8 passed, 0 failed |
| `queuelab-gpu-session` | 15 passed, 0 failed |

**`m5c-gpu-session` was left alone, and at this point it was red: 2 passed, 15 failed.** (It is green now;
the last section says what closed it. This page keeps the order the causes were found in.)

## Why it was left alone

It was already red before any of today's changes. Measured first, then changed — the baseline run reported
the same 15 failures. The diff has nothing to do with termination:

```
 aws sts get-caller-identity --query Account --output text
+aws configure export-credentials --format process
 aws sts get-caller-identity --query Arn --output text
+aws sts get-caller-identity --query Account --output text
-== credentials expire in 719 min; this session needs about 74 plus 30 of headroom
+== the CLI could not export the active credential's expiry; falling back to scanning the credential cache
+== no expiry found in <TMP>/awscache; skipping the check
```

The goldens were recorded at `c7d9e8a`. Between that commit and now, `004cacc` ("the expiry comes from the
active provider") and `85ae2fa` ("match the credential entry this run is using") changed how the wrapper
reads credential expiry, and the stub has no `aws configure export-credentials`. Every m5c scenario that
reaches the credential check therefore diverges.

Re-recording it in the same pass would have written that divergence into the goldens as though it were
intended. It may well be intended — the stub may simply need to answer the new call — but that is a
different question from the one this change was answering, and a golden updated without reading it is a
golden nobody reads.

## Amendment, same day: the credential call was only the first cause

The stub now answers `aws configure export-credentials --format process` with an expiry, and the credential
divergence is gone — the transcripts line up on that call and on the message it produces. The suite is still
red, for a **second** cause that re-recording cannot settle:

```
-PREFIX="run"
+PREFIX="run-ec9f4b39"
+LADDER=""
```

The prefix now carries an eight-character hash that differs on every run, so a re-recorded golden disagrees
with the very next execution of the same scenario. `LADDER=""` arrived with the ladder work in the same
range of commits. Neither is behaviour this suite is meant to pin, and both belong in `run_scenario`'s
normalization beside the checksums and the commit hash it already elides — which is a change to the harness,
not a re-recording.

So the suite stayed red on purpose at this point, and the number to compare against was **2 passed, 16 failed** (the
sixteenth is the new `terminate-accepted-but-still-running`, which has no golden here yet). The three other
suites were re-recorded and verified, because their only diff was the per-call timeouts added to
`describe-instances` plus their own new scenario.

## Closed, same day: three places carried the same nonce

The suite is **11 passed, 0 failed**, twice in a row on a fresh re-record. It took three normalizations,
found one at a time, because the same value appeared in three different shapes:

| where | how it read | what elides it |
|---|---|---|
| the payload | `PREFIX="run-ec9f4b39"` | anchored to the `PREFIX=` assignment |
| every AWS call | `s3://stub-bucket/run-ec9f4b39/src/source.tgz` | `run-<8hex>` in the transcript and the messages |
| the completion marker | `echo "e2ab277f" > /tmp/DONE` | anchored to that line, not to the digit shape |

`RUN_NONCE` is `openssl rand -hex 4`, and `RUN_ID` is `basename $OUT`-nonce. The third one has no `run-`
prefix, which is why it survived the first two passes.

The marker's elision is anchored to its line rather than to eight hex digits **on purpose**: an earlier
normalization in this harness matched any 64 hex characters and erased the engine image digest out of a
log — the one string identifying what was measured. `LADDER` is deliberately not normalized either; it is
fixed per scenario, so a change to it is a change to the payload and belongs in the diff.

### Two things I read wrong on the way

**A repeated count is not determinism.** After the first normalization the suite failed **4 passed, 14
failed** twice, and I recorded that as "the non-determinism is gone, another cause remains". It was not: the
two runs failed identically *for different nonces*. Two runs agreeing on how many scenarios failed is not
two runs agreeing.

**`bash -n` passing is not the check.** The comment explaining the marker elision was inserted between
`sed`'s `-e` arguments, where `#` starts an argument rather than a comment. The syntax check passed it. It
was caught by running the chain against a rendered payload and reading what came out.

## What closed it

Both causes, in the order they were found:

1. `hack/test/spot-lifecycle/bin/aws` answers `configure export-credentials --format process` with an
   expiry, which is the one field `hack/m5c-gpu-session.sh` reads. An empty
   `STUB_CREDENTIALS_EXPIRE_IN_MIN` omits the field, so the cache-scanning fallback stays reachable.
2. `run_scenario` elides the per-run nonce in all three shapes it takes — the `PREFIX=` assignment, the
   `run-<8hex>` in every AWS call and message, and the bare value on the `/tmp/DONE` marker line.

`TARGET=hack/m5c-gpu-session.sh hack/test/spot-lifecycle/characterize.sh` is **11 passed, 0 failed**, and
stays there on a second run — which is the check that matters, because this page records a round where the
same failing count twice was mistaken for a stable one.

All four suites are green: microtest 12/0, price-of-protection 9/0, queuelab 16/0, m5c 11/0.

**Counts as of 2026-09-26: microtest 14/0, price-of-protection 9/0, m5c 13/0, queuelab 16/0 — 52 checks over
48 scenarios.** The numbers above are what this page measured on 2026-09-25 and are left as measured; four
scenarios have been added since (`terminate-shuts-down-then-terminated`, `done-marker-wrong-nonce`,
`terminate-then-state-unreadable`, `credentials-expiry-unreported`), each for a stub knob that existed and
that no scenario set. This page exists so a reader can tell a suite left red deliberately from one nobody
looked at, and a count that has silently moved defeats that — so it is restated here rather than edited above.
