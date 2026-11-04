# Data input: does the input timer see a slow reader, on a real NFS client

Written 2026-11-04. Status: **DRAFT v3, design only; nothing below is built, run or bought.**
Engines: written by Claude from the files cited, at `dev` `59a894f5`.
v1 and v2 were each cold-attacked bare by codex `gpt-6-astra` (high): 24 findings, then 36, both "needs changes first".
The findings grew because the study grew, so v3 shrinks it to one free question and defers everything else, unregistered.
Claude re-checked each surviving finding against the code or the local `distributed-restart:torch251` image (a tag, not a pinned digest) before acting; the dispositions are at the end.
A third review of v3 still answered "needs changes first", with 23 findings on the instrument, the apparatus and provenance, listed under "Open before building"; none of them disputes the scoring rule, whose regions it found exclusive and exhaustive for finite inputs.

This is the candidate called B5 in the project's planning (kept outside the repository, so not a citable source here).
It builds on the NFS-Ganesha setup of `docs/superpowers/specs/2026-11-01-distributed-restart-design.md` and states its finding the way `docs/11_WHAT_THIS_MEASURED.md` does: paired with what it does not say.

## The one question

On a kind cluster with CPU ranks and an NFS 4.1 client mounting NFS-Ganesha, for a **single-rank** trainer reading its batches from files on that mount, **in the training process** (no worker processes, no prefetch):

> Does the host input-acquisition time `a` rise when the reader is delayed by a known amount, and fall back when the same reader runs undelayed, by more than the timer's own noise floor?

It is a test of the **instrument**, on a real NFS client, before any study is built on it.
A pass says the timer brackets the read and sees a slow one; it says nothing about how slow NFS, EFS or any storage is, and nothing about a GPU.

## What exists, and what does not

Verified at `59a894f5`:

| fact | where |
|---|---|
| The restart trainer reads no **dataset** files (it does read and write checkpoints): its 40 samples come from a seeded in-memory generator indexed directly | `experiments/distributed-restart/train.py:97`, `:456-461`, `:652` |
| Its `volume()` records the mount of one path, the global `ROOT`, and takes no argument | `train.py:43`, `:415-438` |
| The NFS-Ganesha kind setup: a privileged ganesha Pod, a static `ReadWriteMany` PV, EFS's recommended mount options; the harness recreates and deletes its own cluster | `hack/distributed-restart-kind.sh` (`:175`), `experiments/distributed-restart/README.md` "Over NFS, on kind" |
| `MLTrainingJob` runs one Pod when `distributed` is omitted, mounts at most one PVC, and sets no memory limit | `api/v1/mltrainingjob_types.go:80`, `:93`; `internal/controller/mltrainingjob_controller.go:270-271` |
| In the pinned CPU image (`distributed-restart:torch251`, torch `2.5.1+cpu`), `tensor.to("cpu")` returns the same object: no copy and no synchronisation | checked by Claude on 2026-11-04 with `docker run … python -c 't.to("cpu") is t'` → `True` |

Not in the repository: a loop that reads batches from files, an acquisition timer, a file-backed dataset generator, a runner for this study.

## Design

**Apparatus to be built (none exists).**

- `experiments/data-input/train.py`: a new file, so the registered restart trainer stays byte-identical.
  It runs one rank, CPU only, no process group, and holds a path-aware `volume(path)`.
- A generator, run as an init container **of the trainer Pod**, which writes the dataset to the NFS claim if the manifest there is absent or does not match.
  The dataset lives on the shared claim, not on an `emptyDir`, so no second Pod needs to see the files.
- hack/data-input-kind.sh: its own cluster name (never `rstnfs`, `rstlife`, `ckad`, `m6clean` or `platform`).
  It copies the ganesha setup from the restart harness, with the privileges stated, and changes no host kernel parameter.
  It runs the trainer as a plain Job with a registered memory limit.

**Dataset.**
`N` files of `S` bytes of seeded incompressible bytes.
A manifest records each file's name, size and SHA-256, and the seed.

**The loop.**
- A batch is `k` whole files in a seeded per-epoch order.
- For each file: `open`, one `read()` of the whole file, `close`, all in the training process.
- The batch is converted by `torch.frombuffer` as `uint8`, concatenated, and reduced by a sum that enters a fixed matrix-multiply workload, so every byte is consumed.
  The `.to(device)` call is a no-op on CPU (above).
- `a` is the host interval around the single call that returns the batch, by `time.monotonic()`.
  It includes the opens, reads and conversion.

**Delayed twin.**
The same trainer with `DELAY_S = d`, which sleeps `d` after each file's read, inside the acquisition call.
`d` is registered so that `k·d` is at least ten times the noise floor `n` (below).

**Cache.**
Every run begins with one discarded warm-up epoch over the whole dataset, so every measured epoch reads the same, warm, client cache state.
The result is about warm-cache acquisition and says so.

**Content gate (V5).**
- Every consumed batch's file names are recorded in order, and the bytes actually delivered to the loop are hashed per file.
- Both are compared with the manifest and the registered order.
- A run that does not match is VOID.
- Before use, the gate is shown to fail on three mutations: one file repeated, one batch skipped, the last batch dropped.

## Registration

**Unit.** A run: one Job, one variant, `E` measured epochs.
The run's statistic is the median `a` over all measured iterations.

**Block.** Three runs in a fixed order: undelayed `U1`, delayed `D`, undelayed `U2`.
The block's statistic is `Δ = a(D) − max(a(U1), a(U2))`.
This is the **one comparison** registered: it is positive and large only if `a` both rose with the delay and fell back without it.
No other contrast is scored, so there is no multiplicity to correct.

