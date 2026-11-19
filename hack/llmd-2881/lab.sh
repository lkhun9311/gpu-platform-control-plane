#!/usr/bin/env bash
# A kind lab for llm-d/llm-d-router#2881: flow control releases a request, then the concurrency filter rejects it.
#
# It follows hack/llmd-kv-lab.sh: upstream's own scripts/kind-dev-env.sh runs from a pinned checkout, so the gateway,
# InferencePool and simulator manifests are upstream's.
# What this wrapper adds is the pins, a uniquely named cluster it owns, a private kubeconfig, on-disk temp files, and
# the EPP configs under test.
#
# Usage: hack/llmd-2881/lab.sh pins | up | mode requests|tokens|hybrid | status | down
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
LAB_DIR="$REPO/hack/llmd-2881"

# --- pins ---------------------------------------------------------------------------------------------------------
ROUTER_REPO=https://github.com/llm-d/llm-d-router.git
# e922a7ae is the main commit cited on #2881 on 2026-11-19, and was still main when this lab was built.
ROUTER_COMMIT=e922a7ae2538328d7ad9c87a6f391b7d0fbf313e
EPP_IMAGE=gpuaas-llmd-2881/epp:${ROUTER_COMMIT:0:12}
# LAB_EPP_COMMIT swaps in an EPP built from another commit, for the comparison arm from before #3065.
# Everything else in the cluster stays as up deployed it.
if [ -n "${LAB_EPP_COMMIT:-}" ]; then
  EPP_IMAGE=gpuaas-llmd-2881/epp:${LAB_EPP_COMMIT:0:12}
fi
# The simulator image hack/llmd-kv-lab.sh builds from llm-d-inference-sim main; its revision label is checked below.
SIM_COMMIT=6ab9d4b2367abe9338665368f61b3ff7e5547e4a
SIM_IMAGE=gpuaas-llmd-kv-lab/sim:${SIM_COMMIT:0:12}
RENDER_IMAGE=vllm/vllm-openai-cpu:v0.31.0
MODEL_NAME=TinyLlama/TinyLlama-1.1B-Chat-v1.0
EPP_NAME=tinyllama-1-1b-chat-v1-0-endpoint-picker

# --- lab shape ----------------------------------------------------------------------------------------------------
CLUSTER=gpuaas-llmd-2881
CTX=kind-$CLUSTER
GATEWAY_HOST_PORT=${GATEWAY_HOST_PORT:-30611}
SIM_REPLICAS=3
# Every simulator runs at most MAX_NUM_SEQS requests at once, the same number the requests-mode detector allows.
MAX_NUM_SEQS=4
# A request lasts TTFT plus max_tokens inter-token gaps, so 16 to 64 tokens hold a slot for 0.26 to 0.74 s.
# The simulator echoes x-request-id and names its pod, so a response can be joined to the EPP's log for it.
SIM_ARGS="--max-num-seqs=$MAX_NUM_SEQS --time-to-first-token=100ms --inter-token-latency=10ms --enable-request-id-headers"
OWNER_CM=gpuaas-llmd-2881-owner

LAB_HOME=${LAB_HOME:-/home/lkhun9311/.cache/llmd-2881}
CHECKOUT=$LAB_HOME/router
export KUBECONFIG=$LAB_HOME/kubeconfig
# Upstream's script calls mktemp; TMPDIR keeps that on disk rather than in the RAM-backed /tmp.
export TMPDIR=$LAB_HOME/tmp
mkdir -p "$TMPDIR"

say() { echo "llmd-2881: $*"; }
die() { echo "llmd-2881: REFUSED: $*" >&2; exit 1; }
k() { kubectl --context "$CTX" --request-timeout=30s "$@"; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }
owned() { k -n kube-system get configmap "$OWNER_CM" >/dev/null 2>&1; }

