# Attempt ledger

Every launched GPU session under contract `a10g-capacity-673-v1`, whether or not it returned evidence, and every launch refused before an instance existed.
The exclusion rules X1 to X5 are those of [`CONTRACT.md`](CONTRACT.md) section 8, fixed before the first session.

| # | OUT | Instance, zone | LaunchTime | Termination confirmed | Elapsed | Cost (at most) | Kit exit | Outcome | Included |
|---|---|---|---|---|---:|---:|---:|---|---|
| 1 | [`runs/s1`](runs/s1/) | i-0a6aeb7cfa3e68f59, ap-northeast-2d, g5.xlarge Spot | 2026-11-22T23:47:29Z | 2026-11-22T23:55:49Z | 500 s | $0.107 | none | Spot reclaim: `Server.SpotInstanceTermination` at 23:50:49Z, before `run.sh` got past its first step; `evidence=partial` | excluded, X1 |
| 2 | [`runs/s2`](runs/s2/) | i-085af91fed69439ba, ap-northeast-2d, g5.xlarge Spot | 2026-11-23T00:01:38Z | 2026-11-23T00:47:46Z | 2,768 s | $0.591 | 0 | `evidence=returned`; pilot saturated, R_sat 8, first unstable 10; the saturation stage did not hold (S2, S3); recovery 60 s after the overload; 3 of 3 restarts serving | included |
| 3 | [`runs/s3`](runs/s3/) | i-0fb48a1f4ebe613d4, ap-northeast-2d, g5.xlarge Spot | 2026-11-23T00:48:59Z | 2026-11-23T01:32:32Z | 2,613 s | $0.558 | 0 | `evidence=returned`; pilot saturated, R_sat 8, first unstable 10; the saturation stage did not hold (S2, S3); recovery 60 s after the overload; 3 of 3 restarts serving | included |

Launches refused before an instance existed (no cost, not counted toward the three sessions):

| When (UTC) | Instance type | Refusal |
|---|---|---|
| 2026-11-22T18:39:48Z | g5.xlarge | the credentials expired in 90 minutes and the session needs 97 |
| 2026-11-22T23:39:52Z | g5.xlarge | no zone had g5.xlarge Spot capacity |
| 2026-11-22T23:42:47Z | g5.xlarge | no zone had g5.xlarge Spot capacity |
| 2026-11-22T23:45:40Z | g5.xlarge | no zone had g5.xlarge Spot capacity |

Under section 8, session 1 counts toward the three launched sessions.
Sessions 2 and 3 are included, so the contract's minimum of two included sessions is met, and all three launches are used.
