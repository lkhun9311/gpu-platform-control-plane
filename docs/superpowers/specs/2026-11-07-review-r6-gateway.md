# Review r6, 2026-11-07: the inference serving path

gpt-6-astra (high) read `internal/gateway`, `cmd/gateway` and the serving results' archives read-only, told only the area.
Every finding was checked against the code by Claude; every fix, test and mutation is Claude's.

## Findings

| # | finding (astra) | verdict (Claude) | change | pinned by |
|---|---|---|---|---|
| 1–3 | restart barrier: Ready-plus-absent Pod, unobserved rank, reused fence entries | duplicate of review r1 | fixed in PR #520 | — |
| 4 | Kueue preemption bypasses the attempt lifecycle | duplicate of review r1 | fixed in PR #520 | — |
| 5 | the state-volume webhook accepts a `volumeMode: Block` claim | duplicate of review r10 item 6 | owned by the r8/r10 branch | — |
| 6 | a spec update leaves a caller's `priority` on its way to an engine still scheduling by it | **confirmed**: `enginePriorityScheduled` distrusts a condition of an older generation, so `anyPriorityScheduled` was false and `settlePriority` neither bound nor stripped (`internal/gateway/server.go:340`) | `MayPrioritySchedule` on `BackendRef`: true when the spec asks for a rendered engine or the controller ever reported one; it widens only the strip, never the bind | spec "removes a caller's priority while a rendered engine's condition is stale", "takes a rendered engine as possibly serving…" |
| 7 | static-cap charges the head's bucket and lets the request fall back to a spare whose bucket it never spent | **confirmed**: `decideAdmission` returns no reservation for static-cap, so `forwardTargets` kept every candidate | `pinnedToHead`: a request static-cap admitted `within_budget` goes to the head only, as a reserved one already did | spec "keeps a request whose tokens it charged to the head off the spare…" (refused head, live spare: standard 0 hits, premium 1) |
| 8 | a stateless admitter's admit returned an empty reason, hiding `telemetry_stale` and `backend_unregistered` | **confirmed** (`admitCandidates` returned `true, ""`) | the head's reason, or a bypass on any candidate in its place | spec "reports the head's reason, or a bypass on any candidate in its place" |
| 9 | KV telemetry freshness was the verdict at publication and did not expire between scrapes | **confirmed**: `fresh` is set in `publish` and read as is in `Admit` | the snapshot carries `freshUntil`; `Admit` and `Observed` judge it at decision time | specs "expires a snapshot at maxStaleness without another scrape", "publishes the time its telemetry expires" |
| 10 | `DRY_RUN=1` of the conformance session creates the results bucket and the IAM instance profile | **confirmed** (`hack/holdcap-conformance/session.sh` ensured both before the dry-run stop) | the ensure steps move after the stop | `hack/test/check-holdcap-conformance-dryrun.sh` with stub `aws`, `git`, `go` (in `harness-check`) |

## What ran

- Gateway suite 323/323 specs; ten separate `-race` runs, 10 of 10 green, no data race; full `go test` (envtest 1.37.0) green; `make lint` 0 issues; `make shell-check` green.
- Nine mutations, one per new check, each on the committed fix and restored with the tree checked clean: all red.

## Published results

No scorer changed, so no archive was re-scored.
The changes are to the gateway's runtime behaviour on paths the published runs did not take, as far as their records show: the kv-aware and static-cap arms of the M5 studies served one engine (`hack/m5b-chain-live.sh`, `replicas: 1`), so no fallback existed for findings 7 and 8 to act on, and they ran the default 2 s scrape against 6 s staleness, so finding 9 could change a decision only during a scrape blocked past 6 s, which no record shows.
No published document reads an admit reason from a stateless admitter.
