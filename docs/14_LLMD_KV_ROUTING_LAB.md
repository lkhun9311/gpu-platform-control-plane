# llm-d-router KV-Cache Routing Lab

A free lab (kind, no GPU, no cloud) that runs llm-d-router's endpoint picker (EPP) behind an InferencePool (v1) and
in front of three llm-d-inference-sim pods, and records, per request, which pod the EPP picked, what it believed about
each pod's cache, and what the pod actually had cached.
It answers issue #598 and is the base that #599 and #600 build on.

Everything below is about routing decisions on a simulator.
The simulator is not an inference engine: it tokenizes with the real TinyLlama tokenizer and tracks a block cache, but
it runs no model, so no latency or throughput figure in this lab says anything about serving performance, and none is
claimed.

## Contents

- [What runs](#what-runs)
- [Pinned versions](#pinned-versions)
- [How to run it](#how-to-run-it)
- [How a request is recorded](#how-a-request-is-recorded)
- [Observations](#observations)
- [What was only read in code](#what-was-only-read-in-code)
- [Limits](#limits)
- [Upstream-relevant findings](#upstream-relevant-findings)
- [#599: shared-942 through the prefix scorers](#599-shared-942-through-the-prefix-scorers)
- [What #599 and #600 can take from here](#what-599-and-600-can-take-from-here)

## What runs

`hack/llmd-kv-lab.sh up` creates a one-node kind cluster named `gpuaas-llmd-kv-lab` and runs upstream's own
`llm-d-router/scripts/kind-dev-env.sh` from a checkout of llm-d-router pinned to one commit, with `KV_CACHE_ENABLED=true`.
That is upstream's dev environment unchanged: Istio as the Gateway API implementation, an HTTPRoute to an
InferencePool, the EPP attached through ext_proc, a vLLM CPU image serving only `/render` (tokenization), and the
simulator as the model server.

What the wrapper adds:

| Addition | Why |
|---|---|
| Every pulled image pinned by digest, the EPP built from the pinned commit and labelled with it; `check` refuses on any drift (kind CLI, checkout HEAD, a dirty checkout, the three upstream files the EPP configs derive from, image digests) | A tag can move under a re-run; a planted change was refused (`drift: router checkout is dirty`) before the lab was trusted |
| A unique cluster name, an owner ConfigMap written right after creation, a private kubeconfig | `down` deletes only a cluster carrying the marker; `up` refuses an unmarked cluster of the same name; the user's other clusters (three existed during this work) are listed and left alone |
| Three simulator replicas with 256 KV blocks of 16 tokens each | Three pods so "picked the warm pod" differs from a tie-break; a small cache so eviction is reachable with a few thousand tokens |
| The simulator echoes `x-request-id` | The gateway replaces the client's id, and the EPP logs its scores under the gateway's; the echo lets each response be joined to the EPP's decision for it |
| `mode` switches the EPP config, then restarts the simulators | Each arm starts from empty caches, and (see [Observation 8](#8-during-a-rolling-restart-push-mode-feeds-the-epp-that-is-leaving)) a simulator started before the current EPP is not known to be connected to it |

The four EPP configs in `hack/llmd-kv-lab/`:

| Arm | Config | Source of cache knowledge |
|---|---|---|
| `precise` | `epp-precise.yaml`: upstream's `llm-d-router/test/e2e/artifacts/config/sim-epp-kvcache-config.yaml` plus `enableMetrics: true` | KV events; simulators dial one socket the EPP binds (push), upstream's dev default |
| `precise-pull` | `epp-precise-pull.yaml` | KV events; the EPP dials each pod's socket (pull), the topology llm-d-router#4105 proposes for the e2e overlays |
| `precise-spec` | `epp-precise-spec.yaml`: `precise` plus `speculativeIndexing: true` | KV events, plus the EPP's own routing decision for 2 s |
| `approx` | `epp-approx.yaml`: upstream's `llm-d-router/test/e2e/artifacts/config/sim-epp-config.yaml` unchanged | Only the EPP's own past routing decisions |

The approximate arm is upstream's config as shipped, so it differs from the precise arms in two more ways than its
source of truth: it estimates tokens from characters instead of calling the tokenizer, and its block is 64 tokens
instead of 16.
Its scores are therefore on a different scale: the score is the matched fraction of the prompt's blocks, so the
approximate 0.857 is 6 of 7 and the precise 0.95 is 19 of 20 (1.0 when the prompt's last block is full too).

## Pinned versions

```
router commit      3d0b21d51d29c2f773556c924e5aaf3ee32cc344 (llm-d/llm-d-router main on 2026-11-15)
EPP image          gpuaas-llmd-kv-lab/epp:3d0b21d51d29, built from that commit's Dockerfile.epp (golang:1.27.4)
simulator          gpuaas-llmd-kv-lab/sim:6ab9d4b2367a, built from llm-d-inference-sim main at
                   6ab9d4b2367abe9338665368f61b3ff7e5547e4a (2026-11-17), labelled with that commit
                   (runs before 2026-11-18: ghcr.io/llm-d/llm-d-inference-sim:v1.2.0@sha256:99924538…c40c91c9)
render (tokenizer) vllm/vllm-openai-cpu:v0.31.0@sha256:495c84fe30f3572b83a78100a1e8ba423dbb77fc532ecefebe114e6b77327bd9
kind node          kindest/node:v1.31.12@sha256:0f5cc49c5e73c0c2bb6e2df56e7df189240d83cf94edfa30946482eb08ec57d2
kind CLI           v0.24.0
Istio              1.29.2 (from the pinned checkout's manifests)
InferencePool      inference.networking.k8s.io/v1 (from the pinned checkout's GIE CRDs)
model              TinyLlama/TinyLlama-1.1B-Chat-v1.0 (tokenizer only)
```

`hack/llmd-kv-lab.sh pins` prints these, and each run directory keeps a copy in `pins.txt` with the drift check's
verdict.
The EPP is built rather than pulled because the v1.0.0 release image predates fixes the follow-up issues test.
The simulator is built for the same reason since 2026-11-18: no release carries llm-d-inference-sim #915 (the running
gauge and latency histograms count only started requests) or #920 (a startup error exits non-zero), and the #599
replay reads that gauge.
This machine's Docker has no buildx, so the build uses a copy of `Dockerfile.epp` with only the
`--platform=${BUILDPLATFORM}` flag removed; the copy lives outside the checkout so the clean-tree check still holds.

## How to run it

```bash
hack/llmd-kv-lab.sh up precise          # about 2 minutes once images are local
hack/llmd-kv-lab.sh status              # pods, the InferencePool, and the simulator digest check
hack/llmd-kv-lab/observe.sh all         # four arms, about 15 minutes; RECOVERY_MINUTES=20 adds a 20-minute watch
hack/llmd-kv-lab/probes.sh oob precise  # repeated probes: oob | lag | leave ARM N | epp-restart | rollout-nowait
hack/llmd-kv-lab.sh down                # deletes only the cluster this script created
```

Each run writes a `<stamp>/<arm>/` directory under `hack/llmd-kv-lab/runs/`: `requests.jsonl` (one line per request), the EPP's logs,
and `snap-*` directories holding the EPP's KV-event and index counters, its `/debug/plugins/state`, each simulator's
prefix-cache counters, and each simulator's TCP sockets on port 5557 read from inside its network namespace.
`summarize.py <run>` prints every request beside the EPP's per-pod scores, and a per-step tally.

The runs this page cites:

| Run | What it holds |
|---|---|
| `20261115-run2` | `observe.sh`: precise (with the 20-minute recovery watch), precise-pull without a notification source, approx |
| `20261115-run3` | `observe.sh`: precise-pull with the source but no `dataLayer` wiring, precise-spec |
| `20261115-run4` | `observe.sh`: precise-pull wired correctly |
| `20261115-oob-*`, `-lag-*`, `-leave-*`, `-restart-*`, `-nowait-*` | `probes.sh`, one probe and arm each |
| `20261115-run1` | the first `observe.sh` run, whose precise arm is invalid and is kept only as the evidence of Observation 8 |
| `20261115-setup` | `evidence-extra-args.sh`: why the lab appends the simulator's second flag itself |
| `20261118-replay599-1`, `-2` | `replay599.sh run`: shared-942 through five arms, twice ([#599](#599-shared-942-through-the-prefix-scorers)) |
| `20261118-churn-<arm>-r1` to `-r3`, `20261118-cancel-<arm>` | `probes.sh churn` and `probes.sh cancel`, the #599 week-1 checks |

## How a request is recorded

`hack/llmd-kv-lab/driver` sends `/v1/completions` with a prompt made of a family's shared prefix (300 words generated
deterministically from the family name) and a suffix unique to the request, so a cache hit can come only from the family
prefix.
A prompt is 325 to 332 tokens, of which 304 (19 blocks of 16) are cached on a hit, or 320 when the start of the suffix,
which repeats within a step ("Question <step>-00"), completes a 20th block an earlier request stored.
For every request it records the pod that served it (the simulator's `x-inference-pod` header), the simulator's own
cached-token count for that prompt (`usage.prompt_tokens_details.cached_tokens`), whether the EPP processed it
(`x-went-into-resp-headers`), and the gateway's request id.
The EPP's view comes from its "Calculated score" debug lines, joined on that id.

So each row carries three things that can disagree: what the EPP believed (scores), where the request went (pod), and
what was true (cached tokens).

**Prompt form changed after the recorded runs.** The prefix now begins with the family's own hash (`f<16 hex>`), so two
families part at the first token.
Before, the prefix began "Context for <family>:", and the restart probes' long family names (`R-delete-vllm-d-…`)
shared their first 16-token block. A pod never warmed for a family therefore scored 0.0417–0.0435 for it, which
"predicted" (score above zero) would count if a warm-up were lost.
That did not decide any recorded result: in all nine restart rows the serving pod scored 0.956–0.958 and the
shared-block pods 0.042–0.043 (`runs/20261115-restart-precise/summary.txt`).
The leave, lag and eviction probes use short family names that part inside the first block.
Runs recorded under `runs/` used the old form, and new runs use the new one, so their prompts are not byte-identical.
A request can also bypass the EPP: the driver sends to a pod through the API server's pod proxy, which is how a prefix
is placed on a pod the EPP did not choose.

## Observations

Every number in this section was read from the run directories named beside it.
"Hit" means the serving pod reported cached tokens for the request; a cold family prefix is 304 cached tokens on a hit.

### 1. Both scorers keep a repeated family on one pod

`20261115-run2`, step `affinity`: four families interleaved, four rounds, 16 requests through the gateway.

| Arm | Hits | First round | Rounds 2 to 4 |
|---|---|---|---|
| precise | 12/16 | 4 misses, all scores 0, a rotating tie-break | every request on its family's pod, score 0.95 there and 0 elsewhere |
| approx | 12/16 | same | same, score 0.857 there |

With one family per request and nothing else competing, the two are indistinguishable at the outcome.
The difference is in what each score means, which the next steps separate.

### 2. A prefix placed without the EPP: only the precise arms see it

Probe `oob` (runs `20261115-oob-<arm>`): a new family warmed twice directly on each of the three pods in turn, two
rounds, each followed 3 s later by one gateway request.

| Arm | Gateway requests | Hit | Predicted (EPP scored the serving pod above 0) |
|---|---|---|---|
| precise | 6 | 6 | 6/6 |
| precise-pull | 6 | 6 | 6/6 |
| approx | 6 | 6 | 0/6 |

The approximate arm hit all six without knowing anything: every score was 0, and the picker's tie-break, which rotates
through tied endpoints in name order, happened to walk the pods in the same order the probe warmed them.
Counted by hits alone, the two arms are identical here; counted by what the EPP believed, they are opposites.
That is the reason every table on this page carries the predicted column, and a caution for any comparison that
reports a hit rate under a lone prefix scorer.
The same luck shows in the single-shot step of `20261115-run2` (`oob`), where the approximate arm's first gateway request
scored every pod 0 and still landed on the warm pod.

### 3. Eviction: the precise index follows the cache, the approximate one does not

`20261115-run2`, step `evict`: the pod holding F0 was sent 12 other prefixes directly (about 250 blocks into a
256-block cache), then F0 twice through the gateway.

| Arm | EPP's belief about F0 after the flood | First F0 request | Second F0 request (0.3 s later) |
|---|---|---|---|
| precise | 0 on every pod; EPP index evictions 0 to 30 | tie-break, miss | tie-break again, miss |
| approx | 0.857 on the old holder | sent to the old holder, miss | old holder, hit (the first request re-stored it) |

Neither could produce a hit on the first request, because no pod held F0.
What differs is whether the belief was true: the approximate arm routed on a cache that no longer existed.
The precise arm's second miss is Observation 4.

### 4. The precise index lags the simulator by up to a second, and speculative indexing hides it

Probe `lag` (runs `20261115-lag-<arm>`): a new family sent twice through the gateway with a gap between the two, three
times per gap.
The cell is how often the second request hit, and in every case the EPP had scored the serving pod above zero
("predicted"), so none of these hits was a tie-break.

| Gap | precise | precise-pull | precise-spec | approx |
|---|---|---|---|---|
| 0.1 s | 0/3 | 1/3 | 3/3 | 3/3 |
| 0.3 s | 1/3 | 1/3 | 3/3 | 3/3 |
| 0.6 s | 1/3 | 2/3 | 3/3 | 3/3 |
| 1.0 s | 3/3 | 3/3 | 3/3 | 3/3 |
| 1.5 s | 3/3 | 3/3 | 3/3 | 3/3 |
| 2.5 s | 3/3 | 3/3 | 3/3 | 3/3 |

Below a second the event-driven arms usually did not know about the first request yet; from a second on they always
did.
Three repetitions per cell is enough to see the edge and not enough to put a number on the probability below it.
The approximate arm records its own decision at routing time, so it has no lag; speculative indexing does the same for
the precise arm and closed the gap at every interval tried.
The second-long window comes from the simulator's 1 s event flush (see
[What was only read in code](#what-was-only-read-in-code)), so its length is a property of this simulator; that the
precise index trails the engine by one publication interval is a property of event-driven indexing.
This is also why Observation 3's second F0 request, 0.3 s after the first, missed in the precise arm and hit with
speculative indexing (`20261115-run3`, `precise-spec-evict-001`, 0.95 on the pod the first request went to).

### 5. A blocked event path delays events; it did not lose them in 33 seconds

`20261115-run2`, precise arm, step `zmq-block`: TCP port 5557 dropped in the kind node's FORWARD chain from
03:42:47 to 03:43:20 (UTC), W2 warmed directly on one pod inside that window, then sent through the gateway.

```
snapshot             messages received   index admissions   sim s9j4c Send-Q on :5557
before block         25                  396                0
while blocked        25                  396                2106
20 s after restore   27                  417                0      (9zvfd still 2552)
```

While blocked, the gateway request for W2 scored 0 everywhere and missed.
After the rule was removed the queued bytes were delivered, the index took 21 admissions, and both later W2 requests
went to the warm pod with 0.95 and hit.
So for an outage of this length the events were late, not lost: TCP held them.
Delivery after the path came back was not immediate either: another pod's 2552 queued bytes were still unacknowledged
20 seconds after the restore, consistent with TCP retransmission backoff, which this lab did not measure directly.

Pull mode behaved the same way (`20261115-run4`, arm `precise-pull`): the warmed pod's message counter stayed at 5 while
blocked and reached 7 after the restore, the index took 21 admissions, and both later W2 requests were predicted hits.
Neither mode was tested with an outage long enough for TCP to give up, which is where events would be lost rather than
late; see [What was only read in code](#what-was-only-read-in-code) for why the bound socket could not even tell.

### 6. One simulator leaving drops every simulator's events for about five seconds (push mode only)

Probe `leave`, five repetitions per arm: delete one simulator pod; as soon as the EPP logs the subscriber's EOF, warm a
new family twice directly on a different, healthy pod; 3 s later send it once through the gateway.
Then, with nobody leaving, the same warm-up on the same pod as the control.

| Arm | Run | Warm-up during the window: EPP predicted it | Control: EPP predicted it |
|---|---|---|---|
| precise (push) | `20261115-leave-precise` | 0/5 | 5/5 |
| precise-pull, warm-up 1 s after the delete | `20261115-leave-precise-pull-immediate` | 5/5 | 5/5 |
| precise-pull, warm-up 30 s after the delete | `20261115-leave-precise-pull` | 5/5 | 5/5 |

In push mode the warm-ups inside the window never reached the index.
The counters say so directly, every repetition: the EPP's receive-error counter rose by one at the delete, and the
index admissions did not move across the warm-up (22, 44, 66, 88 before and after repetitions 2 to 5), while each
control added 22.
Three of the five push-mode gateway requests still hit, because the tie-break happened to choose the warm pod; the
"predicted" column is what separates knowledge from that luck.
In pull mode each pod has its own subscriber, a pod leaving closes only its own, and the EPP logged no EOF at all.
The pull probe waits for an EOF that never comes, so its first run warmed 30 s after the delete; the second bounded the
wait (`LEAVE_EOF_POLLS=4`) and warmed about a second after it, inside the window push mode loses.

The single run in `20261115-run2` (step `leave`, a 15 s wait instead of 3 s) shows the same: messages received 28
before and 28 after the warm-up, the gateway request scored 0 everywhere and missed, and the control scored 0.95 and hit.

### 7. After an EPP restart both arms start cold; the precise arm relearns from new events

`20261115-run2`, step `restart`: the EPP pod deleted, then F1, F2, F3 and W1 sent twice each.
Both arms hit 4/8: every first request after the restart missed, every second hit.
Neither persists its index across a restart, and the simulators do not replay what they hold.
In the precise arm a family warmed directly after the restart (R1) was routed to its warm pod 2/2, so the simulators that
predated the new EPP were delivering to it, and a 20-minute watch (`RECOVERY_MINUTES=20`) saw the message counter keep
rising with every simulator socket ESTABLISHED and its Send-Q empty.

Probe `epp-restart` (runs `20261115-restart-<arm>`) replaced the EPP three ways (pod delete, rollout restart, and a
simulator rollout followed by an EPP rollout) and, once the old EPP pod was gone, warmed a new family on each of the
three pods.
Every warm-up was predicted on the next gateway request: 9/9 in push mode and 9/9 in pull mode.
That result holds only after the old EPP has exited; Observation 8 is about the time before.

### 8. During a rolling restart, push mode feeds the EPP that is leaving

Probe `rollout-nowait` (runs `20261115-nowait-<arm>`): `kubectl rollout restart` of the EPP, then, as soon as the new
EPP serves requests and while the old pod is still terminating, a new family warmed on each pod and routed; then the
same once the old pod is gone.

| Arm | New EPP ready after | Old EPP gone after | Warm-ups predicted while the old EPP was terminating | After it was gone |
|---|---|---|---|---|
| precise (push) | 6 s | 36 s | 0/3 | 3/3 |
| precise-pull | 6 s | 37 s | 3/3 | 3/3 |

In push mode the new EPP's message counter stayed absent (zero) through the window, while every simulator's socket to
the Service was ESTABLISHED with an empty Send-Q, so its bytes were being acknowledged by something.
The only other listener was the old EPP process, which the deployment lets run for up to its 130 s
terminationGracePeriodSeconds; that it was the old process receiving them is inferred, not read from its counters.
After the old pod exited, the simulators redialled and the new EPP had 5 messages and 74 admissions.
In pull mode the new EPP dials each simulator's publisher itself, a publisher accepts any number of subscribers, and
there was no window.
All three push-mode gateway requests in the window still hit, by tie-break, which is why the predicted column is the one
to read.

`20261115-run1` is where this was first seen, and its precise arm is kept only as that evidence.
There the lab switched the EPP config with a rolling restart right after restarting the simulators, and the new EPP's
message counter stayed at zero through every step, about two minutes, until a simulator pod created later connected
(`snap-0-start` to `snap-7c-after-leave`: no messages, no admissions), so the precise arm routed on all-zero scores.
The window measured above closed after about 30 s, so run 1 fits it only if the old EPP took most of its 130 s grace
period to exit that time; run 1 did not record when the old pod went, so that part is not established.
The `epp-restart` probe's three variants, which wait for the old pod to go before testing, recovered every time.
`hack/llmd-kv-lab.sh mode` now restarts the simulators after the EPP, so no arm starts inside such a window.

### 9. Pull mode without explicit datalayer wiring indexes nothing, silently

`20261115-run2` and `20261115-run3`, arm `precise-pull`: the simulators bound `tcp://*:5557` (their logs say
"ZMQ publisher bound"), and the EPP config had no `zmqEndpoint`, leaving `discoverPods` at its default of true.
In both runs the EPP's plugin state reported `"subscribers": []`, the index took 0 admissions, every score was 0, and
the EPP logged no warning or error.
The first run had no endpoint-notification source in the config; the second listed the source but did not wire the
producer to it under `dataLayer`.
With the wiring upstream's own e2e config uses (`llm-d-router/test/e2e/artifacts/config/epp-precise-prefix-cache-config.yaml`,
copied into `epp-precise-pull.yaml`), the EPP held one subscriber per pod and pull mode matched push mode step for step
(`20261115-run4`: affinity 12/16, warm-up 3/3, both predicted).
A configuration that names the precise producer, keeps the default `discoverPods: true`, and omits that wiring is
accepted and routes as if no pod held anything.

## What was only read in code

These explain the observations; none was measured beyond what the observation above it says.
Paths are in llm-d-router at the pinned commit unless another repository is named; paths elsewhere on this page that
start with `llm-d-router/` are in the same checkout.

- **Why one publisher leaving stops all of them (Observation 6).**
  go-zeromq v0.17.0 reads each connection of a socket in its own goroutine and forwards a read error into the queue
  the socket's Recv drains (`zmq4@v0.17.0/msgio.go:100-115`), so one peer's EOF is returned from Recv.
  The router's subscriber treats any Recv error as fatal for the socket (`pkg/kvevents/zmq_subscriber.go:195-201`),
  closes it, and waits `retryInterval`, 5 s (`pkg/kvevents/zmq_subscriber.go:37,134-140`), before binding again.
  Every publisher's connection closes with it and redials; the simulator retries every second
  (llm-d-inference-sim v1.2.0 `pkg/common/publisher.go:89-96`).
- **Why the bound socket cannot notice lost events.**
  The sequence check in the no-replay branch runs only when the subscriber has a source endpoint
  (`pkg/kvevents/zmq_subscriber.go:212-225`), and the bound socket has none because it interleaves every publisher's
  sequence.
  Events dropped while a publisher has no connection therefore leave no trace in the EPP.
- **Why a repeat within a second misses (Observation 4).**
  The simulator publishes a batch when it reaches 16 events or when a 1 s timer fires
  (llm-d-inference-sim v1.2.0 `pkg/kvcache/block_cache.go:35`, `pkg/kvcache/kv_cache_sender.go:100-155`).
  vLLM's own publisher is different code and was not examined here, so the length of this lag belongs to the
  simulator and should not be read as vLLM's.
- **Why pull mode needs explicit wiring (Observation 9).**
  The precise producer subscribes per pod in its endpoint extractor
  (`pkg/epp/framework/plugins/requesthandling/dataproducer/preciseprefixcache/extractor.go:37-61`), which only an
  endpoint-notification source calls.
  It does not implement the datalayer Registrant interface, so nothing registers that source for it when the config
  omits it; plugins such as lora residency do (`pkg/epp/framework/plugins/scheduling/scorer/loraresidency/plugin.go:333-344`).
- **Why a request with no information still lands somewhere predictable (Observation 2).**
  The max-score picker sorts by score and then name, and rotates within a tier of equal scores with a counter
  (`pkg/epp/framework/plugins/scheduling/picker/maxscore/picker.go:97-118`), so with all scores 0 it walks the pods in
  name order, one request at a time.
- **The approximate arm's memory.**
  It records the picked endpoint per block hash in its own LRU after scheduling, from the request alone
  (`pkg/epp/framework/plugins/requesthandling/dataproducer/approximateprefix/plugin.go`), so it has no way to learn of a
  warm-up or an eviction it did not cause.

## Limits

- A simulator, not an engine.
  Its cache is a block LRU fed by the real tokenizer; its event cadence (a 1 s flush) is not vLLM's.
  No latency figure here is a serving latency, and the lab makes no performance claim.
- Requests are sequential, 300 ms apart, with no concurrency, no load, and no other scorer.
  With the prefix scorer alone, a tie falls to the picker's rotation, which a real profile would not.
- Each step ran once per arm in the observe runs; the repeated probes are what carry Observations 2, 4, 6, 7 and 8,
  with three to six repetitions each, which is enough to show a difference of all against none and not enough to
  estimate a rate.
- The EPP ran one replica; nothing here says how several EPP replicas share or diverge in their index.
- One node: every connection is pod to pod through the node's own forwarding, and the ZMQ block is an iptables rule
  there, which is a clean partition, not a lossy or slow link.
- The InferencePool, Gateway and Istio are upstream's dev manifests; this lab does not test them.

## Upstream-relevant findings

Nothing below has been posted.
Each was searched for in llm-d/llm-d-router's issues and pull requests on 2026-11-15 (queries listed) and no existing
report was found; that is a search result, not proof that none exists.

1. **Push mode: one publisher disconnecting silences every publisher for the subscriber's retry interval.**
   Measured: 0/5 warm-ups on healthy pods indexed inside the window, 5/5 controls indexed, and 5/5 in pull mode
   (Observation 6).
   Mechanism read in code (go-zeromq Recv surfaces one peer's EOF; the subscriber treats it as fatal and sleeps 5 s).
   Relevance: llm-d-router#4105 already proposes retiring the bound-socket mode and moving the e2e overlays to pull mode,
   for a security reason; this is an availability reason for the same change, and a note on that issue is the natural
   place for it rather than a new one.
   Searched: "zmq subscriber EOF", "Failed to receive message from zmq subscriber", "global socket reconnect",
   "zmq reconnect", "kv events lost restart".
2. **Push mode: during a rolling restart of the EPP, the new EPP receives no events until the old one exits.**
   Measured: 0/3 in push mode, 3/3 in pull mode, window about 30 s (Observation 8).
   Same relevance to llm-d-router#4105.
3. **Pull mode configured with the precise producer but without `dataLayer` wiring starts cleanly and indexes nothing.**
   Measured twice (Observation 9).
   The producer does not register its notification-source dependency the way other endpoint-tracking plugins do, so
   neither a default source nor a startup error results.
   A small, self-contained change (register the dependency with a default source, or fail when `discoverPods` is on and
   nothing feeds the extractor) is a plausible first PR; the issue should come first, per the repository's process.
   Searched: "endpoint-notification-source precise", "discoverPods subscribers", "precise prefix no subscribers";
   the nearest, llm-d-router#2274 (closed), is a different cause of all-zero scores.
4. **`VLLM_EXTRA_ARGS_D` with two flags breaks `make env-dev-kind`.**
   kustomize emits the placeholder unquoted, so the splitter in `llm-d-router/scripts/kind-dev-env.sh`, which matches
   only a quoted list item, passes both flags to the simulator as one argument; the simulator then exits on a parse
   error.
   `make bench-tokenizer` prints exactly such a two-flag command as its setup instruction.
   Recorded with kubectl v1.36 (kustomize v5.8.1) in `hack/llmd-kv-lab/runs/20261115-setup/extra-args-one-argv.txt`;
   older kustomize versions were not tried, so whether this ever worked is unknown.
5. **llm-d-inference-sim v1.2.0 exits with status 0 on a configuration error.**
   Same file: "failed to read configuration" and a container exit status of 0, so Kubernetes shows the pod as Completed
   before CrashLoopBackOff rather than as Error.
   Minor, and for the simulator repository.

Findings 1 and 2 matter only while the bound-socket mode exists, and #4105 may remove it; their value upstream is as
evidence for that change, measured on upstream's own dev environment.

## #599: shared-942 through the prefix scorers

Issue #599 asked whether llm-d-router's prefix scorers reproduce what gpuaas's own `PrefixAffinity` did in experiment
A's block `shared-942`: a higher prefix-cache hit ratio (0.8191 against `RoundRobin`'s 0.5467) with a worse TTFT p99
(3,139.0 against 2,577.0 ms), the one block that made experiment A's verdict NOT MET
(docs/superpowers/specs/2026-10-27-prefix-aware-routing-design.md, "Run 2").
Short answer: **not observed on the simulator, and in experiment A's own rows the requests that set the p99 were placed
by `PrefixAffinity`'s no-match fallback, exactly as `LeastQueue` placed them, not by prefix affinity.**
Nothing here is posted upstream, and no upstream claim follows from it.

### What shared-942 is

The study `prefix-route-2026-10-27`'s load (`internal/bench/study.go`), with seed 942: one tenant, Poisson arrivals at
0.8 requests a second for 600 s, 482 requests; each a single user message of 41,000 characters, of which 40,000 are one
of 77 system prompts drawn uniformly (each opening with its own header line, so no two share a first chunk) and 1,000
are the request's own, opening with its seed and index; output fixed at 64 tokens.
On the A10G each prompt was about 7,900 tokens (`engineInputTokens` 7,896–7,897), and 77 prompts were 1.5 times one
engine's 393,232-token cache, so routing decides which prompts each engine keeps.
Trace sha256 `2b42ce96…5392e1`; two vLLM 0.27.1 engines, `qwen-a` and `qwen-b`.

### What set experiment A's p99 in shared-942

`hack/llmd-kv-lab/shared942_tail.py` reads run 2's archived `raw.jsonl` rows and nothing else.

- With 482 requests the p99 is the 478th, so the five slowest requests set it.
- For `LeastQueue` and `PrefixAffinity` they are the same five requests, #6, #12, #13, #16 and #17, all scheduled
  between 3.9 and 12.1 s, while both engines' caches were still empty; every one is a `prefix_none` row, a miss.
- `PrefixAffinity` sends a request with no indexed prefix to the least-loaded backend, which is `LeastQueue`'s rule.
  21 of requests #0 to #21 had no match, and the one that matched (#18, at 13.1 s) went where `LeastQueue` sent it
  too, so the two arms routed #0 to #21 identically; the first difference is #22, at 17.8 s.
  Their p99s, 3,129.2 and 3,139.0 ms, are the same request (#6) a few milliseconds apart.
- `RoundRobin`'s five are #6, #12, #13, #58 and #7: three of the same cold-start requests, placed by strict alternation,
  which put #12 and #13 on different engines where the outstanding-count rule had put both on `qwen-b`.

Leaving the first seconds out, which no registered rule did, reverses the order:

| p99 over requests scheduled after | `RoundRobin` | `LeastQueue` | `PrefixAffinity` |
|---|---:|---:|---:|
| 0 s (the registered endpoint) | 2,577.0 | 3,129.2 | 3,139.0 |
| 10 s | 2,137.2 | 2,314.4 | 1,693.5 |
| 20 s | 1,977.6 | 2,078.1 | 1,327.5 |
| 30 s | 1,822.4 | 1,997.9 | 1,309.7 |

So in shared-942 the requests that decided the p99 arrived while the caches were filling, and `PrefixAffinity` placed
them by its fallback, as `LeastQueue` did; over the whole trace its share was 0.527 / 0.473.
Why the outstanding-count placement of the cold start was slower than strict alternation is not established: it is one
trace, and no arm varied only that.
This is a reading after the result: experiment A's verdict stands as registered, and the table above is not a result.

### The replay

`hack/llmd-kv-lab/replay599.sh run` regenerates shared-942 from the study's registration, refuses it unless the
unscaled trace's checksum is the frozen one, and divides every prompt length by ten (4,100 characters, 4,000 shared);
the arrivals and prompt draws do not depend on the lengths, and the replay checks they are unchanged row by row.
It sends the 482 requests open-loop at their scheduled times as streamed `/v1/completions` through the gateway, and
records per request the serving pod, the simulator's cached and prompt tokens and the first content chunk's arrival,
with each simulator's running and waiting gauges sampled every second and the EPP's log followed for its scores.

The simulator shape (`replay599.sh env`), each value tied to experiment A rather than tuned:

| Setting | Value | Why |
|---|---|---|
| Simulators | 2 | experiment A's two engines |
| Prompt | 889–891 tokens (TinyLlama), of which 864 cached on a hit | the scaled prompt as the simulator counts it |
| KV cache | 2,769 blocks of 16 tokens | 51.1 shared prefixes, experiment A's 393,232 / 7,695 |
| `--max-num-seqs` | 1 | one request at a time, so a burst of misses queues as long prefills do on one engine |
| Prefill | 60 ms + 1 ms a token not cached | a miss 0.95 s, a hit 0.09 s, the A10G's 1.0 and 0.09 s |
| Decode | 5 ms a token, 64 tokens | |

Arms, all on the same pinned EPP:

| Arm | Config | What it is |
|---|---|---|
| `rr` | `epp-rr.yaml` | no scorer; every endpoint ties and the max-score picker rotates, so round-robin |
| `approx` | `epp-approx.yaml` | upstream's dev config: the approximate prefix scorer alone |
| `approx-load` | `epp-approx-load.yaml` | upstream's optimized-baseline guide: queue 2, KV utilization 2, prefix 3, no-hit-LRU 2 |
| `precise` | `epp-precise.yaml` | upstream's dev KV-event config, push mode: the precise prefix scorer alone |
| `precise-load` | `epp-precise-load.yaml` | upstream's precise-prefix perf config: active requests 4, KV utilization 2, prefix 2, no-hit-LRU 2, with speculative indexing and pull mode |

`precise-load` differs from `precise` in three ways at once (load scorers, speculative indexing, pull mode), because
each config is upstream's as shipped; a difference between the two is upstream's deployed configs' difference and is
not attributed to any one of the three.

The approximate producer sized its index from the simulators' metrics, 692 entries of 64 tokens a pod (2,769 × 16 / 64),
the same rule experiment A borrowed for its own index (plugin state in each run's `snap-after`).

**Results** (`20261118-replay599-2/summary.txt`; every request succeeded and was joined to the EPP's scores, every
gauge read succeeded).
"Hit" is the simulator's cached tokens over prompt tokens, summed; the simulators' own prefix-cache counters agree
(approx in run 1: 344,736 / 429,442 = 0.803).
"Scorer > 0" counts requests whose picked pod the prefix scorer scored above zero; "of those, missed" counts such a
request that the simulator then served with nothing cached.
TTFT is from the scheduled send to the first content chunk, nearest rank; **it is a simulator's and only says where
requests queued.**

| Arm | Share by pod | Busiest pod's share, worst 30 s window | Hit | Scorer > 0 | Of those, missed | Queue mean / highest sampled, by pod | TTFT p50 | p99 | p99 by pod | p99 after 20 s |
|---|---|---:|---:|---:|---:|---|---:|---:|---|---:|
| `rr` | 0.500 / 0.500 | 0.54 | 0.555 | — | — | 0.36, 0.33 / 3, 4 | 204 | 2,354 | 2,389 / 2,279 | 1,895 |
| `approx` | 0.550 / 0.450 | 0.79 | 0.803 | 384/482 | 0 | 0.29, 0.24 / 4, 2 | 93 | 2,043 | 2,033 / 2,043 | 1,575 |
| `approx-load` | 0.512 / 0.488 | 0.68 | 0.791 | 384/482 | 0 | 0.28, 0.25 / 3, 3 | 93 | 2,003 | 2,003 / 1,866 | 1,293 |
| `precise` | 0.564 / 0.436 | 0.79 | 0.813 | 404/482 | 0 | 0.30, 0.23 / 4, 2 | 95 | 2,041 | 2,015 / 2,041 | 1,576 |
| `precise-load` | 0.508 / 0.492 | 0.71 | 0.700 | 349/482 | 0 | 0.31, 0.27 / 3, 2 | 95 | 2,040 | 2,040 / 1,896 | 1,535 |

The window column is the worst 30 s window starting at any arrival and ending inside the trace (13 to 24 requests);
queues are read once a second, so a shorter peak can be missed.

Run 1 (`20261118-replay599-1`) gave shares within 0.04, hit ratios within 0.016 and p99s within 3 ms (2,352, 2,043,
2,003, 2,040, 2,040); its EPP log was read after the arm, by which time kubelet had rotated most of it away, so its
scorer columns cover 3 to 103 requests an arm and are not used.
The simulator's latencies have no random term in this shape, so two runs agreeing says the apparatus is repeatable, not
that the effect is robust.

What it shows:

1. **The structure carries over to the simulator.**
   `rr`'s hit ratio, 0.555, is experiment A's `RoundRobin` 0.5467, and its slowest requests (#6, #58, #12, #59, #13)
   are four of `RoundRobin`'s five; the prefix arms' 0.700 to 0.813 are at or below `PrefixAffinity`'s 0.8191.
2. **No prefix arm worsened the tail.**
   All four p99s are below `rr`'s in both runs, and after the first 20 s by 319 to 602 ms.
3. **The cold start alternated pods in every arm, for two different reasons.**
   Requests #0 to #17 alternate pods in all five arms.
   In `rr`, `approx` and `precise` every score is 0 then, and the max-score picker rotates through the tie.
   In `approx-load` and `precise-load` the scores do not tie: for #5, for example, the queue or active-request scorer
   and the no-hit-LRU scorer both favoured the pod that got it, so alternation there is the weighted load scores'
   choice on this trace, not a fallback.
   In every prefix arm the four slowest requests are the cold-start misses #6, #12, #13 and #7, and the fifth, which
   is the p99, is a miss at 64 s (#59 or #58) or the cold-start #4.
4. **Concentration is moderate and the scorer is never wrong about a hit here.**
   The lone scorers lean to one pod (0.550 and 0.564 of all requests, 0.79 of the worst 30 s window), and upstream's
   load-aware configs stay near 0.51 (0.68 and 0.71 of the worst window) with a lower hit ratio (0.791 and 0.700).
   No request the prefix scorer credited a pod for went there and missed, in any arm.

So the conflict **was not observed** under llm-d-router's approximate or precise prefix scorers in this simulator
configuration, and nothing here is evidence of an upstream defect.
What this does not show:

- That it cannot happen on vLLM.
  The simulator matches experiment A's cache ratio and isolated prefill costs, not its engine: vLLM ran up to 64
  sequences with a 512-token step budget, and the time from first token to the end of a response had a median of
  1,083.5 ms there (`PrefixAffinity`'s rows) against 326.4 ms here (`approx`, run 2), so outstanding counts, and anything
  a load scorer or experiment A's fallback reads from them, are not reproduced.
- That llm-d's placement would have avoided gpuaas's tail: no arm here applies the outstanding-count fallback, so there
  is no positive control showing that this simulator turns that placement into a worse p99.
- Robustness: one trace, two runs of a simulator with no random term.

Any statement about GPU latency still needs the separately approved GPU run the issue names.

### Endpoint replacement and cancellation (week-1 exit)

`hack/llmd-kv-lab/probes.sh churn ARM` and `probes.sh cancel ARM`, on the replay's simulator shape; `churn599.py`
prints one line per churn run.

**Pod delete under traffic** (three runs per arm): four concurrent streams of family CA, 40 requests each, 0.1 s apart
after each answer, so the prefix scorer steers them to the pod that holds CA; that pod is deleted 3 s in, with
kubectl's default grace period.

| Arm | Requests that succeeded | Served by the deleted pod | In flight at the delete, on the deleted pod | Of those, failed |
|---|---|---|---|---|
| `approx` | 160/160, each run | 30 | 4 | 0 |
| `precise` | 160/160, each run | 25 | 1 | 0 |
| `precise-load` | 160/160, each run | 28 | 1 | 0 |

The counts repeat exactly across the three runs because the simulator has no random term and the delete is timed by a
fixed sleep.
"In flight" is a request sent before the delete was issued and answered after it.
Requests caught on the deleting pod finished there during its termination; a forced delete (`--grace-period=0`) or a
node loss was not tried, and that is the case where a request in flight would be cut.
The first version of this probe sent a family of its own one request at a time, which reached the deleted pod 0 to 5
times a run; it was replaced and its runs dropped.

**Container restart in place** (three runs per arm): kubelet restarts the simulator inside the same pod, so its name and
address stay while its cache empties; then CB, which it held, is sent once.

| Arm | Restarted pod's prefix score for CB | Served by | Cached |
|---|---|---|---|
| `approx` | 0.857, 3 of 3 | the restarted pod | 0, 3 of 3 |
| `precise` (push) | 0.952, 3 of 3 | the restarted pod | 0, 3 of 3 |
| `precise-load` (pull) | 0, 3 of 3 | the other pod | 0 |

In pull mode the restart made the pod leave the pool for a moment; the EPP removed its subscriber and its index
entries, and re-subscribed when it returned (its log shows one "Removed KV-events subscriber" and a second "Creating new
subscriber" for the restarted pod in each of the three runs).
That clearing follows from the endpoint leaving the pool; a restart quick enough that the pod never left it was not
produced here, and nothing says pull mode would clear in that case.
The approximate producer drops a pod's index only when a two-minute sweep finds it absent
(its CleanUpInactivePods loop in llm-d-router's
`pkg/epp/framework/plugins/requesthandling/dataproducer/approximateprefix/plugin.go` at the pinned commit), and the push-mode subscriber has no per-pod
lifecycle at all, so both kept crediting the restarted pod.
The cost measured here is one miss per stale prefix, which a cold pod pays anyway; it routes a request wrongly only
when another pod holds the same prefix, which these probes did not construct.
Push mode is being retired upstream for other reasons (llm-d-router#4105, with this lab's earlier data in its thread),
and an approximate index is by design blind to evictions it did not cause ([Observation 3](#3-eviction-the-precise-index-follows-the-cache-the-approximate-one-does-not)),
so neither is reported as a defect.

**Cancellation** (`approx-load` and `precise-load`, once each): six streamed requests of 900 tokens sent within 0.3 s
to two pods that run one request at a time, every client gone after 1 s (curl exit 28 for all six).
Both simulators read 0 running and 0 waiting from the first read 1.3 s after the start and in all 80 reads over the
next 20 s, so the cancelled requests were dropped rather than generated; a simulator that kept them would have been
busy for about 13 s.
The next ten requests alternated pods with equal active-request and queue scores, so neither the EPP's in-flight count
nor its scraped queue kept the cancelled requests.

### Where this leaves lane 1

- No upstream defect from #599; nothing drafted.
- The lab now replays a registered gpuaas trace through upstream routing with the simulator pinned past #915 and #920,
  which is the fixture week 2 needs for any routing discrepancy that does appear.
- Not done here: several EPP replicas, a restart of a pod that shares a prefix with another, and cancellation while the
  EPP's flow control queues requests (off in this lab; #600's territory).

## What #599 and #600 can take from here

#599 has since run on this lab, with the three cautions below applied: the predicted column, a precise-spec style arm
(`precise-load`), and a load, concurrency and latency shape of its own
([#599](#599-shared-942-through-the-prefix-scorers)).
What follows is as written before it.

**#599 (reproduce the PrefixAffinity tail regression under llm-d-router's scorers) can proceed on this lab, with three
cautions the lab itself found.**
The driver, the per-request join of decision to outcome, and the four arms are what it needs.
First, read hits with the predicted column beside them: a lone prefix scorer's tie-break can produce a perfect hit
rate with no knowledge at all (Observation 2), and the shared-942 regression is about a hit rate.
Second, the precise arm's sub-second lag (Observation 4) is the simulator's flush interval, so any burst effect it
produces must be checked against precise-spec before being attributed to precise routing.
Third, the tail half of the question needs load, concurrency, and the simulator's latency model, which this lab does
not configure; the structural half (where requests go, how concentrated they get) can run here, and any latency claim
still needs the separately approved GPU run the issue already requires.

**#600 (killing the EPP while requests are queued under fail-open) can proceed on this lab for its setup, not yet for its
measurement.**
The cluster, the pinned EPP built from current main, the InferencePool and the restart probes are in place, and
Observation 8 shows the restart choreography matters (wait for the old pod, or test the window deliberately).
What it still needs, and this lab does not have: `failureMode: FailOpen` on the InferencePool (upstream's dev pool
leaves the default), flow control enabled so requests actually queue in the EPP (it is behind a feature gate, and the
lab's responses carry no `x-llm-d-flow-queue-duration-ms` header, so it is off), concurrent load so the queue is
non-empty at the kill, and a body-integrity check on the response (the simulator's echo mode returns the prompt, which
makes one possible).
llm-d-router#4202 and #4203 should be read first, as the issue says.
