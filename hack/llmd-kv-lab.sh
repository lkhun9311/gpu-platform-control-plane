#!/usr/bin/env bash
# A free kind lab for llm-d-router: an InferencePool (v1) whose endpoint picker scores llm-d-inference-sim pods by
# prefix cache, with the precise (KV-event) producer or the approximate one.
#
# It runs upstream's own scripts/kind-dev-env.sh from a pinned checkout instead of re-deriving its manifests, so the
# lab is upstream's dev environment and a difference we observe cannot be one we introduced by rewriting it.
# What this wrapper adds is what that script does not do: it pins every version, refuses on drift, owns a uniquely
# named cluster and never touches another, keeps its kubeconfig out of ~/.kube/config, and switches scorers.
#
# Usage: hack/llmd-kv-lab.sh pins | check | up [precise|precise-pull|precise-spec|approx] | mode precise|precise-pull|precise-spec|approx | status | down
#
# docs/14_LLMD_KV_ROUTING_LAB.md describes the lab and what it showed.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
LAB_DIR="$REPO/hack/llmd-kv-lab"

# --- pins ---------------------------------------------------------------------------------------------------------
# A tag can be re-pushed, so every image is pinned by digest and the tag is only what upstream's script loads by name.
ROUTER_REPO=https://github.com/llm-d/llm-d-router.git
ROUTER_COMMIT=3d0b21d51d29c2f773556c924e5aaf3ee32cc344
SIM_IMAGE=ghcr.io/llm-d/llm-d-inference-sim:v1.2.0
SIM_DIGEST=sha256:9992453829c0dea8d120b8e0322bb0e4237cbb3c6d9ea3bdce060410c40c91c9
RENDER_IMAGE=vllm/vllm-openai-cpu:v0.31.0
RENDER_DIGEST=sha256:495c84fe30f3572b83a78100a1e8ba423dbb77fc532ecefebe114e6b77327bd9
KIND_NODE_IMAGE=kindest/node:v1.31.12
KIND_NODE_DIGEST=sha256:0f5cc49c5e73c0c2bb6e2df56e7df189240d83cf94edfa30946482eb08ec57d2
KIND_CLI_VERSION=v0.24.0
# The EPP is built from the pinned commit because the v1.0.0 release image predates fixes the follow-up issues test.
EPP_IMAGE=gpuaas-llmd-kv-lab/epp:${ROUTER_COMMIT:0:12}
# Upstream files the committed EPP configs were derived from; a changed hash means the arms no longer match upstream.
declare -A UPSTREAM_SHA256=(
  [scripts/kind-dev-env.sh]=78e37ef5611d1a37e74e27c89eecdc675490a77f3e8fb83ecfb3d7176a53a17d
  [test/e2e/artifacts/config/sim-epp-config.yaml]=cb77084207fa0229ca4f50a369a34480ad4652228930d36caf2f143557bbd920
  [test/e2e/artifacts/config/sim-epp-kvcache-config.yaml]=5c059a79848617eb7a5fb75cbadbd02de9ae5feb8d30af1322ae0760a086bd89
)

# --- lab shape ----------------------------------------------------------------------------------------------------
# The name carries this repository's prefix so it cannot collide with upstream's default llm-d-router-dev.
CLUSTER=gpuaas-llmd-kv-lab
CTX=kind-$CLUSTER
GATEWAY_HOST_PORT=${GATEWAY_HOST_PORT:-30598}
# Three pods is the fewest where "picked the warm pod" and "picked by tie-break" are distinguishable often enough.
SIM_REPLICAS=3
# 256 blocks of 16 tokens per pod, so a few thousand tokens of other traffic evicts a prefix and eviction is testable.
SIM_KV_BLOCKS=256
# The gateway replaces the client's x-request-id with its own, and that is the id the EPP logs its scores under.
# The simulator echoing the id it received is what lets a response be joined to the EPP's decision for it.
SIM_ECHO_REQUEST_ID=--enable-request-id-headers
MODEL_NAME=TinyLlama/TinyLlama-1.1B-Chat-v1.0
EPP_NAME=tinyllama-1-1b-chat-v1-0-endpoint-picker
OWNER_CM=gpuaas-llmd-kv-lab-owner

