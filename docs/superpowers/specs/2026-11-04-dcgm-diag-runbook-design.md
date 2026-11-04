# What `dcgmi diag` reports on one rented A10G with no known fault, and the re-admission runbook it would feed: a registration

Written 2026-11-04, before any run.
Revised three times the same day after adversarial reviews by codex `gpt-6-astra` (25 findings, then 23, then 24); each was re-checked against the code and archives before it changed this page.
The per-finding dispositions lived in the working session and are not archived here; what is still open is listed under "Open".
A fourth review of this text still answered "needs changes first", with five blockers; this page was committed as a draft so the work was not lost, not because it was ready.
The same day, free rehearsal item 1 ran with its transcript archived (`hack/dcgm-diag/2026-11-04-image-inspection`, by `hack/dcgm-diag-inspect-image.sh`), and this revision closes or narrows those five; "Open" says which.
**Draft. Not registered.** It becomes the registration only by the owner's approval, from the commit that records that approval, and no run before it counts.
Nothing here has been bought, built or run on a card.
Every number is either read from a file named beside it, derived on this page with its arithmetic shown, or marked "to be measured" or "to be read".

## Why

`docs/03_GPU_NODE_LIFECYCLE.md` ends the node's life cycle with "Re-intake -> Recover" and says "a recovered node re-runs intake before returning to `Serve`".
Its status line lists a "re-intake script" as a target, not as built.
The platform can latch a DCGM-reported fault and taint the node (`internal/controller/nodehealth_gpufault.go`), and run 3 of the gpu-fault study showed the node returning to service on a fresh zero reading (`2026-10-27-gpu-fault-reaction-design.md`, "Result, 2026-11-01").
What no page shows is the step between the two: an operator running an NVIDIA diagnostic on the card before work goes back on it.
The owner's reordering of the next three weeks (`storage/career/job/kor/42dot/apply/2026/08-개발방향-재정렬.md`, section 4 row B2 and section 6 item 5) shrank the original "re-admission gate" to this: "실물 `dcgmi diag`·재편입 runbook, 1.5–2일 / $3–10; 진단 항목별 결과·소요 시간, driver/CUDA/UUID·ECC/Xid 증거. 정상 GPU 1대의 실행 확인일 뿐, 불량 판별률 아님".
That document lives outside this repository, so its wording is quoted here rather than linked.
The reason for the shrinking is part of the question below: an injected fault plus one card with no known fault cannot support "zero false re-admissions", and a card with no known fault passing is not the ability to select a bad one.

## The question

On one rented A10G that has **no known fault** (its health is not independently established):
1. What do `dcgmi diag -r 1`, `-r 2` and `-r 3` print, test by test, and how long does each take, in the order and on the card state this page registers?
2. What evidence of the card's identity and history can be captured around them: driver version, the driver's supported CUDA version, the host's and the image's CUDA toolkits, GPU UUID, ECC mode and counters (volatile and aggregate, single-bit and double-bit), retired or remapped rows if the card reports them, and the Xid lines the kernel log holds on the current boot?
3. Can the platform's existing objects carry a runbook whose decision to return work rests on that evidence, using only what exists today plus one new overlay, and does each step execute on the real card?

It is **not** a question about defect detection.
One card with no known fault cannot show that a diagnostic detects an unhealthy one, how often it misses, or how often it flags a good card.
Such a card can still receive a failing or warning result; that would be reported as printed, and it would not be a measured false-positive rate either.
No sensitivity, specificity, miss rate or false-re-admission rate is computed, quoted or implied by anything on this page.
An overall pass does not show that every requested test executed, since tests can be skipped; executed-and-passed, failed, warned and skipped are kept apart throughout.

## What is verified, and what is not (2026-11-04)

Observed on the laptop on 2026-11-04, with no GPU, against the image this repository already pins.
**The inspection transcript was not archived**, so these are the author's observations until free rehearsal item 1 re-runs them with the transcript, the digest and the platform identity saved:
- `nvcr.io/nvidia/k8s/dcgm-exporter@sha256:3d4e0dfa5fc4d7d12689d29fc6b56cd6c610750e8d187a393882e341fbba6c12` (`config/dcgm-exporter/daemonset.yaml:78`, and the `hostengine` container of `config/dcgm-exporter-fault/kustomization.yaml`) carries `dcgmi` 3.3.9 and `libdcgmmodulediag.so.3.3.9`.
- Its `dcgmi diag --help` documents `-r 1` "Quick (System Validation ~ seconds)", `-r 2` "Medium (Extended System Validation ~ 2 minutes)", `-r 3` "Long (System HW Diagnostics ~ 15 minutes)", and `-r 4`; tests by name; and the flags `-j`, `-v`, `-i`, `-t`, `--fail-early`, `--iterations`, `--statsonfail`, `--debugLogFile`, `--statspath`, `--throttle-mask`.
  Those durations are NVIDIA's help text for 3.3.9, not measurements on an A10G.
- That same image did not contain `/usr/share/nvidia-validation-suite`, where the package's file list places `nvvs` and its plugins, so the exporter's `hostengine` container cannot be assumed to run `dcgmi diag`, and the apparatus needs a different image.

Archived on 2026-11-04 by `hack/dcgm-diag-inspect-image.sh`, with no GPU and `--network none`, in `hack/dcgm-diag/2026-11-04-image-inspection`, one directory per DCGM version:
- Two full DCGM images, amd64, by digest: `nvcr.io/nvidia/cloud-native/dcgm@sha256:b40226d395a35f7db3a88ce1a143c6caafadba2315be2b7b7fa9a4f41fa5b41d` (tag `3.3.9-1-ubuntu22.04`, `dcgmi` 3.3.9) and `nvcr.io/nvidia/cloud-native/dcgm@sha256:30dd30b980ebf2f15a3fe7e629db9b8540f93bed794327dd34a0d4afd8a52c1b` (tag `4.4.2-1-ubuntu22.04`, `dcgmi` 4.4.2); both carry `nvvs` (`image.txt`, `version.txt`, `packages.txt`).
- **3.3.9's plugins exist only for CUDA 10, 11 and 12; 4.4.2's for CUDA 12 and 13** (`plugins.txt`).
  `nvvs` picks the directory by the CUDA version the driver reports; 3.3.9's binary carries "Detected unsupported Cuda version: {}.{}" and no fallback message, while 4.4.2's also carries "Detected unsupported CUDA version {}; defaulting to {}" (`strings.txt`).
- The AMI's driver reports CUDA 13.2: `Driver Version: 595.91.07      CUDA Version: 13.2` in `hack/mps-capability/2026-10-24-run2/m5c-run/mpscap/diag/nvidia-smi.txt`, the same driver version run 3 recorded (`hack/gpu-fault/2026-11-01-run3/preflight-nvidia-smi.csv`).
  So 3.3.9 has no plugin directory for this driver, and the image is 4.4.2 (below).
  Whether 3.3.9 would refuse or run something on CUDA 13.2 needs a GPU; it is not bought to find out.
- **A diagnostic that cannot reach its host engine does not stop.**
  With `--host` naming a socket that does not exist, `dcgmi diag -r 1 -j` prints "Error: unable to establish a connection to the specified host" and then returns a diagnostic result anyway, the same `runtime_error` and the same exit code as with no `--host` and no engine running (226 on 4.4.2, 221 on 3.3.9); with no `--host` it prints no connection error at all (`engine-probe.txt`).
  Both binaries link `dcgmStartEmbedded_v2` and carry "Unable to start an embedded host engine" (`strings.txt`), which is consistent with the review's claim that `dcgmi diag` falls back to an embedded engine; what that engine then tests on a real card needs a GPU.
  `dcgmi discovery -l`, by contrast, refuses with exit 235 and "Unable to connect to host engine" in both cases.
