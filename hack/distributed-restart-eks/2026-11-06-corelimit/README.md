# Paid distributed-restart session, `corelimit` stage, 2026-11-06 (UTC)

The fourth paid run of the distributed-restart apparatus, the one registered in `docs/superpowers/specs/2026-11-06-restart-corelimit-design.md`, approved by the owner on 2026-11-06 ("유료 승인, 전부 병렬 수행", then "권장안으로 진행" for the accepted state-lock risk).
Three g5.xlarge (one A10G each) in an EKS cluster in ap-northeast-2a, CUDA ranks with NCCL, an EFS volume, `hack/eks-gitops-session.sh` with `TRAIN=restart RESTART_STAGE=corelimit`, every paid step under the phase supervisor.

Two launches:
- `launch-1-stopped-at-r2/`, 08:41Z to 09:26Z, from `96140a8c`.
  R2 failed before any GPU was bought: the webhook refused the missing claim, but kubectl rendered the refusal as `The MLTrainingJob ... is invalid: ...`, and the check accepted only the API server's `denied the request` wording.
  The session destroyed the cluster itself, and every residue query was empty; the check was fixed in #509.
- `session/`, 09:47Z to 10:48Z, from `db5a2303`, the run below.
  The session's checks reported no FAIL, the destroy returned zero, and every residue query was empty; an independent query of the region afterwards found no instance, cluster, NAT gateway, volume, EFS file system, EIP or GPU schedule.

## Verdicts

From `session/restart/verdict.txt`, rescored from a clean checkout of `41c4fe54` with the committed scorer: identical, exit 0.
The run's provenance: a clean tree at `db5a2303`, the approved `train.py` (`2c5cdbf0…`), collective timeout 60 s, rendezvous timeout 600 s, case budget 720 s (`session/restart/provenance.txt`).
The operator was the registered one: `session/session.log` R2, and R2 again after R4, read revision `44bd5e74…` running digest `sha256:12d60cfc…`.

| case | arm | verdict | class | resumed from | recovery | lost steps | final parameters vs reference |
|---|---|---|---|---|---|---|---|
| reference | — | ACCEPTED | — | — | — | — | — |
| rank-kill-1 | inherited | ACCEPTED | same-nodes | step 11 | 47.267 s | 1 | equal |
| rank-kill-2 | 0 | ACCEPTED | same-nodes | step 11 | 8.713 s | 1 | equal |
| rank-kill-3 | inherited | ACCEPTED | same-nodes | step 11 | 45.763 s | 1 | equal |
| rank-kill-4 | 0 | ACCEPTED | same-nodes | step 11 | 8.017 s | 1 | equal |
| rank-kill-5 | inherited | ACCEPTED | same-nodes | step 11 | 46.920 s | 1 | equal |
| rank-kill-6 | 0 | ACCEPTED | same-nodes | step 11 | 8.794 s | 1 | equal |
| dcgm-1 | inherited | ACCEPTED | spare | step 11 | 7.836 s | 0 | equal |
| dcgm-2 | inherited | ACCEPTED | spare | step 12 | 7.863 s | 0 | equal |
| dcgm-3 | inherited | ACCEPTED | spare | step 12 | 6.854 s | 0 | equal |

The scorer's summary, by arm and never pooled:
- rank-kill, core limit 0: median 8.7 s, range 8.0 to 8.8 s, lost steps [1, 1, 1].
- rank-kill, core limit inherited: median 46.9 s, range 45.8 to 47.3 s, lost steps [1, 1, 1].
- dcgm, spare: median 7.8 s, range 6.9 to 7.9 s, lost steps [0, 0, 0].
- Checkpoint cost: median 0.265 s, max 0.665 s, over 600 per-rank saves to EFS.

## H2

`experiments/distributed-restart/h2_corelimit.py` on `session/restart`, from the same clean checkout: **H2 SUPPORTED**, "every d is at most 15 s with core dumps off and at least 30 s without".

| case | arm | ranks logged | `d` | survivor's end | finished after the fault | deletion asked after the fault, grace |
|---|---|---|---|---|---|---|
| rank-kill-1 | inherited | `unlimited` | 39 s | exit 137 | 33.2 s | 2.2 s, 30 s |
| rank-kill-3 | inherited | `unlimited` | 38 s | exit 137 | 32.0 s | 2.0 s, 30 s |
| rank-kill-5 | inherited | `unlimited` | 38 s | exit 137, from the Pod watch | 33.3 s | 2.3 s, 30 s |
| rank-kill-2 | 0 | `0` | 1 s | exit 134 | 0.4 s | 2.4 s, 30 s |
| rank-kill-4 | 0 | `0` | 1 s | exit 134 | −0.1 s | 1.9 s, 0 s |
| rank-kill-6 | 0 | `0` | 0 s | exit 134 | 0.2 s | 3.2 s, 0 s |

