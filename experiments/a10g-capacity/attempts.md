# Attempt ledger

Every launched GPU session under contract `a10g-capacity-673-v1`, whether or not it returned evidence, and every launch refused before an instance existed.
The exclusion rules X1 to X5 are those of [`CONTRACT.md`](CONTRACT.md) section 8, fixed before the first session.

| # | OUT | Instance, zone | LaunchTime | Termination confirmed | Elapsed | Cost (at most) | Kit exit | Outcome | Included |
|---|---|---|---|---|---:|---:|---:|---|---|
| 1 | [`runs/s1`](runs/s1/) | i-0a6aeb7cfa3e68f59, ap-northeast-2d, g5.xlarge Spot | 2026-11-22T23:47:29Z | 2026-11-22T23:55:49Z | 500 s | $0.107 | none | Spot reclaim: `Server.SpotInstanceTermination` at 23:50:49Z, before `run.sh` got past its first step; `evidence=partial` | excluded, X1 |

Launches refused before an instance existed (no cost, not counted toward the three sessions):

| When (UTC) | Instance type | Refusal |
|---|---|---|
| 2026-11-22T18:39:48Z | g5.xlarge | the credentials expired in 90 minutes and the session needs 97 |
| 2026-11-22T23:39:52Z | g5.xlarge | no zone had g5.xlarge Spot capacity |
| 2026-11-22T23:42:47Z | g5.xlarge | no zone had g5.xlarge Spot capacity |
| 2026-11-22T23:45:40Z | g5.xlarge | no zone had g5.xlarge Spot capacity |

Under section 8, session 1 counts toward the three launched sessions, so two launches remain and both must be included for the issue's results to be reported.
