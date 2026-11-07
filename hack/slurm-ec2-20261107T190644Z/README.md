# Slurm on EC2, run 2 (2026-11-08): every registered check held

The registration is `docs/superpowers/specs/2026-11-07-slurm-ec2-session-design.md`; the runner is `hack/slurm-ec2-session.sh` at `236779da` (`session-provenance.txt`).
One t3.medium head and two g5.xlarge workers (one A10G each), Spot, ap-northeast-2a, T0 2026-11-07T19:09:03Z.
`verdict.txt` and `verdict.json` are the scorer's output; re-running `python3 hack/slurm-ec2/score.py evidence v.json` on this directory gives the same ten lines.

| Check | What held | Reading |
|---|---|---|
| B1 ×4 | a job given one GPU sees exactly one A10G and runs a CUDA op; a job given none sees no device and is refused `/dev/nvidia0` with EPERM | `No CUDA GPUs are available` in the unallocated job |
| B2 ×3 | a job over its memory limit ends OUT_OF_MEMORY, its cgroup's `oom_kill` is at least 1, the kernel report names its cgroup, slurmd keeps its PID and the node stays up | `oom_kill` 1, slurmd PID 4229 before and after |
| B3a, B3b | with an account GPU limit of 1, the second job pends with `AssocGrpGRES` and starts when the first ends | reason seen 3.0 s after submission, start gap 0.0 s |
| B4 | after an Xid 79 is written to gpu1's health signal, gpu1 drains, the job requeues once onto gpu2, resumes one step after the last checkpoint and ends with the reference run's parameters | drained 4.1 s after the write, resumed at step 36 from step 35, max abs diff 0.0 |

The run cost about $0.45 at the launch-time Spot prices in `spot-prices.txt` (two g5.xlarge at $0.5804/h and one t3.medium at $0.0176/h for about 22 minutes); this is an estimate, not a billed figure.
All three instances were confirmed terminated (`termination.txt`), and the three root volumes in `volumes.txt` were each answered `InvalidVolume.NotFound` afterwards.

## Run 1 did not get this far

Run 1 (2026-11-07, `a7714d2c`) scored every check NOTRUN: both workers waited 21 minutes for a `CONF_READY` file the head had written on the NFS share and never saw it.
That run's evidence is kept outside the repository; a real-NFS rehearsal on three t3 instances showed the same marker after the normal 60 s directory cache, so its cause is not established.
Run 2 differs in that the start and end signals travel over S3 with acknowledgements, every write is checked, the workers mount with `vers=4.1,lookupcache=positive`, and each host ships its own diagnostics (`diag/`).

## What this does not show

One run of each check on one pair of A10G nodes; Slurm 23.11 from the Ubuntu archive, not a site build; a GPU fault written into the health signal, not a real Xid; no Pyxis/Enroot, no multi-node jobs.
