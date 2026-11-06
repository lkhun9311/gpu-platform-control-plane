# Review r3: GPU fault detection and monitoring, verified and fixed

Written 2026-11-07.
gpt-6-astra (codex, high effort, read-only sandbox) reviewed this area of `dev` at `116092ef` without being told where to look, and returned ten findings.
Claude checked each against the code and the archives before changing anything; a finding's verdict below is Claude's, and the evidence column is what Claude read or ran.
codex ran no tests (its sandbox is read-only); every test and mutation result below is Claude's, run on this branch.

## Verdicts

| # | finding (astra) | verdict | evidence (Claude) |
|---|---|---|---|
| 1 | `GPUFaultFieldsNotCollected` joins on `Hostname`, so one card with both fault fields hides another card missing one | CONFIRMED | `config/prometheus/gpu_rules.yaml` counted by `Hostname` only; the operator's own `Assess` (`internal/gpufault/classify.go`) already judges `Missing` per card, so the alert was the coarser of the two |
| 2 | the gpu-fault runner offers the all-in rate $1.1324 as the Spot `MaxPrice` | CONFIRMED | `hack/gpu-fault-session.sh` used `MAX_PRICE_FIXED=1.1324` for zone selection and `spot_launch`'s `MaxPrice`; the registration defines $1.1324 as the Spot cap $1.10 plus 200 GB gp3 and a public IPv4. Exposure: compute up to $0.0324/h above the cap, about $0.07 over a 2.24 h session |
| 3 | the sweeper gate reads `Datapoints[0].Sum` only | PARTLY | the code reads the first datapoint and ignores any other (confirmed); whether CloudWatch returns two buckets for this 30-minute, 1,800 s query was not checked against the service |
| 4 | the credential is checked before the image builds and uploads, not before the purchase | CONFIRMED | the only check sat before `make docker-build`; nothing re-read the expiry before `run-instances` |
| 5 | the termination wait is not bounded by its deadline | PARTLY | the wait was raised to 300 s whenever less remained, which carried it past the registered `LaunchTime` + 7,480 s (confirmed); the per-call bound is the AWS CLI's own timeouts, unchanged here |
| 6 | scorer failure and evidence loss leave the session successful, and the positive test accepts evidence loss | CONFIRMED | the scorer's status was never read; the exit status depended on termination alone; the test's `^GPU FAULT REACTION: NO-EVIDENCE` prefix is also what a session prints when no archive came back |
| 7 | P5 reports `held` with no injection observed | CONFIRMED | `Judge` started from `held`; run 1 (`hack/gpu-fault/2026-10-26-run1/verdict.txt`) has no repetition and printed `held`; two empty allocatable readings compared equal |
| 8 | the alert and runbook say the operator "has already tainted" the node | CONFIRMED | `GPUFaultSource.Tick` scrapes only nodes a NodeHealth names, and no code creates NodeHealth objects |
| 9 | the delivery check counts receipts by alert name, so a repeated Xid notification can satisfy the ECC step | CONFIRMED | `received` matched `alertname` and status only. The archived run's sink (`hack/gpu-alert-delivery-20261031T235222Z/sink.jsonl`) holds one firing and one resolved notification each for `field=xid` and `field=ecc_dbe`, so its recorded result stands |
| 10 | `index-platforms.exit` records 0 after the platform check fails | CONFIRMED | `python3 … \|\| fail …` then `echo "exit=$?"` wrote `fail`'s status. The archived records (`hack/dcgm-diag/2026-11-04-image-inspection/*/index-platforms.exit`) are genuine passes: both images resolved `linux/amd64` and both indexes list it |

## Changes

