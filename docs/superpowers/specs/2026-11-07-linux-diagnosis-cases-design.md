# Linux diagnosis cases: memory limits, OOM and the kernel log (M-42A-5)

Written 2026-11-07, before any scored run.
Status: **design; not yet run.**
This is item M-42A-5 of the operations track in `docs/superpowers/specs/2026-10-31-inference-portfolio-roadmap.md`: "cgroup v2 memory limits and OOM, GPU memory exhaustion, reading Xid from kernel logs, reproduced and written up".
The owner asked for it on 2026-11-07 ("42dot의 남은 두 항목 … 현재 gpuaas 개발에서 진행").

## What it is for

An operator paged for a training or serving Pod that died, or did not die, has three sources: the Pod's status, the container's cgroup, and the kernel log.
They disagree in ways that matter, and each case below is chosen so that one source misleads.
Each case is reproduced on kind, the three sources are captured, and a checker states what each source said.
The write-up is a diagnosis table: symptom, the source that misleads, the source that settles it, and the command.

It licenses statements about kubelet, containerd and cgroup v2 at the versions and kernel recorded with the run.
It does not license statements about node-pressure eviction, swap, or any GPU behaviour; those are under "Not covered".

## What two spikes already showed (2026-11-07, one run each, not scored)

The Pod: PID 1 is `sh`, which starts a Python child that allocates 256 MiB under a 128 Mi limit, then prints and sleeps.

| | kind v1.31.0, kubelet default | kind v1.37.0, `singleProcessOOMKill: true` |
|---|---|---|
| `memory.oom.group` in the container | (not read: the whole container died first) | `0` |
| child | killed | killed, `exit=137` printed by the parent |
| parent `sh` | killed by the kernel ("going to be killed due to memory.oom.group set") | survives, prints `parent-done` |
| container `exitCode` | 137 | **0** |
| Pod phase | Failed | **Succeeded** |
| container `reason` | OOMKilled | **OOMKilled** |
| `memory.events` | (not read) | `oom 0`, `oom_kill 1` |

A Pod that **succeeded with exit code 0 still carried `reason: OOMKilled`**: containerd sets the reason from the cgroup's OOM event, not from how PID 1 ended.
An alert on `reason == OOMKilled` and an alert on a non-zero exit disagree about this Pod, and both read the API correctly.

Two more things the kernel lines showed, which the design below now captures instead of assuming:
- `oom_memcg` (the cgroup whose limit was exhausted) was the **Pod's** slice, while `task_memcg` (the victim's) was the container's scope; with one container, the Pod slice carries the same 128 Mi and slightly more usage, so its limit is the one hit.
  `memory.events` inside the container read `oom 0` because the container's own limit was not the one exhausted, and `oom_kill 1` because a process in it was killed.
- The kernel line names the container by `cri-containerd-<id>.scope` and the Pod by `kubelet-kubepods-pod<uid>.slice`, which joins it to the API.

A second spike (v1.31, one run each) for the tmpfs and page-cache cases gave: tmpfs case `Failed`, 137, `OOMKilled`; the kernel's line for the killed `dd` read `anon-rss:1132kB, shmem-rss:0kB`, while the memory-cgroup statistics the kernel printed in the same report read `shmem 131420160`; the tmpfs was sized at 131072 KiB, the container's limit.
Page-cache case `Succeeded`, `memory.current` 133697536 of 134217728, `file` 131878912 of which `inactive_file` 131862528, `memory.events max 170`, `oom_kill 0`.
The kubelet's summary returned zeros for that Pod twelve seconds after creation (cAdvisor's housekeeping interval is 10 s by default).

These are spike observations; only the harness's output below is cited.

## Clusters

Two clusters from one image, `kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5`, differing in one kubelet field:
`lddiag-group` with `singleProcessOOMKill: false` (the default, which makes the kubelet set `memory.oom.group=1`) and `lddiag-single` with `singleProcessOOMKill: true`.
The harness reads the effective kubelet configuration from `/configz` and refuses to run a case on a cluster whose value is not the intended one.
v1.31, which the shared `platform` cluster runs and which has no such field, behaves as `false`; the spike above is the only evidence of that and the write-up says so.
The harness creates both clusters and deletes them at the end; `platform`, `ckad` and `m6clean` are never used, because a case that kills processes on purpose has no business on a cluster other work depends on.
Recorded per run: kernel version, containerd version (`containerd --version` in the node), kubelet version, and the image's resolved digest and architecture from `crictl inspecti`.

## Cases

Every case is one Pod with `restartPolicy: Never`, one container limited to 128 Mi memory and 500m CPU, and the image `python@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9` (python 3.12-slim, pulled by that digest from Docker Hub; the spike pulled it on a fresh node).
Each workload is a shell script in the Pod spec that prints a `begin` marker, does its one thing, and, if it is still alive, prints its cgroup files between markers.
Allocation and I/O are bounded: Python allocates with `bytearray` (zero-filled, so touched), and files are written and read with `dd bs=1M`, whose record counts are checked.

