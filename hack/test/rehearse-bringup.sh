#!/usr/bin/env bash
#
# Runs the GPU-free half of the device session's user-data on a development machine.
#
# The session's user-data is a heredoc that nothing executes until an instance exists, so the first thing
# ever to run those lines is a $3.18/hour g5.12xlarge. That is how a kubeconfig path the script had asserted
# without checking survived into a paid run: kind built the cluster, wrote its config somewhere else, and the
# session died three minutes in having produced no records.
#
# Cluster bring-up needs no card. kind, Kueue, the CRDs and the operator all install the same way on a
# laptop as on the rented box, so the span between the REHEARSABLE markers in hack/queuelab-gpu-session.sh
# runs here for nothing. What is left unrehearsed after this is the device plugin, DCGM and preflight checks
# 3 and 4 -- the parts that genuinely need hardware, and the only parts the instance should be discovering.
#
# This is not a stub of the user-data. It is the user-data, extracted verbatim, so a line that works here
# and fails there is a difference between the two machines rather than between two copies of a script.
set -euo pipefail

RUNNER="${RUNNER:-hack/queuelab-gpu-session.sh}"
CLUSTER=qlgpu
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$(mktemp -u /tmp/rehearse-kubeconfig-XXXXXX)}"
KEEP="${KEEP:-0}"

say()  { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$RUNNER" ] || fail "$RUNNER not found; run this from the repository root"
for b in kind kubectl docker make; do
  command -v "$b" >/dev/null || fail "$b is not on PATH, and this rehearsal runs the real thing rather than a stub"
done
docker info >/dev/null 2>&1 || fail "the docker daemon is not reachable"

# The span is taken by marker rather than by line number, so editing the runner above it cannot silently
# shift what gets rehearsed.
#
# Both markers are counted BEFORE anything is extracted, because the obvious awk is unsafe: with the closing
# marker deleted the range never ends, awk happily returns the whole rest of the file, and a length check
# passes because the result is longer rather than shorter. Deliberately deleting the marker to see the
# failure is what found that -- the rehearsal did not refuse, it executed the tail of the runner.
opens=$(grep -c '^# >>> REHEARSABLE' "$RUNNER" || true)
closes=$(grep -c '^# <<< REHEARSABLE' "$RUNNER" || true)
[ "$opens" = "1" ] && [ "$closes" = "1" ] \
  || fail "$RUNNER has $opens opening and $closes closing REHEARSABLE markers; exactly one of each is required"
first=$(grep -n '^# >>> REHEARSABLE' "$RUNNER" | cut -d: -f1)
last=$(grep -n '^# <<< REHEARSABLE' "$RUNNER" | cut -d: -f1)
[ "$first" -lt "$last" ] || fail "the closing REHEARSABLE marker (line $last) precedes the opening one (line $first)"

SPAN=$(mktemp /tmp/rehearse-span-XXXXXX.sh)
sed -n "$((first + 1)),$((last - 1))p" "$RUNNER" > "$SPAN"
lines=$(wc -l < "$SPAN")
[ "$lines" -gt 20 ] || fail "extracted only $lines lines between the REHEARSABLE markers"
say "extracted $lines lines from $RUNNER (lines $((first + 1))-$((last - 1)))"

# The one substitution this rehearsal makes, and it is announced rather than hidden.
#
# The span exports KUBECONFIG itself, to /tmp/kubeconfig -- the same literal path the instance uses. Left
# alone it would overwrite whatever a developer has at that path between runs. Nothing else is rewritten:
# the cluster name, the manifest URLs, the image tag and the node label are all the instance's own.
sed -i "s|^export KUBECONFIG=/tmp/kubeconfig$|export KUBECONFIG=$KUBECONFIG_PATH|" "$SPAN"
grep -q "export KUBECONFIG=$KUBECONFIG_PATH" "$SPAN" \
  || fail "the span no longer exports KUBECONFIG=/tmp/kubeconfig, so this rehearsal cannot redirect it"

cleanup() {
  rc=$?
  if [ "$KEEP" = "1" ]; then
    say "KEEP=1, leaving cluster $CLUSTER and $KUBECONFIG_PATH in place"
  else
    say "deleting cluster $CLUSTER"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    rm -f "$KUBECONFIG_PATH"
  fi
  rm -rf "$SPAN" "${WORKDIR:-}"
  exit $rc
}
trap cleanup EXIT INT TERM

kind get clusters 2>/dev/null | grep -qx "$CLUSTER" \
  && fail "a kind cluster named $CLUSTER already exists; delete it first (kind delete cluster --name $CLUSTER)"

# Run with HOME UNSET, because that is the environment that cost the paid session.
#
# cloud-init runs user-data with no HOME, and kind with no HOME writes .kube/config relative to the working
# directory. Setting HOME to some unwritable path would be a different test: the fallback would be absolute
# and the original bug would not reproduce. Unsetting it is the faithful one.
#
# The working directory is a checkout of the source, because that is what the instance runs from.
#
# user-data extracts the uploaded archive to /src and cds there, so `make docker-build` and
# `kubectl apply -f config/crd/bases/` are relative to a source tree. A bare scratch directory made the
# rehearsal fail for a reason the instance would never hit, which is a rehearsal reporting its own defect as
# the runner's.
#
# It is a COPY rather than the repository itself, and that is not incidental: with HOME unset kind writes
# .kube/config relative to the working directory, so running here would dirty the tree -- and the session's
# provenance guard refuses a dirty tree, meaning a rehearsal would block the session it precedes.
#
# `git stash create` gives a tree that includes uncommitted work, falling back to HEAD when there is none.
# The instance always ships HEAD; this ships what you are about to commit, which is the thing worth checking
# before renting hardware. Which one it used is printed.
WORKDIR=$(mktemp -d /tmp/rehearse-cwd-XXXXXX)
TREEISH=$(git stash create 2>/dev/null || true)
if [ -n "$TREEISH" ]; then
  say "source: working tree including uncommitted changes (stash $(git rev-parse --short "$TREEISH"))"
else
  TREEISH=HEAD
  say "source: HEAD $(git rev-parse --short HEAD), working tree clean -- exactly what the instance would ship"
fi
git archive --format=tar "$TREEISH" | tar -x -C "$WORKDIR" \
  || fail "could not lay out the source in $WORKDIR"
[ -f "$WORKDIR/Makefile" ] || fail "the extracted source has no Makefile; the archive is not what it should be"

say "running the span with HOME unset, from $WORKDIR"
start=$(date +%s)
set +e
( cd "$WORKDIR" && env -u HOME bash -x "$SPAN" )
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))

