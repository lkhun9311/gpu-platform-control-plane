#!/usr/bin/env bash
# The tenant boundary on a throwaway kind cluster with an enforcing CNI, free.
#
#   hack/tenant-boundary/run.sh <out-dir>            # builds kind-tenantlab, runs every check, deletes the cluster
#   KEEP=1 hack/tenant-boundary/run.sh <out-dir>     # leaves the cluster for inspection
#
# It records what happened in <out-dir>/results.jsonl and the run's facts in <out-dir>/run.json, and scores them
# with check.py into <out-dir>/verdict.json; check.py holds what each check must observe, not this script.
# The design and the check list: docs/superpowers/specs/2026-11-07-tenant-boundary-design.md, "Proof".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
[ $# -eq 1 ] || { echo "usage: $0 <out-dir>" >&2; exit 2; }
OUT=$1
CLUSTER=tenantlab
CTX=kind-$CLUSTER
NODE_IMAGE=kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
# NetworkPolicy is enforced by the CNI, and kindnet's enforcement is not what EKS runs, so the proof runs Calico at
# a pinned manifest; the hash is of the file as fetched on 2026-11-07.
CALICO_VERSION=v3.33.0
CALICO_SHA256=2de8f47595fb9c41b3f47d7b767a1f8e72ecf84057af834738ff12689a234da5
PROBE_DIGEST=sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
PLATFORM_NS=gpu-platform-control-plane-system
KUSTOMIZE=${KUSTOMIZE:-$REPO/bin/kustomize}
[ -x "$KUSTOMIZE" ] || KUSTOMIZE=$(command -v kustomize) || { echo "refuse: no kustomize" >&2; exit 2; }

# The cluster is this script's own: it refuses one it did not create rather than run checks on someone's state.
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "refuse: a kind cluster named $CLUSTER already exists; delete it (kind delete cluster --name $CLUSTER) first" >&2
  exit 2
fi
mkdir -p "$OUT"
[ -z "$(ls -A "$OUT")" ] || { echo "refuse: $OUT is not empty" >&2; exit 2; }
OUT=$(cd "$OUT" && pwd)
LOG=$OUT/run.log
WORK=$(mktemp -d)
cleanup() {
  rm -rf "$WORK"
  if [ "${KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || echo "warn: deleting $CLUSTER failed; see $LOG" >&2; fi
}
trap cleanup EXIT

k() { kubectl --context "$CTX" "$@"; }
# A tenant's request, made as a user of the group the bundle binds, the way the authenticator would present them.
as_tenant() { local t=$1; shift; kubectl --context "$CTX" --as="user-$t" --as-group="tenant:$t" "$@"; }
die() { echo "run: $*; see $LOG" >&2; tail -20 "$LOG" >&2; exit 1; }

# rec <id> <command...>: runs the command, keeps its exit status and both streams, and never stops the run, because
# a check that fails is a result to record, not an error.
rec() {
  local id=$1; shift
  local rc=0
  "$@" >"$WORK/out" 2>"$WORK/err" || rc=$?
  python3 - "$id" "$rc" "$WORK/out" "$WORK/err" >>"$OUT/results.jsonl" <<'EOF'
import json, sys
id_, rc, out, err = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
print(json.dumps({"id": id_, "exit": rc, "stdout": open(out).read(), "stderr": open(err).read()}))
EOF
  echo "$id exit=$rc" >>"$LOG"
}

dirty=$(git -C "$REPO" status --porcelain -- config hack/tenant hack/tenant-boundary internal | wc -l)
python3 - "$OUT/run.json" <<EOF
import json, sys
json.dump({
  "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "git_head": "$(git -C "$REPO" rev-parse HEAD)",
  "dirty_paths": $dirty,
  "cluster": "$CLUSTER",
  "node_image": "$NODE_IMAGE",
  "cni": "calico",
  "calico_version": "$CALICO_VERSION",
  "calico_manifest_sha256": "$CALICO_SHA256",
  "probe_image": "busybox:1.37.0",
  "probe_digest": "$PROBE_DIGEST",
  "kind": "$(kind version)",
  "kubectl": "$(kubectl version --client | head -1)",
}, open(sys.argv[1], "w"), indent=2)
EOF

echo "== cluster" | tee -a "$LOG"
cat >"$WORK/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --config "$WORK/kind.yaml" >>"$LOG" 2>&1 || die "kind create"
curl -sSfL -o "$WORK/calico.yaml" "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml" >>"$LOG" 2>&1 ||
  die "fetch calico"
echo "$CALICO_SHA256  $WORK/calico.yaml" | sha256sum -c >>"$LOG" 2>&1 || die "the calico manifest is not the pinned one"
k apply -f "$WORK/calico.yaml" >>"$LOG" 2>&1 || die "apply calico"
k -n kube-system rollout status ds/calico-node --timeout=600s >>"$LOG" 2>&1 || die "calico-node"
k -n kube-system rollout status deploy/calico-kube-controllers --timeout=300s >>"$LOG" 2>&1 || die "calico-kube-controllers"
k wait --for=condition=Ready node --all --timeout=300s >>"$LOG" 2>&1 || die "nodes Ready"
k -n kube-system rollout status deploy/coredns --timeout=300s >>"$LOG" 2>&1 || die "coredns"
# The nodes pull the probe by digest: `kind load` of a multi-platform image fails on the attestation manifests a
# local save carries, and a digest is the pin either way.
PROBE_REF=busybox@$PROBE_DIGEST

echo "== platform" | tee -a "$LOG"
k apply --server-side -f "$REPO/config/crd/bases" >>"$LOG" 2>&1 || die "platform CRDs"
k apply --server-side -f "$REPO/config/kueue-crds" >>"$LOG" 2>&1 || die "kueue CRDs"
"$KUSTOMIZE" build "$REPO/config/policy" >"$WORK/policy.yaml" 2>>"$LOG" || die "render config/policy"
k apply -f "$WORK/policy.yaml" >>"$LOG" 2>&1 || die "apply config/policy"
# The platform namespace comes from the shipped overlay, so the label the tenant policies trust is the one that
# ships, not one this script adds.
"$KUSTOMIZE" build "$REPO/config/default" >"$WORK/default.yaml" 2>>"$LOG" || die "render config/default"
python3 - "$WORK/default.yaml" >"$WORK/platform-ns.yaml" <<'EOF' || die "select the platform Namespace"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Namespace"]
assert len(docs) == 1, f"expected one Namespace in config/default, got {len(docs)}"
print(yaml.safe_dump(docs[0]))
EOF
k apply -f "$WORK/platform-ns.yaml" >>"$LOG" 2>&1 || die "platform namespace"
# Where Prometheus runs is the operator's choice; labelling it is the onboarding step the bundle relies on.
k create namespace monitoring >>"$LOG" 2>&1 || die "monitoring namespace"
k label namespace monitoring platform.lkhun9311.github.io/role=monitoring >>"$LOG" 2>&1 || die "label monitoring"
for t in train-a serve-a; do
  k apply -k "$REPO/config/tenants/$t" >>"$LOG" 2>&1 || die "tenant $t"
  # Until the quota controller has computed the quota's usage, the apiserver refuses every create the quota covers
  # ("status unknown for quota"), so a tenant onboarded a moment ago is refused for a reason that is not the boundary.
  k -n "$t" wait --for=jsonpath='{.status.used.pods}' resourcequota/tenant-baseline --timeout=120s >>"$LOG" 2>&1 ||
    die "quota status in $t"
done

# Every stand-in serves its own name over HTTP, so a success also says which Pod answered.
pod() { # pod <ns> <name> <node> <port> [label=value...]
  local ns=$1 name=$2 node=$3 port=$4; shift 4
  local labels="app.kubernetes.io/part-of: tenantlab"
  for l in "$@"; do labels="$labels, ${l%%=*}: ${l#*=}"; done
  k apply -f - >>"$LOG" 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $name, namespace: $ns, labels: {$labels}}
spec:
  nodeName: $CLUSTER-$node
  automountServiceAccountToken: false
  containers:
    - name: c
      image: $PROBE_REF
      command: ["sh", "-c", "mkdir -p /www && echo $name > /www/index.html && exec httpd -f -p $port -h /www"]
EOF
}
pod train-a rank-0 worker 8000
pod train-a rank-1 worker2 8000
pod train-a engine-a worker 8000 app.kubernetes.io/name=inferencedeployment
pod serve-a engine-b worker2 8000 app.kubernetes.io/name=inferencedeployment
pod "$PLATFORM_NS" gateway worker2 9090 app.kubernetes.io/component=gateway
pod monitoring prometheus worker 8000
for p in train-a/rank-0 train-a/rank-1 train-a/engine-a serve-a/engine-b "$PLATFORM_NS/gateway" monitoring/prometheus; do
  k -n "${p%/*}" wait --for=condition=Ready "pod/${p#*/}" --timeout=300s >>"$LOG" 2>&1 || die "pod $p"
done
ip() { k -n "$1" get pod "$2" -o jsonpath='{.status.podIP}'; }
RANK1=$(ip train-a rank-1) RANK0=$(ip train-a rank-0) ENGINE_A=$(ip train-a engine-a) ENGINE_B=$(ip serve-a engine-b)
GATEWAY=$(ip "$PLATFORM_NS" gateway)
KUBERNETES_IP=$(k get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
k get pods -A -o wide >"$OUT/pods.txt" 2>>"$LOG"
python3 - "$OUT/run.json" <<EOF
import json, sys
r = json.load(open(sys.argv[1]))
r["kubernetes_service_ip"] = "$KUBERNETES_IP"
r["pod_ips"] = {"rank-0": "$RANK0", "rank-1": "$RANK1", "engine-a": "$ENGINE_A", "engine-b": "$ENGINE_B", "gateway": "$GATEWAY"}
json.dump(r, open(sys.argv[1], "w"), indent=2)
EOF

echo "== api checks" | tee -a "$LOG"
job() { # job <ns> <name>
  cat <<EOF
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata: {name: $2, namespace: $1}
spec: {queue: gpu-train-a, image: "trainer:v1", gpuCount: 1, gpuClass: a10g}
EOF
}
FIN=mltrainingjob.platform.lkhun9311.github.io/finalizer
rec own-namespace-job sh -c "$(declare -f job); job train-a job-a | kubectl --context $CTX --as=user-train-a --as-group=tenant:train-a create -f -"
rec other-namespace-job sh -c "$(declare -f job); job serve-a job-x | kubectl --context $CTX --as=user-train-a --as-group=tenant:train-a create -f -"
rec create-pod as_tenant train-a -n train-a run direct --image="$PROBE_REF" --restart=Never
rec create-job as_tenant train-a -n train-a create job direct --image="$PROBE_REF"
rec create-resourcequota as_tenant train-a -n train-a create quota mine --hard=pods=1000
rec create-localqueue sh -c "printf '%s\n' 'apiVersion: kueue.x-k8s.io/v1beta1' 'kind: LocalQueue' 'metadata: {name: mine, namespace: train-a}' 'spec: {clusterQueue: gpu-serve-a}' | kubectl --context $CTX --as=user-train-a --as-group=tenant:train-a create -f -"
rec create-networkpolicy sh -c "printf '%s\n' 'apiVersion: networking.k8s.io/v1' 'kind: NetworkPolicy' 'metadata: {name: open, namespace: train-a}' 'spec: {podSelector: {}, ingress: [{}], egress: [{}]}' | kubectl --context $CTX --as=user-train-a --as-group=tenant:train-a create -f -"
rec tenant-fences as_tenant train-a -n train-a annotate mltrainingjob job-a platform.lkhun9311.github.io/fenced-nodes=n1
rec admin-fences k -n train-a annotate mltrainingjob job-a platform.lkhun9311.github.io/fenced-nodes=n1
k -n train-a patch mltrainingjob job-a --type=merge -p "{\"metadata\":{\"finalizers\":[\"$FIN\"]}}" >>"$LOG" 2>&1 || die "add the finalizer as the controller would"
rec tenant-strips-finalizer as_tenant train-a -n train-a patch mltrainingjob job-a --type=merge -p '{"metadata":{"finalizers":null}}'
k -n train-a patch mltrainingjob job-a --type=merge -p '{"metadata":{"finalizers":null}}' >>"$LOG" 2>&1 || die "release the finalizer"
rec tenant-binds-staged-volume sh -c "printf '%s\n' 'apiVersion: v1' 'kind: PersistentVolumeClaim' 'metadata: {name: staged, namespace: train-a}' 'spec: {accessModes: [ReadWriteOnce], volumeName: staged-for-serve-a, resources: {requests: {storage: 1Gi}}}' | kubectl --context $CTX --as=user-train-a --as-group=tenant:train-a create -f -"
printf '%s\n' 'apiVersion: platform.lkhun9311.github.io/v1' 'kind: GPUQuotaPolicy' 'metadata: {name: train-a}' \
  'spec: {tenant: train-a, targetNamespace: train-a, gpuClass: a10g, limits: {gpuCount: 1}}' | k create -f - >>"$LOG" 2>&1 || die "GPUQuotaPolicy"
# A PUT of the edited object, because kubectl's annotate, label and patch all read the object first, and a refused read
# is not the refused write under test.
put_edited() { # put_edited <api path> <python statement over o>
  k get --raw "$1" | python3 -c "import json,sys; o=json.load(sys.stdin); $2; print(json.dumps(o))" >"$WORK/put.json" &&
    kubectl --context "$CTX" --as=user-train-a --as-group=tenant:train-a replace --raw "$1" -f "$WORK/put.json"
}
rec tenant-raises-tier put_edited /apis/platform.lkhun9311.github.io/v1/gpuquotapolicies/train-a \
  "o['metadata'].setdefault('annotations', {})['platform.lkhun9311.github.io/tier'] = 'premium'"
rec tenant-labels-namespace put_edited /api/v1/namespaces/train-a \
  "o['metadata']['labels']['pod-security.kubernetes.io/enforce'] = 'privileged'"
rec privileged-pod sh -c "printf '%s\n' 'apiVersion: v1' 'kind: Pod' 'metadata: {name: priv, namespace: train-a}' 'spec: {containers: [{name: c, image: $PROBE_REF, securityContext: {privileged: true}}]}' | kubectl --context $CTX create -f -"

echo "== network checks" | tee -a "$LOG"
get() { local ns=$1 p=$2 url=$3; k -n "$ns" exec "$p" -- wget -T 3 -q -O- "$url"; }
rec rank-to-rank get train-a rank-0 "http://$RANK1:8000/"
rec dns k -n train-a exec rank-0 -- nslookup kubernetes.default.svc.cluster.local
rec gateway-to-own-engine get "$PLATFORM_NS" gateway "http://$ENGINE_A:8000/"
rec gateway-to-other-engine get "$PLATFORM_NS" gateway "http://$ENGINE_B:8000/"
rec monitoring-to-gateway get monitoring prometheus "http://$GATEWAY:9090/"
rec monitoring-to-rank get monitoring prometheus "http://$RANK0:8000/"
rec tenant-to-other-engine get train-a rank-0 "http://$ENGINE_B:8000/"
rec tenant-to-gateway-metrics get train-a rank-0 "http://$GATEWAY:9090/"
rec trainer-to-own-engine get train-a rank-0 "http://$ENGINE_A:8000/"
k get networkpolicy -A -o yaml >"$OUT/networkpolicies.yaml" 2>>"$LOG"

echo "== verdict" | tee -a "$LOG"
python3 "$HERE/check.py" "$OUT" | tee -a "$LOG"
