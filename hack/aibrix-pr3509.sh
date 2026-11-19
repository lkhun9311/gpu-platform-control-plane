#!/usr/bin/env bash
# Replays the vllm-project/aibrix#3439 case against AIBrix main and against pull request #3509, for KPA and APA.
#
# #3509 adds the opt-in annotation autoscaling.aibrix.ai/hold-scale-down-on-metric-failure.
# With it, a failing metric source should block a metric-driven scale-down.
# A healthy source should still scale up, and minReplicas and maxReplicas should still apply.
# Without it, the default best-effort behaviour should not change.
#
# This reuses the lane 2 lab (hack/aibrix-lane2.sh): the same simulator images, the same two metric sources, and
# upstream's standalone autoscaler overlay with the image swapped and --v=2 added.
# The one difference is the scale target.
# It is a plain Deployment here, so no gpuaas reconciler runs and only AIBrix decides the replicas.
#
# The cluster is named aibrix-pr3509, its kubeconfig is a private file under LAB_HOME, and ~/.kube/config is never read
# or written.
#
# Usage: hack/aibrix-pr3509.sh pins | up | run <main|pr> <KPA|APA> <off|on> | upwindow <off|on> | down
#
# docs/15_AIBRIX_AUTOSCALING_LAB.md, section "Verifying #3509", describes the runs and what they showed.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
LAB_DIR="$REPO/hack/aibrix-pr3509"

# --- pins ---------------------------------------------------------------------------------------------------------
# main is the base of #3509; pr is its head when this lab was run.
MAIN_COMMIT=afdb4791527e6039df391cd8a811b6e6c682c975
PR_COMMIT=cb1a2f3f05d6dbaebff27d036d22ee68609c28f0
# Worktrees of one AIBrix clone, checked out at the two commits above.
MAIN_SRC=${MAIN_SRC:-$HOME/workspace/oss/aibrix-wt-main-afdb4791}
PR_SRC=${PR_SRC:-$HOME/workspace/oss/aibrix-wt-pr3509}
IMAGE_REPO=gpuaas-aibrix-pr3509/aibrix-controller
# The lane 1 simulator and the lane 2 shim around it, both already built by the lane 1 and lane 2 labs.
SIM_COMMIT=6ab9d4b2367abe9338665368f61b3ff7e5547e4a
SIM_IMAGE=gpuaas-llmd-kv-lab/sim:${SIM_COMMIT:0:12}
SHIM_IMAGE=gpuaas-aibrix-lane2/simshim:${SIM_COMMIT:0:12}
BASE_IMAGE=gcr.io/distroless/static:nonroot@sha256:d62067879de890a1def9da0e7766b7d20810a5e5555cef8506b752437d7a3e88
KIND_NODE_IMAGE=kindest/node:v1.31.12@sha256:0f5cc49c5e73c0c2bb6e2df56e7df189240d83cf94edfa30946482eb08ec57d2

# --- lab shape ----------------------------------------------------------------------------------------------------
CLUSTER=aibrix-pr3509
CTX=kind-$CLUSTER
OWNER_CM=gpuaas-aibrix-pr3509-owner
NS=pr3509
CTRL=aibrix-autoscaling-controller-manager
LAB_HOME=${LAB_HOME:-$REPO/tmp/aibrix-pr3509}
KCFG=$LAB_HOME/kubeconfig
export KUBECONFIG=$KCFG
# Each phase lasts this many seconds; the controller resyncs every 10 s.
PHASE=${PHASE:-40}

say() { echo "aibrix-pr3509: $*"; }
die() { echo "aibrix-pr3509: REFUSED: $*" >&2; exit 1; }
k() { kubectl --kubeconfig "$KCFG" --context "$CTX" --request-timeout=30s "$@"; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }
owned() { k -n kube-system get configmap "$OWNER_CM" >/dev/null 2>&1; }
image_for() { case $1 in main) echo "$IMAGE_REPO:${MAIN_COMMIT:0:12}" ;; pr) echo "$IMAGE_REPO:${PR_COMMIT:0:12}" ;; *) die "build is main or pr" ;; esac; }
commit_for() { case $1 in main) echo "$MAIN_COMMIT" ;; pr) echo "$PR_COMMIT" ;; esac; }
src_for() { case $1 in main) echo "$MAIN_SRC" ;; pr) echo "$PR_SRC" ;; esac; }

