# hold-cap conformance session, 2026-10-11T03:06Z

Commit `58e313f`, run by `hack/holdcap-conformance/session.sh` on one Spot g5.2xlarge in gpu-lab (`instance-id.txt`), approved by the owner.
The files here are what the instance uploaded; `instance-log.txt` is its user-data log.

## What it showed

| check | evidence | result |
|---|---|---|
| The card | `nvidia-smi.csv` | one NVIDIA A10G, driver 595.91.07 |
| The capped engine runs the measured arguments | `args-holdcap.txt` against `pp_expected_args 384` less `enable_logging_iteration_details` and `scheduler_cls`, plus `served_model_name` | match on all 14 keys, `long_prefill_token_threshold: 384` among them |
| Status was not HoldCap before that engine was ready | `at-create-infd.json` | `Off`, generation 1, reason `RolloutInProgress` |
| Status reported HoldCap once it was | `holdcap-infd.json` | `HoldCap`, observedGeneration 1 = generation 1, at 03:18:27, 9 min 31 s after the object was created at 03:08:56 (`steps.txt`, `holdcap-infd.json`) |
| Turning HoldCap off moved status first | `off-status-latency.txt`, `off-immediate-pods.txt` | `Off` for generation 2 within 0.1 s of the patch, while the capped Pod was still `Terminating` |
| Recreate rolled to an engine without the cap | `args-off.txt` against `pp_expected_args 0`, `off-deployment.json`, `off-pods.txt` | match on all 13 keys; strategy `Recreate`, template annotation `Off`, one new Pod |
| The engine takes a tier priority | `request-priority-{0,1}.{code,txt}` | both streaming requests answered 200 and ended with `data: [DONE]` |

## What it did not show

- Any latency or protection; that is Finding 9's, measured with the pilot's hand-applied engine.
- The gateway; its HoldCap path is covered by `internal/gateway`'s tests, not by this session.
- Node selection on EKS: the kind worker was labelled `node.kubernetes.io/instance-type=g5.2xlarge` and `platform.lkhun9311.github.io/gpu=true` by hand.
- The engine's own priority ordering under load; the two requests show only that the field is accepted.

## The attempt before it

Run `20261011T025605Z` at commit `9255037` ended at its eighth minute, before any engine started.
The bring-up installs kubectl v1.31, whose `kubectl wait` errors at once on a CRD with no status yet; the local rehearsal had used a newer kubectl.
`58e313f` replaced the wait with a poll and was rehearsed with kubectl v1.31 before this run.