LAB_HOME=${LAB_HOME:-$REPO/tmp/llmd-kv-lab}
CHECKOUT=$LAB_HOME/llm-d-router
# A private kubeconfig, so creating and deleting the lab never rewrites the contexts of the user's other clusters.
export KUBECONFIG=$LAB_HOME/kubeconfig

say() { echo "llmd-kv-lab: $*"; }
die() { echo "llmd-kv-lab: REFUSED: $*" >&2; exit 1; }
k() { kubectl --context "$CTX" --request-timeout=30s "$@"; }

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }

# The marker is written right after this script creates the cluster, so a cluster without it is someone else's.
owned() { k -n kube-system get configmap "$OWNER_CM" >/dev/null 2>&1; }

image_digest_ok() {
  local image=$1 digest=$2 repo=${1%:*}
  docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null \
    | grep -qx "${repo#docker.io/}@$digest"
}

cmd_pins() {
  cat <<EOF
router commit     $ROUTER_COMMIT ($ROUTER_REPO)
EPP image         $EPP_IMAGE (built from that commit with its Dockerfile.epp, golang:1.27.4)
simulator         $SIM_IMAGE@$SIM_DIGEST
render (tokenizer) $RENDER_IMAGE@$RENDER_DIGEST
kind node         $KIND_NODE_IMAGE@$KIND_NODE_DIGEST
kind CLI          $KIND_CLI_VERSION
cluster           $CLUSTER (context $CTX, kubeconfig $KUBECONFIG)
gateway           127.0.0.1:$GATEWAY_HOST_PORT
simulator pods    $SIM_REPLICAS x $SIM_KV_BLOCKS KV blocks of 16 tokens
EOF
}

fetch_checkout() {
  if [ ! -d "$CHECKOUT/.git" ]; then
    mkdir -p "$LAB_HOME"
    git clone --quiet "$ROUTER_REPO" "$CHECKOUT"
  fi
  if [ "$(git -C "$CHECKOUT" rev-parse HEAD)" != "$ROUTER_COMMIT" ]; then
    git -C "$CHECKOUT" fetch --quiet origin "$ROUTER_COMMIT" 2>/dev/null || git -C "$CHECKOUT" fetch --quiet origin
    git -C "$CHECKOUT" -c advice.detachedHead=false checkout --quiet "$ROUTER_COMMIT"
  fi
}

# checkout_ok reports whether the router checkout is the pinned commit, clean, and carries the pinned upstream files.
checkout_ok() {
  local bad=0 got f
  if [ -d "$CHECKOUT/.git" ]; then
    got=$(git -C "$CHECKOUT" rev-parse HEAD)
    [ "$got" = "$ROUTER_COMMIT" ] || { echo "  drift: router checkout at $got" >&2; bad=1; }
    [ -z "$(git -C "$CHECKOUT" status --porcelain)" ] || { echo "  drift: router checkout is dirty" >&2; bad=1; }
    for f in "${!UPSTREAM_SHA256[@]}"; do
      got=$(sha256sum "$CHECKOUT/$f" | awk '{print $1}')
      [ "$got" = "${UPSTREAM_SHA256[$f]}" ] || { echo "  drift: $f sha256 $got" >&2; bad=1; }
    done
  else
    echo "  missing: router checkout $CHECKOUT (up fetches it)" >&2; bad=1
  fi
  [ "$bad" = 0 ]
}

# check refuses on any drift: a different kind CLI, a moved or dirty checkout, an upstream file that changed under
# the committed arms, or an image whose tag now points somewhere other than the pinned digest.
cmd_check() {
  local bad=0 got
  got=$(kind version | awk '{print $2}')
  [ "$got" = "$KIND_CLI_VERSION" ] || { echo "  drift: kind CLI is $got, pinned $KIND_CLI_VERSION" >&2; bad=1; }
  checkout_ok || bad=1
  image_digest_ok "$SIM_IMAGE" "$SIM_DIGEST" || { echo "  drift: $SIM_IMAGE is not $SIM_DIGEST locally" >&2; bad=1; }
  image_digest_ok "$RENDER_IMAGE" "$RENDER_DIGEST" || { echo "  drift: $RENDER_IMAGE is not $RENDER_DIGEST locally" >&2; bad=1; }
  image_digest_ok "$KIND_NODE_IMAGE" "$KIND_NODE_DIGEST" || { echo "  drift: $KIND_NODE_IMAGE is not $KIND_NODE_DIGEST locally" >&2; bad=1; }
  got=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$EPP_IMAGE" 2>/dev/null || true)
  [ "$got" = "$ROUTER_COMMIT" ] || { echo "  drift: $EPP_IMAGE is not labelled with the pinned commit (got '$got')" >&2; bad=1; }
  [ "$bad" = 0 ] || die "version drift (above)"
  say "all pins match"
}