cmd_pins() {
  cat <<EOF
router commit   $ROUTER_COMMIT ($ROUTER_REPO), checkout $CHECKOUT at $(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null || echo missing)
EPP image       $EPP_IMAGE (LAB_EPP_COMMIT=${LAB_EPP_COMMIT:-unset}) revision=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$EPP_IMAGE" 2>/dev/null || echo missing) id=$(docker image inspect --format '{{.Id}}' "$EPP_IMAGE" 2>/dev/null || echo missing)
simulator       $SIM_IMAGE revision=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$SIM_IMAGE" 2>/dev/null || echo missing)
render          $RENDER_IMAGE $(docker image inspect --format '{{index .RepoDigests 0}}' "$RENDER_IMAGE" 2>/dev/null || echo missing)
kind CLI        $(kind version)
cluster         $CLUSTER, ${SIM_REPLICAS} simulator pods, args: $SIM_ARGS
EOF
}

# check refuses a moved or dirty checkout and images that do not carry the pinned revisions.
cmd_check() {
  local got
  got=$(git -C "$CHECKOUT" rev-parse HEAD)
  [ "$got" = "$ROUTER_COMMIT" ] || die "router checkout at $got, pinned $ROUTER_COMMIT"
  [ -z "$(git -C "$CHECKOUT" status --porcelain)" ] || die "router checkout is dirty"
  got=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$EPP_IMAGE")
  [ "$got" = "$ROUTER_COMMIT" ] || die "$EPP_IMAGE is labelled '$got'"
  got=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$SIM_IMAGE")
  [ "$got" = "$SIM_COMMIT" ] || die "$SIM_IMAGE is labelled '$got'"
  say "pins match"
}

render_config() {
  local mode=$1 out=$2
  [ -f "$LAB_DIR/epp-$mode.yaml" ] || die "no EPP config for mode '$mode'"
  # shellcheck disable=SC2016 # envsubst takes the variable names literally
  MODEL_NAME=$MODEL_NAME VLLM_RENDER_URL=http://vllm-render:8082 \
    envsubst '${MODEL_NAME} ${VLLM_RENDER_URL}' <"$LAB_DIR/epp-$mode.yaml" >"$out"
}

cmd_up() {
  local mode=${1:-requests}
  cmd_check
  if cluster_exists; then
    owned || die "a kind cluster named $CLUSTER exists and was not created by this script"
  else
    say "existing kind clusters (left alone): $(kind get clusters 2>/dev/null | tr '\n' ' ')"
    # The cluster is created here with the gateway bound to 127.0.0.1, and upstream's script reuses it.
    kind create cluster --name "$CLUSTER" --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.31.12
  extraPortMappings:
  - containerPort: 30080
    hostPort: $GATEWAY_HOST_PORT
    listenAddress: 127.0.0.1
    protocol: TCP
EOF
    k -n kube-system create configmap "$OWNER_CM" --from-literal=router-commit="$ROUTER_COMMIT" >/dev/null
  fi
  local cfg=$LAB_HOME/epp-config-up.yaml
  render_config "$mode" "$cfg"
  # VLLM_SIM_MODE=random with ignore_eos in each request makes a request last exactly its max_tokens.
  (cd "$CHECKOUT" && CLUSTER_NAME=$CLUSTER GATEWAY_HOST_PORT=$GATEWAY_HOST_PORT \
    VLLM_IMAGE=$SIM_IMAGE EPP_IMAGE=$EPP_IMAGE SIDECAR_IMAGE=$EPP_IMAGE VLLM_RENDER_IMAGE=$RENDER_IMAGE \
    VLLM_REPLICA_COUNT_D=$SIM_REPLICAS VLLM_SIM_MODE=random VLLM_EXTRA_ARGS_D="$SIM_ARGS" \
    EPP_CONFIG="$cfg" MODEL_NAME=$MODEL_NAME ./scripts/kind-dev-env.sh) >"$LAB_HOME/kind-dev-env.log" 2>&1 \
    || { tail -30 "$LAB_HOME/kind-dev-env.log" >&2; die "upstream kind-dev-env.sh failed (log: $LAB_HOME/kind-dev-env.log)"; }
  k apply -f "$LAB_DIR/preserve-request-id.yaml" >/dev/null
  cmd_mode "$mode"
  cmd_status
}

