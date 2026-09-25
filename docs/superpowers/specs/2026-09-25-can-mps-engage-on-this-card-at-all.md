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