Every attempt-1 rank of every case logged `core_pattern=|/usr/lib/systemd/systemd-coredump %P %u %g %s %t %c %h`, the pipe the registration assumed, with `%c`, so the treated arm counts under its treatment-validity rule.
`rank-kill-5`'s survivor's streams ended without its container's end, the race the first pre-launch review found; the Pod watch gave it.
The finish and deletion times are differences of uncorrected stamps on different clocks (the faulted node, the survivor's kubelet in whole seconds, the API server); they separate tens of seconds from a few, nothing finer.

Read as the registration says it may be read:
- SUPPORTED says that, on these nodes, setting the ranks' core limit to 0 shortened `d`, three cases against three.
- The stop after the fault was shorter too, not only `d`: the treated survivors finished within a second of the fault, the untreated ones 32 to 33 s after it (`phases_eks.py`: stop barrier satisfied at a median of +3.3 s against +41.3 s).
- With the limit at 0 the survivor ended by its own abort, exit 134, within a second; with the node's limit it did not end by itself, and exit 137 came about 30 s after its deletion was asked for, the Pod's grace.
  That is what a core dump still being written when the grace ran out predicts; 137 alone does not say who sent the SIGKILL or that a dump was in progress, and this run collected no host-side record of one.
- The treated survivors' logs end `Aborted (core dumped)`, though every one logged `core_limit=0`: the shell reports the kernel's core-dump flag from the wait status.
  Linux 6.12's `elf_core_dump` returns that flag as soon as it has filled in the notes, before it writes anything (`has_dumped = 1` in `fs/binfmt_elf.c`), so the flag says the kernel started a dump, not that one was stored; under the pipe the limit acts through `systemd-coredump`, as the registration says.
  So the treatment did not keep the kernel from starting a dump; what it removed is what followed, which is where the untreated survivors spent the grace.
  The untreated survivors' logs carry no such line: their shells were killed with them.
- In this run's untreated cases the 38 to 39 s are mostly the Pod's 30 s grace: the deletion was asked about 2 s after the fault, the survivor ended about 30 s after that, and the stop barrier was satisfied 7 to 9 s later still (`phases_eks.py`: stopped at +40.1 to +42.2 s); in the treated cases the barrier followed the survivor's end by about 3 s.
  `full`'s and `retarget`'s rank-kill stops were the same size, 38 and 39 s, which suggests the same composition; neither run recorded the survivor's end, so it is not shown for them.

## Who established what

- The figures above are the committed scorer's and `h2_corelimit.py`'s, run from the clean checkout of `41c4fe54`; the tables are copied from their output.
- gpt-6-astra, asked to re-derive them from the raw files without running either script, reached every `d`, survivor end, deletion request, recovery and arm summary above, and H2 SUPPORTED; it found no number in the archive to disagree with.
- It pointed out the treated survivors' `Aborted (core dumped)` lines; the reading of them above is from the kernel source, checked in this session, not from it.

## Cost

An estimate, not billing data:
- GPUs: three g5.xlarge launched 10:05:54Z and terminated 10:31:15Z, 10:32:15Z and 10:32:15Z (CloudTrail), 78.05 instance-minutes at $1.237/h: $1.61.
- The rest (control plane, CPU node, NAT, EFS), both launches, 104.8 minutes at the registration's $0.263/h: $0.46.
- Data through the NAT, EFS and IPv4: at most the registration's $0.71.
- About $2.1 to $2.8 for the stage, inside the registration's expected $3 to $5.

## What this does not show

- Which part of the dump held the survivor: the kernel's work before the helper declines, the pipe, or `systemd-coredump`'s; no host-side record was collected.
- That a core dump is what an untreated survivor was doing when it was killed, beyond being what the two arms' difference predicts.
- Whether a shorter `terminationGracePeriodSeconds` or `TORCH_NCCL_ASYNC_ERROR_HANDLING` would shorten the stop as well; neither was varied.
- A rate or a tail: three cases per arm.
- The cost of turning core dumps off: a crash leaves no core to debug.

The status timelines and Pod watches are committed compressed (`timeline.jsonl.xz`, `pod-watch.json.xz`); `runbook-verify/*.out` are not committed, as in the earlier sessions.
