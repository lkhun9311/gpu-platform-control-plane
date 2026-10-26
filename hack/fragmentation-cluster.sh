#!/usr/bin/env bash
# Builds and deletes the throwaway kind cluster the repack rerun runs on.
#
# The rerun is registered in docs/superpowers/specs/2026-10-22-repack-with-a-continuous-collector-design.md.
# It needs an operator built from this tree, which the long-lived kind-platform cluster does not run, and that
# cluster refuses every MLTrainingJob create through a webhook nothing serves.
# So this builds one called frag, with the node image the original study's cluster ran pinned by digest, two
# simulated devices on every node as the original registration's fixture, and Kueue at the version kind-platform
# runs.
# The setup repeats hack/distributed-partial-placement.sh's rather than sourcing it, so that harness stays
# byte-identical to the version its recorded runs used.
#
# Usage:
#   EXDIR=ex/frag-r3 hack/fragmentation-cluster.sh up     # build, and record provenance in $EXDIR
#   hack/fragmentation-cluster.sh down                    # delete it
# Then: CLUSTER=frag EXDIR=ex/frag-r3 hack/fragmentation.sh fixture, and trials, as the registration lists.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=frag
CONTEXT=kind-$CLUSTER
SYS=gpu-platform-control-plane-system
TAG=frag
# kind-platform's node image, the cluster the 25 trials ran on, by the digest docker reports for it.
NODE_IMAGE=kindest/node:v1.31.0@sha256:53df588e04085fd41ae12de0c3fe4c72f7013bba32a20e7325357a1ac94ba865
KUEUE_VERSION=v0.18.3
CERT_MANAGER_VERSION=v1.21.1

k() { kubectl --context "$CONTEXT" "$@"; }

down() {
  local listed
  listed=$(kind get clusters 2>&1) || { echo "kind get clusters failed: $listed" >&2; return 1; }
  if grep -qx "$CLUSTER" <<<"$listed"; then
    kind delete cluster --name "$CLUSTER" || return 1
  fi
  listed=$(kind get clusters 2>&1)
  if grep -qx "$CLUSTER" <<<"$listed"; then
    echo "$CLUSTER STILL EXISTS" >&2
    return 1
  fi
  echo "deleted $CLUSTER (listed now: $(tr '\n' ' ' <<<"$listed"))"
}

