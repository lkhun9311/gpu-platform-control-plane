# Run records

These lines are copied from each run's session log, termination record and outcome file.
Elapsed time runs from EC2's LaunchTime to the confirmed termination, which bounds the billed time from above.
The cost is that elapsed time at the all-in rate the session printed: the Spot price cap plus 120 GB of gp3 storage and a public IPv4 address.
Spot billing at the market price, below the cap, makes the real charge lower.

| Run | Instance | LaunchTime | Termination confirmed | Elapsed | All-in rate | Cost (at most) | Kit exit |
|---|---|---|---|---|---|---|---|
| 1 | g5.xlarge, i-01656e3485453bf85 | 2026-11-19T16:03:09Z | 2026-11-19T16:11:13Z | 484 s | $0.7683/h | $0.1033 | 127 |
| 2 | g5.xlarge, i-06b93560e1e84289c | 2026-11-19T16:15:51Z | 2026-11-19T16:29:59Z | 848 s | $0.7683/h | $0.1810 | 0 |
| 3 | g5.2xlarge, i-05285a30738d865fe | 2026-11-19T16:34:03Z | 2026-11-19T16:49:56Z | 953 s | $0.8683/h | $0.2299 | 0 |
| 4 | g5.2xlarge, i-0a1146c3f2f768ddd | 2026-11-19T23:31:40Z | 2026-11-19T23:47:11Z | 931 s | $0.8683/h | $0.2246 | 0 |
| 5 | g5.2xlarge, i-05ea90dacf4906907 | 2026-11-19T23:50:10Z | 2026-11-20T00:08:16Z | 1,086 s | $0.8683/h | $0.2619 | 0 |
| 6 | g5.2xlarge, i-03bc122ed9fc79c47 | 2026-11-20T02:12:45Z | 2026-11-20T02:45:22Z | 1,957 s | $0.8683/h | $0.4720 | 0 |

All instances ran in ap-northeast-2 with one NVIDIA A10G (24 GB).
