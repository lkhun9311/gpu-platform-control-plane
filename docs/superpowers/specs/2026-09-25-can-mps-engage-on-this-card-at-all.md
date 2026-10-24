# Can MPS engage on this card at all — pre-registered

Written 2026-09-25, before any card time is bought for it. It exists because the last three attempts to
measure MPS measured something else, and because the study that would have carried it says it will not.

## Why a new page

`2026-09-10-does-splitting-the-card-buy-protection.md` is frozen: its result is recorded and its `mps` arm
was refused. `2026-09-13-what-the-split-costs-in-throughput.md` says so in one line — *"`mps` is not in this
page. It failed to engage on this card in the eighth pilot and reading 4c refused it; nothing here changes
that."* So there is no pre-registration a paid MPS session could report against, and a session with nothing
to report against is a session whose result is decided after seeing it.

## The question, and what it is NOT

**Does the NVIDIA device plugin's MPS mode make a g5 A10G allocatable to two Pods that both reach the
control daemon?**

That is a capability question, not a performance one. This page registers **no** latency or throughput
comparison. If MPS engages, what the split costs is a separate study on a separate page; if it does not, the
answer is a recorded refusal and the arms beside it stand.

The reason for that narrowing is the failure it keeps hitting. The eighth pilot's Pods came back with

```
Allocate failed due to no healthy devices present; cannot allocate unhealthy devices nvidia.com/gpu
```

— the plugin advertised two devices and **the kubelet refused to allocate them**, before any container
started. Nothing about client configuration can reach that, so a page that registers throughput bars would
spend a card measuring a thing that never ran.

## Bars, fixed now

| # | Bar | Passes when |
|---|---|---|
| B1 | the node advertises the split | `nvidia.com/gpu` allocatable is exactly 2 under the MPS overlay |
| B2 | the kubelet will allocate them | both engine Pods reach `Running`, with no `no healthy devices` event on either |
| B3 | both Pods are real MPS clients | each has `CUDA_MPS_PIPE_DIRECTORY` set, that directory exists, and the control endpoint inside it is a **socket** (`-S`, not `-e`) |
| B4 | the daemon has both | `nvidia-smi` on the instance reports an `M+C` compute process for the MPS server and one client process per engine — the command is named below, because this bar had no instrument when it was first written |
| B5 | the arrangement survives work | the matrix's own replay completes for both engines: `raw-mps-1.jsonl` exists with a non-zero row count and no row carries a 5xx |

B3 is `-S` on purpose. `-e` accepted a regular file and the entry a dead server leaves behind, which is how
an arm with no daemon at the other end could be labelled an MPS client.

B4 is the bar the previous attempts did not have. The plugin rolling out is the server half of a two-sided
arrangement, and three sessions took it for the whole.

**B4's instrument, named here because writing a bar without one is how a bar goes unmeasured.** This page
first said "the control daemon's own log names two client connections, or `nvidia-smi` reports an MPS server
with two clients", and neither is something this repository collects: the session runs
`nvidia-smi --query-gpu=index,name,memory.total` and never asks about compute processes, and nothing reads
the daemon's log — `hack/m5c-matrix.sh:821` only waits for its rollout. The matrix's own comment
(`hack/m5c-matrix.sh:946`) says the pipe-and-socket check "does NOT prove kernels are routed through the MPS
server; only nvidia-smi on the host" can. So the session must run, on the instance and while both engines
are serving:

```
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
nvidia-smi   # the process table's type column: M+C on the clients, C on the server
```

and upload the output beside the other preflight files. B4 passes when that table shows one MPS server
process and two client processes, and it is **unmeasured** — not passed — if the command was not run.

**B5 is the matrix's replay, not a hand-made request.** The earlier wording ("a single 200 each") does not
match how anything here runs: `hack/m5c-matrix.sh` replays a `gen-trace` trace and refuses to start unless
all four load parameters are given (`hack/m5c-matrix.sh:160`). Asking for one request would mean building a
second path to the engines that no other arm uses. The bar is therefore the artifact the matrix already
produces for every other arm.

## Three outcomes, because two cannot separate the causes

