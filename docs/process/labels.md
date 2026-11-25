# Issues, labels and pull requests

This repository follows the Kubernetes SIG flow.

## Flow

1. Open an issue from a form (feature, bug or experiment) before writing code.
2. Label it with one `kind/*`, one or more `area/*` and one `priority/*`, then add `triage/accepted` when it is scoped.
3. Add `lifecycle/active` while it is being worked on.
4. Branch `feat/<issue>-<topic>` from `dev`, commit in small steps, and open a PR to `dev` with `Fixes #N` or `Part of #N`.
5. The `PR checks` workflow fails without a `kind/*` label, without an issue link, or with a `do-not-merge/*` label, and sets `size/*`.
6. Merge to `dev` when every check is green. Promotion to `main` is a separate, approved step.

## Labels

| Prefix | Values | Meaning |
|---|---|---|
| `kind/` | bug, feature, cleanup, documentation, test, experiment | What kind of change |
| `area/` | admission, gateway, serving, scheduling, observability, mlops, harness, gpu-runner, infra, ci, upstream | Which part of the system |
| `priority/` | critical-urgent, important-soon, important-longterm, backlog | When it should be done |
| `triage/` | accepted, needs-information | Whether it is ready to work on |
| `size/` | XS, S, M, L, XL, XXL | Lines changed in a PR, set by CI |
| `lifecycle/` | active | Someone is working on it now |
| `do-not-merge/` | hold | The PR must not merge yet |

Size thresholds, on added plus deleted lines: XS under 10, S under 30, M under 100, L under 500, XL under 1000, XXL from 1000.