prepare_images() {
  for pair in "$SIM_IMAGE@$SIM_DIGEST" "$RENDER_IMAGE@$RENDER_DIGEST" "$KIND_NODE_IMAGE@$KIND_NODE_DIGEST"; do
    local image=${pair%@*} digest=${pair#*@}
    image_digest_ok "$image" "$digest" && continue
    # Pull by digest and tag it, so a re-pushed tag can never be what gets loaded.
    docker pull --quiet "${image%:*}@$digest" >/dev/null
    docker tag "${image%:*}@$digest" "$image"
  done
  if ! docker image inspect "$EPP_IMAGE" >/dev/null 2>&1; then
    say "building $EPP_IMAGE from $ROUTER_COMMIT"
    # Dockerfile.epp says FROM --platform=${BUILDPLATFORM}, which only BuildKit defines.
    # Without buildx the legacy builder sees it empty and refuses, so a copy without that one flag is built instead.
    # The copy lives outside the checkout so the drift check's clean-tree test still holds.
    local dockerfile=$CHECKOUT/Dockerfile.epp
    if ! docker buildx version >/dev/null 2>&1; then
      dockerfile=$LAB_HOME/Dockerfile.epp.legacy-builder
      # shellcheck disable=SC2016 # the Dockerfile's own ${BUILDPLATFORM} is matched literally, not expanded
      sed 's/^FROM --platform=\${BUILDPLATFORM} /FROM /' "$CHECKOUT/Dockerfile.epp" >"$dockerfile"
    fi
    docker build --quiet --platform linux/amd64 \
      --build-arg TARGETOS=linux --build-arg TARGETARCH=amd64 --build-arg COMMIT_SHA="$ROUTER_COMMIT" \
      --label org.opencontainers.image.revision="$ROUTER_COMMIT" \
      -t "$EPP_IMAGE" -f "$dockerfile" "$CHECKOUT" >/dev/null
  fi
}

create_cluster() {
  if cluster_exists; then
    owned || die "a kind cluster named $CLUSTER exists and was not created by this script; not touching it"
    say "reusing $CLUSTER"
    return
  fi
  say "existing kind clusters (left alone): $(kind get clusters 2>/dev/null | tr '\n' ' ')"
  # The gateway is published on 127.0.0.1 only, which upstream's own cluster config does not do.
  kind create cluster --name "$CLUSTER" --wait 120s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: ${KIND_NODE_IMAGE%:*}@$KIND_NODE_DIGEST
  extraPortMappings:
  - containerPort: 30080
    hostPort: $GATEWAY_HOST_PORT
    listenAddress: 127.0.0.1
    protocol: TCP
EOF
  k -n kube-system create configmap "$OWNER_CM" \
    --from-literal=created-by=hack/llmd-kv-lab.sh --from-literal=router-commit="$ROUTER_COMMIT" >/dev/null
}

render_config() {
  local mode=$1 out=$2
  [ -f "$LAB_DIR/epp-$mode.yaml" ] || die "no EPP config for mode '$mode' (precise, precise-pull, precise-spec or approx)"
  # shellcheck disable=SC2016 # envsubst takes the variable names literally
  MODEL_NAME=$MODEL_NAME VLLM_RENDER_URL=http://vllm-render:8082 \
    envsubst '${MODEL_NAME} ${VLLM_RENDER_URL}' <"$LAB_DIR/epp-$mode.yaml" >"$out"
}

cmd_up() {
  local mode=${1:-precise}
  fetch_checkout
  # The checkout is verified before anything is built from it, because the EPP image is labelled with the pinned commit
  # and a later check trusts that label: an image built from a modified tree would pass every later run.
  checkout_ok || die "router checkout drift (above); nothing was built"
  prepare_images
  cmd_check
  create_cluster
  # Upstream's script reuses an existing cluster, so it only deploys into the one created above.
  # KV_CACHE_ENABLED=true is what makes the simulators emit KV events; the EPP config is chosen separately below.
  # SIDECAR_IMAGE is set to the EPP image because the EPD layout deletes the sidecar, and the default :dev tag would
  # otherwise be pulled unpinned only to be loaded and never run.
  local epp_image=$EPP_IMAGE
  (cd "$CHECKOUT" && CLUSTER_NAME=$CLUSTER GATEWAY_HOST_PORT=$GATEWAY_HOST_PORT KV_CACHE_ENABLED=true \
    VLLM_IMAGE=$SIM_IMAGE EPP_IMAGE=$epp_image SIDECAR_IMAGE=$epp_image VLLM_RENDER_IMAGE=$RENDER_IMAGE \
    VLLM_REPLICA_COUNT_D=$SIM_REPLICAS VLLM_EXTRA_ARGS_D="--kv-cache-size=$SIM_KV_BLOCKS" \
    EPP_CONFIG="$LAB_DIR/epp-$mode.yaml" MODEL_NAME=$MODEL_NAME \
    ./scripts/kind-dev-env.sh) >"$LAB_HOME/kind-dev-env.log" 2>&1 \
    || { tail -30 "$LAB_HOME/kind-dev-env.log" >&2; die "upstream kind-dev-env.sh failed (log: $LAB_HOME/kind-dev-env.log)"; }
  # VLLM_EXTRA_ARGS_D carries one flag only: kustomize emits the placeholder unquoted, upstream's awk splitter only
  # matches a quoted line, and two flags in it reach the simulator as one argument and crash it (docs/14 records this).
  # So the second flag is appended here, after upstream's apply has reset the args.
  if ! k get deployment vllm-d -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- "$SIM_ECHO_REQUEST_ID"; then
    k patch deployment vllm-d --type json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"$SIM_ECHO_REQUEST_ID\"}]" >/dev/null
  fi
  k rollout status deployment/vllm-d --timeout=300s >/dev/null
  # Upstream's script creates the config map but does not restart a running EPP, so a re-run would keep the old
  # config; going through mode applies the chosen one and orders the restarts.
  cmd_mode "$mode"
  cmd_status
}

# set_sim_zmq push|pull makes the simulators dial the EPP's bound socket (push, upstream's dev default) or bind
# tcp://*:5557 for the EPP to dial (pull); the simulator binds when the address has a wildcard and dials otherwise.
set_sim_zmq() {
  local args
  args=$(k get deployment vllm-d -o json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
args = [a for a in d["spec"]["template"]["spec"]["containers"][0]["args"] if a != "--zmq-endpoint=tcp://*:5557"]
# pflag keeps the last value, so the appended bind address overrides the dial address earlier in the list.
if sys.argv[1] == "pull":
    args.append("--zmq-endpoint=tcp://*:5557")
print(json.dumps(args))' "$1")
  k patch deployment vllm-d --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$args}]" >/dev/null
}

