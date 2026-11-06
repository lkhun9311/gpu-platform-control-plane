# Linux diagnosis cases: memory limits, OOM and the kernel log (M-42A-5)

Written 2026-11-07, before any scored run.
Status: **design; not yet run.**
This is item M-42A-5 of the operations track in `docs/superpowers/specs/2026-10-31-inference-portfolio-roadmap.md`: "cgroup v2 memory limits and OOM, GPU memory exhaustion, reading Xid from kernel logs, reproduced and written up".
The owner asked for it on 2026-11-07 ("42dot의 남은 두 항목 … 현재 gpuaas 개발에서 진행").

## What it is for

An operator who is paged for a training or serving Pod that died, or did not die, has three sources: the Pod's status, the container's cgroup, and the kernel log.
They disagree in ways that matter, and the cases below are chosen so that each one has a source that misleads.
Each case is reproduced on kind, its three sources are captured, and a checker states what each source says.
The write-up is a diagnosis table: symptom, the source that misleads, the source that settles it, and the command.

It licenses statements about kubelet, containerd and cgroup v2 on the kernel and versions recorded below.
It does not license statements about node-pressure eviction, swap, or any GPU behaviour; those are named under "Not covered".

## What a spike already showed (2026-11-07, not scored)

Two throwaway clusters, the same Pod: PID 1 is `sh`, which starts a Python child that allocates 256 MiB under a 128 Mi limit, then prints and sleeps.

| | kind v1.31.0, kubelet default | kind v1.37.0, `singleProcessOOMKill: true` |
|---|---|---|
| `memory.oom.group` in the container | (not read: the whole container died first) | `0` |
| child | killed | killed, `exit=137` printed by the parent |
| parent `sh` | killed by the kernel ("going to be killed due to memory.oom.group set") | survives, prints `parent-done` |
| container `exitCode` | 137 | **0** |
| Pod phase | Failed | **Succeeded** |
| container `reason` | OOMKilled | **OOMKilled** |
| `memory.events` | (not read) | `oom 0`, `oom_kill 1` |

The right-hand column is the point: a Pod that **succeeded with exit code 0 still carries `reason: OOMKilled`**, because the reason comes from the cgroup's OOM event, not from how PID 1 ended.
A dashboard that alerts on `reason == OOMKilled` and one that alerts on a non-zero exit disagree about this Pod, and both are reading the API correctly.
The kernel line names the container by its `cri-containerd-<id>.scope`, which joins it to the Pod's `containerID`.

These are observations from one run each; the harness below re-collects them and only its output is cited.

## Cases

Every case runs as one Pod with `restartPolicy: Never`, a 128 Mi memory limit, and the image `python@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9` (python 3.12-slim), pulled by digest.
Each case runs three times; a case's outcome must be the same in all three to be reported.

| id | cluster | what the workload does | what an operator would see first | what settles it |
|---|---|---|---|---|
| C1 | v1.31 default | PID 1 allocates past the limit | `OOMKilled`, 137 | consistent; the baseline every other case is read against |
| C2a | v1.31 default | a child allocates past the limit, PID 1 is a shell | `OOMKilled`, 137, and the shell's own output after the child is missing | the kernel's `memory.oom.group` line: the shell was killed for its child |
| C2b | v1.37, `singleProcessOOMKill: true` | the same Pod | `Succeeded`, exit 0 | `reason: OOMKilled` and `memory.events oom_kill 1`: a process died and the job did not notice |
| C3 | v1.31 default | PID 1 writes 192 MiB into an `emptyDir` with `medium: Memory`, holding almost no heap | `OOMKilled` for a process whose heap is small | the kernel line's `shmem-rss`, and `memory.stat shmem`: tmpfs pages are charged to the container |
| C4 | v1.31 default | PID 1 writes 512 MiB to a disk-backed `emptyDir` and reads it back | a usage graph near the limit | no OOM: `memory.stat file` holds the bulk, and the kubelet's `workingSetBytes` stays well under `memory.current` |

C2a and C2b differ in the kubelet setting and the Kubernetes version together; the version difference is not separated from the setting, and the write-up says so.
`singleProcessOOMKill` does not exist in v1.31's kubelet, which is why two versions are needed.

## Clusters

Two clusters created by the harness and deleted by it at the end: `lddiag31` from `kindest/node:v1.31.0@sha256:25a3504b2b340954595fa7a6ed1575ef2edadf5abd83c0776a4308b64bf47c93` with the default kubelet configuration, and `lddiag37` from `kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5` with `singleProcessOOMKill: true`.
The shared clusters (`platform`, `ckad`, `m6clean`) are never used: a case that kills processes on purpose has no business on a cluster other work depends on.
The kernel is the host's (kind nodes are containers); its version and `memory.oom.group` behaviour are recorded per run.

## What is captured per case

- the Pod's final status as JSON (`kubectl get pod -o json`);
- the container's log;
- from inside the container, written by the workload's own shell before it exits where it still can: `memory.max`, `memory.current`, `memory.peak`, `memory.oom.group`, `memory.events` and `memory.stat`;
- the kubelet's `/stats/summary` entry for the Pod, polled every second while it runs;
- the host kernel journal from one second before the Pod was created to its end (`journalctl -k -o short-monotonic`), with the exit status of `journalctl` recorded apart from any filter.

A case whose PID 1 is killed cannot report its own cgroup files afterwards; for C1, C2a and C3 those come from the kernel line and the Pod status only, and the checker does not demand them.

## The checker

`hack/linux-diag/check.py` reads one run directory and writes `verdict.json`: for each case, each source's reading, and whether the case's expected readings (the table above) all hold in all three repetitions.
It refuses, rather than reports, a case:

- whose kernel journal read failed or held no `Memory cgroup out of memory` line when the case expects one;
- whose kernel line names a container ID that is not the Pod's;
- whose repetitions disagree;
- whose `journalctl` window overlaps another case's (cases run one at a time, so this would mean the harness is wrong).

C4 expects **no** kernel OOM line for its container; an unreadable journal is a refusal there too, because "absent" from a log that was not read is not "did not happen".

Every rule is pinned by a test in `hack/test/check-linux-diag.sh` against fixtures cut from a real run, and each rule is mutated once to show its test goes red.

## Not covered

- **Node-pressure eviction.** Producing it on kind means pressing the host's memory, which this workstation shares with other work.
- **GPU memory exhaustion and Xid in the kernel log.** Neither exists without a GPU.
  Both go into the next paid session's (M-42A-7) spare minutes as descriptive captures: a CUDA allocation past the card's memory in a Pod, recording the framework's error, the Pod's status and `nvidia-smi`; and `journalctl -k` filtered for `NVRM` on every GPU node, expected to hold no Xid since nothing is induced.
  A reader for Xid lines is not written until a real line exists to cut its fixture from: two earlier fixtures written from documentation instead of captured output were wrong, and one voided a paid run.
- **Swap**, `memory.high` throttling, and `oom_score_adj` choices between containers.