cmd_pins() {
  cat <<EOF
aibrix main       $MAIN_COMMIT -> $(image_for main)
aibrix pr #3509   $PR_COMMIT -> $(image_for pr)
simulator         $SIM_IMAGE
serving image     $SHIM_IMAGE
base              $BASE_IMAGE
kind node         $KIND_NODE_IMAGE
cluster           $CLUSTER, kubeconfig ${KCFG#"$REPO"/}
EOF
}

build_one() {
  local b=$1 src commit img ctx
  src=$(src_for "$b")
  commit=$(commit_for "$b")
  img=$(image_for "$b")
  [ "$(git -C "$src" rev-parse HEAD)" = "$commit" ] || die "$src is not at $commit"
  [ -z "$(git -C "$src" status --porcelain)" ] || die "$src has local changes"
  ctx=$LAB_HOME/build-$b
  rm -rf "$ctx" && mkdir -p "$ctx"
  (cd "$src" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOTOOLCHAIN=local go build -trimpath -buildvcs=false -o "$ctx/manager" ./cmd/controllers)
  docker build -q -t "$img" --label "org.opencontainers.image.revision=$commit" -f - "$ctx" >/dev/null <<EOF
FROM $BASE_IMAGE
COPY manager /manager
USER 65532:65532
ENTRYPOINT ["/manager"]
EOF
  say "built $img from $src"
}

cmd_up() {
  local got
  mkdir -p "$LAB_HOME"
  for img in "$SIM_IMAGE" "$SHIM_IMAGE"; do
    got=$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || true)
    [ -n "$got" ] || die "$img is missing; build it with hack/llmd-kv-lab.sh up and hack/aibrix-lane2.sh up"
  done
  build_one main
  build_one pr
  if cluster_exists; then
    owned || die "a kind cluster named $CLUSTER exists and has no $OWNER_CM marker; not touching it"
  else
    kind create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --kubeconfig "$KCFG" --wait 120s
    k -n kube-system create configmap "$OWNER_CM" --from-literal=createdBy=hack/aibrix-pr3509.sh >/dev/null
  fi
  for img in "$SIM_IMAGE" "$SHIM_IMAGE" "$(image_for main)" "$(image_for pr)"; do
    kind load docker-image --name "$CLUSTER" "$img" >/dev/null
  done
  # The overlay is the same at both commits; the PR touches no file under config/.
  k kustomize "$MAIN_SRC/config/standalone/autoscaler-controller" \
    | sed -e "s#image: aibrix/controller-manager:v0.8.0#image: $(image_for main)#" \
      -e 's#^\( *\)- --disable-webhook$#&\n\1- --v=2#' >"$LAB_HOME/aibrix-autoscaler.yaml"
  grep -q "image: $(image_for main)" "$LAB_HOME/aibrix-autoscaler.yaml" || die "the overlay no longer names aibrix/controller-manager:v0.8.0"
  grep -q -- "- --v=2" "$LAB_HOME/aibrix-autoscaler.yaml" || die "the overlay no longer passes --disable-webhook"
  k create namespace aibrix-system --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply --server-side -f "$LAB_HOME/aibrix-autoscaler.yaml" >/dev/null
  k -n aibrix-system rollout status "deploy/$CTRL" --timeout=180s
  say "up"
}

# use_build points the controller at one build and restarts it, so every run starts with empty in-memory history.
use_build() {
  local img
  img=$(image_for "$1")
  k -n aibrix-system set image "deploy/$CTRL" "*=$img" >/dev/null
  k -n aibrix-system rollout restart "deploy/$CTRL" >/dev/null
  k -n aibrix-system rollout status "deploy/$CTRL" --timeout=180s >/dev/null
  [ "$(k -n aibrix-system get "deploy/$CTRL" -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$img" ] \
    || die "the controller is not running $img"
}