# What kind did with no HOME is asserted rather than assumed, because it is the whole point of the fix.
if [ -e "$WORKDIR/.kube/config" ]; then
  fail "kind still wrote a kubeconfig relative to the working directory ($WORKDIR/.kube/config), so the span is not using the explicit --kubeconfig path"
fi

if [ "$rc" -ne 0 ]; then
  fail "the span exited $rc after ${elapsed}s -- this is a failure the instance would have paid for"
fi

# Exiting zero is not the same as having built the thing. The span's own guards are `|| exit 1`, so a
# command that succeeds while producing nothing passes them, and asserting the result separately is the
# difference between "did not fail" and "worked".
export KUBECONFIG="$KUBECONFIG_PATH"
kubectl get nodes >/dev/null 2>&1 || fail "the span exited zero but its cluster is unreachable through $KUBECONFIG_PATH"
kubectl -n kueue-system get deploy kueue-controller-manager >/dev/null 2>&1 || fail "Kueue is not installed"
kubectl get crd mltrainingjobs.platform.lkhun9311.github.io >/dev/null 2>&1 || fail "the MLTrainingJob CRD was not applied"
label=$(kubectl get node "$CLUSTER-worker" -o jsonpath='{.metadata.labels.platform\.lkhun9311\.github\.io/gpu}' 2>/dev/null || true)
[ "$label" = "true" ] || fail "the worker does not carry the label both DaemonSets select on (got '${label:-none}')"

# The operator has to RUN, not merely be applied. `make docker-build` and `kind load` both succeed for an
# image whose binary crashes on start, and `kubectl apply` reports success for a Deployment that never
# becomes Available. Without this the rehearsal would pass on a broken operator, which is the failure mode
# it exists to prevent.
kubectl -n gpu-platform-control-plane-system rollout status \
  deploy/gpu-platform-control-plane-controller-manager --timeout=180s \
  || fail "the operator was applied but never became Available; the image built and loaded, so look at the Pod"

# The device mount is checkable without a device, and it is the half of the recipe that was missing.
#
# accept-nvidia-visible-devices-as-volume-mounts only means something if something is actually mounted under
# /var/run/nvidia-container-devices/, and a session had the setting without the mount: the toolkit was
# configured to honour a request nobody made, and the plugin advertised 0 of 4 cards. Whether the mount
# EXISTS is a property of the kind config, so it is verifiable here; whether it then yields cards is not.
docker exec "$CLUSTER-worker" test -e /var/run/nvidia-container-devices/all \
  || fail "the worker node has no /var/run/nvidia-container-devices/all, so the container runtime is never asked for the cards"

say "bring-up rehearsed in ${elapsed}s: cluster reachable, Kueue up, CRD applied, worker labelled, operator Available"
say "device mount present in the node container (whether it yields cards needs hardware)"
say "NOT rehearsed, and only a real card can: the device plugin, DCGM, and preflight checks 3 and 4"
