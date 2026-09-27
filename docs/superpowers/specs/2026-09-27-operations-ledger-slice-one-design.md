# Operations ledger, slice 1 — the record the cluster does not take with it (design spec, v1)

Date: 2026-09-27 · Milestone: M7 (failure/evidence) · Author: lkhun9311

Written before any ledger code exists. `docs/07_OPERATIONS_LEDGER_AND_EVIDENCE.md` has said "designed only
— no code" since 2026-08-07, and its "To fill" line still reads "ledger DDL (SQLite local / Postgres real),
projector from CR/status/events". So there is no schema to implement here: this page decides one, for two
tables out of six, and says what it refuses to decide yet.

## The problem in one sentence

Every record this project produces lives in Kubernetes objects on clusters that are deliberately thrown away,
so the evidence dies with the cluster that produced it.

### Why that is not a theoretical complaint

`kind` clusters are torn down at the end of a session by design, and the paid EC2 sessions — more than thirty
GPUs since 2026-09-02 — are torn down because leaving them running is the standing cost hazard. A
`WorkloadRun` that recorded a real injection on real hardware exists only until `kind delete cluster`.

The gap is already load-bearing in a published document. `docs/06_OBSERVABILITY_BENCHMARK_FAILURE.md:70` lists
FR-001's expected evidence as `workload_runs.failure_reason=quota_exceed`. There is no `workload_runs`, so
running FR-001 today produces evidence that the repository's own failure-report table says is incomplete.
That is the concrete reason this comes before FR-001 rather than after it.

## What slice 1 is, and what it is not

Two tables of the six: `workload_runs` and `operation_events`. `model_versions`, `deployment_runs`,
`benchmark_runs` and `node_health_history` are not written, not stubbed, and not migrated.

The reason is not effort. Four more projections means four more places where a row can be written that
nothing reads and nothing checks, and this repository has spent the last month finding checks that cannot
tell "did not run" from "passed". One projection whose duplication and absence semantics are pinned by tests
is worth more than six that are merely present.

| Table                 | Slice 1        | Why                                                                 |
|-----------------------|----------------|---------------------------------------------------------------------|
| `workload_runs`       | written        | the only table a published document already cites as evidence       |
| `operation_events`    | written        | a run with no transitions recorded is a verdict with no trail        |
| `node_health_history` | not in slice 1 | waits on the NodeHealth intake contract, which is itself undecided   |
| `benchmark_runs`      | not in slice 1 | the paid-run outputs are files today; moving them is its own change  |
| `deployment_runs`     | not in slice 1 | nothing cites it yet                                                 |
| `model_versions`      | not in slice 1 | nothing cites it yet                                                 |

## Decisions

### The driver is forced, not chosen

`Dockerfile:22` builds with `CGO_ENABLED=0`. That eliminates `github.com/mattn/go-sqlite3` and every other
cgo binding, leaving `modernc.org/sqlite`, the pure-Go translation. This is worth stating because it is the
kind of constraint that is discovered at container-build time rather than at `go test` time, and because a
future reader comparing drivers should know the comparison was never open.

### The ledger is a projection, and must never be able to fail a reconcile

`docs/07` is explicit that the source of truth is the Kubernetes resources and the controllers, and that the
ledger is an evidence projection. That forbids the obvious implementation — write to SQLite inside
`Reconcile` — because a ledger write that returns an error would then decide whether a workload proceeds.
An evidence store must not acquire a vote on the thing it is evidence about.

So slice 1 puts the projector outside the operator entirely: a command that reads `WorkloadRun` objects from
an API server and writes rows. The operator is unchanged by this slice. Nothing in `internal/controller/`
imports the ledger.

### What the projector claims, and what it does not

It claims: at the moment it ran, these objects were in these states, and here is what their own status
stamps say happened.

It does not claim to have observed every transition. It is a poll, not a watch, so a phase that appeared and
was replaced between two runs is invisible to it. Recording a row that implies continuous observation would
be the same error this repository keeps finding in its own checks, so a projected run carries the generation
and the observation time it was taken from, and the reader prints them.

### Idempotency comes from the object's own offsets, never from the projector's clock

`workload_runs` is keyed by the object UID, so re-projecting updates one row rather than appending another.

`operation_events` is the harder half, and reading `api/v1/workloadrun_types.go` changed the answer this page
first gave. There is no `lastTransitionTime` to key on: the run's trail is `status.observations`, and a
`WorkloadRunObservation` carries `elapsedSeconds`, `state` and `healthy` — an offset from `status.startedAt`,
deliberately not a wall clock, "so a trail can be read without knowing when the run happened". The only wall
clock in the whole status is `startedAt` itself.

