# Kind rehearsal of the restart lifecycle with rank Pods held by `rank-stopped`, 2026-11-06 (commit `f9939cc6`)

Runs `a` and `c` of `hack/restart-lifecycle-kind.sh`, from `fix/restart-controller-review` at `f9939cc6` with a clean tree (`provenance.txt`): the first commit at which every rank Pod carries `platform.lkhun9311.github.io/rank-stopped` from its Job's template.
It was taken to check, on a real Job controller and kubelet, what envtest cannot: that the Job controller copies the finalizer onto every rank Pod, that the controller releases it once the kubelet reports the Pod terminal, and that the stop barrier, the spare and replacement recoveries and the runner's retirement still complete.
The three fixes made after the bare review of that commit (`bc2c72fa`) change the deletion path, the eviction trigger and the binding-time read; none of them is on a path these runs take, and they were not rehearsed here.

## What it showed

- Run `a` (smoke as registered): reference, no-rng-control, dcgm-1 (spare, recovery 4.2 s) and terminate-wait-1 (replacement after the fence, 166.1 s) ACCEPTED through the kind shim (`run-a/verdict.txt`).
- Run `c`: reference and rank-kill-1 (spare, 5.0 s) ACCEPTED; rank-kill-2 NOTRUN because the rehearsal's own finalizer on an attempt-2 Pod keeps rank-kill-1 from being retired, which is what the run is for.
  The MLTrainingJob now also stays while that Pod stays, since its deletion is held until every rank Pod is known stopped; the runner records the same NOTRUN.
- `check_lifecycle.py` and the outcome check: 0 FAIL each.
- The unmodified EKS scorer voids every case for gloo on CPU, the boundary the shim moves, as in every earlier rehearsal.

Kind figures are not EKS figures. The status timelines and Pod watches are committed compressed; the two Kueue manifest dumps are left out, as before.
