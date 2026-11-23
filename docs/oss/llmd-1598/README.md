# llm-d-router #1598 pilot kit

The pilot of `docs/superpowers/specs/2026-11-21-llmd-1598-real-gpu-ab-design.md`: one g5.12xlarge Spot session, four vLLM 0.34.0 engines (Qwen2.5-3B-Instruct) behind one EPP and Envoy, 18 cells.
It decides nothing about the arms.
It answers two questions:
- Does the apparatus work end to end on real engines: the token ledger, the lifecycle joins, router credit joined to `cached_tokens`, the 4 Hz load sampler, and each cell's validity checks?
- Does K's burst concentrate at all under A1?

The pilot ran on 2026-11-21 ($1.95): the apparatus held and no effect showed; the spec's third revision ("Main-run design after the pilot") says why and adds a second pilot, `STAGE=pilot2` below. Nothing after the pilot is launched.

## Arms

| arm | EPP binary | config |
|---|---|---|
| A1 | llm-d-router `733d0e4e` | `kit/configs/a1-a2.yaml.tmpl`: the llm-d guide's optimized-baseline plugin set, `peakPrefillThroughput` measured first in the pilot |
| A2 | `733d0e4e` with llm-d-router#4313 head `d44cd676` merged (tree `f48fadc5`) | the same file |
| A3 | A1's | `kit/configs/a3.yaml.tmpl`: `max-score-picker` alone (round-robin) |

## Layout

| file | what |
|---|---|
| `kit/run.sh` | installs vLLM from its pinned wheel, builds both EPP binaries from pinned SHAs (the merged tree is checked), fetches Envoy 1.40.2 and the model, then runs `pilot.py` and `verdict.py` |
| `kit/pilot.py` | the plan: calibration, isolated TTFT per block, A3 ramps (A and B at 10, 20, 40, 80/s; W942 at 1.75, 2.9, 4.4/s), logging at `-v=2` and `-v=5` on A and K, A2 and A3 on A, the B pressure cell |
| `kit/workloads.py`, `sender.py`, `sampler.py`, `logs.py` | schedules and token-ID prompts, the open-loop sender, the 4 Hz sampler and counter snapshots, the EPP and Envoy log readers |
| `kit/analysis.py`, `verdict.py` | the registered rules, and the pilot's verdict (exit 0 apparatus holds, 3 incomplete, 4 apparatus failed) |
| `test/fake_engine.py` | a fake vLLM server (token-ID prompts, prefix-cache blocks, usage, vLLM metric names, `/reset_prefix_cache`, injectable faults) |
| `test/test_kit.py`, `test/mutate.py` | unit tests of every rule, and the mutants each must catch |
| `hack/llmd-1598-kit-test.sh` | the offline gate: unit tests, mutants, `run.sh` refusals, and `run.sh` end to end against the real EPP and Envoy with fake engines, clean and with two faults |

## Gate before any launch

```
bash hack/llmd-1598-kit-test.sh
```

## Stages

`run.sh` needs `STAGE`, passed through the session's `KIT_ENV`:
- `pilot`: the first pilot's plan, which ran on 2026-11-21 (`hack/gpu-kit-runs/2026-11-21-llmd-1598-pilot`; K is now released primed, with 12 bursts).
- `pilot2`: the second pilot of the spec's third revision: A1 and A3 ramps on A and B and A1's on W942 at `-v=2`, from 64/s in x1.25 steps, each arm stopping at its first failure; K, K-equal and K-stagger (4 ms, a feasibility probe judged by frozen rules) under A1 with the primed release; on seeds 4 and 944, which the main run does not use. Its verdict exits 0 only with a grid anchor (the lowest bracketed knee) for A, B and W942 and at least one valid K and K-equal burst.

- `pilot3`: the K-only third pilot of the spec's fifth revision: primed K under A1, A2 and A3, K-equal and K-stagger under A1, on seed 5, with preload visibility bounded by Envoy's first upstream body byte. Its verdict exits 0 only when the frozen acceptance rules hold (three distinct preload engines registered before release with body times, no early decision, 90% of releases within 2 ms, 9 of 12 jointly valid A1/A2 bursts).

`TMPDIR` moves the offline gate's scratch off `/tmp` when it is short of space or inodes.

The main sessions (X1 to X3, Y1 to Y3) are written after P2, from P2's registered grid.

## Launch of the K-only third pilot

The second pilot ran on 2026-11-22 (`hack/gpu-kit-runs/2026-11-22-llmd-1598-pilot2`).
The third pilot ran on 2026-11-22 from 17:01:06Z to its confirmed termination at 17:16:12Z (`hack/gpu-kit-runs/2026-11-22-llmd-1598-pilot3`), with the command below; its verdict was APPARATUS HOLDS.

```
SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab INSTANCE_TYPE=g5.12xlarge OUT=hack/gpu-kit-runs/<date>-llmd-1598-pilot3 \
  KIT_ENV='STAGE=pilot3;BUDGET_S=3250' bash hack/gpu-kit-session.sh docs/oss/llmd-1598/kit
```

Worst case: the runner's g5.12xlarge constants, a $3.48/h Spot cap plus $0.0683/h of disk and IPv4, billed to the 4,020 s termination deadline, **$3.9623**, under its $4.00 per-session cap, which it checks before buying.
That assumes EC2 confirms the termination by its deadline, as the runner states.
The account's Spot G and VT quota is 48 vCPU, exactly one g5.12xlarge, so nothing else can run beside it.
