#!/usr/bin/env bash
# A free kind lab for lane 2 of the upstream integration design: an AIBrix PodAutoscaler owning the replicas of a
# gpuaas InferenceDeployment, replayed through the missing-metric case of vllm-project/aibrix#3439.
#
# The case: a KPA with a healthy, low per-pod metric and an external metric that holds the replicas up.
# The external endpoint goes away, and the question is whether the pod metric alone scales the target down.
# It then comes back with a higher value, and the question is whether the scale-up it asks for goes ahead.
#
# What runs where:
#   - the AIBrix controller-manager, built from a pinned AIBrix commit, runs in the cluster with only its pod
#     autoscaler controller enabled, from upstream's own config/standalone/autoscaler-controller kustomization;
#   - gpuaas's InferenceDeployment reconciler runs on the host from this checkout (hack/aibrix-lane2/reconciler);
#   - the serving pods are llm-d-inference-sim, the lane-1 build, behind hack/aibrix-lane2/simshim.
#
# The cluster is named aibrix-lane2, its kubeconfig is a private file under LAB_HOME, and ~/.kube/config is never read
# or written: every kind and kubectl call names that file.
#
# Usage: hack/aibrix-lane2.sh pins | up | replay [cooldown] [hold-seconds] | fight | down
#   replay  runs the #3439 timeline with the given scale-down-cooldown-window (default 0s) and outage length.
#   fight   hands the replicas back to the controller and records the two writers undoing each other.
#
# docs/15_AIBRIX_AUTOSCALING_LAB.md describes the lab and what it showed.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
LAB_DIR="$REPO/hack/aibrix-lane2"

# --- pins ---------------------------------------------------------------------------------------------------------
# AIBrix main as of 2026-11-18, which #3439 was filed against; no fix for it has merged there.
AIBRIX_REPO=https://github.com/vllm-project/aibrix.git
AIBRIX_COMMIT=01ac3858c6a187a364ba9bd107f901bb4c32b4b2
AIBRIX_IMAGE=gpuaas-aibrix-lane2/aibrix-controller:${AIBRIX_COMMIT:0:12}
# The simulator lane 1 built (hack/llmd-kv-lab.sh), checked by the commit label it carries.
SIM_COMMIT=6ab9d4b2367abe9338665368f61b3ff7e5547e4a
SIM_IMAGE=gpuaas-llmd-kv-lab/sim:${SIM_COMMIT:0:12}
SHIM_IMAGE=gpuaas-aibrix-lane2/simshim:${SIM_COMMIT:0:12}
BASE_IMAGE=gcr.io/distroless/static:nonroot@sha256:d62067879de890a1def9da0e7766b7d20810a5e5555cef8506b752437d7a3e88
KIND_NODE_IMAGE=kindest/node:v1.31.12@sha256:0f5cc49c5e73c0c2bb6e2df56e7df189240d83cf94edfa30946482eb08ec57d2

# --- lab shape ----------------------------------------------------------------------------------------------------
CLUSTER=aibrix-lane2
CTX=kind-$CLUSTER
OWNER_CM=gpuaas-aibrix-lane2-owner
NS=lane2
LAB_HOME=${LAB_HOME:-$REPO/tmp/aibrix-lane2}
KCFG=$LAB_HOME/kubeconfig
CHECKOUT=$LAB_HOME/aibrix
# Every call below names the file as well; the export only covers a tool that would otherwise fall back to ~/.kube/config.
export KUBECONFIG=$KCFG
# Queue lengths before the outage and after it: 200 holds 4 replicas against a target of 50, and 300 asks for 6.
QUEUE_BEFORE=200
QUEUE_AFTER=300

say() { echo "aibrix-lane2: $*"; }
die() { echo "aibrix-lane2: REFUSED: $*" >&2; exit 1; }
k() { kubectl --kubeconfig "$KCFG" --context "$CTX" --request-timeout=30s "$@"; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }
# The marker is written right after this script creates the cluster, so a cluster without it is someone else's.
owned() { k -n kube-system get configmap "$OWNER_CM" >/dev/null 2>&1; }