The first answer this page gave was (object UID, `elapsedSeconds`, `state`), and a cold review killed it. The
controller truncates elapsed time to whole seconds (`internal/controller/workloadrun_controller.go:230`) and
appends on every state change (`:234`), so `Ready@0 → Degraded@0 → Ready@0` is a legal trail inside one
second — and its first and third entries collide. The key would either abort the projection or silently drop
the later transition, and a projector counting that drop as "already present" would report a loss as a
successful replay.

So the identity is (object UID, the observation's **ordinal in the trail**). The API defines
`status.observations` as "the trail, in the order they were seen"
(`api/v1/workloadrun_types.go:189`), which makes the position part of what the record means rather than an
implementation detail. `elapsedSeconds` remains the timing authority for reading the trail; it is simply not
unique enough to be the identity.

A wall-clock time is *derived* as `startedAt + elapsedSeconds` rather than stored as the authority — the same
separation `internal/queuelab/ledger.go:37` already makes, keeping an elapsed offset as the timing authority
and the wall clock for provenance only. Two ledgers in one repository must not disagree about which clock
decides.

Keying on the projector's own clock was the other alternative, and it fails loudly enough to name: every
replay would write a new row with a new timestamp, the table would grow without bound, and every row in it
would look legitimate.

One hole stays open and is recorded rather than closed: rewriting `startedAt` for the same UID would change
the derived wall time of every stored event without changing any key. No code path does that today — it is
set once on entry to `Observing` (`:147`) and nothing resets status — so this slice does not defend against
it, and says so instead of implying it cannot happen.

### A run that never started is recorded as a run, with no events

`status.startedAt` is set only on entry to `Observing` (`internal/controller/workloadrun_controller.go:147`),
so a run that never got that far has none and no wall clock can be derived for it at all.

Be precise about which runs those are, because the first version of this page was not. `Refused` is **not** one
of them: the gap check at `:160` refuses a trail with a hole in it, which happens *after* a run has been
observing and therefore after it has a start. A refused run usually has one. The runs without a start are the
ones that never entered `Observing` at all — refused at the first look because the target does not exist, or
still `Pending`.

Such a run still gets its `workload_runs` row, with zero `operation_events`. That is the distinction the
ledger exists to keep: "this run was never observed" is a different fact from "this run was observed and
nothing happened", and a schema that could not tell them apart would be storing the very confusion
`status.lastObservedAt` was added to the API to prevent.

### The column FR-001 asks for cannot be filled yet, so it is not created

`docs/06_OBSERVABILITY_BENCHMARK_FAILURE.md:70` names `workload_runs.failure_reason=quota_exceed` as FR-001's
expected evidence. No field on `WorkloadRun` produces such a code. What exists is `status.reason`, and the
controller writes prose into it — `"never observed %s during the %ds window"`
(`internal/controller/workloadrun_controller.go:207`) — plus `status.verdict`, whose whole vocabulary is
`Recovered` and `NotRecovered`.

Putting that prose in a column called `failure_reason` would make FR-001 look satisfied while storing
something else entirely, which is worse than the empty column it replaced. So slice 1 stores `reason` and
`verdict` under their own names and creates no `failure_reason`.

The gap is wider than a missing column, and saying so is the point. `WorkloadRun`'s scenario enum admits
exactly `ServingPodKilled` and `DegradedNode` (`api/v1/workloadrun_types.go:52`); **quota exceeded is not a
scenario this API can run at all.** So no storage decision could produce FR-001's evidence, and this slice
must not be described as delivering it. Closing it needs either a producing API — a scenario plus a coded
refusal vocabulary — or a correction to doc 06 that stops promising a row nothing can write. Both are API
decisions, not storage ones, and neither is done here.

### An unreadable ledger refuses; it does not report an empty one

If the database cannot be opened, or its schema version is newer than the binary understands, the reader
exits non-zero saying so. It does not print an empty list.

This is the rule `CLAUDE.md` already states for `internal/queuelab` and `internal/bench` — prefer an error
over a figure the evidence does not support — applied to the place where it matters most. "No runs recorded"
and "could not read the recording" are different sentences, and a reader who is shown the first when the
second is true has been told something false about their own system.

### Schema versioning

One `schema_migrations` table, integer version, applied in order, recorded in the same transaction as the
DDL it describes. Migrations are append-only: an applied migration is never edited, because a developer whose
database already has version 3 would silently keep the old shape while the file says otherwise.

## Sketch

```
schema_migrations(version INTEGER PRIMARY KEY, applied_at_unix_nanos INTEGER NOT NULL)

workload_runs(
  uid              TEXT NOT NULL PRIMARY KEY,   -- the Kubernetes object UID
  namespace        TEXT NOT NULL,
  name             TEXT NOT NULL,
  scenario         TEXT NOT NULL,
  target_kind      TEXT NOT NULL,
  target_name      TEXT NOT NULL,
  target_namespace TEXT NOT NULL,      -- the EMPTY STRING for cluster-scoped kinds, which is how the API says it
  phase            TEXT NOT NULL,      -- CHECK IN (Pending, Observing, Complete, Refused)
  verdict          TEXT,               -- CHECK NULL OR IN (Recovered, NotRecovered); NULL beside Refused
  reason           TEXT,               -- the controller's prose, stored as prose
  started_at_unix_nanos  INTEGER,      -- NULL for a run that never entered Observing
  observed_generation    INTEGER NOT NULL,
  projected_at_unix_nanos INTEGER NOT NULL,  -- when the PROJECTION was taken, not when anything happened
  -- plus CHECKs: no empty uid/namespace/name/scenario/target, generation >= 0, projected_at > 0
)

operation_events(
  object_uid       TEXT NOT NULL,
  ordinal          INTEGER NOT NULL,   -- the observation's position in status.observations
  elapsed_seconds  INTEGER NOT NULL,   -- the timing authority for READING the trail
  state            TEXT NOT NULL,      -- the target's own vocabulary, unnormalised
  healthy          INTEGER NOT NULL,   -- CHECK IN (0, 1)
  PRIMARY KEY (object_uid, ordinal)
  -- plus CHECKs: no empty uid/state, ordinal >= 0, elapsed_seconds >= 0
)
```

The primary key is the replay mechanism rather than a uniqueness check bolted beside one, so a replay is
absorbed by the storage engine instead of by a code path a test has to remember to exercise. But a conflict
alone is not idempotency, and that distinction cost this page a revision: the projector treats a conflict as
the normal outcome of a replay, and then **compares the stored row against what is being reported**, refusing
when they disagree. A `DO NOTHING` with no comparison would silently keep whichever reading arrived first.

The projector also refuses a ledger that holds MORE observations than the object now reports. The controller's
trail is append-only, so that should be impossible — which is exactly why it is checked rather than assumed,
because rows beyond the trail's end are a claim that something was observed, standing on nothing.

Two things `STRICT` does not do, having been claimed here before they were measured: it constrains storage
classes, not values, so `healthy = 17`, a negative offset and an empty required string all passed. Those are
`CHECK` constraints now. The phase and verdict vocabularies are pinned the same way — a value the API cannot
produce is not evidence, so it must stop a projection loudly rather than be stored and read back later as
though something had reported it.

`projected_at_unix_nanos` is named for what it is. Calling it `observed_at` would invite a reader to treat it
as the time something happened, and the number would support that reading while being false.

## Testing

The tests that decide whether this slice is worth anything:

- Projecting the same objects three times leaves the row counts unchanged, and the third projection reports
  every observation as already present rather than as newly written.
- `Ready@0 → Degraded@0 → Ready@0`, a legal trail inside one second, survives as **three** rows and replays
  as three. This is the case that broke the first key.
- A projector restart mid-way, then a full re-run, produces the same table as a single clean run.
- A projection that fails partway leaves nothing at all, including the runs it had already written.
- A run that never entered `Observing` produces one `workload_runs` row and zero `operation_events`, with a
  NULL `started_at_unix_nanos` rather than a zero that would read as the epoch, and a NULL verdict rather than
  an empty string.
- The same position reported twice with different contents is refused, and the refusal leaves the stored
  reading untouched.
- A ledger holding more observations than the object now reports is refused.
- A version number that does not describe the database is refused: a missing table the version claims, a
  history with a hole in it, tables with no migration record, a migration table with no rows.
- Values the API cannot produce are refused by the schema: a non-numeric offset, `healthy = 17`, a negative
  offset or ordinal, an empty required string, an unknown phase, a NULL target namespace.
- A missing database file makes the reader refuse rather than report an empty ledger.

Every one of these is a statement about absence or about a refusal, which is the class this repository has
repeatedly found unguarded.

Three were mutation-verified rather than trusted, and the verification itself needed two corrections worth
recording:

- Restoring the old `(uid, elapsed, state)` key made the round-trip test fail with `observation 2 ... neither
  inserted nor found` — the transition is lost, exactly as the review said.
- Removing the ghost-row check accepts a shrinking trail. The first attempt at this mutation deleted the
  block's closing brace and the package stopped compiling; a red build is not a red assertion, so it was
  redone by disabling the condition and leaving the syntax intact.
- Dropping all seventeen `CHECK` constraints reddened four cases and left two quiet, which I first read as
  "those two are unguarded". They were not: a diagnostic showed every value case is rejected by a named
  `CHECK` and the type case by `STRICT`, and the two had simply been reported in a different order. Reading an
  absence from a list as evidence is the same mistake this project keeps finding elsewhere. The test has since
  been split so that one failure names one mechanism.

One earlier test in this package was also found to be passing on an accident — it planted schema version 8 and
asserted on the string `"7"`, which the temporary pathname supplied — so expected strings are now built from
the fixture's own values.

## Two decisions taken after a second review

**The reader is `cmd/platformctl`, with `workload-runs project|get|list`.** The seven binaries that
already exist are all things you point AT a live cluster — the manager, the gateway service, the device-plugin
simulator, two benchmark tools, a load generator, and a single-controller driver. Not one of them reads a
durable record. `workloadrunctl` looks closest and is the clearest category error: it "runs the WorkloadRun
reconciler and nothing else" (`cmd/workloadrunctl/main.go:17`), and offline SQLite inspection is not that. The
alternative of shipping the library with no command was rejected because it leaves the slice's own claim
unmet: a ledger that needs Go written against it to be read is not evidence anyone can check, which is the
"unread ledger" this design refuses. An eighth entry point costs a name to learn; `README.md` already promises
this one.

**FR-001 is corrected in doc 06 rather than added to `WorkloadRun`.** Quota refusal is request-path evidence
and lives in the gateway, which already refuses with a stable code and counts it per tenant. A `WorkloadRun`
watches one target's phase and recovery, and a quota refusal changes neither an `InferenceDeployment` nor a
`NodeHealth` — so a `QuotaExceeded` scenario would be an enum value that can never produce a verdict, exactly
the failure the type's own comment warns about at `api/v1/workloadrun_types.go:41`. Doc 06 now promises what
the code actually emits, and marks as unbuilt the two things it does not: a durable record of the refusal, and
the "event" the old row named.

## Three holes the second review found, and what closed them

- **A stale projection could rewrite history backwards.** The UPSERT replaced phase and verdict
  unconditionally, so an older `Observing` snapshot could overwrite `Complete` with every column still looking
  like a legitimate reading. `status.lastObservedAt` exists to say when the controller last looked, and the
  schema did not even store it. It does now, and the update only fires when the incoming snapshot is at least
  as fresh.
- **Two accounts could be merged under one UID.** On conflict the immutable columns — namespace, name,
  scenario, target, `startedAt` — were neither compared nor updated, so a new status could be grafted onto an
  old identity. They are compared now, and a mismatch is refused. Delete-and-recreate is unaffected:
  Kubernetes issues a new UID, so it lands in its own row.
- **The schema admitted lifecycle states the API cannot produce.** Phase and verdict were constrained
  independently, which permitted `Complete` with no answer — and a test of mine asserted that combination was
  *legitimate*, pinning the opposite of the API's contract that a verdict is set only in `Complete`
  (`api/v1/workloadrun_types.go:196`). The pair is constrained together now.

Observations with no `startedAt` are also refused rather than stored: every offset in the trail is measured
from that origin, so a trail without one has no clock.

### Freshness is decided before anything else the snapshot says

Closing the first two holes put them in conflict, and a test found it rather than reasoning: a snapshot from a
minute ago legitimately has a **shorter** trail, so the shrinking-trail check fired and refused a projection
that should have been a quiet no-op. Two guards, each correct alone, disagreed about the same input.

The resolution is an ordering rather than a compromise. A stale snapshot has no standing to say anything — not
that the phase moved, and not that the trail shrank — so it is skipped whole and counted as skipped. The
shrinking-trail check therefore only ever runs against a snapshot that is at least as fresh as the stored one,
which is the only case where a shorter trail is genuinely a contradiction.

`RunsStale` is reported rather than left silent, because "nothing changed, the ledger was already ahead" and
"nothing changed, there was nothing to do" are different facts about the run.

## What this page deliberately does not decide

The Postgres form `docs/07` mentions. Whether the projector eventually becomes a watch. Where the database
file lives in a real deployment. Whether `platformctl` grows beyond `workload-runs`. Whether the gateway
should durably record its own refusals, which is what would actually close FR-001. Each is a real question,
and answering them here would be writing a design for code nobody has yet needed.