# sample prints one timeline row.
sample() {
  local t0=$1 label=$2 now spec ready desired eps tgt min max active
  now=$(date +%s)
  spec=$(k -n "$NS" get deploy chat -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  ready=$(k -n "$NS" get deploy chat -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "?")
  desired=$(k -n "$NS" get podautoscaler chat -o jsonpath='{.status.desiredScale}' 2>/dev/null || echo "?")
  eps=$(k -n "$NS" get endpointslices -l kubernetes.io/service-name=queue-metrics \
    -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' 2>/dev/null | grep -c true || true)
  tgt=$(k -n "$NS" get podautoscaler chat -o jsonpath='{.spec.metricsSources[0].targetValue}' 2>/dev/null || echo "?")
  min=$(k -n "$NS" get podautoscaler chat -o jsonpath='{.spec.minReplicas}' 2>/dev/null || echo "?")
  max=$(k -n "$NS" get podautoscaler chat -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "?")
  active=$(k -n "$NS" get podautoscaler chat \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}/{.reason}{end}' 2>/dev/null || echo "?")
  printf '%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%H:%M:%S)" $((now - t0)) "$label" \
    "$spec" "${ready:-0}" "$desired" "$eps" "$tgt" "$min" "$max" "$active"
}

watch_for() {
  local t0=$1 label=$2 secs=$3 until
  until=$(($(date +%s) + secs))
  while [ "$(date +%s)" -lt "$until" ]; do
    sample "$t0" "$label" | tee -a "$OUT/timeline.tsv"
    sleep 5
  done
}

render_pa() {
  local strategy=$1 mode=$2 hold=""
  [ "$mode" = on ] && hold='    autoscaling.aibrix.ai/hold-scale-down-on-metric-failure: "true"'
  sed -e "s#STRATEGY#$strategy#" "$LAB_DIR/podautoscaler.yaml" | awk -v hold="$hold" '{print} /scale-down-cooldown-window/ && hold != "" {print hold}'
}

collect() {
  local since=$1
  k -n "$NS" get events --sort-by=.lastTimestamp \
    -o custom-columns=FIRST:.firstTimestamp,LAST:.lastTimestamp,COUNT:.count,TYPE:.type,REASON:.reason,KIND:.involvedObject.kind,MESSAGE:.message \
    >"$OUT/events.txt"
  k -n "$NS" get podautoscaler chat -o yaml >"$OUT/podautoscaler.yaml"
  k -n aibrix-system logs "deploy/$CTRL" --since-time="$since" >"$OUT/aibrix-controller.log" 2>&1 || true
  grep -E 'Failed to compute replicas for metric|Multi metric autoscaling computed result|Successfully rescaled|metric sources|Scaling adjustment|stays at|Reconciler error' \
    "$OUT/aibrix-controller.log" >"$OUT/aibrix-decisions.log" || true
  gzip -f "$OUT/aibrix-controller.log"
  cmd_pins >"$OUT/pins.txt"
  echo "controller image $(k -n aibrix-system get "deploy/$CTRL" -o jsonpath='{.spec.template.spec.containers[0].image}')" >>"$OUT/pins.txt"
  echo "gpuaas $(git -C "$REPO" rev-parse HEAD)" >>"$OUT/pins.txt"
}

# cmd_run is one replay: both sources readable, then the queue source down for the rest of the run except the end.
# While it is down, the pod metric's target is moved so that the healthy source asks for a scale-up, a capped
# scale-up and a scale-down, and the bounds are moved under and over the current count.
cmd_run() {
  local build=$1 strategy=$2 mode=$3 t0 since
  owned || die "no lab cluster; run up first"
  case "$strategy" in KPA | APA) ;; *) die "strategy is KPA or APA" ;; esac
  case "$mode" in on | off) ;; *) die "mode is on or off" ;; esac
  [ "$build" = main ] && [ "$mode" = on ] && die "main has no hold annotation"
  OUT=$LAB_DIR/runs/$(date -u +%Y%m%dT%H%M%SZ)-$build-$strategy-hold-$mode
  mkdir -p "$OUT"
  use_build "$build"
  k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
  sed -e "s#SHIM_IMAGE#$SHIM_IMAGE#" -e "s#SIM_IMAGE#$SIM_IMAGE#" "$LAB_DIR/workload.yaml" | k apply -f - >/dev/null
  k -n "$NS" rollout status deploy/queue-metrics --timeout=120s >/dev/null
  k -n "$NS" rollout status deploy/chat --timeout=180s >/dev/null
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  render_pa "$strategy" "$mode" | tee "$OUT/podautoscaler-applied.yaml" | k apply -f - >/dev/null
  printf 'utc\tt_s\tphase\tdeploy_spec_replicas\tdeploy_ready\tpa_desired\tqueue_endpoints\tkv_target\tmin\tmax\tscaling_active\n' \
    | tee "$OUT/timeline.tsv"
  t0=$(date +%s)
  local pa=(-n "$NS" patch podautoscaler chat --type json -p)

  say "1 baseline: kv 0.25/0.5 asks 2, queue 200/50 asks 4"
  watch_for "$t0" 1-baseline "$PHASE"
  say "2 outage: queue source down for the rest of the run; kv alone asks 2"
  k -n "$NS" scale deploy/queue-metrics --replicas=0 >/dev/null
  watch_for "$t0" 2-outage $((PHASE + 20))
  say "3 healthy source above target: kv target 0.2"
  k "${pa[@]}" '[{"op":"replace","path":"/spec/metricsSources/0/targetValue","value":"0.2"}]' >/dev/null
  watch_for "$t0" 3-scaleup "$PHASE"
  say "4 scale-up past maxReplicas 6: kv target 0.15"
  k "${pa[@]}" '[{"op":"replace","path":"/spec/metricsSources/0/targetValue","value":"0.15"}]' >/dev/null
  watch_for "$t0" 4-capped "$PHASE"
  say "5 healthy source below target again: kv target 0.5"
  k "${pa[@]}" '[{"op":"replace","path":"/spec/metricsSources/0/targetValue","value":"0.5"}]' >/dev/null
  watch_for "$t0" 5-down-again "$PHASE"
  say "6 minReplicas 7 above the current count"
  k "${pa[@]}" '[{"op":"replace","path":"/spec/maxReplicas","value":8},{"op":"replace","path":"/spec/minReplicas","value":7}]' >/dev/null
  watch_for "$t0" 6-min7 "$PHASE"
  say "7 maxReplicas 5 below the current count"
  k "${pa[@]}" '[{"op":"replace","path":"/spec/minReplicas","value":1},{"op":"replace","path":"/spec/maxReplicas","value":5}]' >/dev/null
  watch_for "$t0" 7-max5 "$PHASE"
  say "8 recovery: queue source back at 100, asking 2"
  k -n "$NS" patch deploy/queue-metrics --type json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/args/5","value":"{\"waiting-requests\":100}"}]' >/dev/null
  k -n "$NS" scale deploy/queue-metrics --replicas=1 >/dev/null
  watch_for "$t0" 8-recovery $((PHASE + 20))

  collect "$since"
  say "recorded in $OUT"
}