cmd_pins() {
  cat <<EOF
aibrix            $AIBRIX_REPO $AIBRIX_COMMIT -> $AIBRIX_IMAGE
simulator         $SIM_IMAGE (llm-d-inference-sim $SIM_COMMIT, built by hack/llmd-kv-lab.sh)
serving image     $SHIM_IMAGE (simulator + hack/aibrix-lane2/simshim)
base              $BASE_IMAGE
kind node         $KIND_NODE_IMAGE
cluster           $CLUSTER, kubeconfig $KCFG
EOF
}

fetch_checkout() {
  mkdir -p "$LAB_HOME"
  [ -d "$CHECKOUT/.git" ] || git clone -q --filter=blob:none "$AIBRIX_REPO" "$CHECKOUT"
  git -C "$CHECKOUT" fetch -q origin "$AIBRIX_COMMIT"
  git -C "$CHECKOUT" checkout -q --detach "$AIBRIX_COMMIT"
  [ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$AIBRIX_COMMIT" ] || die "the AIBrix checkout is not at $AIBRIX_COMMIT"
  [ -z "$(git -C "$CHECKOUT" status --porcelain)" ] || die "the AIBrix checkout at $CHECKOUT has local changes"
}

prepare_images() {
  local got ctx
  got=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$SIM_IMAGE" 2>/dev/null || true)
  [ "$got" = "$SIM_COMMIT" ] || die "$SIM_IMAGE is missing or not labelled $SIM_COMMIT (got '$got'); build it with hack/llmd-kv-lab.sh up"
  ctx=$LAB_HOME/build
  rm -rf "$ctx" && mkdir -p "$ctx"
  # Both binaries are built here from pinned sources and copied onto a pinned base, so no Dockerfile fetches anything.
  (cd "$CHECKOUT" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOTOOLCHAIN=local go build -trimpath -o "$ctx/manager" ./cmd/controllers)
  (cd "$REPO" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "$ctx/simshim" ./hack/aibrix-lane2/simshim)
  docker build -q -t "$AIBRIX_IMAGE" --label "org.opencontainers.image.revision=$AIBRIX_COMMIT" -f - "$ctx" >/dev/null <<EOF
FROM $BASE_IMAGE
COPY manager /manager
USER 65532:65532
ENTRYPOINT ["/manager"]
EOF
  # The JSON is written without spaces because simshim splits SIM_EXTRA_ARGS on whitespace.
  docker build -q -t "$SHIM_IMAGE" -f - "$ctx" >/dev/null <<EOF
FROM $SIM_IMAGE
COPY simshim /simshim
ENV SIM_EXTRA_ARGS='--port 8080 --fake-metrics {"kv-cache-usage":0.25}'
ENTRYPOINT ["/simshim"]
EOF
}

create_cluster() {
  if cluster_exists; then
    owned || die "a kind cluster named $CLUSTER exists and has no $OWNER_CM marker; not touching it"
    return
  fi
  kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --kubeconfig "$KCFG" --wait 120s
  k -n kube-system create configmap "$OWNER_CM" --from-literal=createdBy=hack/aibrix-lane2.sh >/dev/null
}

cmd_up() {
  fetch_checkout
  prepare_images
  create_cluster
  for img in "$SIM_IMAGE" "$SHIM_IMAGE" "$AIBRIX_IMAGE"; do
    kind load docker-image --name "$CLUSTER" "$img" >/dev/null
  done
  # gpuaas's CRDs, so the reconciler can read InferenceDeployments and the GPUQuotaPolicies it lists for the queue label.
  k apply --server-side -f "$REPO/config/crd/bases" >/dev/null
  # Upstream's standalone overlay, with its release image swapped for the pinned build.
  # The one added argument is --v=2: the line that lists every source's recommendation and the max taken over them,
  # "Multi metric autoscaling computed result", is logged only at that level.
  k kustomize "$CHECKOUT/config/standalone/autoscaler-controller" \
    | sed -e "s#image: aibrix/controller-manager:v0.8.0#image: $AIBRIX_IMAGE#" \
      -e 's#^\( *\)- --disable-webhook$#&\n\1- --v=2#' >"$LAB_HOME/aibrix-autoscaler.yaml"
  grep -q "image: $AIBRIX_IMAGE" "$LAB_HOME/aibrix-autoscaler.yaml" || die "the upstream overlay no longer names aibrix/controller-manager:v0.8.0"
  grep -q -- "- --v=2" "$LAB_HOME/aibrix-autoscaler.yaml" || die "the upstream overlay no longer passes --disable-webhook, where --v=2 is added"
  # The overlay places everything in aibrix-system without creating it.
  k create namespace aibrix-system --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply --server-side -f "$LAB_HOME/aibrix-autoscaler.yaml" >/dev/null
  k -n aibrix-system rollout status deploy/aibrix-autoscaling-controller-manager --timeout=180s
  say "up; start the reconciler with: go run ./hack/aibrix-lane2/reconciler --kubeconfig $KCFG >$LAB_HOME/reconciler.log 2>&1"
}

render() {
  sed -e "s#SHIM_IMAGE#$SHIM_IMAGE#" -e "s#SIM_IMAGE#$SIM_IMAGE#" -e "s#QUEUE_LENGTH#$QUEUE_BEFORE#" "$LAB_DIR/workload.yaml"
}

# sample prints one timeline row: wall clock, seconds since start, phase label, the Deployment's replicas as written
# and as ready, the PodAutoscaler's desired and actual scale, the queue endpoint count, and both metric readings.
sample() {
  local t0=$1 label=$2 now spec ready desired actual eps kv queue pod
  now=$(date +%s)
  spec=$(k -n "$NS" get deploy chat -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  ready=$(k -n "$NS" get deploy chat -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  desired=$(k -n "$NS" get podautoscaler chat -o jsonpath='{.status.desiredScale}' 2>/dev/null || echo "?")
  actual=$(k -n "$NS" get podautoscaler chat -o jsonpath='{.status.actualScale}' 2>/dev/null || echo "?")
  eps=$(k -n "$NS" get endpointslices -l kubernetes.io/service-name=queue-metrics \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true || true)
  pod=$(k -n "$NS" get pods -l app.kubernetes.io/instance=chat --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  kv=unavailable
  if [ -n "$pod" ]; then
    kv=$(k get --raw "/api/v1/namespaces/$NS/pods/$pod:8080/proxy/metrics" 2>/dev/null \
      | awk '/^vllm:kv_cache_usage_perc[{ ]/ {print $NF; exit}' || true)
    kv=${kv:-unavailable}
  fi
  queue=$(k get --raw "/api/v1/namespaces/$NS/services/queue-metrics:8000/proxy/metrics" 2>/dev/null \
    | awk '/^vllm:num_requests_waiting[{ ]/ {print $NF; exit}' || true)
  printf '%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%H:%M:%S)" $((now - t0)) "$label" \
    "$spec" "${ready:-0}" "$desired" "$actual" "$eps" "$kv" "${queue:-unavailable}"
}

# watch_for samples every 5s for at most the given seconds, and stops early once the condition holds.
watch_for() {
  local t0=$1 label=$2 secs=$3 cond=${4:-false} until row
  until=$(($(date +%s) + secs))
  while [ "$(date +%s)" -lt "$until" ]; do
    row=$(sample "$t0" "$label")
    echo "$row" | tee -a "$OUT/timeline.tsv"
    if eval "$cond"; then return 0; fi
    sleep 5
  done
}

collect() {
  k -n "$NS" get events --sort-by=.lastTimestamp \
    -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message \
    >"$OUT/events.txt"
  k -n "$NS" get podautoscaler chat -o yaml >"$OUT/podautoscaler.yaml"
  k -n "$NS" get inferencedeployment chat -o yaml >"$OUT/inferencedeployment.yaml"
  k -n aibrix-system logs deploy/aibrix-autoscaling-controller-manager --since=1h >"$OUT/aibrix-controller.log" 2>&1 || true
  # The two lines that decide the case: the failed source being skipped, and the max taken over what is left.
  grep -E 'Failed to compute replicas for metric|Multi metric autoscaling computed result|Successfully rescaled|all [0-9]+ metric sources failed' \
    "$OUT/aibrix-controller.log" >"$OUT/aibrix-decisions.log" || true
  # The reconciler runs on the host, so its log is wherever it was started; LAB_HOME is the place the usage line names.
  cp "$LAB_HOME/reconciler.log" "$OUT/reconciler.log" 2>/dev/null || true
  cmd_pins >"$OUT/pins.txt"
  echo "gpuaas $(git -C "$REPO" rev-parse HEAD)$([ -n "$(git -C "$REPO" status --porcelain -- api internal hack/aibrix-lane2)" ] && echo ' (with uncommitted changes)')" >>"$OUT/pins.txt"
}

cmd_replay() {
  local cooldown=${1:-0s} hold=${2:-90} t0
  owned || die "no lab cluster; run up first"
  OUT=$LAB_DIR/runs/$(date -u +%Y%m%dT%H%M%SZ)-cooldown-$cooldown
  mkdir -p "$OUT"
  k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
  render | k apply -f - >/dev/null
  k -n "$NS" rollout status deploy/queue-metrics --timeout=120s >/dev/null
  # The reconciler, not this script, creates the Deployment; waiting on it is waiting on the reconciler.
  for _ in $(seq 60); do k -n "$NS" get deploy chat >/dev/null 2>&1 && break; sleep 2; done
  k -n "$NS" get deploy chat >/dev/null 2>&1 || die "no Deployment chat; is the reconciler running?"
  k -n "$NS" rollout status deploy/chat --timeout=180s >/dev/null
  sed "s#SCALE_DOWN_COOLDOWN#$cooldown#" "$LAB_DIR/podautoscaler.yaml" | k apply -f - >/dev/null
  printf 'utc\tt_s\tphase\tdeploy_spec_replicas\tdeploy_ready\tpa_desired\tpa_actual\tqueue_endpoints\tpod_kv_cache_usage\tqueue_length\n' \
    | tee "$OUT/timeline.tsv"
  t0=$(date +%s)

  say "phase 1: both metrics readable, queue $QUEUE_BEFORE; expect 4 held"
  watch_for "$t0" baseline 90

  say "phase 2: queue endpoint gone for ${hold}s"
  k -n "$NS" scale deploy/queue-metrics --replicas=0 >/dev/null
  watch_for "$t0" outage "$hold"

  say "phase 3: queue endpoint back at $QUEUE_AFTER; expect a scale-up to 6"
  k -n "$NS" patch deploy/queue-metrics --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/5\",\"value\":\"{\\\"waiting-requests\\\":$QUEUE_AFTER}\"}]" >/dev/null
  k -n "$NS" scale deploy/queue-metrics --replicas=1 >/dev/null
  # shellcheck disable=SC2016 # watch_for evaluates the condition against each new row
  watch_for "$t0" recovery 180 '[ "$(echo "$row" | cut -f5)" = 6 ]'
  watch_for "$t0" settled 30

  collect
  say "recorded in $OUT"
}

# cmd_fight is the live counterpart of the envtest: with the controller as the replica owner, every AIBrix write is undone.
cmd_fight() {
  local t0
  owned || die "no lab cluster; run up first"
  OUT=$LAB_DIR/runs/$(date -u +%Y%m%dT%H%M%SZ)-controller-owned
  mkdir -p "$OUT"
  printf 'utc\tt_s\tphase\tdeploy_spec_replicas\tdeploy_ready\tpa_desired\tpa_actual\tqueue_endpoints\tpod_kv_cache_usage\tqueue_length\n' \
    | tee "$OUT/timeline.tsv"
  t0=$(date +%s)
  watch_for "$t0" external-owner 20
  k -n "$NS" patch inferencedeployment chat --type json -p '[{"op":"remove","path":"/spec/replicasOwner"}]' >/dev/null
  # Long enough for AIBrix to write its count again after the controller has undone it.
  watch_for "$t0" controller-owner 120
  k -n "$NS" get deploy chat --show-managed-fields -o yaml >"$OUT/deployment-managed-fields.yaml"
  collect
  say "recorded in $OUT"
}

cmd_down() {
  if ! cluster_exists; then say "no cluster named $CLUSTER"; return; fi
  owned || die "$CLUSTER exists but has no $OWNER_CM marker; not deleting a cluster this script did not create"
  kind delete cluster --name "$CLUSTER" --kubeconfig "$KCFG"
}

case "${1:-}" in
  pins) cmd_pins ;;
  up) cmd_up ;;
  replay) shift; cmd_replay "$@" ;;
  fight) cmd_fight ;;
  down) cmd_down ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 2 ;;
esac
