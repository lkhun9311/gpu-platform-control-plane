#!/usr/bin/env bash
# The free rehearsal of the GPU fault-reaction study, on kind, with the gpu-simulator's fake DCGM.
#
#   bash hack/gpu-fault-reaction.sh            # the registered five blocks, about 75 minutes
#   GF_BLOCKS=3 bash hack/gpu-fault-reaction.sh
#
# docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md is the registration. This builds kind cluster
# `gpufault` (context kind-gpufault) from this tree, runs the smoke cell, the arms and the two stale checks through
# hack/lib/gpu-fault.sh -- the same procedure the paid instance runs -- scores it, and deletes the cluster (KEEP=1
# keeps it). It proves the apparatus, the scorer and the refusals; the fake is not DCGM, and the scorer labels the
# result REHEARSAL from the recorded mode, so nothing here can be read as a measurement of DCGM.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=gpufault
TAG=gpufault
# busybox rebuilt as a single-platform local image: kind's `ctr images import --all-platforms` refuses the
# multi-platform busybox:1.36 a pull leaves behind ("content digest ... not found"), which voided a rehearsal.
JOB_BASE=busybox:1.36
JOB_IMAGE=gpufault-job:busybox
OUT=${OUT:-hack/gpu-fault-rehearsal-$(date -u +%Y%m%dT%H%M%SZ)}
[ ! -e "$OUT" ] || { echo "$OUT exists; each rehearsal writes a new directory" >&2; exit 1; }
mkdir -p "$OUT/reps" "$OUT/checks" || exit 1

# The paid session's topology: the worker's card is faulted, and the control-plane is the healthy node.
export GF_MODE=fake GF_OUT=$OUT GF_TARGET=$CLUSTER-worker GF_HEALTHY=$CLUSTER-control-plane
export GF_SYS=gpu-platform-control-plane-system GF_NS=gpufault GF_EXPORTER=app.kubernetes.io/component=gpu-simulator
export GF_JOB_IMAGE=$JOB_IMAGE GF_CONTEXT=kind-$CLUSTER GF_LOG=$OUT/log.txt GF_ARMS_END=""
export GF_EMPTY_BODY=$OUT/empty-body.json
echo '{}' >"$GF_EMPTY_BODY"
# shellcheck source=hack/lib/gpu-fault.sh
. hack/lib/gpu-fault.sh

# Only a cluster this run created is deleted: a refusal because one already exists must leave it alone (codex review).
CREATED=0
cleanup() {
  # A repetition cut short leaves its probe and watches running; they are this run's, and stop with it.
  gf_probe_stop
  gf_watch_stop
  [ "$CREATED" = 1 ] || { gf_log "cleanup: this run created no cluster, so none is deleted"; return; }
  [ "${KEEP:-0}" = 1 ] && { gf_log "cleanup: KEEP=1, leaving $CLUSTER"; return; }
  local listed
  listed=$(kind get clusters 2>>"$GF_LOG") || gf_log "cleanup: kind get clusters failed"
  if grep -qx "$CLUSTER" <<<"$listed"; then
    kind delete cluster --name "$CLUSTER" >>"$GF_LOG" 2>&1 || gf_log "cleanup: kind delete failed"
    if grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$GF_LOG")"; then gf_log "cleanup: $CLUSTER STILL EXISTS"; else gf_log "cleanup: deleted $CLUSTER"; fi
  fi
}
trap cleanup EXIT
die() { gf_log "REHEARSAL VOID: $*"; echo "$*" >"$OUT/VOID"; { gfk get pods -A -o wide; gfk get events -A --sort-by=.lastTimestamp | tail -60; } >>"$OUT/failure-state.txt" 2>&1; exit 1; }

for tool in docker kind kubectl python3 go; do command -v "$tool" >/dev/null || die "missing tool $tool"; done
{
  echo "commit=$(git rev-parse HEAD)"
  echo "dirty_files=$(git status --porcelain | wc -l)"
  echo "mode=$GF_MODE"
  echo "kind=$(kind version)"
  echo "kueue=$(grep '^version=' config/kueue-controller/RELEASE | cut -d= -f2)"
  echo "blocks=${GF_BLOCKS:-5}"
} >"$OUT/provenance.txt"

