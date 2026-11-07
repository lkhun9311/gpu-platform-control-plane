# shellcheck shell=bash
# What the drill's scenarios share: the cluster, the state directory outside the repository, and the fake DCGM.
CLUSTER=drill
CONTEXT=kind-$CLUSTER
SYS=gpu-platform-control-plane-system
NS=train-a
QUEUE=gpu-$NS
IMG=distributed-restart:drill
DRILL_STATE=${DRILL_STATE:-$HOME/.cache/gpuaas-drill}
TRUTH=$DRILL_STATE/truth
mkdir -p "$TRUTH"

k() { kubectl --context "$CONTEXT" "$@"; }
say() { echo "$(date -u +%H:%M:%S) $*"; }
fail() {
  say "FAILED: $*" >&2
  exit 1
}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# wait_until SECONDS CMD...: runs CMD every 2 s until it succeeds; 1 when the time runs out.
wait_until() {
  local limit=$1 i
  shift
  for i in $(seq 1 $((limit / 2))); do "$@" && return 0; sleep 2; done
  return 1
}

# sim_ip NODE: the IP of the gpu-simulator Pod (and its fake DCGM) on NODE.
sim_ip() {
  k -n "$SYS" get pods -l app.kubernetes.io/component=gpu-simulator --field-selector "spec.nodeName=$1" \
    -o jsonpath='{.items[0].status.podIP}'
}

# dcgm_inject NODE FIELD VALUE: what `dcgmi test --inject` does on a real node, into the fake on NODE.
# The fake keeps the newest sample by its timestamp (injection time plus offset) and refuses an older one, so every
# injection of the cluster's life takes a larger offset than the last; a fixed one let a reset's value 0 block the
# next fault (found rehearsing S2 twice).
dcgm_inject() {
  local ip off
  ip=$(sim_ip "$1") && [ -n "$ip" ] || fail "no gpu-simulator Pod on $1"
  off=$(($(cat "$DRILL_STATE/dcgm-offset" 2>&1 | grep -E '^[0-9]+$' || echo 0) + 900))
  echo "$off" >"$DRILL_STATE/dcgm-offset"
  docker exec "$1" curl -sf -X POST "http://$ip:9400/inject?gpu=0&field=$2&value=$3&offset=$off" || fail "inject $2=$3 on $1"
  echo
}

# holder NAME NODE: a Kueue-admitted one-GPU Job pinned to NODE, as the fragmentation study's holders are.
holder() {
  cat <<EOF | k apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $1
  namespace: $NS
  labels: {kueue.x-k8s.io/queue-name: $QUEUE, drill.lkhun9311.github.io/role: holder}
spec:
  suspend: true
  backoffLimit: 0
  template:
    metadata:
      labels: {drill.lkhun9311.github.io/role: holder}
    spec:
      restartPolicy: Never
      nodeSelector: {kubernetes.io/hostname: $2}
      containers:
        - name: holder
          image: $IMG
          imagePullPolicy: IfNotPresent
          command: ["sleep", "86400"]
          resources: {limits: {nvidia.com/gpu: 1}}
EOF
}

# running_on JOBNAME: the node of the Job's Running Pod, or nothing.
running_on() {
  k -n "$NS" get pods -l "job-name=$1" -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.spec.nodeName}{"\n"}{end}' | head -1
}
