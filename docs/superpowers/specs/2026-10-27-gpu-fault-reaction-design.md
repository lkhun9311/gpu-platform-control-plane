# How long the platform takes to react to a GPU fault DCGM reports: a registration

Written 2026-10-26 and 2026-10-27, before any run.
**Registered and frozen for purchase, 2026-10-27, at the commit that carries this line.** The owner approved every valid experiment of 2026-10-27, this one among them, on 2026-10-26 ("유효 실험도 전부 승인하니 진행"); nothing below changes after this commit, and a run from any other commit does not count.
Until this line, the page said: "Draft. Not registered: it becomes the registration only by the owner's approval, from the commit that records that approval, and no run before it counts."
Two parts: a free rehearsal on kind with a fake exporter, which tests the apparatus and is never a result; and one paid session on one g5.2xlarge, the only run this page can score as a result.
The first draft was attacked by codex `gpt-6-astra` before anything was built on it; its seventeen findings and what was done with each are in "Adversarial review" at the end, and the prompt and reply are in `docs/superpowers/specs/data/2026-10-27-gpu-fault-reaction/`.

## Why

`docs/03_GPU_NODE_LIFECYCLE.md` and `docs/06_OBSERVABILITY_BENCHMARK_FAILURE.md` both state the gap: nothing DCGM, Xid or ECC reports reaches `NodeHealth`.
The reconciler reads the Node's `Ready` condition and nothing else, so a card that reports an uncorrectable error on a node whose kubelet is healthy is invisible to this platform, and a training job keeps running on it.
Fault handling of that kind is what GPU platform operators are asked for (NAVER Cloud GPUaaS Infra, "GPU 서버 자원 모니터링, 장애 대응 및 운영 자동화 도구 개발" with "NVIDIA DCGM 및 Prometheus, Grafana"; 42dot, "GPU 하드웨어 및 소프트웨어 스택 전반의 장애를 모니터링하고 진단하여 고가용성 유지 및 신속한 장애 복구"), and what a large run meets in practice: a 504-GPU pre-training run identified ten GPU failures by Xid (arXiv 2605.09370), and Toss describes health checks and preflight as the first layer of its GPU cluster (https://toss.tech/article/gpu-native-cluster).
This page builds the missing path and asks how long each hop of it takes, and whether it stays quiet when nothing is wrong.

## The question

When DCGM holds a GPU fault value for a node's card — an Xid in `DCGM_FI_DEV_XID_ERRORS` or a double-bit ECC count in `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL`, put there by injection — how long does each hop of this platform's reaction take, from the value being in DCGM to the displaced training job being placed on a healthy node; do a benign field change and no change at all, both watched by a working observer, produce no reaction; and does missing data neither set nor clear a fault?

## The known boundary: this measures the platform's path, not the device plugin's

Verified against the sources, 2026-10-26:
- `dcgmi test --inject` writes into DCGM's cache: its parser describes the switch as "Inject values into cache.", requires `-f/--field` and `-v/--value`, takes a single `--gpuid` (default **1**, so the runner always passes `--gpuid 0`), and `--offset` is the "Number of seconds into the future in which to inject the data", default 1 (NVIDIA/DCGM, dcgmi/CommandLineParser.cpp, function ProcessAdminCommandLine; upstream names, not files in this repository).
  The library call is `dcgmInjectFieldValue(dcgmHandle_t, unsigned int gpuId, dcgmInjectFieldValue_t *)`, which "injects a sample into the cache manager" (`dcgmlib/dcgm_test_apis.h`).
  The help text of the **exact** `dcgmi` in the pinned exporter image shows the same flags: version 3.3.9, extracted from layer `sha256:8e0a5837…` of `nvcr.io/nvidia/k8s/dcgm-exporter@sha256:19a6d4fe…`, the amd64 manifest of the digest `config/dcgm-exporter/daemonset.yaml` pins. That layer also carries `/usr/bin/nv-hostengine` and `libdcgm.so.3.3.9`.
- `dcgmi test --introspect` does **not** read a value back: the same binary's strings for that output are cache metadata ("Newest Timestamp", "Oldest Timestamp", "Fetch Count"). The readback is therefore `dcgmi dmon -e <field> -i 0 -c 1`, whose row for the card is `GPU 0 <value>`; that this row carries the injected value is something the smoke cell must show (S3).
- Field identifiers, `dcgmlib/dcgm_fields.h`: `DCGM_FI_DEV_XID_ERRORS` is an alias of `DCGM_FI_DEV_XID_ERROR`, **230**, "The value is the specific XID error"; `DCGM_FI_DEV_ECC_SBE_VOL_TOTAL` **310** and `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL` **311**, "Total single/double bit volatile ECC errors".
- dcgm-exporter 3.3.9-3.6.1's default counters export `DCGM_FI_DEV_XID_ERRORS` as a gauge, "Value of the last XID error encountered", and carry the four ECC totals **commented out**; the study overlay `config/dcgm-exporter-fault/` names all three fields itself.
- The NVIDIA k8s-device-plugin's health check (NVIDIA/k8s-device-plugin, internal/rm/health.go, at v0.16.2, the version `config/nvidia-device-plugin/daemonset.yaml` pins) creates an NVML event set, waits on eventSet.Wait(5000), skips every event that is not an NVML Xid-critical-error event, and has no reference to DCGM.
  An injected DCGM value produces no NVML event, so **the plugin is not expected to mark the device unhealthy, and `allocatable` is not expected to change**.
  What is measured here is this platform's reaction to what DCGM reports, not the device plugin's, and not what a real fault does to NVML.
- Injection needs a host engine to connect to. The exporter as `config/dcgm-exporter/` deploys it runs DCGM embedded, which opens no port for `dcgmi`.
  The study overlay therefore runs `nv-hostengine -n` (bound to 127.0.0.1, its default) as a second container in the exporter's Pod, and the exporter with `-r localhost:5555` (`--remote-hostengine-info` in the 3.3.9 binary's `--help`), so the exporter and `dcgmi` read and write one cache.

Not verified, and confirmed or refuted only by the paid smoke cell (S1 to S6 below):
- that `nv-hostengine` starts inside a kind node on an A10G and lists the card;
- that the exporter in remote mode exports what the host engine holds, so an injected value appears on `/metrics`;
- that `dcgmi dmon` returns the injected value;
- that an injected value **persists** against DCGM's own polling. Field 311 is read from NVML on each update, and a sample injected one second in the future (the default offset) would be the newest only until the next poll.
  The runner injects every value with a fixed offset of 900 s, so the injected sample is the newest by timestamp for 900 s, longer than one repetition plus its reset (260 s at most, below); a later injection, at a later wall time with the same offset, is newer still, so a reset supersedes the fault.
  That DCGM returns the newest sample by timestamp rather than the last one written is the reading this rests on, and S3 to S5 test it for 30 s;