- **The diagnostic's JSON names a card by entity, serial and device ID, as far as the binary shows.**
  The lower-case key strings in 4.4.2's `dcgmi` include `entity_id`, `entity_groups`, `serial`, `serial_num`, `device_id`, `results`, `tests`, `test_summary`, `warnings`, `info`, `error_id`, `error_category`, `metadata`, `runtime_error` and `driver_version`, and no `uuid`; the strings containing "UUID" are "Device UUID", "UUID" and an entity-parser message (`strings.txt`).
  The exact nesting, and whether a UUID appears anywhere in `-j` output, need a GPU.
- A dcgm-exporter built on DCGM 4.4.2 exists: `nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.1-ubuntu22.04`, amd64 `sha256:6b5975cdd430d05692c92137bb264938196ee9165e55205a0e31a5e89a9873ee` (`docker manifest inspect`, 2026-11-04); it was not pulled or inspected.

Read from the code on 2026-11-04, at `59a894f5`:
- `removeGPUFaultTaint` deletes only a taint with key `platform.lkhun9311.github.io/gpu-fault` and effect `NoSchedule` (`isGPUFaultTaint`, `internal/controller/nodehealth_gpufault.go:249-267`).
- `removeUnhealthyTaint` (`internal/controller/reconcile_helpers.go:172`) deletes only the taint `isManagedTaint` matches and keeps every other taint.
  No other non-test code in `internal/` assigns `Node.spec.taints`.
  So an operator's taint with another key survives both of the platform's release paths.
- On a fresh reading with no fault, `decideGPUFault` sets `GPUHealthy=True` and drops the latch and the `gpu-fault` taint (`nodehealth_gpufault.go:221-225`, `:296-298`).
  An operator's taint does not change this: the platform's health and the operator's hold are independent states.
- The acknowledgement annotation is never removed by the controller, and the fingerprint it matches is `UUID/field=value` with no incident identity (`internal/gpufault/classify.go:263-268`).
  A later fault with the same card, field and value would therefore match an old acknowledgement.
- `displaceGPUWork` deactivates the Workloads of GPU Pods **on the node** that have a Job owner (`nodehealth_gpufault.go:360-400`), and only with `--gpu-fault-evict-workloads` (`internal/controller/gpufault_setup.go:59`, which the gpu-fault setup adds at `hack/lib/gpu-fault.sh:651`); with no such Pod there is nothing to displace.
- `reactivateDisplaced` runs on every reconcile of the `NodeHealth` and checks only the Workload's own eviction, quota and handoff state (`nodehealth_gpufault.go:320-324`, `:452-480`), not any operator hold.
  A displaced Workload is therefore reactivated, and may be admitted, while the node is still held.
- An `MLTrainingJob` has no placement field, and the one `gpu` ResourceFlavor has an empty spec (`config/kueue/resourceflavor.yaml:14`), so it matches the simulator's node as well as the card's.
  The gpu-fault study places its job on the card by tainting the other node with `gpufault-study/hold` while it submits (`hack/lib/gpu-fault.sh`, `gf_cell`).
- `gf_submit_job` runs an endless `sleep` loop (`hack/lib/gpu-fault.sh:269-283`): it holds a GPU and never computes or completes.
  GPU execution after recovery is shown in that study by `gf_recovery_check`, NVIDIA's vectorAdd sample pinned at `hack/gpu-fault-instance.sh:20`.
- The exporter tolerates `nvidia.com/gpu` and `gpu-fault` (`config/dcgm-exporter/daemonset.yaml:46-56`); the NVIDIA device plugin tolerates only `nvidia.com/gpu` (`config/nvidia-device-plugin/daemonset.yaml:41-44`).
  Neither tolerates a new hold taint, so either one recreated during a hold would stay Pending.
- The policy reads the **volatile** double-bit count (`DCGM_FI_DEV_ECC_DBE_VOL_TOTAL`) and ignores Xids 13, 31, 43, 45 and 68 (`classify.go:40-66`).
- The inherited runner reads the driver version only inside the instance's user-data (`hack/gpu-fault-session.sh:215`), after purchase, and does not compare it with any expected value.

Not verified, and found out only by the paid session or by the free rehearsal where stated:
- which image carries `nvvs` and the plugins, at which digest and DCGM version (rehearsal item 1);
- the image's entrypoint, user, required capabilities and DCGM execution mode, which decide the exact `docker run` and `kubectl exec` lines (rehearsal item 1);
- the `-j` output's field names and nesting, and the exact status words the selected version prints (rehearsal items 1 and 3, and the first real output);
- whether DCGM diagnostics read values that `dcgmi test --inject` placed in the host engine's cache (not established either way; see Part 2);
- every duration, and whether `-r 3` completes on a g5.2xlarge inside its limit;
- whether this card exposes ECC counters and retired or remapped rows, read from `nvidia-smi -q -d ECC,PAGE_RETIREMENT,ROW_REMAPPER` (the display names are to be confirmed on the AMI's `nvidia-smi` in the session's first command).

## The apparatus

### Two options, and which one

