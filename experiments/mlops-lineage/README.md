# Can a served answer be traced back to its training data, and can a bad model be taken back?

The job posting asks for MLOps across a model's lifecycle, and this repository had none: `MLTrainingJob` runs a
container and `InferenceDeployment` serves one, and nothing connected the model one produced to the model the
other served. This experiment builds the smallest connection that can be checked — one classifier, one tracking
server, one promotion rule, one serving path — and checks it where it usually breaks, not where it usually works.

## Registered before the first run (2026-10-09)

Everything in this section was written before `hack/mlops-lineage.sh` was run on kind. A local rehearsal with
plain containers came first and is described under "Rehearsal", because it shaped two design choices below.

### Setup

- A throwaway single-node kind cluster named `mlops`, with Kueue v0.18.3, the operator and the simulated-GPU
  device plugin built from this tree, and an MLflow 2.17.2 tracking server (`ghcr.io/mlflow/mlflow:v2.17.2`, pulled by the node itself because `kind load` cannot import it,
  SQLite and artifacts inside the Pod) in namespace `mlops`.
- `train.py` is submitted as an `MLTrainingJob`. It trains `Linear(8, 1)` on 2,000 generated points, evaluates
  on 1,000 held-out points, and registers the weights as a version of model `clf` with three hashes: the
  training data, `train.py` itself, and the saved weights. `VARIANT=noisy` adds a labelling bug confined to one
  region of the input.
- `gate.py` is the promotion rule: a candidate becomes `champion` when there is none yet, or when its held-out
  accuracy is at most 0.02 below the champion's.
- `serve.py` runs as an `InferenceDeployment`. Its `storageUri` is either `models:/clf/<version>` (pinned) or
  `models:/clf@champion` (follows the alias, resolved once at start-up). It refuses to start if the weights'
  hash differs from the one registered, and every `/predict` answer names the version, run and weights hash.
- `poll.py` asks `/predict` 20 times a second through a NodePort and records each answer's status and version.

### Steps and readings

| step | what happens | reading | registered expectation |
|---|---|---|---|
| 1 | train v1 (`clean`) and v2 (`noisy`) | accuracies | — (validity check 1) |
| 2 | gate v1, then gate v2 | decisions | v1 promoted; **v2 refused, alias unmoved** |
| 3 | serve `models:/clf/1`, query it | the lineage chain | the answer's version, run and weights hash, and that run's data hash, code hash and commit, all equal what the training Job printed |
| 4 | force-deploy v2 by editing `storageUri`, then put v1 back; three cycles | non-200 answers per cycle; seconds from the rollback edit to the last v2 answer | **0 non-200** in every cycle; seconds reported |
| 5 | serve `models:/clf@champion`, force the alias to v2, wait 60 s, then restart the Deployment | share of answers still v1 during the 60 s; version after the restart | **100% v1** while the alias says v2; **v2** after the restart |

### Validity checks (a failure voids the run)

1. The models are what the experiment needs: v1 accuracy ≥ 0.95, and v2 at least 0.05 below v1.
2. The poller was answered: each polled window has at least 90% of the requests it intended to send recorded.
3. The served weights are the trained weights: the hash in the first pinned answer equals the hash the v1
   training Job printed.

### Rehearsal (plain containers, before the registration was frozen)

v1 reached 0.995 and v2 0.615 held-out accuracy. The gate promoted v1 and refused v2. A server pinned to v1 and one
following the alias both answered v1; after the alias was forced to v2, the alias server still answered v1 until
it was restarted, then v2. Replacing the registered hash with a wrong value made the server exit with status 1
instead of serving. The rehearsal also changed the design twice: MLflow 2.17 answers a missing alias with
`400 INVALID_PARAMETER_VALUE`, not 404, so the gate matches that exact message; and `InferenceDeployment` has
**no `env` field**, so a serving container cannot be told where the tracking server is — `serve.py` assumes a
Service named `mlflow` in its own namespace, which is a limitation of the CRD that this experiment records rather
than fixes.

### What this cannot show

- A real model, a real registry deployment (database, object store, authentication) or GPU serving.
- GitOps: step 4's rollback is an edit to the `InferenceDeployment`, which is what an Argo CD sync would apply,
  but no Git repository or Argo CD is in the loop.