# cmd_upwindow checks whether a held scale-down changes what a scale-up cooldown sees, on the PR build with KPA.
# A held pass returns before the controller records a recommendation, so the low recommendations of the outage
# are in the cooldown history only when the hold is off.
# The scale-up window is 60 s and the scale-down window 300 s, so neither run scales down during the outage.
cmd_upwindow() {
  local mode=$1 t0 since
  owned || die "no lab cluster; run up first"
  case "$mode" in on | off) ;; *) die "mode is on or off" ;; esac
  OUT=$LAB_DIR/runs/$(date -u +%Y%m%dT%H%M%SZ)-pr-KPA-hold-$mode-upwindow60s
  mkdir -p "$OUT"
  use_build pr
  k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
  sed -e "s#SHIM_IMAGE#$SHIM_IMAGE#" -e "s#SIM_IMAGE#$SIM_IMAGE#" "$LAB_DIR/workload.yaml" | k apply -f - >/dev/null
  k -n "$NS" rollout status deploy/queue-metrics --timeout=120s >/dev/null
  k -n "$NS" rollout status deploy/chat --timeout=180s >/dev/null
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  render_pa KPA "$mode" \
    | sed -e 's#^\( *\)autoscaling.aibrix.ai/scale-down-cooldown-window: 0s$#\1autoscaling.aibrix.ai/scale-down-cooldown-window: 300s\n\1autoscaling.aibrix.ai/scale-up-cooldown-window: 60s#' \
    | tee "$OUT/podautoscaler-applied.yaml" | k apply -f - >/dev/null
  grep -q 'scale-up-cooldown-window: 60s' "$OUT/podautoscaler-applied.yaml" || die "the scale-up window was not set"
  printf 'utc\tt_s\tphase\tdeploy_spec_replicas\tdeploy_ready\tpa_desired\tqueue_endpoints\tkv_target\tmin\tmax\tscaling_active\n' \
    | tee "$OUT/timeline.tsv"
  t0=$(date +%s)
  say "1 baseline: both sources readable, 4 held by the queue"
  watch_for "$t0" 1-baseline "$PHASE"
  say "2 outage longer than the scale-up window: kv alone asks 2"
  k -n "$NS" scale deploy/queue-metrics --replicas=0 >/dev/null
  watch_for "$t0" 2-outage 80
  say "3 healthy source asks 7, capped at 6, while the queue still fails"
  k -n "$NS" patch podautoscaler chat --type json \
    -p '[{"op":"replace","path":"/spec/metricsSources/0/targetValue","value":"0.15"}]' >/dev/null
  watch_for "$t0" 3-scaleup 80
  collect "$since"
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
  run) shift; cmd_run "$@" ;;
  upwindow) shift; cmd_upwindow "$@" ;;
  down) cmd_down ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 2 ;;
esac
