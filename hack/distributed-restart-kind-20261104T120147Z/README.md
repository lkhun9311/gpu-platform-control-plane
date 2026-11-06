# Directed kind cases of the restart trainer's fixes after the paid full stage, 2026-11-04 (commit e8b8410e)

The registration said the trainer's checkpoint fallbacks and its one rendezvous deadline "ran only on their normal
paths": neither paid stage, nor any kind run, had induced the failures they were fixed for.
These runs induce each of them through a whole-job restart on kind, with two CPU/gloo ranks sharing an NFS-Ganesha volume
mounted with the EFS options (`hack/distributed-restart-kind.sh`, `STORAGE=nfs`), and score them with
`experiments/distributed-restart/score_kind.py`.
`hack/test/check-restart-directed-kind.sh` pins every verdict below from the committed files.

Four runs, each on a fresh cluster from a clean commit, differing only in the trainer the workload image carries
(`provenance.txt`, `trainer_rev` and `train_py_sha256`):

| run | trainer | cases | verdict |
|---|---|---|---|
| `hack/distributed-restart-kind-20261104T120147Z` (this) | the tree's, sha256 `2c5cdbf0...f53f572c` | reference and all six | all checks passed |
| `hack/distributed-restart-kind-20261104T122732Z` | before #490 (`8d3c83c1`, `2db31cbd...`, the full stage's) | reference and the three fallbacks | 15 failed, as it must |
| `hack/distributed-restart-kind-20261104T124600Z` | before the rendezvous setting (`d1e8a0ba`) | reference, late and never | 9 failed, as it must |
| `hack/distributed-restart-kind-20261104T113421Z` | the tree's, at `697d6d1b` | the first run, its spoil made below the server | 3 failed; superseded |

## The cases

Every case kills rank 0 right after step 6 is published, holds attempt 1's Workload until the storage has been read, and
then releases it; what differs is what attempt 2 meets.

| case | what attempt 2 meets | tree's trainer | trainer without the fix |
|---|---|---|---|
| `nfs-fallback-malformed` | step 6's manifest parses but its shards are `[{}, {}]` | both ranks pass over step 6 together and resume from step 5, ending with the reference's parameters | rank 0 raises `KeyError: 'rank'` out of the search; the job fails |
| `nfs-fallback-otherdir` | step 6's manifest names another checkpoint's uuid | both pass over it and resume from step 5 | takes it for step 6 and resumes from step 6 |
| `nfs-fallback-unreadable` | a directory where rank 1's shard was | rank 1's read fails with errno 21, both pass over step 6 together and resume from step 5 | rank 1 raises `IsADirectoryError`; the job fails |
| `nfs-rendezvous-late` | one worker for two ranks; the peer let in 420 s after the first rank started | the peer started 421 s later, both resumed from step 6 and finished, 448 s after the job's creation | the first rank gave up at 61 s ("1/2 clients joined"); the job fails |
| `nfs-rendezvous-never` | the peer never let in | the lone rank waited 602 s and failed, 614 s after the job's creation | the lone rank gave up at 62 s |
| `nfs-rendezvous-never-unset` | the same, without `CKPT_RENDEZVOUS_TIMEOUT` | the lone rank gave up at 62 s: the control, the collective timeout bounding the join | not run |

The settings are the paid session's: `CKPT_RENDEZVOUS_TIMEOUT=600` and `CKPT_COLLECTIVE_TIMEOUT=60`.
The registration's case budget, 720 s from the job's creation, holds both rendezvous cases as built here.
The late peer is let in at 420 s, inside the 600 s join and far past the 60 s, so the late case finishes in 448 s.
The never case fails at 614 s, so it ends as a failed attempt and not as a case censored at its budget.
The harness waits up to 900 s for them, so its own wait decides neither.

In the never cases the lone rank's exit frees its GPU, and the waiting peer is then scheduled on it: it starts 2 s later
into an attempt already failing, and is killed 30 s after that.
The scorer counts that as never joining only because it started after the lone rank ended, and fails a recorded peer
whose start time is missing (codex review of e8b8410e).

## What changed while getting here

- The first run (`...T113421Z`) spoiled step 6 in the server's export directory, below NFS-Ganesha.
  The server's cache went on naming rank 1's shard as published, and attempt 2's rank 1, on a node that had never looked
  the shard up, read it whole and resumed from step 6; its unreadable case failed for that reason, not the trainer's.
  The spoil now goes through an NFS client on the worker attempt 1 left idle (`nfs_probe.py spoil`).
- These runs' samples over the 600 s cases are 7 to 11 MB a run, so the timelines are committed xz-compressed, and
  `score_kind.py` now reads them, as `score_eks.py` reads the paid archives'.
  Every run scores the same compressed as plain; the scorer before that change failed 6 checks of this run compressed.

## What this does not show

- No GPU, NCCL, EFS or EC2: gloo on CPU over one host's NFS-Ganesha, mounted with the EFS options.
- One run of each case: an observation that the path works and that the earlier trainer did not, not a rate.
- What #490 itself changed in the join is not what the never case separates: a peer that never connects fails at the
  store's construction under either trainer.
  #490 changed the bound for a peer that connects to the store late and then never joins its barrier, which
  `experiments/distributed-restart/check_rendezvous.py` covers locally; inducing that on kind needs a process speaking to
  rank 0's store from inside the cluster, which these runs do not have.
- So the trainer before the rendezvous setting is the control for the late and never cases, and those two show what the
  setting buys, not what #490 added to it.
- Every spoil is made while no rank runs; a checkpoint damaged while attempt 2 reads it is not tried.