The first version of this page said B1 or B2 missing meant MPS does not engage, and anything later meant the
apparatus was broken. That split is not decidable from the bars alone: a Pod that never reaches `Running`
can be a kubelet refusing an unhealthy device **or** an image that would not pull, a node too small, a
missing toleration. And B3 or B4 failing after B1 and B2 passed can be a real MPS limitation rather than a
fault of this harness.

So the outcome is one of three, and the run must name which:

| outcome | when | what it licenses |
|---|---|---|
| **INVALID** | a precondition was not met — the overlay is not the pinned one, an engine manifest lacks `hostIPC`, the image did not pull, the node could not schedule the Pod | nothing; the run is not evidence about MPS |
| **REFUSED** | the device plugin advertised and the kubelet declined, with the `no healthy devices` event captured, or the daemon rejected a client with its reason recorded | that **this AMI and driver** do not engage MPS — not "this card" in general |
| **INCONCLUSIVE** | a bar was missed and the diagnostics do not establish why | that the question is still open, and what evidence the next attempt must capture |

**The diagnostics are mandatory output, not a courtesy.** A run that cannot classify itself is INCONCLUSIVE
by definition, so the session uploads, for both engine Pods: `kubectl describe pod`, the kubelet's events for
that node, the device-plugin DaemonSet's logs, the MPS control daemon's logs, and `nvidia-smi` including the
compute-process table. Without those the outcome cannot be REFUSED, whatever the bars say.

A REFUSED outcome is written to `refused-mps.txt` and reported as reading 4c, as before.

## Invalidation rules

- If the MPS overlay is not the one in `config/nvidia-device-plugin-mps`, the run is void.
- If either engine manifest lacks `hostIPC: true`, the run is void — the daemon's own spec requires the
  shared namespace and a client without it falls back silently.
- If the session cannot confirm the instance terminated, the run is void regardless of what it measured.
- If a bar is missed and the cause is not established, it is recorded as missed, not excused.

## Stopping rule

One instance, one attempt at B1–B5, and a hard stop at **40 minutes** of instance time. If B1 or B2 fails
the session ends there rather than retrying with different plugin settings: the settings are the
pre-registered ones, and tuning until it passes is how a capability question becomes a search.

**The stop is a contract the runner has to enforce, not a sentence on this page.** Forty minutes means:

- an absolute deadline of **2,400 seconds from the instance's `LaunchTime`**, not from when a shell noticed
  it — the existing wrapper's backstop timer starts after boot, which is a different clock;
- per-step budgets inside it: 12 minutes to a Running pair (B1–B2), 8 to the client and daemon evidence
  (B3–B4), 12 to the replay (B5), and **8 reserved** for evidence upload and teardown, which do not come out
  of the measurement;
- the AMI **ID** pinned in the run record rather than resolved from `latest`, together with the driver and
  container-toolkit versions, the engine image digests and the manifest SHA — a capability answer about an
  AMI is worth nothing without naming it;
- B1–B5 written to a structured file as they are decided, so a session cut short still says how far it got.

## Cost

A g5.2xlarge Spot instance for under an hour. The TTL kill switch is armed before the instance exists and
the session fails if termination cannot be confirmed.

## What a pass licenses

That MPS can be made to engage on this card, with two clients attached, under this repository's own
manifests. It licenses a **later** performance study; it is not one.

## Amendment, 2026-10-03: this page named the wrong failure, in the wrong arm, from the wrong pilot — and the real cause was fixed the day before it was written

**No card has been bought for this page.** This is a pre-purchase revision, not a post-hoc one, and it is
dated here rather than edited into the body above so a reader can see which text predates it.