- that field 311 and field 310 can be injected and exported on an A10G at all.

## The platform's reaction, as built for this study

Opt-in and inert by default: nothing below runs unless the operator is started with `--gpu-fault-source=dcgm`, and nothing is evicted unless it is also started with `--gpu-fault-evict-workloads`.
The operator scrapes each node's exporter Pod directly once a second (`--gpu-fault-scrape-interval`, timeout `--gpu-fault-scrape-timeout` 0.8 s), and a reading older than `--gpu-fault-stale-after` 5 s is not fresh.
5 s is a convention: four missed scrapes, so that one slow scrape does not flap the signal; `GPUFaultSourceConfig.Validate` refuses a stale-after that does not exceed the interval.
Each hop is stamped by the component that performs it.

| hop | what happens | where its time comes from |
|---|---|---|
| H0 | the runner injects, then reads the value back with `dcgmi dmon` | the runner's host clock, `date +%s.%N`, just before the injection call and when it returns: the value became available inside **[t_inj0, t_inj1]**; the readback afterwards, **t_rb**, confirms it and starts nothing |
| H1 | the exporter serves the value on `/metrics` | the runner's probe, which reads `/metrics` through the apiserver's Pod proxy every 0.2 s plus one request: **t_exp**. A poll, because the exporter carries no per-sample timestamp |
| H2 | the operator's scraper reads the value | annotation `gpufault.platform.lkhun9311.github.io/observed-at` on the `NodeHealth`, RFC 3339 with nanoseconds: when the scrape that first carried the fault fingerprint returned, **t_obs** |
| H3 | the reconciler sets `GPUHealthy=False` (reason `XidError`, `EccDoubleBitError` or `MultipleFaults`) and taints the node `platform.lkhun9311.github.io/gpu-fault=true:NoSchedule` | annotation `…/tainted-at`, written after the Node patch succeeded: **t_taint** |
| H4 | the reconciler deactivates the Kueue `Workload` of each GPU Pod on the node (`spec.active=false`) | annotation `…/deactivated-at` on the Workload, the time the patch was sent: **t_deact** |
| H5 | Kueue decides the eviction: `Evicted=True`, reason `Deactivated` | that condition's `lastTransitionTime`, whole seconds: **t_evict**, the eviction decision only |
| H5a | Kueue's Job integration suspends the Job | the Job's `Suspended=True` condition, whole seconds: **t_suspend** |
| H5b | the quota is released | the Workload's first `QuotaReserved` not `True` after the deactivation, in the order the watch delivered them, whole seconds: **t_release** |
| H6 | the displaced Pod's container stops | its `state.terminated.finishedAt`, whole seconds: **t_stop** |
| H7 | the reconciler reactivates the Workload it deactivated, once Kueue reports it evicted and its quota released; Kueue requeues and re-admits it | annotation `…/reactivated-at` (nanoseconds), then the first `QuotaReserved=True` after the release in stream order: **t_readmit** (whole seconds) |
| H8 | the new Pod is bound to the healthy node and its container starts | its `PodScheduled=True` `lastTransitionTime` on the healthy node, and `state.running.startedAt`, whole seconds: **t_placed**, **t_run** |
| H9 (reset) | the runner injects zero back; the next fresh scrape reading every fault field at zero clears the condition and removes the taint | annotation `…/cleared-at` |

Every value the operator reads, the single-bit count included, is written to `…/reading` with the time it first appeared in `…/reading-at`, when it changes; that is the evidence a control's value was read and ignored rather than never read.

The un-fault path is deliberate and narrow. A latched fault clears only on a **fresh** scrape in which every fault field on every card reads **zero** — what a GPU reset or a driver reload leaves — or when an operator writes the current fingerprint into `gpufault.platform.lkhun9311.github.io/acknowledged`.
"No fault" is not enough: the Xid field holds the last Xid only, so an application Xid arriving after a fatal one replaces it and reads as no fault while nothing was repaired (`TestGPUFaultApplicationXidAfterAFatalOneKeepsTheLatch`).
Stale or missing data never clears a fault and never sets one.
Stale data has its own condition, `GPUSignal=False` with reason `Stale`, `NoExporter`, `AmbiguousExporter`, `ScrapeFailed` or `NoCards`; with no latched fault, `GPUHealthy` is then `Unknown`, never `True`.

The fault policy, and where each part of it comes from:
- an Xid is a fault unless it is 13, 31, 43, 45 or 68, the Xids NVIDIA's device plugin v0.16.2 ignores as application errors ("the GPU should still be healthy", in the plugin's internal/rm/health.go). Borrowed with citation, so that this platform's quarantine and the plugin's own unhealthy rule agree on which Xids are about the card;
- `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL` above zero is a fault: NVIDIA's Xid catalogue reports a double-bit ECC error as Xid 48, which is not in the ignored list;
- `DCGM_FI_DEV_ECC_SBE_VOL_TOTAL` is never a fault: single-bit errors are corrected, and the device plugin subscribes to them and acts on none. That is what makes it the benign arm;
- a card missing either fault field cannot be called healthy: `GPUHealthy=Unknown`, reason `FieldMissing`.

## Clocks and resolution

Both the rehearsal and the paid session run one kind cluster on one machine: the runner, the operator, Kueue, the apiserver and the kubelets read the same kernel clock, because kind nodes are containers on it. There is no cross-host offset.
The nanosecond stamps are the operator's and the runner's; every Kubernetes condition and container time is truncated to the whole second.
So every hop is reported as an interval `[lo, hi]`:
- from the injection bracket to a nanosecond stamp t: `[t − t_inj1, t − t_inj0]`;
- from the bracket to a whole-second time s: `[s − t_inj1, s + 1 − t_inj0]`;
- from a nanosecond stamp t to a whole-second time s: `[s − t, s + 1 − t]`;
- between two whole-second times: `[s2 − s1 − 1, s2 − s1 + 1]` (re-admission, and lost work).
Watch streams (`kubectl get -w -o json`) are recorded for the Node, the `NodeHealth`, the Workload, the Job and the job's Pods, because a deleted Pod's `finishedAt` exists nowhere else afterwards.
Kueue's transitions are identified by the order the Workload's watch delivered them, not by comparing whole-second stamps, which can reorder events inside one second.
Each watch records when it started and ended (`watch-<resource>.log`); a watch that started after the injection, ended inside the window, or restarted, leaves a gap whose contents are unknown, and the repetition is INVALID (V3), never quiet.

## Arms and repetitions

| arm | injection | expected platform action |
|---|---|---|
| `xid` | field 230 := 79 ("GPU has fallen off the bus", not ignored) | H2 to H8 |
| `ecc` | field 311 := 1 | H2 to H8 |
| `benign` | field 310 := 1 | none, and the reading recorded |
| `none` | nothing; after the window, a sentinel: field 310 := 100 + the repetition's number | none in the window, and the sentinel recorded |

