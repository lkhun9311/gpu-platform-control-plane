# Review r9, 2026-11-07: the claims in the public documents

gpt-6-astra (high) read `56519750` read-only on 2026-11-07, asked to check every headline claim a hiring reader meets first (README, `docs/00`–`docs/11`, `experiments/*/README.md`) against the archived evidence.
Every finding below was checked by Claude against the files and archives before a document changed; every edit is Claude's.
This branch is based on `fix/slurm-docs-review` (PR #515), which had already corrected some of the same pages under review r4.

## Findings 1–6: covered elsewhere

| # | finding | where it is handled |
|---|---|---|
| 1 | Ready node plus absent Pods taken as a stopped rank | PR #520 (`rank-stopped` finalizer) |
| 2 | a rank lost before discovery escapes fencing | PR #520 |
| 3 | fence acknowledgements reused across attempts | PR #520 (`fencedBy`, `name#N`) |
| 4 | ordinary Kueue eviction bypasses the attempt | PR #520 (trigger `Evicted`) |
| 5 | the fault handoff can override an operator's stop | PR #520 (optimistic lock) |
| 6 | RWX check accepts raw-block or unusable claims | PR #520 (Lost, deleting) and the controllers review branch (`volumeMode`) |

## Findings 7–15

| # | finding | verdict (Claude) | change |
|---|---|---|---|
| 7 | spending controls described as enforced limits | **confirmed**: `infra/aws/bootstrap/budget.tf` is a monthly $30 notification budget (10/80/100 %), not enforcement; no daily budget and no escalation exist; the 52-vCPU quota paragraph predates the 2026-11-01 raise to 128 | `docs/04` budget-cap sentence corrected; `docs/09` budget row rewritten with the old text quoted; `docs/09` quota paragraph marked superseded with the 128-vCPU source; the current controls listed in `docs/00` "Current state" |
| 8 | private subnets credited with no internet route | **confirmed**: `vpc.tf` enables one NAT gateway | `docs/09` Option C sentence rewritten: no public addresses inbound, outbound open through the NAT; correction dated |
| 9 | NAT comparison keeps arithmetic its own correction invalidated | **confirmed**: recomputed A = 6 × 0.059 + 13 × 0.059 = $1.121; B cannot fetch the public images; on equal (mirrored) terms A $0.413, B $0.712 | dated recomputation after the code block in `docs/09`; the Option C "$0 image layers" claim annotated |
| 10 | Finding 3b mixes the ninth pilot's improvement with the 3b run | **confirmed**: 884.6 ms is pilot `shared` 1,892.2 − `timeSlicing` 1,007.5 ms; the 3b run bought no `timeSlicing` arm | `docs/11`: a dated note names the pilot before those paragraphs, "It" names the pilot's arm, "the table above" names the Finding 3 table |
| 11 | partial-placement witness called a second tenant | **confirmed** (same namespace `partial`, same queue `gpu-partial`); `docs/11:477` and the failure matrix were already annotated by PR #515 | `docs/11` "What each finding needs" row: "a second workload in the same queue (not a second tenant)" |
| 12 | present-tense capability statements contradict later runs | **confirmed** for each cited line | one "Current state (2026-11-07)" table at the top of `docs/00` with the latest evidence per area; stale lines in `docs/00`, `docs/01` (two), `docs/02`, `docs/03`, `docs/04` (two), `docs/06` (two), `docs/09` (two), `experiments/cpu-ddp`, `experiments/distributed-restart` marked historical with the later run named; the Slurm comparison row was already fixed by PR #515 |
| 13 | HoldCap "none of the gaps holds requests for an uncapped engine" contradicts the next bullet | **confirmed** | `docs/05` qualification corrected, dated |
| 14 | published results whose raw archives are not in the repository | **confirmed**: Argo CD self-heal, simulated MIG, fragmentation and CPU DDP point at gitignored `ex/` | each page says "raw records not in this repository" beside its figures; nothing invented. The self-heal page's "within a second" corrected to "within three seconds" (deletions 156.7–156.8 s against a reported 159.5 s retry) |
| 15 | Slurm comparison gives the Xid drain latency to ECC too | **confirmed**: `06b` signal 12:29:33.145, drain 12:29:38.022, 4.877 s; the check polls every 5 s | `experiments/slurm-lab/README.md` row and the single-observation note give 1.5 s (Xid) and 4.9 s (ECC) |

## The headline-claim table

astra's table rated each headline claim as supported, historical, report-supported only, or unsupported here.
Changes made from it beyond the findings above:

- README's "$1.69 total spend" is labelled an estimate from durations and list prices; no billing reconciliation is archived for those runs.
- The GPU-fault summaries that stopped at run 2's failure now name run 3 (`docs/00`, `docs/03`, `docs/06`).
- The restart full-stage medians are marked in `docs/00` "Current state" as that revision's, with the later stages linked.
- Claims rated "report-supported only, raw unverified here" whose raw archives exist elsewhere (the 2026-10-01 M5-c collection and the September sharing pilots) were not changed: their pages already name their archives, and this review could not read them either.

## What changed in published numbers

| page | before | after |
|---|---|---|
| `experiments/slurm-lab/README.md` | ECC drains in 1.5 s | ECC drains in 4.9 s; Xid stays 1.5 s |
| `docs/09` NAT comparison | option A $0.413 vs B $0.712 (1.7×) | with this cluster's sources A $1.121 and B unusable; $0.413 vs $0.712 only with the public images mirrored into ECR |
| `experiments/argocd-selfheal/README.md` | retry matches repair "within a second" | within three seconds (2.8 s for deletions) |

No measured table was rewritten; each correction is dated beside the text it replaces.

## What ran

`make docs-check`, `hack/test/check-published-spreads.sh` and `hack/test/check-slurm-lab-host.sh`: all pass.
No Go code changed.