**The misattribution.** The section above says the eighth pilot's Pods came back with `Allocate failed due to
no healthy devices present; cannot allocate unhealthy devices nvidia.com/gpu`. Measured today against the
archives: that string appears in **one** archive, `hack/m5c-20260911-235956` — the **fourth** pilot — and the
two events name `vllm-shared-a` Pods, which is the **shared** arm, not the MPS arm. The eighth pilot's
archive (`hack/m5c-20260912-084918`) contains **zero** occurrences of it. What that archive holds instead is

```
nvidia-device-plugin-mps-g5s4h   0/1   CrashLoopBackOff   6 (4m10s ago)
node m5cgpu-worker allocatable nvidia.com/gpu=0 capacity=0
```

So the failure this page was built around — advertise two, kubelet declines — is a failure mode **this study
has never observed in the arm it is about**. The plugin advertised **0**, because it was not running.

**What that does to the bars.** B1 reads "allocatable is exactly 2" and B2 "the kubelet will allocate them".
Both presuppose that the plugin got far enough to advertise. A crash-looping plugin advertises 0, and 0 is
equally consistent with a plugin that ignored its config, a kubelet that has not re-registered, and a plugin
that died before registering. The bars are **not renumbered or relaxed** here; one predecessor condition is
added, because without it B1 cannot distinguish those cases:

| # | Bar | Passes when |
|---|---|---|
| B0 | the plugin is alive to be believed | the MPS device-plugin Pod is `Running` with 0 restarts when the advertisement is read, and the control daemon Pod likewise |

**The real cause was already named, by the session that died.** `config/nvidia-device-plugin-mps/daemonset.yaml`
quotes it in its own comment: `error starting plugins: unable to validate flags: using MPS requires
--mps-root to be specified`. `git log -S'--mps-root'` dates the fix to `72bfed3`, **2026-09-24 21:22 +0900** —
twelve days after the eighth pilot, **one day before this page was written**, and the **only** commit to touch
that directory after the pilot. This page therefore registered a capability question whose known blocker had
been removed the previous day, and did not say so.

**The honest status is "fixed and never retested", not "MPS does not engage on this card".** Three documents
carry the second sentence. The next paid cell is MPS's **first** test since the fix.

**One instrument gap is closed today.** `plugin_diagnosis` in `hack/m5c-matrix.sh` captured only the current
container's log, and a crash-looping pod's current attempt has not yet reached its failure — which is exactly
why the eighth pilot's archive holds startup noise (`ERROR: driverInitFileInfo 578 result=11`, a message that
also appears in containers using no MPS at all) and not the line that mattered. `--previous` is added, the way
the engine diagnosis beside it already did it.

**What is deliberately NOT changed.** The manifest differs from the official v0.16.2 Helm chart in three
places: no `${mps.root}/shm` → `/dev/shm` mount, no `NVIDIA_VISIBLE_DEVICES=all` or
`NVIDIA_DRIVER_CAPABILITIES=compute,utility`, and a `hostIPC: true` the chart does not set. None of them is
supported by evidence as a cause here, and changing them in the same step as the `--mps-root` fix would mean a
successful next run could not say which change bought the success. If B0–B2 fail again, the `[previous]` log
is what selects the next change. Separately, `mps.enableHostPID` — which the project's own values file
explains the MPS server needs to find its PID through `/proc/self` — arrived in **v0.18.0**, after the pinned
`v0.16.2`; raising the pin is a candidate this page does not take today.

## Amendment, 2026-10-24: the runner's contract, fixed before the first purchase

**No card has been bought for this page.**
The owner approved buying its one session on 2026-10-24.
This amendment settles what the runner could not implement as written. It is dated here and does not edit the text above.
It changes no bar's subject and relaxes none.
My reading and codex `gpt-6-astra`'s, made independently, found the same two gaps in the page: B4's process types, and B5's workload.

**B4 contradicted itself, and NVIDIA's wording settles it.**
The bar table asks for "an `M+C` compute process for the MPS server". The command note below it says "`M+C` on the clients, `C` on the server".
NVIDIA's MPS Quick Start (https://docs.nvidia.com/deploy/mps/latest/quick-start.html, read 2026-10-24) says only two things on this:
- `nvidia-smi` verifies "the existence of the `nvidia-cuda-mps-server` process";
- a client application "will also appear in `nvidia-smi` with the `M+C` type specified".
It does not give the server's type.
B4 therefore passes when, in a table captured while both engines are Ready:
- exactly one process is named `nvidia-cuda-mps-server`;
- two processes are of type `M+C`, each mapped to a different engine Pod through `/proc/<pid>/cgroup`.
The server's type is recorded and not judged.
A captured table that shows anything else is a **failed** B4. B4 is **unmeasured** only when either command did not run or could not be read.

**B5's workload, frozen.**
The page named the matrix's replay but not its load, and the session's defaults are mutable.
The replay is `gen-trace` with:
- seed 11;
- `--duration-ms 120000`;
- rate 2 requests a second;
- premium weight 1, contender weight 0.054, probe weight 0;
- premium prompt 1,174 characters, contender prompt 42,579;
- 64 and 16 output tokens;
- a request timeout of 60,000 ms.
The prompt sizes, output tokens, timeout and mix are the matrix's registered ones. The rate is lowered from 9.85 to 2 because this bar asks whether the arrangement survives work, not how fast. A load chosen near capacity would turn an overload into a B5 failure that says nothing about MPS.
B5 passes when:
- the replay exits 0;
- `raw-mps-1.jsonl` parses row by row;
- both the premium and the contender tenant have rows;
- no row carries a 5xx.
4xx rows and rows with an `errorKind` are counted and printed beside it, not judged. The page asked for no 5xx and nothing more, and this does not move that line after the fact.

**The clock and the phases.**
Every deadline counts from EC2's `LaunchTime`, which the session reads right after the launch and writes to the run's S3 prefix. The instance reads it from there.
An instance that cannot read it within 180 s of its own start stops and the run is INVALID. Its boot time is later than `LaunchTime`, so a deadline taken from it would overrun.

| from `LaunchTime` | ends no later than | work |
|---|---:|---|
| bring-up, B0, B1, B2 | 720 s | driver check, toolkit, kind, the overlay, a Running pair |
| B3, B4 | 1,200 s | serving readiness, the client probes, the two host tables |
| B5 | 1,920 s | the replay above and its decision |
| evidence | 2,040 s | the diagnostics, the journal, the upload |
| termination | 2,400 s | the shutdown and its confirmation |

**Whether 720 s is enough, from the archives, before the purchase.**
Four session archives on this instance type record `LaunchTime`: the admission pilot's stages A and B, its diagnostic and its length calibration, of 2026-10-08 to 2026-10-10. Those archives are kept on the owner's machine and are not committed.
Their cold first cell pulled the engine image and downloaded the weights.
In each, the engine's first log line came 452 to 499 s after `LaunchTime`, and its last line before startup completed came 582 to 655 s after it.
The log line stands in for Running and is not a Pod-phase timestamp. Those cells ran one engine, and this one runs two behind an MPS plugin and its control daemon.
So phase 1 has some 3 to 4 minutes of margin, and a slow image pull could spend it. A phase 1 that runs out is recorded as interrupted, and the run is INCONCLUSIVE, not a refusal.

A phase may end early and never borrows time.
A phase that runs out records its open bar as interrupted, not as failed or passed, and the run goes straight to the evidence step.

**The kills, in the order they should fire.**
1. The instance shuts itself down once the evidence step ends. Its own timer shuts it down at 2,100 s from `LaunchTime` if that step hangs, and it launches with shutdown set to terminate.
2. The session terminates the instance when the run's completion marker arrives, or at 2,100 s, and waits until EC2 reports it terminated.
3. The termination sweeper (`infra/aws/bootstrap/sweeper/sweeper.py`) runs every five minutes and does not depend on either. It ends any instance whose `study-deadline` tag has passed.

**The tag is written twice.**
- At launch it is the launch request plus 2,040 s. That holds if the session dies before it can rewrite it: the request precedes `LaunchTime`, so the latest sweep is no later than 2,340 s after `LaunchTime`.
- Once the session has read `LaunchTime`, it rewrites the tag to `LaunchTime` plus 2,070 s. That keeps the sweeper out of the evidence step, which ends at 2,040 s, and the latest sweep requests termination by 2,370 s.

codex found that the first version of this paragraph overlapped the two. It set the tag to the request plus 1,980 s, so a sweep could end the instance at 1,980 s, while the evidence step ran to 2,040 s.
A five-minute sweeper bounds its latest request, never its earliest.
Billing ends as the instance enters `shutting-down` (https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-lifecycle.html, read 2026-10-24), so the sweeper's bound is on the termination request. The confirmation that follows is recorded rather than assumed.
Before the purchase, the deployed sweeper's schedule and state are read back from AWS.

**The classification, applied in this order.**
1. **INVALID:**
   - termination not confirmed;
   - `LaunchTime` unreadable on the instance;
   - the overlay or either engine manifest not the pinned one;
   - an image that did not pull;
   - a Pod that could not be scheduled for a reason the diagnostics name and that is not the device.
2. **REFUSED:**
   - the plugin advertised two and a `no healthy devices` event on an engine Pod is captured;
   - or the control daemon's log records a client's rejection with its reason;
   - and in either case the mandatory diagnostics were uploaded.
3. **PASS:** B0 to B5 each passed, the provenance and diagnostics are complete, and termination is confirmed.
4. **INCONCLUSIVE:** everything else, including a bar left interrupted or unmeasured.
A failed bar whose cause the diagnostics do not establish is recorded as failed. Not knowing why does not erase the measurement.

**The run record before B0:**
- the AMI ID, pinned before launch and checked against the image ID EC2 reports for the instance;
- the driver version;
- the container toolkit's version on the host and in the kind node;
- the engine images' digests;
- the SHA-256 of the rendered overlay and of both engine manifests.

## Result, 2026-10-24: run 1 is INCONCLUSIVE, because our overlay never let a client reach the daemon

**Verdict: `MPS: INCONCLUSIVE`.** B0, B1 and B2 passed; B3 failed; B4 was unmeasured; B5 is absent.
This is the classification above applied as written, by `benchharness mps-capability-verdict` on the journal.
It is not REFUSED: the daemon's log records no CUDA client at all, so it records no rejection of one, and no `no healthy devices` event was captured.
It says nothing about whether MPS can engage on an A10G, because no CUDA client ever asked it to.

**The purchase.** One g5.2xlarge Spot instance, `i-0d6780100fc296545`, in ap-northeast-2a, from commit `04fac8f3`, AMI `ami-097edab977037f65f`, driver 595.91.07.
`LaunchTime` was 04:31:37Z. CloudTrail records `TerminateInstances` at 04:46:23Z, 886 s later, and the session read the instance as terminated at 1,182 s.
At the zone's Spot price read before launch, $0.683 an hour, the 886 s cost about $0.17. That is the price times the time, not a billed figure.
The sweeper did not have to act.

**When each bar ran, from `LaunchTime`.**

| event | s |
|---|---:|
| `LaunchTime` read on the instance | 93 |
| B0 started | 252 |
| B2 decided, both Pods Running | 470 |
| B3 started, after the wait for both engines to be Ready | 858 |
| B4 decided | 862 |
| diagnostics uploaded | 867 |
| termination requested | 886 |

Phase 1 ended at 470 s against its 720 s bound. The margin estimated from the archives held on this run.

**What the evidence shows.**
- The control daemon started under the pinned image (its log names commit `42a0fa92`, the v0.16.2 tag), opened `/mps/nvidia.com/gpu/pipe/control`, and set a 50% thread share and an 11,514 MiB pinned-memory limit.
  After that it accepted one connection, at 04:35:39.120, and that was the plugin's health check (the daemon's get_default_active_thread_percentage command, logged by the plugin as "MPS daemon is healthy" in the same millisecond). No CUDA client connected and no MPS server started.
  codex corrected this line: the first version said nothing connected at all.
- Inside both engine containers `CUDA_MPS_PIPE_DIRECTORY` was `/mps/nvidia.com/gpu/pipe`. The directory existed and held no control socket. That is B3's failure.
- `nvidia-smi` at 867 s showed the card in Exclusive Process mode with one process, `VLLM::EngineCore`, of type `C`, holding 9,908 MiB. There was no `nvidia-cuda-mps-server`.
  So engine A ran on the card directly, without MPS.
- Engine B's container exited with code 1 four times and was never Ready, so B4's table was not captured.
  Its log was not captured either: the diagnostics collect the plugin's and the daemon's logs and not the engines'. Why it exited is therefore not established here.

**Why no client reached the daemon, read from the source of the pinned build.**
In the v0.16.2 tag (`42a0fa92`), `internal/plugin/server.go:89-90` builds the daemon's paths from the fixed container root `/mps`, and builds `mpsHostRoot` from the `--mps-root` flag.
`updateResponseForMPS` (`server.go:381-388`) then mounts `mpsHostRoot`'s pipe directory, as a **host** path, at the container's `/mps/nvidia.com/gpu/pipe`.
Our overlay passes `--mps-root=/mps`, while the daemon's state is in the host's `/run/nvidia/mps`. Each engine was therefore given the host's `/mps/nvidia.com/gpu/pipe`, an empty directory.
The overlay's own comment says the opposite, that the flag is "the path INSIDE this container". That comment is wrong, and it is what the 2026-09-12 fix was built on.
The upstream chart at the same tag passes the host root (`MPS_ROOT` set to `mps.root`), and it also shares a tmpfs at host `<root>/shm` through a `mount-shm` init container, which our overlay lacks. The plugin mounts that shm into each client at `/dev/shm`, where our engines mount their own volume.
A rerun needs both corrected first. They are settled in an amendment dated before that rerun.
The source reading above is mine. codex `gpt-6-astra` was asked the same question independently, and its answer is recorded with the amendment, not merged into this paragraph.

**The evidence** is committed in `hack/mps-capability/2026-10-24-run1/`, with a `SHA256SUMS` over every file in it. The binaries and the source archive the instance ran are kept on the owner's machine.

## Amendment, 2026-10-24: the overlay and the engines' shm corrected before run 2

**Written before run 2 was bought.** The owner approved run 2 on 2026-10-24, after reading run 1's result.
No bar, outcome rule, phase, deadline, kill or B5 load above changes. What changes is the arrangement under test, which run 1 showed was not MPS as NVIDIA deploys it.

**What changes, and where.**
1. `config/nvidia-device-plugin-mps/daemonset.yaml`:
   - the plugin's `--mps-root` is the host root, `/run/nvidia/mps`, which equals the hostPath both DaemonSets mount at `/mps`;
   - the daemon first runs `mps-control-daemon mount-shm` in a privileged init container, with `/mps` propagated Bidirectionally;
   - the daemon and the plugin both mount the host's `/run/nvidia/mps/shm` at `/dev/shm`.
   These three follow the chart at the pinned tag, v0.16.2. `hack/test/check-mps-overlay.sh` renders the overlay and pins each of them. It fails on run 1's overlay, and on each of five single-point mutations of the new one.
2. Under this study only, the engines are applied without their own `/dev/shm`. `config/vllm-shared/mps-shm-patch.yaml` removes the mount and the `dshm` volume, and `mpscap_engine_manifest` renders each engine through `kubectl kustomize` and refuses a render that still carries either.
   The time-slicing and exclusive arms apply the engine files unchanged.
   So under MPS each engine's `/dev/shm` is the daemon's tmpfs, shared by both engines and half the node's memory, instead of its own 1 GiB.
   That is a difference between this study's engines and the matrix's. It does not touch a capability answer, and any later MPS comparison has to record it.
3. The engines' pin covers the patch as well as both engine files. Each pin's files are now named once, in `hack/lib/mps-capability.sh`, for the session, the instance and the session's test.
4. The diagnostics collect both engines' logs, current and previous, as rows that are not required. An engine refused its device has no container to log, and a required row would leave the collection incomplete in exactly the case REFUSED needs it complete.

**Who established what.**
- The plugin takes `--mps-root` as a host path: I read it in the v0.16.2 source (`internal/plugin/server.go:89-90`, `381-392`). codex `gpt-6-astra`, asked independently and told nothing of my reading, reached the same conclusion from the same files.
- The chart's shm arrangement: read by both of us, separately, from the same tag's chart.
- Without the patch, the engine's own `/dev/shm` would cover the plugin's. That is codex's reading of kubelet v1.31.0 and containerd v1.7.18. I have not verified it, and no container's mount table showed it.
  The patch removes the question rather than relying on its answer.
- `mount-shm`'s tmpfs reaches the node and a second, unprivileged Pod: I ran the init container from the pinned image on a throwaway kind cluster at `kindest/node:v1.31.0`, the instance's node image.
  The tmpfs appeared on the node's `/run/nvidia/mps/shm` as a shared mount, and a file written by one Pod was read by the other.
- The engine render: checked with kubectl v1.31.0, the version the instance installs, as well as the local one.
- codex also corrected one line of run 1's result: the daemon did accept a connection, the plugin's health check, and what never connected was a CUDA client.

**What is not known until run 2.** Whether a CUDA client now reaches the daemon on the card. Why engine B exited in run 1, whose log was not kept. Whether the Exclusive Process mode that locked out a second non-MPS process was all of it.

**The purchase is the same as run 1's:**
- one g5.2xlarge Spot at no more than $1.1324 an hour;
- the 2,400 s stop from `LaunchTime`;
- the same sweeper tag;
- a new output directory, hack/mpscap-20261024-run2, which the runner refuses to reuse.