| id | cluster | workload | the source that misleads | the source that settles it |
|---|---|---|---|---|
| C1 | group | PID 1 is Python and allocates 256 MiB | none; the baseline | — |
| C2a | group | PID 1 is `sh`; a Python child allocates 256 MiB; the shell then prints `parent-done` | the log: it ends without the shell's lines, as if the script stopped | the kernel's "going to be killed due to memory.oom.group set" line and a `Killed process … (sh)` line |
| C2b | single | the same Pod | the phase and exit code: `Succeeded`, 0 | `reason: OOMKilled`, `memory.events oom_kill 1`, and one `Killed process … (python3)` line |
| C3 | group | `sh` runs `dd` writing 192 MiB into an `emptyDir` with `medium: Memory` | the kernel's `Killed process` line: no process is large | the memory-cgroup statistics block of the same kernel report: `shmem` holds the limit |
| C4 | group | `sh` writes 512 MiB to a disk-backed `emptyDir`, reads it back with `dd`, then sleeps 40 s | `memory.current` at the limit and `memory.events max` > 0 | `oom_kill 0` in the container, no OOM report for the Pod, and `workingSetBytes` = usage − `inactive_file` far below usage |

## What is captured per case

- the Pod's status as JSON once a second from creation until 10 s after it ends, so a reason that arrives late is seen (containerd sets `OOMKilled` from a `TaskOOM` event, asynchronously to PID 1's exit);
- the container's log;
- from inside the container, where it is still alive: `memory.max`, `memory.current`, `memory.peak`, `memory.oom.group`, `memory.events` and `memory.stat`, printed by the workload;
- for C4 only, the kubelet's `/stats/summary` entry for the container, polled every 2 s during the 40 s sleep, keeping each sample's own `time` field;
- the host's kernel journal from 1 s before creation to 10 s after the end (`journalctl -k -o short-monotonic --since @… --until @…`), its exit status recorded apart from any filter.

## The checker

`hack/linux-diag/check.py` reads a run directory and writes `verdict.json`.
It parses each kernel OOM report as one record: the `invoked oom-killer` line, the `memory: usage … limit …` line, the statistics block, the `oom-kill:constraint=…,oom_memcg=…,task_memcg=…,task=…,pid=…` line, any `going to be killed due to memory.oom.group set` line, and every `Killed process` line up to the next report.
A record belongs to a case when its `task_memcg` names the case's container ID; `oom_memcg` is reported beside it as the limit that was hit.

Two outcomes are kept apart:
- **INVALID**: the instrumentation did not see the case. The journal read failed; the Pod never started; the case's expected cluster setting was not in effect; the workload's `dd` record counts show the I/O did not complete (C3 is exempt: its `dd` is the victim); for C4, fewer than three summary samples with distinct `time` fields after the workload's read finished.
- otherwise the case is **observed**, and for each expected reading the checker says **held** or **did not hold**, with the value seen.

Every scheduled repetition is reported, three per case, including invalid ones, with no re-run to replace one.
A case is summarised as "held in N of 3"; disagreement between repetitions is a result, not a refusal.

Expected readings, numerically:

| case | expected |
|---|---|
| C1 | phase `Failed`, exit 137, reason `OOMKilled`; one OOM record with `task=python3` |
| C2a | phase `Failed`, exit 137, reason `OOMKilled`; the record has the `memory.oom.group` line and `Killed process` lines for both `python3` and `sh`; the log has no `parent-done` |
| C2b | phase `Succeeded`, exit 0, reason `OOMKilled`; the log has `child-exit=137` and `parent-done`; `memory.oom.group` 0 and `oom_kill` 1 in the container; the record has no `memory.oom.group` line and one `Killed process` line, for `python3` |
| C3 | phase `Failed`, exit 137, reason `OOMKilled`; the victim's `anon-rss` plus `shmem-rss` under 16 MiB; the statistics block's `shmem` at least 96 MiB |
| C4 | phase `Succeeded`, exit 0, reason `Completed`; `dd` wrote and read 512 records; `oom_kill` 0 and `max` ≥ 1 in the container; no OOM record naming the container; `memory.current` ≥ 90% of `memory.max` at the end; median `workingSetBytes` of the valid samples ≤ 50% of the median `usageBytes` |

For C4, "no OOM record" is reported as "no matching journal record", and is believed together with the container's own `oom_kill 0` read after the workload finished, not on its own.

Every rule is pinned by a test in `hack/test/check-linux-diag.sh` against fixtures cut from the run's own output, and each rule is mutated once to show its test goes red.

## Not covered

- **Node-pressure eviction.** Producing it on kind means pressing the host's memory, which this workstation shares with other work.
- **GPU memory exhaustion and Xid in the kernel log.** Neither exists without a GPU.
  Both go into the next paid session's (M-42A-7) spare minutes as descriptive captures: a CUDA allocation past the card's memory in a Pod, recording the framework's error, the Pod's status and `nvidia-smi`; and `journalctl -k` filtered for `NVRM` on every GPU node, expected to hold no Xid since nothing is induced.
  A reader for Xid lines is not written until a real line exists to cut its fixture from: two earlier fixtures written from documentation instead of captured output were wrong, and one voided a paid run.
- **Swap**, `memory.high` throttling, and `oom_score_adj` choices between containers.

## Review before the run

gpt-6-astra read the first draft on 2026-11-07, without direction, and returned ten findings.
Taken: the case C3 witness (the victim's `shmem-rss` cannot show tmpfs, so the statistics block is read), the limit that was hit (`oom_memcg`) reported apart from the victim, C4's sample timing and its numeric thresholds, C2 compared on one image with the setting alone varied, the Pod status polled over time, every repetition reported with invalid kept apart from "did not hold", "no matching journal record" as the wording, and bounded, checked I/O.
Not taken: that the image digest is a local image ID and not pullable. `docker image inspect` gives the same value as both the ID and the repository digest under the containerd image store, and the spike's fresh node pulled it by that digest from Docker Hub.
