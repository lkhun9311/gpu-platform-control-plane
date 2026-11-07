# Linux diagnosis cases: memory limits, OOM and the kernel log — the results

The design, written before the scored run, is `docs/superpowers/specs/2026-11-07-linux-diagnosis-cases-design.md`.
The run is `hack/linux-diag-20261106T230435Z/` (2026-11-06 23:04 UTC, 2026-11-07 08:04 KST), scored by `hack/linux-diag/check.py`; `hack/test/check-linux-diag.sh` pins every rule of the checker against copies of this run with one thing changed.
Two throwaway kind clusters, both `kindest/node:v1.37.0` (containerd v2.3.4, host kernel 7.0.0-31), differing only in the kubelet's `singleProcessOOMKill`, read back from `/configz` before every case.
Every case: one Pod, one container, a 128 Mi memory limit, three repetitions interleaved across cases.

## The headline

**A Pod can succeed with exit code 0 and still say `reason: OOMKilled`.**
With `singleProcessOOMKill: true`, a child process killed for memory leaves the container's main process running; the job finishes, the Pod is `Succeeded` with exit 0, and the container's terminated `reason` is `OOMKilled`, because containerd sets the reason from the cgroup's OOM event, not from how the main process ended.
An alert on a non-zero exit and an alert on `reason == OOMKilled` disagree about this Pod, and both read the API correctly.
With the default (`false`), the kubelet sets `memory.oom.group=1` and the kernel kills every process in the container for the child's allocation: the same workload ends `Failed`, 137.

## Every case held in 3 of 3, none invalid

| case | cluster | what the workload did | what the Pod said | what settled it |
|---|---|---|---|---|
| C1 | group | Python as PID 1 allocates 256 MiB | `Failed`, 137, `OOMKilled` | one kernel report, `task=python3` (the baseline) |
| C2a | group | a shell starts a Python child that allocates 256 MiB, then would print `parent-done` | `Failed`, 137, `OOMKilled`; the log ends without the shell's lines | the kernel's "going to be killed due to memory.oom.group set" line and `Killed process` lines for both `python3` and `sh` |
| C2b | single | the same Pod | **`Succeeded`, 0, `OOMKilled`**; the log has `child-exit=137` and `parent-done` | in the container `memory.oom.group 0`, `memory.events oom_kill 1`; one kernel `Killed process` line, for `python3`, and no group line |
| C3 | group | a shell's `dd` writes 192 MiB into an `emptyDir` with `medium: Memory` | `Failed`, 137, `OOMKilled`, and the kernel's line for the killed `dd` shows `anon-rss` 1,132 to 1,136 kB and `shmem-rss:0kB` | the memory-cgroup statistics in the same kernel report: `shmem` 129,163,264 to 131,272,704 bytes, the limit's worth, in pages no process maps |
| C4 | group | a shell writes 512 MiB to a disk-backed `emptyDir`, reads it back, sleeps 40 s | `memory.current` 133,210,112 to 133,865,472 of 134,217,728 (99.3 to 99.7%), `memory.events max` 222 to 425 | `Succeeded`, 0, `Completed`; `oom_kill 0` in the container, no kernel report naming it; the kubelet's median `workingSetBytes` 1.6 to 1.9 MB against a median `usageBytes` of 131.0 to 131.8 MB (7 to 10 fresh samples each) |

Reading each row:

- **C2a and C2b** differ in one kubelet field on one image, and the outcome flips from a failed job to a succeeded one that lost a process.
  On `false` the log is the misleading source: it simply stops, as if the script had ended; the kernel line says why.
  On `true` the phase and exit code are the misleading sources; `memory.events oom_kill` and the reason say a process died.
- **C3**: the per-process line every OOM guide quotes names no large process, because tmpfs pages are charged to the cgroup but mapped by no process; `shmem-rss` is the victim's mapped shared memory, not the cgroup's.
  The answer is in the statistics block the kernel prints with the same report.
  The tmpfs was sized at the container's limit (131,072 KiB), so a memory-backed volume and the heap share one budget.
- **C4**: a graph of `memory.current` or `container_memory_usage_bytes` at 99% of the limit, with the limit hit hundreds of times (`memory.events max`), is page cache being reclaimed, not an OOM in waiting; `workingSetBytes` subtracts `inactive_file` and stays at about 1.4% of usage.
- **Which limit was hit.** In every OOM case the kernel's `oom_memcg` is the **Pod's** slice and `task_memcg` the container's scope: with one container the Pod slice carries the same 128 Mi limit and also holds the pause container, which is consistent with its limit being the one reached first.
  That is why C2b's container reads `oom 0` (its own limit was not hit) beside `oom_kill 1` (a process in it was killed).
- **The join.** The kernel report names the container as `cri-containerd-<id>.scope` and the Pod as `kubelet-kubepods-pod<uid>.slice`; the checker attributes a report to a case only when the ID matches the Pod's `containerID`.
- **Timing of the reason.** The terminated `reason` was present at the first poll that showed the container terminated in every case; the polls ran once a second, so this does not bound containerd's event latency below a second.

## The commands

| question | command |
|---|---|
| did the kernel kill something, and which limit | `journalctl -k -o short-monotonic \| grep -E 'invoked oom-killer\|oom-kill:constraint\|Killed process\|oom.group'` — read `oom_memcg` (the limit) and `task_memcg` (the victim) |
| was it the whole container or one process | in the container: `cat /sys/fs/cgroup/memory.oom.group`; on the node: the kubelet's `singleProcessOOMKill` from `kubectl get --raw /api/v1/nodes/<n>/proxy/configz` |
| did a process in this container die of memory | `cat /sys/fs/cgroup/memory.events` (`oom_kill`), and the container's terminated `reason`, whatever its exit code |
| what was the memory | the statistics block of the kernel report (`anon`, `file`, `shmem`), or `memory.stat` in a live container |
| is "near the limit" a problem | `memory.stat` `inactive_file` and the kubelet's `workingSetBytes` (`/stats/summary`), not `memory.current` |

## What this does not say

- Nothing about node-pressure eviction, swap, `memory.high` or `oom_score_adj` between containers; none was produced.
- Nothing about kubelet versions other than v1.37.0. The v1.31 platform cluster has no `singleProcessOOMKill` and behaves as `false`; a single unscored spike on v1.31 agreed with C2a, and that is the only evidence for it.
- Nothing about GPUs. GPU memory exhaustion and Xid lines in the kernel log need a card; they are planned as descriptive captures in the next paid session (M-42A-7), and no Xid reader is written until a real line exists to cut its fixture from.

## The record

- The kernel journal kept per case is the host's kernel log for the case's window trimmed to its OOM reports (`hack/linux-diag/trim-journal.py`): the rest named the workstation and its hardware.
  The scored verdict was computed before the trim was applied to this archive, and the checker's verdict on the trimmed archive is byte-for-byte the same; later runs trim at capture.
- gpt-6-astra read the design before the run and returned ten findings; nine were taken and one refused, as the design records.
- The checker's eleven rules were each broken once and its test went red each time (2026-11-07).