| # | change | commit | pinning test | mutation (Claude) |
|---|---|---|---|---|
| 1 | judged per card, `(Hostname, gpu, UUID)`; summary and runbook name the card | `f028c1b7` | `gpu_rules_test.yaml`: card 4 of w1 has utilisation and Xid, no ECC, beside w1's fully covered card 0 | join back to `on (Hostname)`: promtool FAILED |
| 2 | `MAX_PRICE_FIXED=1.10` is what zones are chosen by and EC2 is offered; `ALL_IN_RATE=1.1324` is recorded as a cost | `bdc8ad3e` | `check-gpu-fault-session.sh`: a $1.12 offer is refused; the launch carries `MaxPrice` 1.10 | back to 1.1324: 3 FAIL |
| 3 | every datapoint summed; a non-list answer refused | `bdc8ad3e` | an error in the second datapoint is refused; a whole session passes on `[3.0, 3.0]`, each under the minimum of 4 | first datapoint only: 19 FAIL |
| 4 | the credential is read again just before the purchase | `bdc8ad3e` | a credential that passes before the build and not before the purchase is refused before `run-instances` | the second check removed: 1 FAIL |
| 5 | no 300 s floor; a wait past the deadline is 0 s and an unconfirmed termination is reported | `bdc8ad3e`, test `76640b24` | `LaunchTime` 8,000 s ago gives "waiting up to 0s" | floor restored: 1 FAIL |
| 6 | `evidence=`, `scoring=` and `termination=` recorded apart; a missing archive or a scorer that printed no verdict line fails the session | `bdc8ad3e`, test `76640b24` | the positive case must show the arms read `NOT-RUN` from the returned `smoke.env` and `verdict.json`; an unreadable `smoke.env` gives `scoring=failed` and a non-zero exit; no archive gives `evidence=missing` and a non-zero exit | scoring rule removed: 1 FAIL; evidence exit removed: 1 FAIL |
| 7 | P5 is `held` only with a valid injecting repetition that read allocatable on both sides, else `NOT-OBSERVED`; empty readings never compare equal | `2eef261d` | `TestP5NeedsAnObservation` | default back to `held`: FAIL; readings not required: FAIL |
| 8 | the description says "expected", names the NodeHealth prerequisite and the failed-reconcile case, and the runbook says how to confirm the taint | `be70ae4b` | the promtool expectation carries the new description | old wording restored: promtool FAILED |
| 9 | counting moved to `hack/alert-receipts.py` with `LABEL=VALUE` filters; the Xid steps filter `field=xid`, the ECC steps `field=ecc_dbe` | `74eff16f` | `check-alert-receipts.sh` (in `harness-check`): the archived sink, and a sink of Xid notifications only, which gives 0 ECC receipts | filter ignored: 5 FAIL |
| 10 | the platform check's status is taken before `fail` runs | `6a0ca862` | `check-dcgm-diag-inspect-image.sh` (in `harness-check`), stub curl and docker: an index without the platform run records `exit=1`, one with it `exit=0` | `exit=0` written unconditionally: 1 FAIL. The new test also failed on the unfixed script, before the fix |

## Re-scoring the archives (Claude)

`benchharness gpu-fault-verdict` built from this branch against every committed gpu-fault archive, compared with the one built from `dev`:

- run 1: P5 `held` becomes `NOT-OBSERVED: no valid repetition injected and read allocatable before and after`; the label (`REFUSED`) and every arm are unchanged.
  The design page already said P5 "held only because no injection ran"; it now also says what the scorer prints.
- run 2, run 3 and both rehearsals: identical output from both builds.
  (Run 2 and the 2026-10-26 rehearsal already differ from their archived `verdict.txt` in the recovery-check lines; that difference is the same on `dev` and predates this branch.)

No other published number or verdict changed.

## Not done

- `hack/gpu-alert-delivery.sh` was changed and syntax-checked, and its counting is tested, but the script itself was not run again end to end on kind (its queue phase alone waits up to 40 minutes).
- `hack/mps-capability-session.sh` offers the same $1.1324 as `MaxPrice` (finding 2's pattern); it is outside this area and is left for the paid-session review.
- The partial-card case of finding 1's second half (a card missing all its series while others on the node report) is not alerted: `kube_node_status_capacity` cannot be compared with a card count when time-slicing advertises replicas.
- Each AWS call in the termination wait is bounded only by the CLI's timeouts (finding 5).
