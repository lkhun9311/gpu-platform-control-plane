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

**`m5c-gpu-session` was left alone, and it is red: 2 passed, 15 failed.**

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

## What closes it

Teach `hack/test/spot-lifecycle/bin/aws` to answer `configure export-credentials --format process` with an
expiry, re-run `TARGET=hack/m5c-gpu-session.sh hack/test/spot-lifecycle/characterize.sh`, and check that the
only remaining diff is the termination lines the other three suites also gained. Until then this suite is red
on purpose, and `2 passed, 15 failed` is the number to compare against.
