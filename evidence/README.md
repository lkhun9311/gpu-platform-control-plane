# This directory is empty, and that is the honest state

`docs/06_OBSERVABILITY_BENCHMARK_FAILURE.md` shows a report tree under `evidence/` and says of it: *"This is the
**target** layout — none of it exists yet."* That is still true. What was not true is that a reader had no way
to find out without cloning and looking: `evidence/` is gitignored, so a checkout contains neither the
placeholder directories nor any note explaining them. This file is the note.

`docs/02_CONTROL_PLANE_API.md:160` shows `reportUri: evidence/benchmark-reports/gateway-loadtest.md` and labels
it "illustrative path only". Nothing writes to that path today.

## Where the evidence actually is

| what | where | how much |
|---|---|---|
| Curated captures from paid GPU sessions | `docs/captures/` | 19 entries, `INDEX.md` first |
| Published study results, each with its own invalidation notes | `experiments/*/README.md` | 4 studies |
| Run logs committed beside the scripts that produced them | `hack/*.log`, `hack/*-cycle-*.md` | e.g. `m6-e2e-evidence.log` (392 lines), `m7-evidence-trail.log`, `m5b-chain-live-evidence.log`, `eks-cluster-cycle-20260918.md` |
| Pre-registrations and dated corrections | `docs/superpowers/specs/` | 54 pages |

## Why this is not simply populated

The report tree in `docs/06` describes artefacts from a **noisy-neighbour benchmark on real GPU nodes** that has
not been run. Filling the directory with anything else would make the layout look satisfied while the run it
describes still has not happened — which is the failure this repository spends most of its effort avoiding.

The directory stays empty until that run produces its artefacts. Until then, the table above is where to look.