# mode swaps the EPP config and restarts the EPP, then the simulators, so each run starts with empty counters.
cmd_mode() {
  local mode=${1:?mode requests|tokens|hybrid}
  owned || die "$CLUSTER is not up, or not ours"
  local cfg=$LAB_HOME/epp-config-$mode.yaml
  render_config "$mode" "$cfg"
  k create configmap epp-config --from-file=epp-config.yaml="$cfg" --dry-run=client -o yaml | k apply -f - >/dev/null
  local want_rev
  want_rev=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$EPP_IMAGE")
  [ "$want_rev" = "${LAB_EPP_COMMIT:-$ROUTER_COMMIT}" ] || die "$EPP_IMAGE is labelled '$want_rev'"
  if ! docker exec "$CLUSTER-control-plane" crictl inspecti "docker.io/$EPP_IMAGE" >/dev/null 2>&1; then
    kind load docker-image --name "$CLUSTER" "$EPP_IMAGE" >/dev/null
  fi
  k set image deployment/"$EPP_NAME" epp="$EPP_IMAGE" >/dev/null
  k rollout restart deployment/"$EPP_NAME" >/dev/null
  k rollout status deployment/"$EPP_NAME" --timeout=180s >/dev/null
  k rollout restart deployment/vllm-d >/dev/null
  k rollout status deployment/vllm-d --timeout=300s >/dev/null
  # Terminating pods still match the selectors for a while.
  local _
  for _ in $(seq 1 90); do
    [ "$(k get pods -l llm-d.ai/component=decode --no-headers 2>/dev/null | wc -l)" = "$SIM_REPLICAS" ] \
      && [ "$(k get pods -l app=$EPP_NAME --no-headers 2>/dev/null | wc -l)" = 1 ] && break
    sleep 2
  done
  verify_running
  k -n kube-system patch configmap "$OWNER_CM" --type merge -p "{\"data\":{\"mode\":\"$mode\"}}" >/dev/null
  say "EPP runs the $mode config behind freshly started simulators"
}

# verify_running refuses a cluster whose EPP or simulator pods do not run the pinned images and simulator flags.
verify_running() {
  local spec args
  spec=$(k get deployment "$EPP_NAME" -o jsonpath='{.spec.template.spec.containers[0].image}')
  [ "$spec" = "$EPP_IMAGE" ] || die "EPP deployment runs $spec"
  spec=$(k get deployment vllm-d -o jsonpath='{.spec.template.spec.containers[0].image}')
  [ "$spec" = "$SIM_IMAGE" ] || die "simulator deployment runs $spec"
  args=$(k get deployment vllm-d -o jsonpath='{.spec.template.spec.containers[0].args}')
  local a
  for a in $SIM_ARGS --mode=random; do
    grep -qF -- "\"$a\"" <<<"$args" || die "simulator args lack $a: $args"
  done
  # Without the filter the client's 503s cannot be joined to the EPP's log.
  k get envoyfilter preserve-request-id >/dev/null || die "EnvoyFilter preserve-request-id is missing"
}

cmd_status() {
  owned || die "$CLUSTER is not up, or not ours"
  say "mode: $(k -n kube-system get configmap "$OWNER_CM" -o jsonpath='{.data.mode}')"
  k get pods -o wide
}

cmd_down() {
  cluster_exists || { say "$CLUSTER does not exist"; return; }
  owned || die "$CLUSTER has no $OWNER_CM marker; not deleting a cluster this script did not create"
  kind delete cluster --name "$CLUSTER"
}

case "${1:-}" in
  pins) cmd_pins ;;
  check) cmd_check ;;
  up) cmd_up "${2:-requests}" ;;
  mode) cmd_mode "${2:-}" ;;
  status) cmd_status ;;
  down) cmd_down ;;
  *) echo "usage: $0 pins|check|up [mode]|mode requests|tokens|hybrid|status|down" >&2; exit 2 ;;
esac