# mode swaps the EPP config, restarts the EPP, then restarts the simulators.
# The simulators restart second, and always, for two reasons: each arm starts from empty caches, and in push mode a
# simulator that dialled the previous EPP pod keeps an ESTABLISHED connection to an address that no longer exists
# (measured in docs/14), so only a simulator started after the EPP is known to be connected to it.
cmd_mode() {
  local mode=${1:?mode precise|precise-pull|precise-spec|approx}
  owned || die "$CLUSTER is not up, or not ours"
  local tmp
  tmp=$(mktemp)
  render_config "$mode" "$tmp"
  k create configmap epp-config --from-file=epp-config.yaml="$tmp" --dry-run=client -o yaml | k apply -f - >/dev/null
  rm -f "$tmp"
  k rollout restart deployment/"$EPP_NAME" >/dev/null
  k rollout status deployment/"$EPP_NAME" --timeout=180s >/dev/null
  if [ "$mode" = precise-pull ]; then set_sim_zmq pull; else set_sim_zmq push; fi
  k rollout restart deployment/vllm-d >/dev/null
  k rollout status deployment/vllm-d --timeout=300s >/dev/null
  # The arm measures only after the restarted pods are shown to run the pinned images.
  verify_running_images
  k -n kube-system patch configmap "$OWNER_CM" --type merge -p "{\"data\":{\"mode\":\"$mode\"}}" >/dev/null
  say "EPP now runs the $mode config, behind freshly started simulators"
}