gf_log "== images"
make docker-build IMG=controller:$TAG >>"$GF_LOG" 2>&1 || die "operator image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$GF_LOG" 2>&1 || die "simulator image"
docker pull "$JOB_BASE" >>"$GF_LOG" 2>&1 || die "pull $JOB_BASE"
# Labelled for the same reason as the paid runner's job image (hack/gpu-fault-session.sh).
printf 'FROM %s\nLABEL io.gpufault.role=job\n' "$JOB_BASE" | docker build -q -t "$JOB_IMAGE" - >>"$GF_LOG" 2>&1 || die "build $JOB_IMAGE"
for img in controller:$TAG gpu-simulator:$TAG "$JOB_IMAGE"; do
  echo "image $img=$(docker image inspect "$img" --format '{{.Id}}')" >>"$OUT/provenance.txt"
done

gf_log "== cluster $CLUSTER"
if grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$GF_LOG")"; then die "a cluster named $CLUSTER already exists; delete it first"; fi
# Set before the create, because a create that fails halfway leaves nodes behind that are this run's to remove.
CREATED=1
kind create cluster --name "$CLUSTER" --config hack/kind-config-gpufault.yaml >>"$GF_LOG" 2>&1 || die "kind create"
# Loaded as single-platform archives: with Docker's containerd image store, `kind load docker-image` exports the
# base image's multi-platform index and the node's import fails on a platform it was never given ("content digest
# ... not found"); that voided two rehearsals.
for img in controller:$TAG gpu-simulator:$TAG "$JOB_IMAGE"; do
  docker save --platform linux/amd64 -o "$OUT/image.tar" "$img" >>"$GF_LOG" 2>&1 || die "docker save $img"
  python3 hack/image-archive-check.py "$OUT/image.tar" >>"$GF_LOG" 2>&1 || die "the archive of $img would fail the node's import"
  kind load image-archive "$OUT/image.tar" --name "$CLUSTER" >>"$GF_LOG" 2>&1 || die "kind load $img"
  rm -f "$OUT/image.tar"
done
# The healthy node takes workloads only once its control-plane taint is gone, as on the paid instance.
gfk taint node "$GF_HEALTHY" node-role.kubernetes.io/control-plane:NoSchedule- >>"$GF_LOG" 2>&1 || die "untaint $GF_HEALTHY"

gf_log "== queueing and the fake device plugin with its fake DCGM"
gf_install_queueing || die "queueing"
# config/device-plugin carries only the namespaced DaemonSet, so its namespace is created first (codex review).
gfk create ns "$GF_SYS" >>"$GF_LOG" 2>&1 || die "namespace $GF_SYS"
gfk kustomize config/device-plugin >"$OUT/device-plugin.yaml" || die "device plugin render"
gfk apply -f "$OUT/device-plugin.yaml" >>"$GF_LOG" 2>&1 || die "device plugin"
gfk -n "$GF_SYS" set image ds/gpu-simulator "*=gpu-simulator:$TAG" >>"$GF_LOG" 2>&1 || die "simulator image set"
gfk -n "$GF_SYS" patch ds/gpu-simulator --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FAKE_DCGM_ADDR","value":":9400"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NODE_NAME","valueFrom":{"fieldRef":{"fieldPath":"spec.nodeName"}}}}
]' >>"$GF_LOG" 2>&1 || die "simulator fake DCGM"
gfk -n "$GF_SYS" rollout status ds/gpu-simulator --timeout=180s >>"$GF_LOG" 2>&1 || die "simulator rollout"
for n in "$GF_TARGET" "$GF_HEALTHY"; do
  gf_wait_until 60 sh -c "[ \"\$(kubectl --context $GF_CONTEXT get node $n -o jsonpath='{.status.allocatable.nvidia\\.com/gpu}')\" = 1 ]" ||
    die "$n does not advertise one nvidia.com/gpu"
done

gf_log "== smoke cell, before the operator exists"
gf_smoke || die "smoke cell stopped the session: $(grep '^stop=' "$OUT/smoke.env")"

gf_log "== operator and tenant"
gf_deploy_operator controller:$TAG || die "operator"
gf_tenant || die "tenant"

gf_log "== arms"
gf_arms
gf_log "== stale checks"
gf_stale_checks || gf_log "the stale checks did not complete"
gf_log "== recovery check"
gf_recovery_check || gf_log "the recovery check did not complete"

gf_log "== score"
go run ./cmd/benchharness gpu-fault-verdict --dir "$OUT" --json "$OUT/verdict.json" | tee "$OUT/verdict.txt"
gf_log "rehearsal evidence in $OUT"