- Rollback with more than one replica, or under load heavier than 20 requests a second.

## Amendment 1 (2026-10-09, after the first run and before the second)

A review of the committed code found that the first run's numbers could not carry two of their claims:
- **Step 4's times were send times.** `poll.py` stamped each request when it was sent, so "the last v2 answer"
  was the last request *sent* that came back v2; one sent before the rollback and answered after it was
  invisible. The poller now records completion time as well, and step 4 reads completion times.
- **Validity check 2 compared the rows with a window derived from the same rows**, so rows lost from either end
  shrank the window and passed. It now requires every sent request to be recorded and the sent count to reach 90%
  of the poller's own wall-clock window at its rate.

Nothing else changes. The whole experiment is re-run under these two corrections, and the section below is
replaced by that run's result; the first run's directory is kept as `hack/mlops-lineage-20261009T022150Z`.

## Result (2026-10-09, under Amendment 1): VALID, every reading as registered

Run `hack/mlops-lineage-20261009T023102Z`, scored by `score.py`, which printed `VALID`. The tree was `db20793` plus
the Amendment 1 changes to `poll.py`, `score.py`, `hack/mlops-lineage.sh` and this page, committed unchanged with
this record.

| step | result |
|---|---|
| 1. train | v1 0.995, v2 0.615 — the same accuracies, and the same v1 weights hash `00e666…`, as the first run |
| 2. gate | v1 promoted; **v2 refused**, alias unmoved |
| 3. lineage | all seven links held |
| 4. rollback ×3 | **0 non-200** in 921, 946 and 938 requests; the last v2 answer **completed** 11.82, 12.00 and 11.95 s after the rollback edit, the first v1 answer 10.87, 11.10 and 11.00 s after it |
| 5. alias trap | **1,202 of 1,202 answers over 60 s were still v1** after the alias moved to v2; v2 after a restart |

The slowest answer in the rollback polls took 6 ms, so on this cluster send time and completion time differ by
less than the reported precision and the first run's step-4 figures were not wrong in practice — they were
measured on the wrong clock, and a slower backend would have made that matter. The findings below were written
from the first run and hold for this one unchanged.

## Result of the first run (2026-10-09), superseded by Amendment 1

Run `hack/mlops-lineage-20261009T022150Z`, scored by `score.py`, which printed `VALID`. The tree was `1240e34`
plus this experiment's own files, uncommitted at run time and committed unchanged in `598611c`.

| step | result |
|---|---|
| 1. train | v1 0.995, v2 0.615 held-out accuracy, both registered through `MLTrainingJob` |
| 2. gate | v1 promoted; **v2 refused** (0.38 below the champion against a 0.02 allowance), alias unmoved |
| 3. lineage | the served answer named version 1, its run, and weights `00e666…`; that run carries the trainer's data hash, code hash and commit, and the weights hash matches — all seven links held |
| 4. rollback ×3 | **0 non-200** in 938, 938 and 929 requests; the last v2 answer came 12.06, 12.19 and 11.63 s after the rollback edit, the first v1 answer 11.11, 11.29 and 10.98 s after it |
| 5. alias trap | after the alias was forced to v2, **1,202 of 1,202 answers over 60 s were still v1**; after a restart, v2 |

- **A served answer can be walked back to the bytes it was trained on**, and the serving side refuses weights
  that do not match what was registered — the rehearsal showed it exits rather than serves.
- **The gate stopped the bad model; nothing stopped an operator.** Editing `storageUri` put v2 in front of users
  with no check at all, and the rollback was the same edit in reverse. The rule exists only where something calls it.
- **Rollback cost no errors, and about 11 to 12 seconds.** For roughly one second in each cycle both versions
  answered: the rolling update starts the new Pod before it removes the old one, so "rolled back" is a window,
  not an instant.
- **The registry and the cluster disagreed for as long as nobody restarted the Pod.** Moving `champion` to v2 is
  what most MLflow workflows call "deploying", and it deployed nothing: the server resolves the alias once at
  start-up. Pinning a version in the manifest is what made step 4's rollback an auditable edit.

Before this run, two launches stopped while loading images, before any step ran: `kind load` could not import the
MLflow image, first as pulled and then rebuilt `FROM` it, so the node now pulls the pinned tag itself. Neither
launch directory is kept.
