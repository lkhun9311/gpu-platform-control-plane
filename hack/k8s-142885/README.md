# kubernetes/kubernetes#142885: lowering `limits.swap` below current swap usage

Reproduction for the open review question on kubernetes/kubernetes#142885 (KEP-5359, WorkloadControlledSwap):
iholder101's comment on `pkg/kubelet/kuberuntime/kuberuntime_manager.go` (r4584451906, following r4427802056).
Nothing here was posted upstream.

## Setup

| | |
|---|---|
| PR head | `5a0b7d10d74c49bccfd6ed328cd78bd89020eccc` (kubelet reports `v1.38.0-beta.0.782+5a0b7d10d74c49`) |
| Binaries | `make WHAT="cmd/kube-apiserver cmd/kube-controller-manager cmd/kube-scheduler cmd/kubelet cmd/kubectl cmd/kube-proxy"` on the PR head, go1.27.4; checksums in `evidence/instance1/env/bins.sha256` |
| Cluster | `hack/local-up-cluster.sh -O` with `LIMITED_SWAP=true FAIL_SWAP_ON=false FEATURE_GATES=WorkloadControlledSwap=true` (gate on in all components); kubelet runs on the host, no kind |
| Node | EC2 t3.large, Ubuntu 24.04.5, kernel `7.0.0-1017-aws`, cgroup v2, 4 GiB swapfile, containerd 2.2.1, runc 1.3.4, cgroupfs driver |
| Stats path | containerd is not a legacy-cAdvisor runtime, so the kubelet uses the CRI stats provider; swap usage for the resize check comes from its cAdvisor fallback |

Why not kind on the workstation: the workstation runs with swap off (`/proc/swaps` empty) and without root, so there was no swap for a kind node to use.
Two instances were used: instance 1 for A/B/C/R and the kernel cases, instance 2 for the S cases after R1 showed a race.

## Cases

The workload writes 320 MiB once under `limits.memory: 128Mi`, then sleeps, so about 256 MiB sits in swap and is never touched again.

| Case | PATCH (`/resize`) | Runs | Result |
|---|---|---|---|
| A | `limits.swap` 512Mi -> 64Mi, swap.current 256 MiB, PATCH 10 s after the allocator finished | A1-A3 (inst. 1, 300 s), A4 (inst. 2, 60 s) | 4/4 stuck: `PodResizeInProgress=True`, reason `Error`; memory.swap.max stays 536870912; swap.current the same at every 20 s sample |
| B (control) | 512Mi -> 384Mi, above usage | B1-B3 | 3/3 `ResizeStarted` -> `ResizeCompleted` 46-76 ms apart in the kubelet log; memory.swap.max 402653184 |
| C | no `limits.swap`, LimitedSwap; `requests.memory` 512Mi -> 128Mi, derived swap 281337856 -> 70335197, usage 142008320 | C1 | stuck like A; the memory-request part is held too (containerStatuses requests.memory stays 512Mi) |
| S | A's PATCH sent right after the allocator finished, no settle | S1-S5 (inst. 2) | 5/5 completed: memory.swap.max = 67108864 while memory.swap.current = 268431360, no error, `ResizeCompleted` |
| R | A's PATCH, then 512Mi again after 60 s | R1 | the first PATCH completed below usage (same race as S), so R1 does not test recovery from a stuck resize; the raise-back completed |

A, per sample (A1; A2/A3/A4 identical in shape, `evidence/instance*/summary-table.md`):

| t | spec limits.swap | containerStatuses limits.swap | memory.swap.max | memory.swap.current | memory.max | oom_kill | PodResizeInProgress |
|---|---|---|---|---|---|---|---|
| before | 512Mi | 512Mi | 536870912 | 268791808 | 134217728 | 0 | absent |
| +20 s .. +303 s (15 samples) | 64Mi | 512Mi | 536870912 | 268791808 | 134217728 | 0 | True / Error |

`allocatedResources` carries only requests (cpu 100m, memory 64Mi) throughout; pod-level `status.resources` has no swap because the pod sets no pod-level `limits.swap`.

The condition message, events and kubelet log for A1:

```
PodResizeInProgress True Error: cannot decrease memory or swap limits: attempting to set container "app" swap limit (67108864) below current swap usage (268791808)
E1119 11:16:55.465956    3724 kuberuntime_manager.go:1179] "Allocated pod resize is not currently feasible" err="cannot decrease memory or swap limits: attempting to set container \"app\" swap limit (67108864) below current swap usage (268791808)" pod="default/swap-explicit"
Warning ResizeError Pod resize error: {...,"generation":2,"error":"cannot decrease memory or swap limits: attempting to set container \"app\" swap limit (67108864) below current swap usage (268791808)"}
```

The validator error appears 23-24 times in 300 s (every 11-15 s, the first attempt included) in A1-A3 and C1, with the same usage figure each time.

C1's line: `attempting to set container "app" swap limit (70335197) below current swap usage (142008320)`.

### Why S passed

Not captured: the usage value the check read in S1-S5 and R1.
With `app` present in the stats, the check passes only if that value is at most 67108864, while the cgroup held 268431360; stale stats are the likely cause.
One other path exists in the code: a container absent from `podUsageStats.Containers` is never compared, and `mergeSwapUsage` does not add it back (`kuberuntime_manager.go` around lines 1563 and 1616).
That path is unlikely here, because `PodCPUAndMemoryStats` lists every running container from CRI, but it is a gap in its own right.
`stats-lag.sh` polled the kubelet's `/stats/summary` from the allocator's READY line: `swapUsageBytes` was 0 through +6 s and +12 s, first 268431360 at +8 s and +14 s, then its timestamp moved 16 s and 19 s later (`evidence/instance2/lag1.txt`, `lag2.txt`).
The summary pads a missing CRI swap value with 0 stamped now, while the resize check takes cAdvisor's sample, so the probe shows the stats arrive late, not which value the check read.
The pre-PATCH summary capture failed in S1, S2 and A4 (the apiserver refused the node proxy) and shows 0 in S3-S5.

## Kernel semantics, no kubelet (`kernel-swapmax.sh`)

A bare cgroup with memory.max 64M, 192 MiB written once (about 197 MiB in swap), then `memory.swap.max` set to 32M.

| Case | Runs | Result |
|---|---|---|
| K1 write below usage, stay cold | 3 | write rc=0 (no EBUSY); swap.current unchanged after 60 s (206290944 -> 206290944) |
| K2 then read and rewrite every page | 3 | OOM kill in 3/3 (`oom_kill 1`); the process was alive for the 30 s before the touch |
| K2c same touch, swap.max left at max | 2 | no OOM; swap.current unchanged (206286848) |
| K3 then free 3/4 of the memory | 3 | 2/3: swap.current 54685696 / 54648832 (still above 32M), alive; 1/3 OOM-killed |
| K4 `swapoff -a` while the group holds swap above memory.max (swap.max left at max) | 1 | `swapoff failed: Cannot allocate memory`, the process OOM-killed |

`swap_max_write()` in mm/memcontrol.c is a bare `xchg(&memcg->swap.max, max)`: no reclaim, no error, unlike `memory_max_write()`.
cgroup-v2.rst says that when the limit is reduced under current usage, "the existing swap entries are reclaimed gradually"; the mechanism is that a swap-in frees the slot once usage is at least half the limit (`mem_cgroup_swap_full()`).
In these runs that gradual path did not show: cold pages stayed (K1), and a group at memory.max that touched its pages was OOM-killed rather than drained (K2), while the same touch with no lowered limit left usage flat (K2c).
Freeing memory did lower usage (K3).
The `oom_kill` counter does not tell a memcg OOM from a global one, and no OOM trace was kept.

## Files

- `ec2-up.sh`, `ec2-down.sh`: the instance (2 h in-instance shutdown, sweeper deadline tag, standard credits) and its teardown.
- `node-setup.sh`, `containerd-from-github.sh`: the cluster on the instance.
- `run-case.sh`, `run-all.sh`, `pod-explicit.yaml`, `pod-limitedswap.yaml`: the resize cases.
- `kernel-swapmax.sh`, `stats-lag.sh`, `summarize.py`.
- `evidence/instance1`, `evidence/instance2`: samples, kubelet lines, events, final pod YAML, environment.
  `evidence/instance1/kernel-rep1` holds the first kernel run as captured from the terminal; its files were overwritten by a later run, which is `kernel-rep3`.

## Reading the event files

Each `events.txt` is the namespace's event list at the end of that case, so it also holds older events from earlier cases with the same pod name.
For example, B2's file contains A's `ResizeError` lines, marked about 27 minutes old.
Judge each case by its own `samples.jsonl` and `kubelet.log`, and by event ages inside that case's window.