up() {
  : "${EXDIR:?set EXDIR to the evidence directory}"
  mkdir -p "$EXDIR"
  local log=$EXDIR/cluster.log prov=$EXDIR/cluster-provenance.txt
  : >>"$log"
  die() {
    echo "cluster setup failed at: $*; tail of $log:" >&2
    tail -n 20 "$log" >&2
    exit 1
  }
  retry() {
    for _ in $(seq 1 40); do "$@" && return 0; sleep 3; done
    return 1
  }
  # The operator under test is the tree's, so a tree that differs from its commit is not any commit's operator,
  # and the registration freezes a commit.
  # The whole tree, not only the code directories: go.mod, the Dockerfiles and the Makefile feed the builds too.
  local dirty
  dirty=$(git status --porcelain)
  [ -z "$dirty" ] || die "uncommitted or untracked changes, so the images would not be HEAD's: $dirty"

  export PATH="$PWD/bin:$PATH"
  command -v kustomize >/dev/null || make kustomize >>"$log" 2>&1 || die "make kustomize"
  for tool in docker kind kubectl kustomize python3; do command -v "$tool" >/dev/null || die "missing tool $tool"; done
  {
    echo "commit=$(git rev-parse HEAD)"
    echo "dirty_files=$(git status --porcelain | wc -l)"
    echo "kind=$(kind version)"
    echo "node_image=$NODE_IMAGE"
    echo "kueue=$KUEUE_VERSION"
    echo "cert_manager=$CERT_MANAGER_VERSION"
    echo "fragmentation_sh_sha256=$(sha256sum hack/fragmentation.sh | cut -d' ' -f1)"
  } >"$prov"

  make docker-build IMG=controller:$TAG >>"$log" 2>&1 || die "operator image"
  make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$log" 2>&1 || die "simulator image"
  echo "operator_image=$(docker image inspect controller:$TAG --format '{{.Id}}')" >>"$prov"
  echo "simulator_image=$(docker image inspect gpu-simulator:$TAG --format '{{.Id}}')" >>"$prov"

  down >>"$log" 2>&1 || die "delete old cluster"
  kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --config hack/kind-config.yaml >>"$log" 2>&1 ||
    die "kind create"
  echo "kubelet=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')" >>"$prov"
  # The target and holders run pause:3.10, which this node image already holds as its sandbox image; loading the
  # host's copy fails, since ctr cannot find the other platforms' content a single-platform pull lacks.
  docker exec "$CLUSTER-worker" crictl images 2>>"$log" | grep -qE '^registry\.k8s\.io/pause +3\.10 ' ||
    die "the node image does not hold registry.k8s.io/pause:3.10"
  for img in controller:$TAG gpu-simulator:$TAG; do
    kind load docker-image "$img" --name "$CLUSTER" >>"$log" 2>&1 || die "kind load $img"
  done

  k apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml" >>"$log" 2>&1 ||
    die "cert-manager"
  k -n cert-manager wait --for=condition=Available deploy --all --timeout=300s >>"$log" 2>&1 || die "cert-manager Available"
  k apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_VERSION/manifests.yaml" >>"$log" 2>&1 ||
    die "kueue"
  k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$log" 2>&1 ||
    die "kueue Available"
  kustomize build config/crd | k apply --server-side -f - >>"$log" 2>&1 || die "CRDs"
  # shellcheck disable=SC2317  # called through retry
  apply_operator() { kustomize build config/operator-webhook | k apply --server-side -f - >>"$log" 2>&1; }
  retry apply_operator || die "operator"
  local opdep
  opdep=$(k -n "$SYS" get deploy -o name | grep controller-manager | head -1)
  [ -n "$opdep" ] || die "no controller-manager deployment"
  # The manifests pin an ECR digest a kind node cannot pull, so the local build is set explicitly.
  k -n "$SYS" set image "$opdep" manager=controller:$TAG >>"$log" 2>&1 || die "operator image set"
  k -n "$SYS" patch "$opdep" --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$log" 2>&1 ||
    die "operator pull policy"
  k -n "$SYS" rollout status "$opdep" --timeout=240s >>"$log" 2>&1 || die "operator rollout"

  kustomize build config/device-plugin | k apply -f - >>"$log" 2>&1 || die "device plugin"
  k -n "$SYS" set image ds/gpu-simulator "*=gpu-simulator:$TAG" >>"$log" 2>&1 || die "simulator image set"
  k -n "$SYS" patch ds/gpu-simulator --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$log" 2>&1 ||
    die "simulator pull policy"
  # Two per node is the original registration's fixture: C_i = 2 on each worker.
  k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=2 >>"$log" 2>&1 || die "simulator count"
  k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$log" 2>&1 || die "simulator rollout"
  local gpus=""
  for _ in $(seq 1 60); do
    gpus=$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.allocatable.nvidia\.com/gpu}{" "}{end}')
    [ "$gpus" = "$CLUSTER-control-plane=2 $CLUSTER-worker=2 $CLUSTER-worker2=2 " ] && break
    sleep 3
  done
  [ "$gpus" = "$CLUSTER-control-plane=2 $CLUSTER-worker=2 $CLUSTER-worker2=2 " ] ||
    die "the nodes do not each advertise two nvidia.com/gpu (allocatable: '$gpus')"
  echo "allocatable=$gpus" >>"$prov"
  echo "cluster $CLUSTER is up: $gpus"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *)
    echo "usage: $0 up|down" >&2
    exit 2
    ;;
esac
