# Single-A10G capacity, overload and recovery

Issue [#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673).
The rules are in [`CONTRACT.md`](CONTRACT.md), committed before any GPU session, and every launched session is listed in [`attempts.md`](attempts.md).
The GPU results of the two included sessions are in [`RESULTS.md`](RESULTS.md); this directory also holds the contract, the kit, its offline evidence and the gateway's share measured on kind.

## Files

| Path | What it is |
|---|---|
| `CONTRACT.md`, `kit/contract.json` | The measurement contract; the kit and the analysis read the JSON, and the gate fails if the two disagree |
| `kit/run.sh` | One session: the engine in docker, a warm-up, the pilot, one cycle, three restarts, the report |
| `kit/analysis.py` | Every rule of the contract on the raw rows: ledger, stability, saturation, cycle plan, recovery, exclusions |
| `kit/sampler.py` | The 1 s `/metrics` scraper, and the drain check between pilot rungs |
| `../../cmd/capacityrun` | The stage replayer and restart prober, on `bench.HTTPSender`, `bench.Replay` and `bench.ReconcileRecording`; the kit builds it from the commit `SRC_SHA` in `run.sh` names |
| `test/` | Unit tests, the must-fail fixtures for each rule, and the mutants |
| `gateway/` | The kind measurement's cluster config and its latency summary |
| `../../hack/a10g-capacity-kit-test.sh` | The offline gate: tests, fixtures, mutants, pins, refusals, and the full kit against the benchharness stub |
| `../../hack/a10g-gateway-kind.sh` | Gateway processing latency on kind, with a stub backend, admission off, an explicit non-limiting rate limit and the recorder off |

## Gateway processing latency on kind

Record: [`hack/a10g-gateway-kind/20261122T164207Z/`](../../hack/a10g-gateway-kind/20261122T164207Z/), at commit `e1d98396`, with `settings.txt`, the raw rows and `latency.txt`.
One kind node, the deployed gateway (500m CPU limit) with `--admission-mode=off`, the InferenceDeployment's admission Off, an explicit rate limit of 600,000 requests a minute with a 10,000 burst, and no request recorder.
The stub answers 128 frames after 20 ms at 8 ms apart, with no concurrency limit; the workload is the contract's, 60 s per stage, and both arms replay the same arrivals.

| Rate | n per arm | TTFT p99, gateway / direct | TTFT p99 difference | TTFT p50 difference | E2E p99 difference |
|---:|---:|---|---:|---:|---:|
| 3 req/s | 185 | 22.27 / 21.47 ms | 0.81 ms | 0.28 ms | 0.30 ms |
| 8 req/s | 498 | 22.16 / 21.30 ms | 0.86 ms | 0.25 ms | -0.29 ms |
| 16 req/s | 968 | 21.78 / 21.20 ms | 0.58 ms | 0.24 ms | 5.24 ms |
| 28 req/s | 1,755 | 21.66 / 21.00 ms | 0.66 ms | 0.23 ms | 3.63 ms |
| 42 req/s | 2,478 | 21.68 / 21.13 ms | 0.55 ms | 0.18 ms | -3.82 ms |

Every request of every stage completed.
A difference is between two quantiles of two runs with the same arrivals, not a per-request overhead, and the E2E differences change sign across rates, so this single run does not resolve an E2E difference of a few milliseconds.
This is the gateway's share on a CPU node with a stub; it is never added to a GPU figure, and it says nothing about the gateway under admission other than Off.

## Launching a session

The runner is [`hack/gpu-kit-session.sh`](../../hack/gpu-kit-session.sh) on `dev`, merged by pull request #686 as commit `4b38c545`; sessions 1 to 3 ran it before that merge from `feat/llmd-1598-real-gpu-ab` at `06b8b59d` (each session's `session-provenance.txt`), whose copy of the file is identical to the one on `dev`.
Its own tree must stay clean, so `OUT` points outside it.
Another study holds the account's whole G and VT Spot quota between 17:00 and 22:00 UTC, so a launch then fails before any instance exists.

```bash
bash hack/a10g-capacity-kit-test.sh        # in this worktree; must print "all checks passed"
git -C ~/workspace/gpu-platform-control-plane worktree add --detach .claude/worktrees/gpukit-runner origin/dev
cd ~/workspace/gpu-platform-control-plane/.claude/worktrees/gpukit-runner
SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab INSTANCE_TYPE=g5.xlarge \
  OUT=$HOME/workspace/gpu-platform-control-plane/.claude/worktrees/a10g-capacity/experiments/a10g-capacity/runs/s1 \
  bash hack/gpu-kit-session.sh $HOME/workspace/gpu-platform-control-plane/.claude/worktrees/a10g-capacity/experiments/a10g-capacity/kit
```

Use `runs/s2` and `runs/s3` for the next sessions; the runner refuses an `OUT` that exists.

## Time and cost

The runner's g5.xlarge worst case is 4,020 s at the $0.70/h Spot cap plus $0.0683/h of storage and address, $0.7683/h all in: **$0.8579 per session**, and $2.57 for the contract's three sessions.
The kit itself is bounded by `session.budget_s`, 3,200 s from its start, inside the runner's 3,300 s.

The expected kit time, from the 2026-11-16 readiness runs of the same image on g5.xlarge (`hack/version-readiness/2026-11-16-run6/vr-run/summary.txt`) and this kit's own stage lengths:

| Phase | Expected | Bound |
|---|---:|---:|
| Image pull (576 s then, on slower storage) beside the sender build | about 500 s | 1,200 s |
| First engine start (weights download and first compile; 350 s then) | about 350 s | 1,200 s |
| Warm-up | 60 s plus drain | 120 s |
| Pilot, about 8 rungs to a saturation near 10 to 14 req/s | about 600 s | 900 s |
| Cycle | 630 s plus up to 60 s drain | 690 s |
| Three warm restarts (about 100 s each then) | about 330 s | 3 x 260 s, the third skipped if time is short |
| Report and checksums | under 30 s | 60 s |

That is about 2,500 s of kit, plus about 150 s of bring-up before it and about 100 s of upload and termination after: **about 2,750 billed seconds, about $0.59 at the cap**, less at the market price.
These are expectations, not measurements of this kit; each session's row in `attempts.md` will carry its measured elapsed time.