cmd_status() {
  owned || die "$CLUSTER is not up, or not ours"
  say "mode: $(k -n kube-system get configmap "$OWNER_CM" -o jsonpath='{.data.mode}')"
  k get inferencepool,pods -o wide
  verify_running_images
}

# deploy_image_ok checks one Deployment runs the pinned image: its template names the image, and every one of its pods
# runs the config id the node loaded for that image's tag.
# A pod reports the config id rather than a registry digest, so the pod side is matched to the node's own image.
deploy_image_ok() {
  local deploy=$1 image=$2 node=$CLUSTER-control-plane spec node_id sel ids
  spec=$(k get deployment "$deploy" -o jsonpath='{.spec.template.spec.containers[*].image}')
  grep -qxF -- "$image" <<<"${spec// /$'\n'}" || { echo "  drift: deployment/$deploy runs '$spec', pinned $image" >&2; return 1; }
  node_id=$(docker exec "$node" crictl images --no-trunc | awk -v r="${image%:*}" -v t="${image##*:}" '$1==r && $2==t {print $3}')
  # shellcheck disable=SC2016 # the go-template's variables are the template's, not the shell's
  sel=$(k get deployment "$deploy" -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')
  ids=$(k get pods -l "${sel%,}" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}')
  if [ -z "$node_id" ] || [ -z "$ids" ] || grep -qvxF -- "$node_id" <<<"$ids"; then
    echo "  drift: a pod of deployment/$deploy runs an image other than the node's $image ($node_id): $ids" >&2
    return 1
  fi
}

# verify_running_images refuses a cluster whose simulator, EPP or renderer is not the pinned image, as they run now.
#
# check reads only the host's images and checkout; a Deployment edited after up would otherwise be measured under
# "all pins match". The simulator's node image is also held to its pinned registry digest.
verify_running_images() {
  local node=$CLUSTER-control-plane node_digest bad=0
  node_digest=$(docker exec "$node" ctr -n k8s.io images ls "name==$SIM_IMAGE" | awk 'NR==2 {print $3}')
  [ "$node_digest" = "$SIM_DIGEST" ] || { echo "  drift: the node's $SIM_IMAGE is $node_digest, pinned $SIM_DIGEST" >&2; bad=1; }
  deploy_image_ok vllm-d "$SIM_IMAGE" || bad=1
  deploy_image_ok "$EPP_NAME" "$EPP_IMAGE" || bad=1
  deploy_image_ok vllm-render "$RENDER_IMAGE" || bad=1
  [ "$bad" = 0 ] || die "running images drifted from the pins (above)"
  say "simulator, EPP and renderer pods run their pinned images"
}

cmd_down() {
  if ! cluster_exists; then
    say "$CLUSTER does not exist; nothing to do"
    return
  fi
  owned || die "$CLUSTER exists but has no $OWNER_CM marker; not deleting a cluster this script did not create"
  kind delete cluster --name "$CLUSTER"
}

# Dispatch only when run, so a test can source the functions without bringing anything up.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    pins) cmd_pins ;;
    # check inspects the checkout as it is; only up fetches or moves it, so drift is reported rather than repaired.
    check) cmd_check ;;
    up) cmd_up "${2:-precise}" ;;
    mode) cmd_mode "${2:-}" ;;
    status) cmd_status ;;
    down) cmd_down ;;
    *) echo "usage: $0 pins|check|up [precise|precise-pull|precise-spec|approx]|mode precise|precise-pull|precise-spec|approx|status|down" >&2; exit 2 ;;
  esac
fi