**Option A, the gpu-fault session's machine.**
One g5.2xlarge Spot instance, the pinned Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) `ami-097edab977037f65f` (run 3's, `hack/gpu-fault/2026-11-01-run3/session-provenance.txt`), with the kind cluster `m5cgpu`, the NVIDIA device plugin, the study exporter and its host engine, the operator, Kueue, and `gpu-simulator` on the control plane.

**Option B, a plain instance.**
The same instance and AMI, no kind, no operator: host preparation, then the diagnostic container.

**Chosen: A's machine, with B's measurement first.**
Part 1 (the diagnostics) runs on the host before any kind cluster exists, so no other host engine or cluster workload is present during it.
Part 2 (the runbook) needs the real `NodeHealth`, taint and operator, which only A provides.
Plain B alone would leave the runbook as prose with no object changing, which is the "paper" outcome this repository's pages refuse.

**This ordering is not what the existing runner does, and is new work.**
`hack/gpu-fault-session.sh:171-175` splices `hack/m5c-gpu-session.sh` from `export DEBIAN_FRONTEND=noninteractive` (line 979) through `upload /tmp/node-cards.txt preflight-node-cards.txt` (line 1097) as one span, run in a child shell (`timeout ... bash /tmp/bringup.sh`, `hack/gpu-fault-session.sh:230`), and that span creates the kind cluster at line 1041.
The new runner splices two spans, each run as its own child process: host preparation (from line 979 to before line 1040) and the kind bring-up (from line 1040, which is `export KUBECONFIG=/tmp/kubeconfig`, through line 1097).
Starting the second span at the export keeps `KUBECONFIG` in the process that uses it; the parent also exports `KUBECONFIG=/tmp/kubeconfig` before running Part 2, as the inherited tail already does (`hack/gpu-fault-session.sh:241`).
Each span gets its own phase, and both, with the handoff between the two processes, are rehearsed (rehearsal item 6).
The historical "2 min 43 s" (`hack/m5c-gpu-session.sh:697`, a comment recording an older session's S3 timestamps for the whole span on a warm AMI) is used below only as an estimate for each half, labelled as such.

### The image

**DCGM 4.4.2**, the full image `nvcr.io/nvidia/cloud-native/dcgm:4.4.2-1-ubuntu22.04`, pinned by its index digest `sha256:becae9b24707d2bdfce87cb72626e24b2fbfbca812329ca52540ad0e0d955717` (Docker's `RepoDigests` after a pull by tag, 2026-11-04), whose amd64 image is the `sha256:30dd30b9…52c1b` inspected above.
3.3.9 was preferred because it matches the exporter's client, but its plugins stop at CUDA 12 and the AMI's driver reports CUDA 13.2, so it is not used.
That makes Part 2 a version change of the platform's reading path, recorded as one: the overlay moves **both** the `hostengine` container and the exporter to DCGM 4.4.2, the exporter to `nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.1-ubuntu22.04`, so the client and the host engine are one version again, as they are today at 3.3.9.
Rehearsal item 2 pulls that exporter, records its index digest and `dcgmi --version`, and checks on kind that it serves the three fault fields and utilisation from `/etc/dcgm-exporter/queuelab-metrics.csv` before anything is bought.
Part 2's platform readings are therefore of a 4.4.2 exporter, not of the 3.3.9 one the platform otherwise runs, and nothing here says the 3.3.9 path behaves the same.
In session, before Part 1, the host's `nvidia-smi` "CUDA Version" is read; if its major version has no directory under the image's `/usr/libexec/datacenter-gpu-manager-4/plugins/`, the session aborts as REFUSED (driver), since `nvvs` would otherwise pick a fallback directory (the 4.4.2 binary's "defaulting to" message) and test with plugins built for another CUDA.
If the rehearsal cannot pin both images by digest, the session is not bought.

### Part 1 commands

The exact `docker run` line is **frozen at registration from rehearsal item 1**, and must state: the entrypoint override (`--entrypoint`), the effective user, `--gpus all` and any capability the image documents as required, the diagnostic's own embedded mode (no separate host engine is started, on the host or in the container), a bind-mounted output directory for stdout, stderr and `--debugLogFile`, and a container name per run so it can be killed and inspected.
Part 1 runs **no `dcgmi` command other than `dcgmi diag`**: `dcgmi discovery` queries a running host engine, which Part 1 deliberately does not have.
Part 1's `dcgmi diag` is given no `--host`, so it runs on the embedded engine the inspection above shows `dcgmi` starting when none is reachable; that is the intended mode here, and the archived stderr must show no connection error, since none is attempted.
The card's identity in Part 1 is read through NVML with `nvidia-smi` on the host.
Evidence commands that read the host are run **on the host, not in a container**, because a container does not see the host's toolkit or, without extra privilege, the kernel log:

| row | command | where |
|---|---|---|
| boot | `cat /proc/sys/kernel/random/boot_id`; `uptime -s` | host |
| card, driver, identity | `nvidia-smi --query-gpu=index,name,uuid,serial,pci.bus_id,driver_version,memory.total,ecc.mode.current,persistence_mode --format=csv`; `nvidia-smi -q` | host |
| driver's supported CUDA | the "CUDA Version" line of `nvidia-smi` (driver capability, not a toolkit) | host |
| host toolkit | `command -v nvcc` and `nvcc --version`; absent is recorded as absent on the host | host |
| image's CUDA | the image's package and library listing for CUDA (`dpkg -l` and `ls` of its CUDA library paths) | image, rehearsal and session |
| ECC, retirement, remapping | `nvidia-smi -q -d ECC,PAGE_RETIREMENT,ROW_REMAPPER` | host |
| card state | `nvidia-smi --query-gpu=temperature.gpu,clocks.sm,clocks.mem,power.draw,power.limit,clocks_throttle_reasons.active --format=csv` | host |
| kernel Xid | `journalctl -k -b --no-pager --show-cursor -o short-monotonic`, filtered afterwards for NVRM and `Xid`, its exit status recorded separately from the filter's | host |
| diagnostics | `dcgmi diag -r N -j` | image |

Each command's exit status, start and end (`date +%s.%N` on the host), stdout and stderr are kept as separate files.
A kernel-log read that fails or is denied is recorded as **UNREADABLE**, never as an empty history.

**The driver contract.**
The committed registration names the expected driver version: 595.91.07, the version run 3 read on this AMI (`hack/gpu-fault/2026-11-01-run3/preflight-nvidia-smi.csv`).
Before purchase the runner refuses only if that expected value is absent from the registration; the actual driver cannot be read before purchase.
On the instance, the first `nvidia-smi` read is compared with it: a mismatch is an **in-session abort**, not a refusal: nothing further runs on the card, the evidence so far is uploaded, the instance shuts itself down at once, and the session verdict is `DCGM DIAG: REFUSED (driver)`.

**Order and state.**
Order: `-r 1` three times, then `-r 3` once, then `-r 2` three times.
`-r 3` comes before `-r 2` so that its 1,800 s limit is reserved: a valid but slow earlier run can starve only a `-r 2` repetition, never the single `-r 3`.
Three is a convention (the least that gives a median that is not an endpoint, as in `2026-10-27-gpu-fault-reaction-design.md`, "Verdict rules"); `-r 3` once because its help text says about 15 minutes, and a second pass would take a further third of Part 1's 2,700 s phase (900 / 2,700).
A new container does not explicitly reset the card, but how much state carries over depends on persistence mode and on whether any client keeps the GPU initialised (unverified against NVIDIA's documentation of state lifetime); a volatile counter that falls between reads is recorded as it reads and never interpreted as recovery.
So the card-state, ECC and kernel rows are read before and after every diagnostic, persistence mode is recorded, and every duration is reported as an observation **in this sequence**, with level confounded with warming and order.
Nothing is described as a level's isolated cost.

**Timing.**
Wall time is measured on the host around the `docker run`, so it includes container start.
A `docker run <image> true` with the same flags, three times before the first diagnostic, gives the container-start overhead, which is reported beside the wall times and never subtracted from them.

**Limits, cancellation and cleanup.**
Per-run limits: `-r 1` 300 s, `-r 2` 600 s, `-r 3` 1,800 s (conventions: at least twice the help text's figure, and for `-r 1` a floor).
A run starts only if its limit plus 30 s fits before Part 1's phase end; otherwise it is **NOT-RUN**, which is not a failure.
On reaching its limit: `docker kill` the named container, wait up to 30 s, then check on the host that no `nvvs` or diagnostic process remains.
The check has three states, never two: **clean** when `pgrep -a nvvs` exits 1 (no match) and `nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader` exits 0 with zero lines; **residual** when either lists a process; **unreadable** when either exits with any other status or prints a line that is not a process row.
The cancellation's own output is saved.
A clean check lets the next run start.
If the check is residual or unreadable, the card is **contaminated**: every later diagnostic is NOT-RUN (contaminated), **Part 2 does not start** (no kind, no workload, no further diagnostic), the evidence is uploaded, and the instance shuts itself down.

**Isolation monitoring.**
During each diagnostic, the host samples `nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader` every 2 s and maps each PID to its cgroup (`/proc/<pid>/cgroup`).
Processes in the diagnostic container's cgroup are the diagnostic's own work and are expected.
Any other compute process makes the run INVALID (V3).
This query lists compute processes only; it is not an inventory of graphics users or monitoring clients.
So the claim made is "no foreign compute process observed at the 2 s cadence".
A run whose monitor did not record at least one sample per 10 s, or in which a sampled PID's cgroup could not be read, is **isolation unverified**: it may still be RESULT for Part 1's characterisation, but it can never satisfy the runbook's return rule.
Before Part 1 the host also shows `docker ps -q` empty, `pgrep -a nv-hostengine` with no match, and no active systemd unit whose name contains `dcgm`; the claim is only "no host-engine process, container or service observed", because a DCGM embedded inside another process would not show under that name.

**Evidence preservation.**
Each completed command's files are uploaded to S3 as soon as the command ends, not only in the final archive, so a Spot interruption keeps every completed run.
The inherited runner uploads its archive only at the end (`hack/gpu-fault-session.sh:247-251`); incremental upload is new work.

### Part 2 commands

After the kind bring-up and the platform phase as `hack/gpu-fault-instance.sh` runs them, through a new overlay config/dcgm-diag (new work):
- the exporter's `hostengine` container uses the diagnostic image (DCGM 4.4.2, above) and mounts an `emptyDir` at `/diag-out` for diagnostic output and debug logs, and the `exporter` container moves to the dcgm-exporter built on the same DCGM, so the client and the host engine stay one version;
- the exporter and the device plugin each gain a toleration for `platform.lkhun9311.github.io/diag-hold` with effect `NoSchedule`, so a recreated infrastructure Pod can return to a held node; the device plugin also gains one for `gpu-fault`, since it has none today.

The diagnostic is `kubectl -n gpu-platform-control-plane-system exec <exporter pod> -c hostengine -- timeout -k 30 600 dcgmi diag --host localhost:5555 -r 2 -j --debugLogFile /diag-out/diag-r2.log`, with stdout and stderr kept on the laptop side; `localhost:5555` is the host engine the exporter itself reads (`config/dcgm-exporter-fault/kustomization.yaml:39-43`), reached from the same Pod.
Because a `dcgmi diag` that cannot reach that engine carries on without it (the inspection above), the engine is bound to the run twice:
immediately before, `dcgmi discovery --host localhost:5555 -l` must exit 0 and list exactly one GPU, which the same inspection shows `discovery` refusing to do without an engine (exit 235);
and afterwards, the diagnostic's stderr must not contain "unable to establish a connection".
Either failing makes the run INVALID (engine), because its result would be the embedded engine's and not the one the platform reads.
**Level 2 is registered here**, not chosen from Part 1, because Part 1 is not a suitability study; that level 2 suits a node waiting to return is a convention, not evidence.
After it returns or times out, the residual check has the same three states as Part 1's: **clean** when `kubectl exec <exporter pod> -c hostengine -- pgrep -a nvvs` exits 1 and the host's `nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader` lists no process outside the `hostengine` container; **residual** when either lists one; **unreadable** on any other exit status, a lost connection, or a missing `pgrep`.
Residual or unreadable: the diagnostic is TIMED-OUT (residual), step 6 decides keep, and the rest of Part 2 is NOT-REACHED.
Then the output is copied out of the container that owns it, before any Pod in Part 2 is recreated, naming that container: `kubectl cp -c hostengine` would default to the Pod's first container, `exporter` (`config/dcgm-exporter/daemonset.yaml:67`), without it, and the copy is done as the tar it wraps, `kubectl exec <exporter pod> -c hostengine -- tar -C /diag-out -cf - . > diag-out.tar`, whose exit status must be 0 and whose archive must list `diag-r2.log`; it is then hashed and uploaded.
A failed copy stops Part 2 before any recreation, so the evidence is not destroyed.
Rehearsal item 1 confirms the image carries `tar`, `timeout` and `pgrep`; if it lacks one, the commands are rewritten before registration.

### How outputs are archived

Raw first, transcribed second: raw stdout, stderr and debug logs of every command are kept byte for byte under `$OUT/` and listed in `SHA256SUMS`.
Run provenance follows `session-provenance.txt` (commit, AMI ID and name, image digests, source and image checksums), plus the DCGM image digest, its `dcgmi --version`, and its archived `dcgmi diag --help`.
The directory is hack/dcgm-diag/<date>-run1/; image archives, the source archive and the scorer binary are recorded in `NOT-COMMITTED.sha256`, as for the gpu-fault runs.

## Registered outcomes, bars and refusals

### Refusals before purchase

The existing runner already refuses on these, and the new runner reuses them: `SESSION_CONFIRM=yes` absent, a dirty tree, credentials for an account other than `007635145730`, a Spot price above the cap in every zone, a "G and VT" Spot quota under 8 vCPU, the termination sweeper not Active and `ENABLED rate(5 minutes)` and aimed at itself, and an earlier instance with this study's `purpose` tag still live.

**New work, not implemented anywhere today** (there is no diagnostic runner and no config/dcgm-diag in this checkout):
- the AMI ID must equal `ami-097edab977037f65f` (the existing check, `hack/gpu-fault-session.sh:62-80`, checks only the ID's syntax and the AMI's name);
- the instance type must be g5.2xlarge;
- the registration must name the expected driver version (the comparison itself happens on the instance, above);
- the credentials must outlast the session's own phases plus the termination wait plus 30 minutes, derived from this runner's constants (the existing runner hard-codes `CRED_MIN_MINUTES=155`, `hack/gpu-fault-session.sh:45`), and are **re-read immediately before launch**, after the builds and pulls, so build time cannot eat the headroom;
- the sweeper's last-thirty-minutes check must sum **every** CloudWatch datapoint in the window (the existing check reads only `Datapoints[0].Sum`, `hack/gpu-fault-session.sh:107-117`, and CloudWatch does not promise one datapoint or their order); a clean idle run is evidence the sweeper ran, not that it terminates;
- the DCGM image digest must be the committed one, and its archived file listing must show `nvvs` and its plugins;
- two constants, not one: the **compute cap** passed as EC2's Spot `MaxPrice` is $1.10 an hour, and the **all-in rate at that cap** used for allowances is $1.1324 an hour ($1.10 + $0.0274 for 200 GB gp3 + $0.005 for a public IPv4, `2026-10-08-measuring-prospective-admission-design.md:733-737`).
  The inherited gpu-fault runner passes the all-in $1.1324 as `MaxPrice` (`hack/gpu-fault-session.sh:29`, `:310`; `hack/lib/spot-run.sh:167`), so its true all-in rate at its cap is $1.1324 + $0.0274 + $0.005 = $1.1648 an hour; that is the inherited runner's discrepancy, recorded here and not repeated.

Each refusal is shown to fire on its own bent copy, one at a time on a clean tree (rehearsal item 5).

### Per diagnostic run

Checked in this order; the first that holds decides:
1. **NOT-RUN**: it was not started (its limit did not fit, the card was contaminated, or the session aborted). Not a failure.
2. **INVALID (identity, interference or engine)**: V1, the `nvidia-smi` read taken immediately before it does not show exactly one A10G with the session's UUID; V3, a foreign compute process was sampled during it; V5, the image digest or driver version is not the registered one; V6 (Part 2 only), the `discovery` check before it failed or its stderr shows "unable to establish a connection".
3. **TIMED-OUT**: it reached its limit and was cancelled; reported as "not complete inside L", never as a time, whatever its output holds. A clean cancellation and a residual one are kept apart.
4. **INVALID (output)**: V2, stdout, stderr and exit status were not all recorded, or stdout is not parseable JSON; V2b, the JSON parses but contains no test name from the selected version's archived test list (an error envelope, not a diagnostic).
5. **RESULT**: otherwise, **whatever the diagnostic itself reported**. A failure, warning or skip is a result, transcribed as printed.

### Transcription rule, frozen before launch

For a RESULT run: each test's name and status string are copied as printed.
A status is classed as passed, failed, warned or skipped **only** by the status words the selected version's documentation and archived help define (read in rehearsal item 1 and written into the registration); any other status word is **unclassified** and listed as such.
Each test's own time is copied if the output carries one.
Coverage is reported apart from repetitions: rehearsal item 1 archives the expected test list for **each** of levels 1, 2 and 3, and every RESULT run lists each expected test as present (with a result record) or missing; a missing test is never folded into a pass.
This is a transcription rule, not a field-name parser: it can be applied by hand to the archived bytes, and a later parser may only reproduce it, never change it.

### Per level

- **REPORTED**: every registered repetition is RESULT (3 for `-r 1` and `-r 2`, 1 for `-r 3`).
- **PARTIAL**: at least one RESULT, fewer than registered.
- **UNJUDGED**: no RESULT.

Every level is reported with its status, and every repetition that is not RESULT is listed with its outcome and reason.
A REPORTED or PARTIAL level reports the transcribed tests, each run's wall time, the container-start overhead, and for three runs the median, minimum and maximum (no mean, no interval, no rate).
No pass bar on any wall time is registered: NVIDIA's "~2 minutes" and "~15 minutes" are help text, and a bar picked from them would be the kind of guess `docs/11_WHAT_THIS_MEASURED.md` ("What the targets were based on") records the earlier ones to have been.
Each level's wall times sit beside the help text's figure, with no verdict word.

### Evidence rows

Each of the rows in the Part 1 table is **REPORTED** (the value as printed, the command, the time), **ABSENT** (the card or host does not report it, with the command's own words, never 0), or **UNREADABLE** (the command failed or was denied, with its exit status and stderr).
The UUID must equal the one the exporter's `/metrics` carries in Part 2; a mismatch is a finding, not a repair.
No value is carried over from run 3: that card was a different instance.

### The session verdict, exhaustive and ordered

1. `DCGM DIAG: NO-EVIDENCE` when neither the incremental uploads nor the archive came back.
2. `DCGM DIAG: REFUSED` when provenance was never recorded, the readings disagree on the image, or the driver did not match (the in-session abort).
3. `DCGM DIAG: INCOMPLETE` when evidence came back but all three levels are UNJUDGED; the evidence rows are still reported.
4. `DCGM DIAG: RESULT` otherwise.

Whatever the verdict, all three levels' statuses (REPORTED, PARTIAL or UNJUDGED) are printed beside it.
Part 2 has its own verdict, below, and Part 1's verdict does not rest on it.

## The runbook, and which platform objects change

The platform today latches a fault, taints, optionally deactivates the Kueue `Workload`s of GPU Pods on the node, and clears the latch on a fresh reading with no fault or on an operator's acknowledgement (`decideGPUFault`).
It does **not** cordon (`docs/03_GPU_NODE_LIFECYCLE.md`, "Degrade -> Cordon"), and draining is operator-approved by design.
It also clears without a diagnostic: anything that brings the fields to zero removes the `gpu-fault` taint by itself.

**What a hold can and cannot close.**
The hold is a second taint, `platform.lkhun9311.github.io/diag-hold=true:NoSchedule`, placed by the operator.
After it is confirmed on the Node, it prevents **ordinary scheduling** of Pods without a matching toleration; it does not evict running Pods, does not stop Pods that tolerate it, and does not stop a Pod bound to the node by `spec.nodeName`.
Between the platform's latch and the operator's hold there is a window in which a fresh zero reading can clear the platform's taint; the runbook does not close that window, and it records whether any GPU Pod started on the node in it.
The platform's health and the hold are independent: the platform can report `GPUHealthy=True` while the operator's hold remains, and the runbook's decision lives in the hold and a decision file, not in `NodeHealth`.

**Scope: no repair, one boot.**
This runbook performs **no repair**.
It decides only whether a node whose fault has gone away by itself can take work again, on evidence from the boot on which the fault was seen.
A card that would need a GPU reset or a reboot ends as **keep**, its hold in place and its evidence archived.
A GPU reset is left out because it needs every client of the GPU detached, monitoring clients included (NVIDIA's `nvidia-smi` documentation, as cited by the review; **not verified here**), and this runbook keeps the exporter's host engine and the device plugin running; a reboot is left out because the decision rule compares against the same boot.
What that leaves unshown: any recovery by reset or reboot, the stop-clients/reset/restart/re-identify procedure a reset would need, and whether a card that needed either would pass the diagnostic afterwards.

| step | who | what changes | evidence |
|---|---|---|---|
| 0. fault latched | the platform | `GPUHealthy=False`, the `gpu-fault` taint, and (with `--gpu-fault-evict-workloads`) each GPU Pod's `Workload` deactivated | `NodeHealth` annotations `fingerprint`, `observed-at`, `tainted-at`; Node taint; Workload annotation `deactivated-at` |
| 1. hold | the operator | places `diag-hold`; then lists Pods on the node that started after `tainted-at`; records whether an acknowledgement annotation is present, whoever wrote it | Node taint, its time, the list, the annotation as found |
| 2. incident capture | the operator | records, before any repair, **journal first**: the kernel journal cursor (`journalctl -k -b --show-cursor -n 0`) and the whole current-boot kernel journal saved to a file; then the boot ID, the UUID (`nvidia-smi`), and the ECC, retirement and remapping read | one file, hashed; a field that cannot be read is written UNREADABLE |
| 3. drain | the operator | lists Pods on the node whose containers request `nvidia.com/gpu`, evicts them, waits until they are gone, then checks `nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader` exits 0 with zero lines | the lists before and after, and the compute-apps read; "verified empty" and "eviction exercised" are recorded apart |
| 4. repair | — | none in this runbook (see Scope) | — |
| 5. diag | the operator | `dcgmi diag -r 2 -j`, the debug log copied out, and the evidence rows read again | the archive of this step, hashed |
| 6. decide | the operator, by the rule below | **return** or **keep** | the decision and every value it read, in a file |
| 7a. return | the operator | deletes **any** acknowledgement annotation, whoever wrote it; waits the operator's configured stale-after plus one scrape interval, both read from its arguments; then reads `GPUSignal=True` with reason `Fresh`, `GPUHealthy=True` with a reason other than `Acknowledged`, no fingerprint, no `gpu-fault` taint, and the readiness below; then removes `diag-hold` | the annotation gone, the wait's start and end, that read, then the taint gone |
| 7a readiness | the operator | before removing the hold: the Node is `Ready`; the NVIDIA device-plugin Pod on the node and the exporter Pod on the node are each `Ready`; and the Node's `status.allocatable` for `nvidia.com/gpu` is 1 | the three reads, with their times |
| 7b. keep | the operator | leaves `diag-hold` | the decision file; the platform's own health may independently read `True` |

Deleting the acknowledgement **before** the hold is removed closes the window in which an identical later fault (same card, field and value) would match an old acknowledgement while work is already back.
The wait is not for a newer reading: `reading-at` is the time the current reading **first** returned (`ReadingSince`, which moves only when a value changes, `internal/controller/gpufault_source.go:105-107`), so after a steady zero it never advances and could never be waited for.
It relies instead on how freshness is kept: the `NodeHealth` reconciler watches its own objects with no event filter (`internal/controller/nodehealth_controller.go:241`), so deleting the annotation re-evaluates the conditions; and the source wakes the reconciler whenever a node's freshness changes, tick by tick (`internal/controller/gpufault_source.go:265-268`), so a `GPUSignal=True` read after stale-after plus one interval has passed since the deletion is one the source still held fresh, or it would have been rewritten `False`.
A signal that is not `True` with reason `Fresh`, or any readiness read that fails, means keep.

**The decision rule (new operator policy, stricter than the platform's).**
Return only when all hold:
- step 2's capture exists and its UUID, ECC, boot ID, cursor and saved journal are all readable; a missing baseline means keep;
- the diagnostic is RESULT, exited 0, and **every test the selected version lists for level 2** appears in the output as a result record classed as passed (a warned, skipped, unclassified or missing test, a TIMED-OUT, an INVALID or an isolation-unverified run means keep);
- the UUID equals step 2's and the UUID in the exporter's `/metrics`, so the controller's readings and the node are bound to one card; and the diagnostic is bound to that card through the serial, because its JSON names a card by entity, serial and device ID and, as far as the binary shows, not by UUID (the inspection above): the diagnostic's result entity must carry a serial equal to the one `nvidia-smi` pairs with that UUID in the identity row read in the same boot, immediately before step 5; a missing serial on either side, more than one result entity, or any mismatch means keep and ends Part 2's same-card claims (whether `-j` carries the serial at all is read from the first real output; if it does not, this rule cannot be met and every decision is keep);
- `nvidia-smi`'s volatile uncorrected (double-bit) ECC total is 0, and its aggregate uncorrected total has not risen since step 2; either counter ABSENT or UNREADABLE means keep;
- the boot ID equals step 2's, and the kernel journal after step 2's cursor holds no `NVRM: Xid` line, **counting every Xid, including 13, 31, 43, 45 and 68**, which the platform's policy ignores; an UNREADABLE journal means keep;
- if the card reports them: no pending page retirement, no pending row remap, and no row-remap failure; a supported field that cannot be read means keep.

These are the conservative reading of what the platform treats as a fault, widened where the platform is lenient; they are not a validated cut-off.
A pass means each listed plugin **reported** Pass; it does not show that every internal subtest of a plugin ran, since some are conditional on topology (NVIDIA's plugin documentation as cited by the review; **not verified here**), and the registration does not claim it shows the card healthy.
What automating step 6 would take (a `NodeHealth` field for the diagnostic, a Job that runs it, an admission condition) is not built, not registered and not proposed here.

### Part 2, on the real card

A real fault cannot be induced on a rented card, so Part 2 injects one into DCGM's cache as `hack/lib/gpu-fault.sh` does (`dcgmi test --inject`, which `gf_inject` writes at `GF_OFFSET_S=900` s into the future, `hack/lib/gpu-fault.sh:31`, `:77-82`).
The platform's smoke cell before it has already injected and reset fields 230, 311 and 310 (`:437-447`), so the host engine's cache holds synthetic history before step 5 runs.
**Whether `dcgmi diag` reads injected cache values is not established.**
Part 2's diagnostic is therefore labelled "taken on a host engine carrying injected values", and its tests are reported but not compared with Part 1's as if they were the same measurement.
Part 1 is the clean measurement: it runs before any host engine on the card has received an injection.

**Placement.**
`MLTrainingJob` has no node selector and the flavor matches both nodes, so the workload is placed on the card the way the gpu-fault study places its job: `gpufault-study/hold=true:NoSchedule` on the simulator's node (`GF_HEALTHY`) while it is submitted, and `gf_job_pod_on` confirms the Pod Ready on the card's node.
In this study that taint **stays** on the simulator's node until exercise Z ends, so the held card's node is the only GPU node a readmitted Pod could go to, and a Pending Pod is the hold's doing and not a quota or flavor choice.

**The workloads.**
- **W**: an `MLTrainingJob` from `gf_submit_job` (one GPU, an endless sleep loop); its role is only to be a running GPU Pod the platform displaces. It does no GPU computation and is never expected to complete.
- **R**: after return, a new helper dd_recovery_probe (new work; `gf_recovery_check` is **not** used, because it submits nothing unless the gpu-fault study's stale-latched check recorded `zero_given=yes`, `hack/lib/gpu-fault.sh:548-552`, which this study never writes, and because it removes the simulator node's placement taint when it ends).
  It submits one `MLTrainingJob` named `dd-recovery`, one GPU, image `GF_RECOVERY_IMAGE` (the pinned vectorAdd sample, `hack/gpu-fault-instance.sh:20`), command `["/cuda-samples/sample"]`, with the simulator node still tainted so the card's node is the only place it can run.
  It waits up to 180 s (run 3's `GF_RECOVERY_S`, `hack/lib/gpu-fault.sh:36`) for the Job to finish, then reads back: the number of Pods, the Pod's node, its phase, its container's exit code, and its log.
  **PASS** when there is exactly one Pod, on the card's node, phase `Succeeded`, exit code 0, and the log contains `Test PASSED`; **FAIL** when it finished any other way; **NOT-COMPLETE** when 180 s passed first; **NOT-SUBMITTED** when the create was refused. Only PASS is evidence of GPU execution after return.
  It is rehearsed on kind with the fake mode's echo command, including the refused-create case.

**Exercise Z (zero clear), the runbook end to end.**
1. Place W on the card as above; a watch on W's Pods and Workload (with UIDs) starts before any injection. The watch covers W only; for any other Pod the runbook's latch-to-hold interval stays unobserved (Open).
2. Inject field 230 := 79; step 0 is observed (latch, taint, W's Workload deactivated, W's Pod gone).
3. Steps 1 and 2 (hold, incident capture).
4. Inject 230 := 0; the platform clears the latch and removes `gpu-fault`.
5. The code allows W's Workload to be reactivated at any time after its eviction, before or after the hold; the time is recorded, and the asserted state is only this: W is active and admitted, and its new Pod is Pending with a `FailedScheduling` event that names the `diag-hold` taint.
6. Steps 3 to 6 (drain, no repair, diagnostic, decision). The drain should find W's Pod Pending and nothing Running; it is recorded as "verified empty", and operator eviction of a running Pod is **not exercised**.
7. On return (7a): W's Pod Running on the card's node (scheduling recovery), then W is deleted and R runs. On keep (7b): the decision is recorded.
   On **both** branches, before the hold or the simulator node's taint is removed and before exercise A starts, W (and R if it ran) is deleted and its Job, Pods and Workload are confirmed gone, so nothing from Z can start during teardown or contaminate A.
   On 7b the hold's later removal is teardown, **not** a return.
8. Only now, after the diagnostic's output is copied out: the exporter Pod and the device-plugin Pod are each deleted once, must return Running on the node, and the exporter's new Pod name is re-read, its `/metrics` must carry the same UUID, and allocatable `nvidia.com/gpu` must be 1 again. A recreated host engine starts from an empty cache (`hack/lib/gpu-fault.sh:519-520`), which is why this comes last. On 7b it runs with the hold still in place, which is what tests the new tolerations; on 7a the hold is gone and it tests only recreation.

**Exercise A (acknowledgement mechanics), narrowed.**
It shows what an acknowledgement does to the latch and that deleting it re-arms the latch; it involves **no workload** and **no return decision**, so it shows nothing about displacement or re-admission under acknowledgement.
1. Re-read the exporter Pod; place `diag-hold`; inject 230 := 79; the latch and `gpu-fault` appear.
2. Write the current fingerprint into `gpufault.platform.lkhun9311.github.io/acknowledged` **while the fault value is still injected**: the platform reports `GPUHealthy=True` with reason `Acknowledged` and removes `gpu-fault`, and `diag-hold` stays.
3. Delete the acknowledgement while the fault value is still injected: the platform must latch again on its next reading.
4. Inject 230 := 0; the latch clears. The hold is removed as teardown, not as a return.

**Part 2 verdict, per step:** **EXECUTED** (the object changed as written, evidenced), **FAILED** (it did not, naming the step and the object), **NOT-REACHED** (an earlier step stopped the session, or the deadline came).
A step that did not run is never counted as one that failed.

**Bars, the runbook's falsifiers:**
- after Z.4, `gpu-fault` is gone and `diag-hold` remains;
- at Z.5, W is active and admitted and its new Pod is Pending with a `FailedScheduling` event naming `diag-hold`;
- after Z.7 on return, W's Pod ran on the card's node and R is PASS;
- after Z.7 on either branch, no Job, Pod or Workload of W or R remains;
- at Z.8, both infrastructure Pods are back Running, with the same UUID and allocatable 1;
- after A.2, `GPUHealthy=True` with reason `Acknowledged`, and `diag-hold` remains;
- after A.3, the latch is held again.

None of these says anything about whether a diagnostic would have disagreed with a real fault: no physical fault was deliberately induced, and no card independently known to be faulty was selected; any fault the card shows by itself is kept as evidence.

## Cost

**Price read method.**
The runner reads `aws ec2 describe-spot-price-history` for g5.2xlarge `Linux/UNIX` at launch, records it in `spot-prices.txt`, and tries only zones at or under the $1.10 compute cap.
The price is **to be read** on the day.
On 2026-11-01 the zones read $0.6769 to $0.6887 an hour (`hack/gpu-fault/2026-11-01-run3/spot-prices.txt`), a value from another day.

**Phases, counted from EC2's `LaunchTime`** (every length is a convention of this page; the new runner's constants supersede these and the arithmetic is re-done from them, rehearsal item 8):

| phase | ends at | contents |
|---|---:|---|
| host preparation | 720 s | driver and toolkit checks, the driver comparison, no kind |
| Part 1, diagnostics | 3,420 s | image pull, container-start overhead, evidence rows, `-r 1` x3, `-r 3` x1, `-r 2` x3 (2,700 s) |
| kind bring-up | 4,020 s | kind, node toolkit, device plugin, overlay (600 s) |
| Part 2, platform and runbook | 5,220 s | platform phase, smoke cell, exercises Z and A (1,200 s) |
| evidence | 5,340 s | final archive and upload |
| instance stop | 5,400 s | `shutdown -h now` from the instance's own backstop |

**Expected duration, by component** (estimates, not measurements): host preparation 163 s and kind bring-up 163 s (each half given the whole historical span's 2 min 43 s, an over-estimate for each half), image pull 120 s (assumed, to be measured), evidence rows 60 s, `-r 1` 3 x 60 s, `-r 2` 3 x 120 s, `-r 3` 900 s, Part 2 1,200 s (its full phase, as a convention), evidence 120 s.
Sum: 163 + 120 + 60 + 180 + 360 + 900 + 163 + 1,200 + 120 = **3,266 s**.
At the 2026-11-01 zone prices plus the $0.0324 an hour of gp3 and IPv4: (0.6769 + 0.0324) x 3,266 / 3,600 = $0.6435, and (0.6887 + 0.0324) x 3,266 / 3,600 = $0.6542, so about **$0.64–0.65**, to be re-read at launch.

**Operating allowance, not a maximum:** (5,400 + 900) s = 1.75 h at the all-in $1.1324 = **$1.98**, conditional on the backstop, the sweeper or the laptop terminating the instance.
If all three fail, spending continues at up to $1.1324 an hour until a person notices.
Two attempts at the allowance are **$3.96**.
The owner's envelope for this item is $3 to $10 (`08-개발방향-재정렬.md`, section 6); a second attempt needs its own approval, as run 2 of the gpu-fault study did.

**Termination chain, reused:** the instance's backstop armed first and re-armed from `LaunchTime`; `--instance-initiated-shutdown-behavior terminate`; the sweeper's `study-deadline` tag; the laptop's EXIT, INT and TERM traps calling `spot_terminate`, which waits for `terminated` and prints TERMINATION UNCONFIRMED otherwise.
The in-session aborts above (driver mismatch, contaminated card) shut the instance down at once rather than waiting for the backstop.
The deadlines (study-deadline at `LaunchTime` + 5,370 s, the termination wait to `LaunchTime` + 5,700 s) follow the inherited runner's pattern and are **re-derived from the new runner's constants** before freezing.

**Account constraint.** The SCP `deny-instance-family` in this repository's configuration allows only `t3.*`, `g4dn.*`, `g5.*` and `g7e.*`; that is the committed policy, not a reading of what is attached live today.

## What it does not show

- **Not a defect-detection rate.** No bad card is tested, and no figure here is a sensitivity, a specificity or a false-re-admission rate. The roadmap row this replaced, "거짓 재편입 0건", is exactly what this cannot claim.
- Not that the card is healthy: it has no known fault.
- Not whether `-r 1/2/3` would flag a real Xid 48, 63/64, 79 or 94/95, degraded memory, a thermal throttle or a downtrained PCIe link: nothing was induced.
- Not a level's isolated cost: the durations are observations in one registered order on a card whose state carries from run to run.
- Not that nothing else touched the card during Part 1: only foreign compute processes at a 2 s cadence, and other host engines once, are checked.
- Not a fleet statement: one instance, one card, one driver, one DCGM version, one day.
- Not about EKS, multi-GPU nodes, NVSwitch, MIG, or H100/B200 diagnostics.
- Not about the platform detecting a real fault: Part 2 uses an injected fault, with all of the gpu-fault study's limits (`2026-10-27-gpu-fault-reaction-design.md`, "What it does not license"), and its diagnostic ran on a host engine carrying injected values.
- Not displacement or re-admission under an acknowledgement: exercise A has no workload.
- Not any repair: a card that would need a GPU reset or a reboot leaves this runbook with keep, and recovery by either is not shown.
- Not that the decision rule is correct: it is stated so it is checkable, and it has been tested against zero faulty cards.
- Not a guarantee against early return: the window between latch and hold remains open, and tolerating or directly bound Pods are not stopped by a taint.
- Not an automation: the platform does not call `dcgmi diag`, and nothing here changes a controller.

## Implementation work this page needs, none of which exists today

1. A new runner, hack/dcgm-diag-session.sh, splicing host preparation and the kind bring-up as two child processes with their own anchors and phases.
2. The Part 1 procedure: frozen container invocation, the driver comparison and abort, limits and cancellation with the contaminated-card abort, the isolation monitor and host-engine precondition, before/after state reads, incremental upload.
3. The overlay config/dcgm-diag: diagnostic image and `/diag-out` in `hostengine`, `diag-hold` tolerations for the exporter and the device plugin, `gpu-fault` for the device plugin.
4. The Part 2 procedure: placement, W, the new dd_recovery_probe for R, the watch, exercises Z and A, the bar checks, the Part 2 diagnostic's limit and residual check.
5. The new refusals listed above, each with a bent-copy test.
6. The two price constants, and the sweeper check over every datapoint (the second is also a defect in the inherited gpu-fault runner, to be fixed there separately).

## Free rehearsal, before anything is bought

Each item needs no GPU and no AWS spend, and none is a result of the study.
1. **Pick and read the diagnostic image, with an archived transcript.** Done on 2026-11-04 for DCGM 3.3.9 and 4.4.2 (`hack/dcgm-diag-inspect-image.sh`, `hack/dcgm-diag/2026-11-04-image-inspection`): digests, `dcgmi --version`, `dcgmi diag --help`, packages, plugin tree, the engine probe and the binaries' strings. Still to read before registration: the level-2 test list and status words as the help and the plugins name them, and whether the image carries `tar`, `timeout` and `pgrep`.
2. **Version pairing.** 4.4.2 is chosen (above), so the exporter moves with it: pull `nvcr.io/nvidia/k8s/dcgm-exporter:4.4.2-4.7.1-ubuntu22.04`, record its index digest and `dcgmi --version`, and show on kind that, run with `-r localhost:5555` against a 4.4.2 `hostengine` container, it serves fields 230, 311 and 310 and utilisation from the repository's metrics file. On the card, the paid preflight before Part 2 is the same check against the real host engine; if it fails, Part 2 is **NOT-REACHED (incompatible)** and Part 1 stands.
3. **The no-card failure shape.** `dcgmi diag -r 1 -j` with no GPU: keep its exit status, stdout and stderr as the fixture for V2 and V2b only. It is not a model of the successful output; a fixture of external output must come from the producer.
4. **The runbook on kind.** `hack/gpu-fault-reaction.sh` builds cluster `gpufault` with a fake DCGM; exercise Z's steps and exercise A run there, labelled REHEARSAL, with the diagnostic replaced by recorded decision inputs: one set that returns, and one set for each keep condition of the rule. What this rehearsal **cannot** show is listed under "Open" below.
5. **Refusals on bent copies, one at a time on a clean tree.** Image digest absent, `nvvs` listing absent, wrong instance type, wrong AMI ID, expected driver absent from the registration, credentials too short at the late re-read, a sweeper answer with two out-of-order datapoints one of which has an error: each must print `SESSION REFUSED` and exit non-zero before any AWS call that spends. The driver mismatch, which is an in-session abort, is shown by running the instance-side check against a stubbed `nvidia-smi` printing another version: it must upload, stop, and leave `REFUSED (driver)`.
6. **The two splices.** Each span runs as its own child process against the stubbed instance tooling (`hack/test/spot-lifecycle`); the host span is shown not to create a cluster, and the kind span is shown to reach the cluster through `KUBECONFIG` it sets itself.
7. **The cancellation path, three stubbed cases and one real one.** The laptop has no GPU, so its `nvidia-smi` cannot read clean; the check is rehearsed with `nvidia-smi` and `pgrep` replaced on `PATH` by stubs, and a container that ignores TERM run past a short limit and killed: (a) both stubs print no row and exit as a clean host would (0 and 1), and the next run starts; (b) the `nvidia-smi` stub prints one compute-process row, and the contaminated-card abort must follow (later runs NOT-RUN, Part 2 not started, shutdown called); (c) the `nvidia-smi` stub exits 9, and the same abort must follow as **unreadable**, not as clean. The first **real** clean read happens on the card: the session's preflight, before Part 1, runs the same cancellation once on a `sleep` container from the diagnostic image and must read clean, or the session aborts before any diagnostic as REFUSED (cancellation check).
8. **Cost and timing arithmetic, re-done from the new runner's constants** rather than from this page's.

## Open

The fourth review's five blockers, as this revision leaves them:
- Freshness after a steady zero: **closed in the text.** Step 7a no longer waits for a newer reading; it waits stale-after plus one interval after deleting the acknowledgement and reads `GPUSignal=True` with reason `Fresh`, on the reconciler and source behaviour cited there.
  Not yet rehearsed: rehearsal item 4 must show it on kind with a steady zero.
- The card's identity in the diagnostic: **narrowed.** The inspection shows key strings for entity, serial and device ID and none for a UUID, so the rule binds the diagnostic to the card through the serial `nvidia-smi` pairs with the UUID.
  Whether `-j` output really carries the serial for the tested entity needs a GPU; if it does not, every decision is keep, and the study reports that rather than repairing it.
- Device-plugin health before return: **closed in the text** (step 7a's readiness row: Node `Ready`, device-plugin and exporter Pods `Ready`, allocatable `nvidia.com/gpu` 1). Not yet rehearsed.
- The laptop cancellation rehearsal: **closed in the text** by stubbing `nvidia-smi` and `pgrep` for three cases and moving the first real clean read to the session's preflight (rehearsal item 7).
- The diagnostic's host engine: **verified without a GPU and closed in the text.** `dcgmi diag` given an unreachable `--host` prints a connection error and returns a result anyway, while `dcgmi discovery` refuses; Part 2 now names `--host localhost:5555`, checks `discovery` first and treats the connection error as INVALID (engine). What the embedded engine would test on a real card is not needed and not bought.

New from this revision, open until rehearsal item 2 is done: Part 2 runs a DCGM 4.4.2 exporter and host engine, not the platform's 3.3.9 pair, and the 4.4.2 exporter has not been pulled or shown to serve the fault fields.

Known weaknesses from the second review that this draft does not fix, kept here so they are not mistaken for settled:
- The kind rehearsal (item 4) uses `gpu-simulator`, one DaemonSet that stands in for both the exporter and the device plugin and tolerates every taint, so it would pass even if the overlay's new tolerations were missing; the infrastructure-recreation bar (Z.8 on keep) is therefore first tested on the paid card, and on a return it is not tested at all. A fix would render the production DaemonSets' scheduling fields onto two stand-ins.
- Step 1's retrospective Pod list can miss a Pod that started and was deleted inside the latch-to-hold window; Z.1's watch covers W only, so for every other Pod that interval is unobserved, in the study and in the runbook.
- The drain (step 3) selects Pods by `nvidia.com/gpu` requests and checks compute processes; it does not inventory privileged host users of the device or graphics clients, and in Z it finds nothing to evict, so operator eviction is not exercised.
- On a return in Z, infrastructure recreation (Z.8) runs after the hold is gone, so the new tolerations are tested on the paid card only on the keep branch; a fix would recreate under an explicit test hold on both branches.
- The journal rule trusts `journalctl` to start exactly after the saved cursor; whether it silently seeks to the nearest surviving entry when that cursor has rotated away (as the review says systemd does; **not verified here**) is not checked, beyond comparing against the journal saved at step 2.
- The splice rehearsal (item 6) uses stubbed instance tooling; the repository's real GPU-free bring-up rehearsal (`hack/test/rehearse-bringup.sh`) is not yet required for the two-process handoff.
- Incremental upload has no completion manifest or retried, verified uploads, and the laptop's downloader fetches a fixed list (`hack/gpu-fault-session.sh:357`), so a partial bundle after an interruption may not be recoverable as promised.

## Decisions for the owner before this is registered

1. Approve Option A with Part 1 first, or ask for B alone (cheaper, shorter, no platform objects change).
2. Approve $1.98 as the one-attempt operating allowance, and say whether a second attempt is pre-approved on a void first one.
3. Approve the runbook's use of an operator-placed second taint as the hold, the decision rule's stricter-than-platform Xid and ECC terms, and its limit to recovery within one boot.
4. Approve the implementation work above as the scope before any purchase.
5. Name another AMI if not `ami-097edab977037f65f`.
