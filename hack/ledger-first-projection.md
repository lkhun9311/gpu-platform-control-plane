# Operations ledger: the first projection outside a test

2026-09-30. `internal/ledger` had storage, a projector, a reader and `cmd/platformctl`, and
`ProjectWorkloadRuns` was called by tests and by nothing else. This is the first run that read a
cluster and wrote the ledger.

## How

```sh
KCTX=kind-m6clean KEEP=1 hack/m7-evidence-trail.sh   # leaves the WorkloadRun in place
go run ./cmd/platformctl workload-runs project -ledger /tmp/ledger.db
go run ./cmd/platformctl workload-runs list    -ledger /tmp/ledger.db
```

`KEEP=1` matters: without it the script removes the namespace and the CRD it added, and there is
nothing left for the projector to read.

## The WorkloadRun the run produced

```
NAMESPACE   NAME    SCENARIO           PHASE      VERDICT     AGE
m7          fr002   ServingPodKilled   Complete   Recovered   106s
```

Its trail, published by the recorder rather than written by the script:

```
s  healthy=true
s  healthy=false
s  healthy=true
```

## What the projector reported

```
seen=1 written=1 stale=0 without-start=0 events-new=3 events-already=0
```

Re-running it is idempotent, which is the projector's own claim:

```
seen=1 written=1 stale=0 without-start=0 events-new=0 events-already=3
```

## What the ledger holds

```
NAMESPACE  NAME   SCENARIO          PHASE     VERDICT    TARGET                         PROJECTED
m7         fr002  ServingPodKilled  Complete  Recovered  InferenceDeployment/m7-target  2026-09-30T13:20:32+09:00
```

```
m7/fr002
  uid        e15c8cad-f51e-4e44-a457-8a9dc89b41ae
  scenario   ServingPodKilled
  target     InferenceDeployment m7/m7-target
  phase      Complete
  verdict    Recovered
  reason     observed Ready at 20s, within the declared 45s
  started    2026-09-30T13:17:34+09:00
  last seen  2026-09-30T13:18:34+09:00
  generation 1
  projected  2026-09-30T13:20:32+09:00
  trail
    #  ELAPSED  STATE    HEALTHY  WALL CLOCK
    0  0s       Ready    true     2026-09-30T13:17:34+09:00
    1  10s      Pending  false    2026-09-30T13:17:44+09:00
    2  20s      Ready    true     2026-09-30T13:17:54+09:00
```

## What this does not close

- Two of six tables. `model_versions`, `deployment_runs`, `benchmark_runs` and
  `node_health_history` do not exist, as tables or as stubs.
- Nothing runs the projector on a schedule. It is a command someone types.
- The ledger file itself is not committed: it is a SQLite database built from a throwaway cluster,
  and this page is the record of the run rather than of its bytes.
