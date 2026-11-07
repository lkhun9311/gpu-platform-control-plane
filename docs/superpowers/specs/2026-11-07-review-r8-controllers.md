# Review r8, 2026-11-07: the controllers and APIs other than the restart lifecycle

gpt-6-astra (high) read `origin/dev` read-only on 2026-11-07, given the area (GPUQuotaPolicy, InferenceDeployment, WorkloadRun, NodeHealth readiness quarantine, the MLTrainingJob non-restart path, their webhooks, RBAC, CRD markers, `config/`) and nothing about where to look.
It returned eleven findings. Each was checked against the code here by Claude, and Kubernetes or Kueue behaviour it cited was checked against the pinned module sources (Kueue v0.18.3, the deployed release, `config/kueue-controller/RELEASE`).
Two findings of review r10 (items 6 and 7) were added to this branch at the main session's request; r10's items 1 to 5 repeat r8's 1 to 3 and #520.
Every fix and test is Claude's. The branch is based on `fix/restart-controller-review` (PR #520), because findings 9 and r10-7 touch the same controller, and is merged after it.

## Findings

| # | finding (astra) | verdict (Claude) | change | commit | pinned by |
|---|---|---|---|---|---|
| 1 | a rank never discovered is left out of fencing | confirmed | fixed in #520 (`rank-stopped` finalizer) | — | #520's envtest |
| 2 | Ready plus Pod absence taken as termination | confirmed | fixed in #520 (same finalizer) | — | #520's envtest |
| 3 | a fence acknowledgement outlives the attempt | confirmed | fixed in #520 (`fencedBy`, `name#N`) | — | #520's envtest |
| 4 | a Pod UPDATE can strip Kueue's admission gate and managed label from a GPU Pod; the guard reads CREATE only | **confirmed**: Kueue v0.18.3 `ValidateUpdate` checks neither, and its Pod controller skips a Pod without `kueue.x-k8s.io/managed` (Kueue v0.18.3, pkg/controller/jobs/pod/pod_controller.go line 590) | the GPU Pod guard also reads UPDATE: nobody may change or remove the managed label, and only `kueue-system:kueue-controller-manager` may remove the `kueue.x-k8s.io/admission` gate | `46c02066` | `TestAGPUPodCannotBeTakenOutOfKueueByAnUpdate` |
| 5 | deleting a finished non-restart Job makes the controller create it again | **confirmed**: `CreateOrUpdate` on a missing Job | a job whose own Job completed or failed (phase plus the `JobComplete`/`JobFailed` reason) is not given a new Job; a Failed from a name conflict still recovers | `a094e55a` | envtest "does not run a finished job again when its Job is cleaned up" |
| 6 | the manager lacks `inferencedeployments/finalizers`, so an API server enforcing owner references refuses its children | **confirmed** by reading: `SetControllerReference` sets `blockOwnerDeletion`; the role granted the finalizers of the other two owners only. Not reproduced: the plugin is off in envtest and kind | marker added, role regenerated | `b22afee7` | `TestTheManagerMayUpdateTheFinalizersOfEveryOwnerItSets` (reads the shipped role for every owner kind) |
| 7 | `parallelism: 0` is accepted and runs one Pod | **confirmed**: `Minimum=0` in the schema, `defaultOne` turns 0 into 1 | `parallelism` and `completions` require at least 1 | `d1aba74f` | envtest "refuses an explicit zero for parallelism and completions" |
| 8 | scale-to-zero reports Ready while replicas drain, and WorkloadRun can read that as recovery | **confirmed**: the code returned Ready on `spec.replicas == 0` alone, against its own comment | ScaledToZero waits for zero counted replicas (Progressing meanwhile); WorkloadRun never reads a target asked for zero replicas as serving | `f0dca2ba` | `TestScaledToZeroWaitsForTheDrain`, `TestIsServingRefusesATargetAskedForZeroReplicas` |
| 9 | an attempt admitted but never running leaves its admission stamp, and the next attempt's Running is measured from it | **confirmed**: nothing cleared `status.admittedAt` | `trigger` clears `admittedAt` when no Running was observed yet, in the same write | `db34a345` | envtest "does not carry an attempt's admission stamp into the next attempt's window" |
| 10 | a WorkloadRun's window and deadline stay editable after its verdict | **confirmed** | both fields immutable (CEL `self == oldSelf`) | `42e6ba01` | envtest "refuses an edit of the window or the deadline" |
| 11 | the selector parity test passes when one guard selects the wrong value | **confirmed** by reading: the value was only required somewhere in the file | the test parses the configuration and requires each device guard's selector to be exactly the enforcement label and value | `e2f82097` | the test itself, mutated |
| r10-6 | the state-volume check accepts a `volumeMode: Block` claim, which the renderer cannot mount | **confirmed** | refused with the reason; `Pending` stays accepted (#520) | `fc02397b` | row "Block mode" |
| r10-7 | the design promises envtest cases with failed status writes, conflicts and a lost create; the suite drives only successful passes | **confirmed** | new envtest drives attempt 1, its failure and attempt 2 through a client that fails every second status write (conflicts and unanswered errors alternately) and loses each attempt's first create response; one Job per attempt, adopted by token, budget spent once | `59f249d1` | the spec itself |

## Mutations (each on the committed fix, restored, tree checked clean)

All sixteen went red: the update handling, the label check and the gate check (4); the finished-job guard (5); the role's finalizer grant (6); `minimum: 0` in the generated CRD for each field (7); the drain check and the serving rule (8); the stamp reset (9); each immutability rule in the generated CRD (10); the Pod guard's selector value (11); the Block check (r10-6); and, for r10-7, adopting a Job without its token and `trigger` appending an attempt instead of stopping the current one.

## Checks run

- `go test` over every package but e2e with envtest 1.37.0: green. The controller suite ran 196 of 196 specs.
- `make lint`: 0 issues. `make docs-check`: green.

## What changes for users

- **Tenants in governed namespaces**: an update to a GPU Pod that changes or removes `kueue.x-k8s.io/managed`, or removes the `kueue.x-k8s.io/admission` gate as anyone but Kueue, is refused. Pod status writes do not pass through the guard. The guard's webhook now also intercepts Pod UPDATE in those namespaces, so its availability matters for updates as it did for creates.
- **MLTrainingJob**: `parallelism: 0` and `completions: 0` are refused at the API (they used to run one Pod). Deleting the Job of a finished job no longer reruns it; to run again, create a new MLTrainingJob.
- **InferenceDeployment**: a scale-down to zero reads Progressing until the Deployment counts no replicas, then Ready/ScaledToZero.
- **WorkloadRun**: `observationWindowSeconds` and `recoversWithinSeconds` cannot be edited after creation.
- **RBAC**: the manager's role gains `update` on `inferencedeployments/finalizers`.
- **Admission-to-running**: after a restart, the reported window is the first attempt seen running, measured from its own admission.

## Left

- Finding 6 is pinned by reading the shipped role, not by an API server enforcing owner references; neither envtest nor kind enables the plugin.
- The Pod guard trusts Kueue's controller by its service-account name; a Kueue installed under another name would be refused its own ungating, which `config/kueue-controller` does not do.