**Noise floor `n`.**
- From a separate calibration of at least six blocks of `U1, U2` only, taken before the registration commit: the largest `|a(U1) − a(U2)|` among them.
- Calibration runs are never used in the result.
- `n`, `d`, `k`, `S`, `N`, `E`, the memory limit and the block count `M` (at least six) are fixed in the registration commit.

**Outcomes.** Let `V` be the number of valid blocks (no VOID run) among the `M` run. The regions are exclusive and cover every case:

| outcome | condition |
|---|---|
| **INSUFFICIENT** | `V < 6` |
| **PASS** | `V ≥ 6` and every valid block has `Δ > n` |
| **FAIL** | `V ≥ 6` and at least `⌈V/2⌉` valid blocks have `Δ ≤ n` |
| **INCONCLUSIVE** | `V ≥ 6`, and between one and `⌈V/2⌉ − 1` valid blocks have `Δ ≤ n` |

**VOID blocks are reported, not re-run.**
Each is listed with its reason, and it counts toward `M` but not toward `V`.
No block is added after the run starts.

**Provenance.**
The result file records:
- the registration commit;
- the trainer's and generator's SHA-256;
- the image digest;
- the runner's commit;
- `git status --porcelain` of `experiments/` and `hack/` (empty).

The scorer refuses a result whose trainer or generator hash, or runner commit, differs from the registration commit's files, or whose tree was dirty.
It also reports `k·d` beside the measured `Δ`, descriptively, not as a bar.

## What this does not show

- Nothing about how slow NFS-Ganesha, EFS or any storage is: the server is one ganesha on the host's disk over a docker bridge, sharing the host's memory with the client.
- Nothing about a cold cache, worker processes, prefetch, staging, a GPU, more than one rank, or another loader (`DataLoader`, DALI, WebDataset).
- Nothing about VAST or any production storage; a supplier's public description of a customer (`vastdata.com/customers/hyundai`) is why the question is worth asking, not evidence here.

## Open before building

The third review's findings, from its headlines; none has yet been checked against the code here, so each is the review's claim until it is:
- Instrument: a PASS does not show the timer brackets the reads; `n` is a run-to-run spread, not the timer's own floor, and nothing verifies its calibration; a requested sleep `d` does not guarantee that elapsed delay; hashing and the sum have no defined place relative to the timer; timing records are not tied to the batches consumed.
- Apparatus: nothing enforces that the volume is NFS; the copied NFS setup depends on a host setting; one warm-up epoch does not show the cache state is the same; a Job can retry, so one Job need not be one run; there is no bounded failure and clean-up protocol; batch completeness and the delay arithmetic are undefined; the memory bound still applies with no workers; CPU placement is unspecified.
- Gate and provenance: the mutations do not exercise the hashing; a reused manifest can keep broken files; the manifest is not bound to the registration; recorded hashes do not show which code ran; the clean-tree check covers less than claimed.
- Scoring: every input must be checked finite before the regions apply.
- Wording: omitting `distributed` gives one Pod only by default, since parallelism and completions can be raised.

## Deferred, not registered

Each needs its own design and its own attack before it is registered, and none is implied by a pass here.

| deferred | why |
|---|---|
| R2, the producer capacity model | it omitted conversion time, did not predict a median, and used `Ch = step − a`, which contains the predicted quantity (r2 #9–#13) |
| R3, staging and the choice of `W*` | constant-epoch multiplication contradicted cold first epochs; break-even sign and uncertainty were wrong; the `W*` rule could pick a slow arm; prefetch was confounded with worker count (r2 #14–#18) |
| worker processes and prefetch | ordering across workers, death of a killed worker, the memory bound, and the queue's use of semaphores in `/dev/shm` were all unresolved (r2 #2–#4, #6) |
| cold-cache labels | `diskstats` and mount counters could not establish dataset residency (r2 #22–#23) |
| the paid GPU calibration session and the confirmatory EKS stage | CUDA timing semantics (r2 #7, #21) and EFS's one-minute, filesystem-wide CloudWatch metrics could not assign a run its own credit state (r2 #29–#31) |
| every EFS credit, metering and billing claim | the v2 claims misclassified staging reads as writes and the cost bound was incomplete (r2 #32–#33) |

## Revision record

**v1 → v2:** 24 findings, 23 accepted and one partly (the API reason, corrected in v2's re-attack); most concerned parts now deferred.

**v2 → v3:** the r2 findings that still apply to the narrowed study:

| r2 # | finding | disposition |
|---|---|---|
| 1 | `emptyDir` is per Pod | accepted on Kubernetes' documented volume semantics (not re-run here); resolved: the generator is an init container of the trainer Pod and writes to the NFS claim |
| 2 | worker order breaks V5 | resolved by `W = 0`: no workers |
| 3 | a killed worker cannot report | resolved by `W = 0` |
| 6 | `/dev/shm` and semaphores | resolved by `W = 0`: no `multiprocessing` queue |
| 7 | `.to()` synchronises | on CPU it is a no-op: checked by Claude in the local `distributed-restart:torch251` image, `t.to("cpu") is t` is `True`; no transcript is archived |
| 20 | content gate hashed the source files, not what the loop received | accepted: V5 hashes the delivered bytes |
| 24–28 | verdict regions, confidence, multiplicity, VOID re-runs | accepted: one fixed statistic, exclusive count regions, no re-runs |
| 35 | provenance not bound | accepted: hashes, commit and clean tree, refused by the scorer |
| 36 | `MLTrainingJob` can run one Pod | accepted in v2, verified at `api/v1/mltrainingjob_types.go:93`; a plain Job is used here only for the memory limit |
| all others | — | moot after narrowing |
