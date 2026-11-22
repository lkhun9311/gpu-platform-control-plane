# Single-A10G capacity, overload and recovery

Issue [#673](https://github.com/lkhun9311/gpu-platform-control-plane/issues/673).
The rules are in [`CONTRACT.md`](CONTRACT.md), committed before any GPU session, and every launched session is listed in [`attempts.md`](attempts.md).
No GPU result exists yet; this directory holds the contract, the kit, its offline evidence and the gateway's share measured on kind.

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

## Launching a session

The runner is `hack/gpu-kit-session.sh`, which is on `feat/llmd-1598-real-gpu-ab` and not yet on `dev`, so it runs from a clean checkout of that branch.
Its own tree must stay clean, so `OUT` points outside it.
Another study holds the account's whole G and VT Spot quota between 17:00 and 22:00 UTC, so a launch then fails before any instance exists.

```bash
bash hack/a10g-capacity-kit-test.sh        # in this worktree; must print "all checks passed"
git -C ~/workspace/gpu-platform-control-plane worktree add --detach .claude/worktrees/gpukit-runner origin/feat/llmd-1598-real-gpu-ab
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