Five repetitions per arm, twenty in all, in five blocks; block b runs the arms in the order rotated by b − 1 (`xid ecc benign none`, then `ecc benign none xid`, …), so drift over the session does not line up with an arm.
Five is a convention, not a power calculation: this is a characterisation with no hypothesis test, five gives a median and a range from distinct runs, and the session's length follows from it ("Phases").
For the controls it gives a count, "no reaction in n fully observed windows", and is published as that count, never as a rate.

**One repetition**, on both the rehearsal and the paid session:
1. Pre-state, read before anything is submitted: on the target node T, `GPUHealthy=True`, `GPUSignal=True`, no `gpu-fault` taint, no latched fingerprint; every field the smoke cell passed reads back 0.
2. The healthy node H carries the runner's own taint `gpufault-study/hold=true:NoSchedule`, so the job can only land on T.
   One `MLTrainingJob`, `gpuCount: 1`, image `busybox:1.36` rebuilt locally as the single-platform `gpufault-job:busybox` (kind's image import refuses the multi-platform original), a shell loop that traps SIGTERM and exits 143, is submitted into a ClusterQueue with a quota of **one** GPU, so re-admission needs the evicted quota back.
   When its Pod is `Ready` on T (at most 60 s), the hold taint is removed from H, and the runner waits 10 s; 60 s and 10 s are conventions, the second so that the displaced attempt has run for a measurable time.
3. The five watches start and must each have delivered their first objects; the exporter probe starts (not for `none`); `allocatable` on T is read; the injection call is bracketed (H0); `dcgmi dmon` reads the value back.
4. Observation for **W = 120 s** from t_inj1. W is an observation cutoff, a convention: four times the kubelet's default 30 s grace period. It bounds what the repetition can report, not how long the platform may take; a reaction not complete inside it is reported as not complete inside W.
5. For `none` only, the sentinel, then at most 10 s (ten scrape periods, a convention) for the operator to record it.
6. `allocatable` on T is read again; the watches and the probe stop; the final objects and the operator's log are saved.
7. Reset (H9): zero injected into every field the smoke cell passed; at most 60 s (a convention, an operating cutoff) for the target to read clear; the job deleted and its Pods gone. A reset that does not clear stops the arms, because every later repetition would start faulted.

**The longest repetition** is 60 + 10 + 120 + 10 + 60 = **260 s**, plus the deletion; the runner does not start a repetition with less than 260 s left in the arms phase, and records those it did not start.

## Endpoints, with units

Per fault repetition, intervals in seconds: **detect** (H0 bracket to t_obs), **taint** (t_obs to t_taint), **evict-request** (t_taint to t_deact), **Kueue eviction decision**, **Job suspension**, **quota release** and **container stop** (each from t_deact), **re-admission** (t_release to t_readmit), **end to end** (H0 bracket to t_placed, the headline: from the value being in DCGM to the job bound to a healthy node), **running** (to t_run), **lost work** (the displaced container's `startedAt` to `finishedAt`: the job keeps no checkpoint, so everything it did is lost), and **exporter lag** (H0 to t_exp, diagnostic).
Per control repetition: the list of platform actions in W (`GPUHealthy=False` in any `NodeHealth` object, a latched fingerprint, the `gpu-fault` taint in any Node object, any Workload with `…/deactivated-at`), and the evidence the operator was reading (V7).
Per arm: each endpoint's per-repetition intervals, and the median, minimum and maximum of their upper ends; no mean, no interval estimate.

## Registered predictions, and where each bound comes from

- **P1, detect.** In every valid fault repetition, the detect interval does not lie wholly above **2.8 s**.
  This is an **idealised** bound, derived from configuration under stated assumptions, not a measured one: the exporter collects once per 1.0 s (`-c 1000`, kept by the overlay), the operator scrapes once per 1.0 s, and one scrape takes at most its 0.8 s timeout, so a value written just after a collection is read at most 1.0 + 1.0 + 0.8 s later **if** collection and publication take no time, no scrape fails, and nothing waits to be scheduled.
  None of those holds exactly: the exporter formats and publishes after it collects, and a failed scrape adds a period (astra, finding 3).
  So a breach is reported with the operator's log, which records every run of failed scrapes ("GPU fault scrape failing"); a breach with a logged failure inside the repetition is explained by it, and a breach without one says the path is slower than the configuration alone predicts. Either way it is reported as a breach, before anything changes.
- **P2, the path.** In every valid fault repetition every hop H2 to H8 is present; the platform latches exactly the injected fingerprint; and t_inj0 ≤ t_obs ≤ t_taint ≤ t_deact, with t_evict, t_readmit and t_placed each no more than 1 s (truncation) before the hop preceding it.
- **P3, placement.** In every valid fault repetition the job's new Pod is bound to H, no new Pod of the job is bound to T after the taint, and the end-to-end interval's upper end is at most W. An interval that straddles W counts as not inside it.
- **P4, controls.** In every valid `benign` and `none` repetition, zero platform actions.
- **P5, the boundary (paid only).** `allocatable` `nvidia.com/gpu` on T is the same before and after every injection. A change is reported as an unexpected change **with its cause unresolved**: the device plugin also marks devices unhealthy on its own NVML errors, so a change alone does not show that injection reached NVML (astra, finding 14).
- **P6, stale data (both runs).** With the operator running, taking T's exporter away for 15 s (three stale-after periods, a convention): with nothing latched, `GPUSignal=False` with a no-reading reason, `GPUHealthy=Unknown`, no taint; with a fault latched, the fault, the taint and the fingerprint all stay; and after the exporter returns and zero is injected, the fault clears.
- No bound on taint, evict-request, the Kueue hops, re-admission, placement time or lost work: no derivation for one exists, and a bar picked now would be the kind of guess `docs/11_WHAT_THIS_MEASURED.md` ("What the targets were based on") records the earlier ones to have been. These are measured and reported.

## Validity, per repetition

A repetition is **INVALID**, reported with its reason and never scored, when:
- V1: the readback is not the injected value (`none`: not the baseline), or the recorded field is not the arm's;
- V2: the pre-state of steps 1 and 2 did not hold;
- V3: a watch stream is missing, empty or unparseable; a watch started after the injection began, ended inside the window or restarted; or the injection and window stamps are unreadable or out of order;
- V5: in an arm that injects, the exporter probe never served the injected value inside the window — the stimulus did not reach the exporter, so nothing the platform did is a reaction to it;
- V6: the repetition does not record which exporter it read (`fake` or `dcgm`); for the session, a tree dirty under `cmd/`, `internal/`, `config/` or `hack/`, or an image digest not recorded;
- V7 (controls): no evidence the operator was reading — for `benign`, the operator's recorded reading never carried the injected single-bit value inside the window; for `none`, it never carried the sentinel within 10 s of it.

What is **not** invalid, because it is the platform's output and the stimulus was established independently by the readback and the probe: a missing hop, a wrong order, a late or wrong placement, and a latched fingerprint that is not the injected one. Each is a result, scored against P2 or P3 with the predicate it broke.

## Verdict rules

Per arm, from its valid repetitions:
- fewer than **3** valid: **UNJUDGED** (a convention: the least that gives a median that is not an endpoint);
- an arm the smoke cell stopped: **NOT-RUN**;
- `xid`, `ecc`: **FAILED** when any valid repetition broke P2 or P3, naming each broken predicate (`P2-missing`, `P2-order`, `P3-late`, `P3-wrong-node`, `attribution`) and the evidence; otherwise **REACTED-OUTSIDE-BOUND** when P1 was breached in any; otherwise **REACTED**;
- `benign`, `none`: **QUIET** when P4 holds in every valid repetition, with the count of fully observed windows; **FALSE-POSITIVE** with each action otherwise.

Beside the arms: P5 (held, or failed with its cause unresolved) and the two P6 checks (PASS, FAIL or NOT-RUN).
The scorer labels the session **REHEARSAL** from the recorded mode when the exporter was the fake, **REFUSED** when there is no smoke record or the repetitions disagree on the exporter, and **RESULT** only for a `dcgm` session.

## Falsifiers

- detect wholly above 2.8 s with no failed scrape logged (P1);
- a control that taints, latches or deactivates (P4): the classifier is not what this page claims;
- the job re-admitted and not placed inside W while H has a free device, or placed back on T (P3);
- stale data that reads healthy, or that releases a latched fault (P6);
- a latch released by an application Xid rather than by zero or an acknowledgement;
- `allocatable` changing on injection, which would at least say the boundary above is incomplete (P5).

## The smoke cell, and what stops what

Run on both, before the operator is deployed so that nothing can react, and recorded in `smoke.env`:
- S1: the exporter Pod on T is Ready and serves field 230; on the paid session, `dcgmi` and `nv-hostengine` are in its `hostengine` container and `dcgmi discovery -l` lists an A10G;
- S2: `/metrics` carries fields 230, 311 and 310 for the card, and gives its UUID;
- S3, S4, S5, for 230 := 79, 311 := 1 and 310 := 1 in turn: inject; `dcgmi dmon` reads the value back; the exporter serves it within 10 s (ten collection periods, a convention); it is still served 30 s later (persistence, a convention longer than any detection chain expected); zero is injected, read back and served within 10 s;
- S6: `allocatable` on T before S3 and after S5.

| smoke outcome | consequence |
|---|---|
| S1 or S2 fails, or S3 (field 230) or S4 (field 311) fails | the session stops before any arm: the platform's policy needs both fault fields to call a card healthy, so no repetition could meet its pre-state. The answer is "injection is not visible through the exporter on this card for that field", which is what the smoke cell exists to find out, at the cost of the bring-up |
| S5 (field 310) fails | `benign` and `none` are NOT-RUN, because both use field 310 (the injection and the sentinel); `xid` and `ecc` run |
| all pass | all four arms run |

## The paid session

One g5.2xlarge Spot instance (one A10G), the `gpu-lab` account (`007635145730`), `ap-northeast-2`, the AMI pinned by ID: the Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) that run 3 of the MPS capability study used, `ami-097edab977037f65f`, unless the owner names another at approval.
Runner: `hack/gpu-fault-session.sh`. It reuses rather than copies: the EC2 lifecycle of `hack/lib/spot-run.sh`, and the instance bring-up of `hack/m5c-gpu-session.sh` spliced between its two anchor lines, exactly as `hack/mps-capability-session.sh` does; the cell procedure is `hack/lib/gpu-fault.sh`, the same file the rehearsal runs; the instance side is `hack/gpu-fault-instance.sh`.
The operator, `gpu-simulator` and job images are built on the laptop from the committed tree, shipped as checksummed tarballs and loaded into kind; Kueue comes from `config/kueue-controller/manifests.yaml`, the pinned v0.18.3.

**Topology on the instance.** The bring-up creates kind cluster `m5cgpu`: a control-plane and one worker holding the card.
The worker is T: the real A10G, the NVIDIA device plugin, the study exporter with its host engine.
The control-plane is H: its control-plane taint removed and `gpu-simulator` pinned to it, advertising one simulated `nvidia.com/gpu`.
**So re-admission on the paid session lands on a simulated device**, and that is stated with every number from it: what the paid session measures on real hardware is H0 to H6, DCGM to eviction; placement on a healthy node is the same scheduler and Kueue path on both clusters, and a second real card would add cost without adding a hop.

**Phases, from EC2's `LaunchTime`, as `hack/mps-capability-session.sh` counts them:**

| phase | ends at | contents |
|---|---:|---|
| bring-up | 720 s | the spliced bring-up, measured at 2 min 43 s on a warm AMI (`docs/superpowers/specs/2026-10-22-paid-retry-candidates.md`); 720 s is the MPS session's registered phase-1 limit, reused |
| platform and smoke | 1,320 s | images loaded, Kueue, CRDs, device plugin, `gpu-simulator` on H, the study exporter, the smoke cell (S3 to S5 take about 60 s each), then the operator and the tenant |
| arms | 6,520 s | twenty repetitions of at most 260 s, 5,200 s |
| stale checks | 6,820 s | P6, two cells of at most about 120 s |
| evidence | 6,940 s | tar and upload |
| instance stop | 7,000 s | `shutdown -h now` from the instance's own backstop |

**Stop rule.** Each phase ends at its deadline whatever has run; a repetition is not started with less than 260 s left, and one the deadline cuts anyway is scored as cut.
A reset that does not clear, or a step that cannot run (a job that cannot be submitted, a hold taint that cannot be set), ends the arms phase and goes to the stale checks and the evidence.
Nothing is re-bought: one attempt, reported as it ran.

**Termination**, inherited from the existing runners rather than written again:
- the instance shuts itself down at `LaunchTime` + 7,000 s from a backstop armed as its first line and re-armed precisely once `LaunchTime` is read, and `spot_launch` sets `--instance-initiated-shutdown-behavior terminate`;
- the launch carries the termination sweeper's `study-deadline` tag at the request plus 6,940 s, rewritten to `LaunchTime` + 6,970 s once `LaunchTime` is known, so a sweep cannot cut the evidence step; the sweeper (`gpu-platform-study-sweeper`, a five-minute schedule) is checked before anything is bought: Active, enabled, aimed at itself, and seen running at least four times without error in the last half hour;
- the laptop's EXIT, INT and TERM traps call `spot_terminate`, which waits for `terminated` and prints TERMINATION UNCONFIRMED otherwise; the wait may run until `LaunchTime` + 7,300 s, because MPS run 2 was voided by a fixed 300 s;
- an earlier instance with this study's `purpose` tag still live refuses the purchase.
`hack/lib/gpu-ttl.sh` is not used: its `ttl_arm` scales an EKS node group to zero, and this session has no node group; the instance's own backstop and the sweeper are its deadline.

None of these is a guarantee on its own (astra, finding 13): the sweeper *requests* termination, its errors are caught per instance, and EventBridge documents delivery delays.
A TERMINATION UNCONFIRMED is therefore an instruction to the operator to terminate by hand at once, and the session exits non-zero.

**Cost.** The rate is the repository's worst-case rate for this instance, **$1.1324 per instance-hour** (Spot cap $1.10, 200 GB gp3 and a public IPv4; `docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md`, "The worst-case rate per instance-hour").
The operating allowance, not a maximum, follows that page's convention of the sweeper's tag plus 15 minutes: 6,970 + 900 s, 2.19 h, **$2.48**, conditional on the backstop, the sweeper or the laptop terminating the instance.
Expected: about 1.7 h at the $0.68/h measured for g5.2xlarge Spot on 2026-09-10 (`docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md`), about **$1.2**. The session reads the live price, records it, and tries only zones under the cap.

**To buy it**, after the owner approves this page and the tree is committed and clean:

```
SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab GPU_FAULT_AMI_ID=ami-097edab977037f65f bash hack/gpu-fault-session.sh
```

Credentials: an SSO session for the `gpu-lab` profile in account `007635145730` whose exported credential expires at least 155 minutes after the start (the 122 minutes to the end of the termination wait and 30 of headroom), with the rights `hack/mps-capability-session.sh` already uses: EC2 Spot launch, describe and terminate, tags, S3 on the study bucket, IAM instance-profile creation, Service Quotas, Lambda, EventBridge and CloudWatch reads.

## What it does not license

- Nothing about what a **real** Xid or ECC error does: a real fault arrives through NVML, may take the card off the bus, may hang the device plugin, and may need a GPU reset or a reboot; injection exercises none of that.
- Nothing about the device plugin's health path, `allocatable`, driver resets, row remapping, or DCGM's own policies and health watches, which are a different DCGM path.
- Nothing about many nodes faulting at once, fault storms, a flapping exporter, or the apiserver under load: one node, one card, one job at a time.
- Nothing about checkpointed training: lost work here is the whole displaced attempt.
- Nothing about a frozen exporter cache. The exporter carries no collection timestamp, so a host engine that stopped updating while the exporter kept serving its last snapshot reads as fresh; only a failed scrape is detected as stale.
- Nothing about EKS: kind, on one machine, with one clock.
- Not that 2.8 s is a service level anyone needs: it is what this configuration should deliver under its assumptions, and the test is whether it does.
- Not a false-positive rate: zero actions in n windows is a count of windows.

## Rehearsal on kind

`hack/gpu-fault-reaction.sh` builds kind cluster `gpufault` (context `kind-gpufault`, `hack/kind-config-gpufault.yaml`) from this tree in the paid session's topology: the worker is T and the control-plane, untainted, is H, each advertising one simulated `nvidia.com/gpu` from `gpu-simulator`, whose fake DCGM (`FAKE_DCGM_ADDR`) serves the three fields per simulated device from a cache it snapshots once per `FAKE_DCGM_COLLECT_MS` (1,000 ms by default, matching `-c 1000`), keeps the newest sample by timestamp, and answers injection, readback and an exporter on/off switch over HTTP in place of `dcgmi` and the exporter Pod leaving.
It runs the same `hack/lib/gpu-fault.sh` procedure — smoke cell, arms, stale checks — scores with the same scorer, and deletes the cluster.
It proves the apparatus, the scorer and the refusals; it measures nothing about DCGM.

### Rehearsal result, 2026-10-26: REHEARSAL, every arm as predicted, both stale checks PASS

Run `hack/gpu-fault-rehearsal-20261026T150138Z/`, three blocks (`GF_BLOCKS=3`, twelve repetitions, three per arm, the least the verdict rules judge), from an uncommitted tree (its `provenance.txt` records the dirty-file count), on the fake exporter.
Shortened from five blocks because the host's kind capacity was contended (below); the scorer counts what ran.
The smoke cell passed S1 to S6 on the fake; `allocatable` was 1 before and after (P5 held, trivially, since the fake has no NVML).

| arm | verdict | valid | detect, upper end (median, min, max) | end to end, upper end | lost work |
|---|---|---|---|---|---|
| `xid` | REACTED | 3 of 3 | 0.864, 0.654, 0.925 s | 2.402, 2.192, 2.463 s | upper end 13 s in all three (each interval [11, 13]) |
| `ecc` | REACTED | 3 of 3 | 0.905, 0.818, 1.015 s | 2.443, 2.356, 2.553 s | upper ends 12 to 13 s |
| `benign` | QUIET | 3 of 3 | — | — | — |
| `none` | QUIET | 3 of 3 | — | — | — |

The in-process hops were milliseconds: observed to tainted 8 to 12 ms, tainted to the deactivation patch 33 to 92 ms. Kueue's eviction decision, the Job's suspension and the quota release fell within the same second as the deactivation or the next; re-admission within ±1 s of the release; the new Pod bound to the control-plane node at most 2.2 to 2.6 s after the injection call (the intervals' upper ends).
P1 held in all six fault repetitions, detect at most 1.015 s against 2.8 s. The fake collects once a second as the real exporter is configured to, but has no DCGM or NVML behind it, so none of these numbers says anything about a card.
Every control window was observed: the benign value and every sentinel appear in the operator's recorded reading. Stale checks: with the fake exporter answering 503 for 15 s, `GPUSignal=False` (`ScrapeFailed`), `GPUHealthy=Unknown`, no taint; with Xid 79 latched first, the fault, the taint and the fingerprint stayed, and cleared after the exporter came back and zero was injected.

Refusals, shown on copies of this evidence bent one way each (the original is untouched): no `smoke.env` → REFUSED and a non-zero exit; a second start in one repetition's Pod watch → that repetition INVALID (V3) and `xid` UNJUDGED with two valid; a readback of 0 for an injection of 1 → INVALID (V1); the benign value removed from the operator's recorded reading → INVALID (V7); the deactivation stamp removed from a Workload stream → `xid` FAILED, a result rather than an invalid run.

Four attempts before it were void, and each is why something above is the way it is:
- two could not boot a kind node: the host's root inotify pool was exhausted by other sessions' clusters ("Failed to create control group inotify object: Too many open files"), which is why the rehearsal cluster has two nodes, not three;
- two failed loading the job image: Docker's containerd store exported busybox's multi-platform index, and the node's import refused it; images are now saved single-platform and loaded as archives, on the paid instance too;
- an earlier start of this run was stopped after its first repetition, because the watch stop killed a function's subshell rather than the `kubectl` in it, and the next repetition's ECC latch landed in the first repetition's stream: the scorer called it an `attribution` failure. The watch now records `kubectl`'s own PID, and the stop checks that it is gone.

## Adversarial review

codex `gpt-6-astra`, reasoning effort high, read-only, given the first draft with no instruction about where to look (`astra-registration-prompt.txt`, reply `astra-registration-reply.txt`).
Each finding was re-derived before it was acted on; the column "re-derived" says how.

| # | finding | re-derived | disposition |
|---|---|---|---|
| 1 | `dcgmi test --introspect` prints cache metadata, not the value | the pinned binary's strings for that output are "Newest Timestamp", "Oldest Timestamp", "Fetch Count" | adopted: readback is `dcgmi dmon -e F -i 0 -c 1`, parsed as the `GPU 0` row; S3 must show it carries the value |
| 2 | readback is after availability; t_obs < t_rb is a correct outcome | follows from H0 to H2 running concurrently | adopted: availability is the injection call's bracket, every hop is an interval from it, readback only confirms |
| 3 | 2.8 s omits collection, publication and failed scrapes | the arithmetic is right, the "worst case" was not | adopted: P1 stated as idealised under named assumptions; failed scrapes are logged on every run of them, and a breach is reported with that log |
| 4 | `Evicted=True` does not timestamp suspension or quota release | Kueue v0.18.3 sets Evicted, then its Job reconciler suspends and the quota clears later | adopted: H5 split into eviction decision, Job `Suspended`, quota release; a Job watch added |
| 5 | strict whole-second comparisons can lose re-admissions; both-truncated differences | arithmetic | adopted: Kueue transitions are read in stream order; both-truncated differences carry ±1 s; a straddle of W is not inside it |
| 6 | a non-empty, parseable watch can have disconnected | a disconnect leaves exactly such a file | adopted: start and end records per watch; a late start, early end or restart is V3 |
| 7 | V3 excluded the wrong-fingerprint outcome the study should detect | the stimulus is established by readback and probe, independently | adopted: a wrong fingerprint is a scored `attribution` failure, not INVALID |
| 8 | QUIET did not need a working observer | a dead scraper leaves the NodeHealth unchanged, which reads as quiet | adopted: the operator records every reading it takes on change; V7 requires the benign value, or the `none` sentinel, to appear in it |
| 9 | the stale falsifier had no cell | true of the draft | adopted: P6, two checks with the operator running |
| 10 | smoke stop and skip rules contradicted; a missing field breaks pre-state | true: a missing 311 leaves `GPUHealthy=Unknown` for every arm | adopted: the decision table above |
| 11 | 210 s per repetition did not add up | 60 + 10 + 120 + 60 = 250 | adopted: 260 s with the sentinel, derived; phases recomputed |
| 12 | conventions were explained as guarantees | true, and 60 / 2.8 is 21, not 30 | adopted: W, the reset and the start limits are stated as cutoffs |
| 13 | $1.92 was presented as a ceiling | the sweeper requests, it does not confirm | adopted: an operating allowance conditional on termination, with the escalation |
| 14 | an `allocatable` change does not prove NVML saw the injection | the plugin marks devices unhealthy on its own NVML errors | adopted: P5 failure is reported with its cause unresolved |
| 15 | an application Xid replacing a fatal one would clear the latch | true of the draft's rule, and of the first implementation | adopted, in the code: a latch clears only on all-zero fault fields or an acknowledgement; tested |
| 16 | "first missing hop" cannot describe an order or placement failure | true | adopted: FAILED with the named predicate |
| 17 | the rule of three has unstated assumptions; n may be under five | true | adopted: controls report a count of fully observed windows, no rate |

Rejected: none. Not verifiable here, and left to the smoke cell as the review also says: A10G field support, injection persistence, and whether `dcgmi dmon` returns an injected value.

## Code review of the implementation

`codex review --uncommitted` with `gpt-6-astra`, reasoning effort high, bare (no prompt), over the uncommitted implementation (`codex-review-uncommitted-1.txt`).
It ran while mutation tests were being applied and reverted in the same tree, so a finding naming a mutated line would have been discounted; none did.
A static review: it did not establish that anything runs, and the tests below are what did.

| finding | re-derived | fixed |
|---|---|---|
| P1: the rehearsal's EXIT trap deletes a `gpufault` cluster that already existed when it refuses to proceed | true: `die` on "already exists" ran the trap, which checked only the name | cleanup deletes only a cluster this run created (`CREATED`) |
| P1: a latched fault clears when the faulted card drops out of the scrape and a healthy card remains | true: `Pristine` judged only the cards present | a latch clears only on a reading that covers every card its fingerprint names (`Assessment.Covers`); `TestGPUFaultLatchHoldsWhenTheFaultedCardDisappears`, and disabling the check fails it |
| P1: the rehearsal applies the simulator DaemonSet before its namespace exists | true: `config/device-plugin` holds only the DaemonSet | the namespace is created first, as the instance script already did |
| P2: serial scrapes let slow exporters delay every other node past the interval and stale-after | true: ten timeouts of 0.8 s per tick | nodes are scraped concurrently, at most 64 at a time; `TestGPUFaultSourceScrapesNodesConcurrently`, and a concurrency of 1 fails it at 2.0 s |

## Result, 2026-10-26: run 1 is REFUSED, because the job image's archive could not be imported onto the kind node

**Verdict: `GPU FAULT REACTION: REFUSED`.** The scorer refused it for "no repetition directory was found" and "no smoke.env: the session never recorded whether injection reaches the exporter"; every arm is UNJUDGED with 0 valid repetitions, and P5 held only because no injection ran.
This says nothing about DCGM, the exporter, the A10G or the platform's reaction: the instance stopped before the platform was installed.

**The purchase.** One g5.2xlarge Spot instance, `i-09c64e59ffb24d702`, in ap-northeast-2a, from `6d9d087f`, the commit that froze this page, on the pinned AMI `ami-097edab977037f65f`.
`LaunchTime` was 19:38:24Z; the session asked EC2 to terminate it at 19:41:36Z, 192 s later, after the instance had written its `DONE` marker, and the wait for `terminated` then confirmed it (`termination.txt`).
Billing ends as the instance enters `shutting-down`, so at the zone's Spot price read before launch, $0.6823 an hour, the run cost about $0.04.

**What happened, from the instance's own log** (`hack/gpu-fault/2026-10-26-run1/log.txt` and `gf-run/`).
- Bring-up exited 0: driver 595.91.07, the kind worker Ready.
- The platform phase stopped at `kind load job` at 19:41:24Z, 180 s after `LaunchTime`: `ctr: mismatched image rootfs and manifest layers`, importing `gpufault-job:busybox`.
- The instance procedure exited 1 and uploaded its evidence and `DONE`; the session's wait for that marker returned at once, and the session terminated the instance, well inside the 720 s bring-up phase rather than at 7,000 s.

**The cause, reproduced off the card.** `FROM busybox:1.36` alone makes no manifest of its own: the image is the official image's amd64 manifest, so `docker save --platform linux/amd64` also writes the attestation manifest that names it as its subject, an in-toto layer, and kind's `ctr images import --all-platforms` tries to unpack that as an image.
The archive this session uploaded holds those two digests (`b7f3d86d…` and the attestation `89ac9548…`, the pair in the instance's error), and on a throwaway kind node of the pinned `kindest/node:v1.31.0` it failed with the same message while a labelled rebuild imported cleanly.
It is a different defect from the two void rehearsals above: those failed on platforms missing from a multi-platform index ("content digest ... not found"), which `--platform linux/amd64` fixed; this is a second manifest of the one platform, which `--platform` keeps. Why the rehearsal that completed did not meet it is not established.
The fix, `ca763d7a` (#410), labels the job image so it has a manifest of its own and adds `hack/image-archive-check.py`, which the runner now applies to all three archives before anything is uploaded or bought; on this run's own archives it refuses `job.tar.gz` and passes the other two.

**The evidence** is in `hack/gpu-fault/2026-10-26-run1/`, with a `SHA256SUMS` over every file in it. The three image archives, the source archive, the local scorer binary and the evidence tarball (which `gf-run/` unpacks) are not committed; `NOT-COMMITTED.sha256` records their hashes, and the files are kept on the owner's machine.

**What follows.** "Nothing is re-bought: one attempt, reported as it ran" (The paid session, above). A second session is therefore not run under this page as it stands; it needs an amendment, written before it is bought and approved by the owner, as MPS run 2 had. The amendment proposed is the smallest one: the job image's build and the archive check, both already merged, with every arm, bound, phase and verdict rule unchanged.

## Amendment for run 2, 2026-10-27, approved by the owner before it is bought

The owner approved a second session on 2026-10-27, after run 1's record and this amendment's proposal were reported to them.
"Nothing is re-bought" is lifted for exactly one more attempt, run 2, and for nothing after it: a run 2 that fails for any reason is reported as it ran, and a third needs its own amendment and approval.

**What changes**, and only this:
- the job image is built as `FROM busybox:1.36` plus a `LABEL`, so it has a manifest of its own (`ca763d7a`, #410);
- the runner refuses to upload or buy unless `hack/image-archive-check.py` passes all three image archives: exactly one manifest, no `io.containerd.manifest.subject` annotation, no in-toto layer (#410).

**What does not change:** the question, the topology, every arm and its repetitions, every endpoint, prediction and bound, the validity rules, the verdict rules, the falsifiers, the smoke cell, the phases and their deadlines, the stop rule, the termination chain, the AMI, the instance type and the cost rate.
Run 1's evidence stays where it is and is not pooled with run 2's; run 2 is scored on its own.

**Run 2 is bought from the commit that carries this section**, once it is merged to `dev`, with the command in "The paid session" above.

## Result, 2026-10-27: run 2 is a RESULT; both fault arms REACTED inside every bound, and the latched stale check FAILED because the platform's own taint kept the exporter off the node

**Verdict: `GPU FAULT REACTION: RESULT`**, from `3584d079`, the merge that carries the amendment above.
The scorer the session ran and a scorer rebuilt from that commit print the same report, and their JSON differs only in the evidence path's prefix.

| arm | verdict | valid | detect, median (min–max) | end to end, median (min–max) | lost work, median |
|---|---|---:|---|---|---:|
| `xid` (Xid 79) | REACTED | 5 of 5 | 1.627 s (1.051–1.758) | 2.502 s (1.926–2.634) | 15 s |
| `ecc` (DBE 1) | REACTED | 5 of 5 | 1.448 s (1.314–1.789) | 2.324 s (2.189–2.664) | 14 s |
| `benign` (SBE 1) | QUIET | 5 of 5 | — | — | — |
| `none` | QUIET | 5 of 5 | — | — | — |

Every figure is an upper end of a truncation interval, as "Endpoints, with units" defines them; the other hops are in `verdict.txt`.
- **P1** held: no detect interval lies wholly above 2.8 s; the largest upper end is 1.789 s.
- **P2 and P3** held in all ten fault repetitions: every hop present, the injected fingerprint latched, the order kept, and the job placed on H inside W = 120 s, at most 2.664 s after the value was in DCGM.
- **P4** held: no control repetition produced a platform action.
- **P5** held across every injection the scorer read, and the smoke cell's own record is `alloc_before=1`, `alloc_after=1` (`smoke.env`), as the boundary section predicts for DCGM's cache.
- **P6, stale-healthy: PASS.** With nothing latched and the exporter away, `GPUSignal=False` (`NoExporter`), `GPUHealthy=Unknown`, no taint.
- **P6, stale-latched: FAIL.**

**What the stale-latched FAIL is.** The check has three clauses, and its record (`gf-run/checks/stale-latched/check.env`) shows how far it got.
- The first two held: Xid 79 latched before the exporter left, and while it was away the fault, the taint and the fingerprint all stayed, with `GPUSignal=False` (`NoExporter`). So the falsifier "stale data that releases a latched fault" did not occur.
- The third was never reached: the runner logged "stale-latched: the exporter did not come back" at 00:22:20Z and returned before injecting zero, so no fresh zero reading was ever given.
- The scorer's reason, "a fresh zero reading did not clear it", is therefore wrong about the cause: it reads the absent `after_*` lines as a reading that failed to clear. The verdict FAIL stands, because the exporter's return is part of the clause the page registered; the reason text is corrected here and in the scorer, not by re-scoring.

**Why the exporter did not come back, reproduced off the card.**
The study takes the exporter away by giving its DaemonSet a node selector nothing matches, and brings it back by removing it, so the Pod is created again.
The DaemonSet tolerates `nvidia.com/gpu:NoSchedule` and nothing else, and with a fault latched, T carries the platform's own `platform.lkhun9311.github.io/gpu-fault:NoSchedule`.
A DaemonSet does not place a new Pod on a node whose `NoSchedule` taint it does not tolerate.
On a throwaway kind node of the pinned `kindest/node:v1.31.0` with the same two tolerations, the running Pod stayed through the taint, and once it left, the DaemonSet's desired count went to 0 and no Pod returned. Adding a toleration for the fault taint brought it back at once.
The stale-healthy check, run with no taint on T, brought its exporter back without trouble.
The instance's own evidence does not record the Pod's scheduling events, so the cause is established by that reproduction and by the configuration, not by an event from the card.

**What it says about the platform.** It is a defect in the product, not in the apparatus: on a node the platform has quarantined, the exporter whose fresh zero reading is the only automatic way to clear the latch cannot come back once it restarts.
After that, only an operator's acknowledgement clears the node.
The NVIDIA device plugin's DaemonSet tolerates the same single taint, so it would not come back to a quarantined node either; the run does not exercise that, and it is noted, not measured.

**What it does not say.** Every fault is a value injected into DCGM's cache, not a hardware fault; re-admission landed on H's simulated device ("Topology on the instance"); one card, one driver (595.91.07); five repetitions per arm, so medians and ranges, not rates.

**The purchase.** One g5.2xlarge Spot instance, `i-09d3bd39d799d566f`, in ap-northeast-2a, on the pinned AMI. `LaunchTime` 23:27:28Z on 2026-10-26; the session asked EC2 to terminate it at 00:22:36Z on 2026-10-27, 3,308 s later, and its wait confirmed `terminated` (`termination.txt`).
At the zone's Spot price read before launch, $0.6822 an hour, that is about **$0.63**.

**The evidence** is in `hack/gpu-fault/2026-10-27-run2/`, with a `SHA256SUMS` over every file in it. The three image archives, the source archive, the local scorer binary and the evidence tarball are not committed; `NOT-COMMITTED.sha256` records their hashes, and the files are kept on the owner's machine.

**What follows**, none of it a re-run: the exporter's DaemonSet tolerates the platform's fault taint, with a test that fails when it does not; the scorer names an absent clause as not reached rather than as a reading; and the runner records the exporter's Pod and events when it does not return.

## Amendment for run 3, approved by the owner on 2026-11-01

**Approved and frozen for purchase, 2026-11-01, at the commit that carries this line.** The owner approved run 3 on 2026-11-01 ("승인", in answer to the report of this amendment, its rehearsal and its cost); nothing below changes after this commit, and run 3 is bought once, from the merge of this commit to `dev`.
Until this line, the heading said: "drafted 2026-11-01: not approved, and nothing is bought from it until the owner approves it".

Run 2 measured the platform's reaction and could not show its recovery.
Its stale-latched check failed because the exporter could not come back to a node the platform had tainted, and nothing in the session asked whether the node, once cleared, ran GPU work again.
The first half is fixed on `dev` (`dbb0041c`: the exporter tolerates the fault taint, with a test that fails without it; the scorer names an unreached clause as not reached).
Run 3 asks the second half, and it is the only new question: **after a latched fault is cleared by a fresh zero reading, does the platform put a CUDA training job back on that node, and does the card run it?**

**What changes**, and only this:
- the session is bought from a commit on `dev` that carries `dbb0041c` and this section;
- a new registered check, `recovery`, runs after stale-latched in the checks phase, and only when stale-latched reached its clearing step;
- the CUDA sample image `nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0`, pinned by its index digest `sha256:7c7540bdf1f942d4fb6db97069fd6c289471b54ac29e3c7fcdf914cf77af7d41` (read from nvcr.io on 2026-11-01), is pulled onto T in the platform phase, before any arm, so that its pull is never inside the check's timing;
- the phases after the arms move by 180 s, the time the new check is given: checks end at 7,000 s, evidence at 7,120 s, the instance stops itself at 7,180 s; the sweeper's tag is set at the request plus 7,120 s and rewritten to `LaunchTime` + 7,150 s; the termination wait may run to `LaunchTime` + 7,480 s.

**The `recovery` check.** Four clauses, each recorded in `checks/recovery/check.env`:
- R1: the target is clear (`gf_is_clear`) once stale-latched's zero reading has been given; the time it was first seen clear is `t_clear`;
- R2: the exporter Pod on T is Running and is not the Pod that served before stale-latched took it away, so the exporter really returned to a node that carried the taint;
- R3: T's `allocatable` `nvidia.com/gpu` is 1;
- R4: with H held off by the same hold taint the arms use, an `MLTrainingJob` named `gf-recovery`, `gpuCount: 1`, through the tenant's queue, running the pinned image's own entrypoint, `/cuda-samples/sample` (vectorAdd; read from the amd64 image's config on 2026-11-01), has its Pod placed on T, completes with exit code 0 and prints `Test PASSED`, within 180 s of its submission.
  It goes through the product's path, `MLTrainingJob` and Kueue, rather than a bare Pod, because that is how a tenant's work would return to the node.
  vectorAdd is the smallest program that allocates device memory, copies, launches a kernel and checks the result on the card; it says the card executes CUDA through the device plugin's allocation, and nothing about the card's health beyond that.
- Recorded beside the clauses, not bounded: `t_submit`, the Pod's `PodScheduled` time, its completion time, the node, the exit code and the log.

**Verdict.** `PASS` when all four hold; `FAIL` naming each clause that did not; `NOT-REACHED` when stale-latched never gave its zero reading or the checks phase ended before the check began, which is a step that did not run and never a reading.
On the kind rehearsal the job image is the study's busybox, printing the marker, because there is no card; the session is labelled REHEARSAL there as everywhere else, and the check's line says the program was not CUDA.

**Prediction P7.** The `recovery` check passes.
**Falsifiers it adds:** the exporter does not return to a tainted node with the fix in place (R2); the job placed on H, or not placed inside 180 s while T is clear (R4); vectorAdd failing on a card the platform has just called healthy (R4).

**What does not change:** the question, the topology, every arm and its repetitions, every endpoint, prediction and bound, the validity rules, the verdict rules for the arms and both stale checks, the falsifiers above, the smoke cell, the stop rule, the termination chain, the AMI, the instance type and the cost rate.
The arms run again as registered; run 3's evidence is scored on its own and is not pooled with run 2's.

**Cost.** The operating allowance by this page's convention becomes 7,150 + 900 s, 2.24 h, **$2.53** at $1.1324 per instance-hour.
Run 2 ran 3,308 s for about **$0.63** at the zone's Spot price; run 3 adds the check and its pre-pull, so about the same is expected.

**Rehearsed on kind, 2026-11-01**, from `4726f072` with one block (`GF_BLOCKS=1`): `hack/gpu-fault-rehearsal-20261031T235244Z/`.
The label is REHEARSAL and the four arms are UNJUDGED with one repetition each, as one block must leave them; stale-healthy, stale-latched and recovery each PASS, and the recovery line says its job was busybox, not CUDA.
`dirty_files=1` in its provenance is the rehearsal's own evidence directory, which exists before the line is written.
It shows the procedure, the gate on `zero_given` and the scorer working together; it shows nothing about a card.

**What it does not license**, beyond the list above: that a card which really faulted is healthy once DCGM reads zero, since the fault was injected into DCGM's cache and the card never faulted; that the device plugin would return to a tainted node, since it does not tolerate the fault taint and the session never restarts it; a burn-in, since one vectorAdd is one kernel; a recovery time, since one check is one observation.
