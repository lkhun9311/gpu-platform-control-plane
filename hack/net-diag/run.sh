#!/usr/bin/env bash
# Reproduces the cases of docs/superpowers/specs/2026-11-07-network-diagnosis-cases-design.md on a throwaway kind
# cluster. Usage: hack/net-diag/run.sh [OUT_DIR]; REPS (default 3) and KEEP_CLUSTER=1 are honoured.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NODE_IMAGE='kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5'
NETSHOOT='nicolaka/netshoot@sha256:7f08c4aff13ff61a35d30e30c5c1ea8396eac6ab4ce19fd02d5a4b3b5d0d09a2'
REPS="${REPS:-3}"
OUT="${1:-$REPO/hack/net-diag-$(date -u +%Y%m%dT%H%M%SZ)}"
CLUSTER=netdiag
CTX="kind-$CLUSTER"
CASES=(b n1a n1b n2a n2b n3a n3b)

# A directory holding an earlier run would mix its probes into this one's verdict.
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  echo "refuse: $OUT is not empty; give a new directory" >&2
  exit 1
fi
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

# Only a cluster this invocation created is deleted: one already there belongs to someone else or to a kept run.
CREATED=0
cleanup() {
  if [ "$CREATED" = 1 ] && [ "${KEEP_CLUSTER:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER"; fi
}
trap cleanup EXIT
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "refuse: cluster $CLUSTER already exists; delete it first so its state is this run's" >&2
  exit 1
fi
CREATED=1
kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --wait 180s
docker exec "$CLUSTER-control-plane" crictl pull "docker.io/$NETSHOOT" > /dev/null

k() { kubectl --context "$CTX" "$@"; }

{
  echo "kubelet $(docker exec "$CLUSTER-control-plane" kubelet --version)"
  echo "kube_proxy_$(k -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode:')"
  echo "kindnet $(k -n kube-system get ds kindnet -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "coredns $(k -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "netshoot $NETSHOOT"
} > "$OUT/versions.txt"

k apply -f - > /dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: server, labels: {app: server}}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: s
    image: $NETSHOOT
    imagePullPolicy: IfNotPresent
    command: ["python3", "-m", "http.server", "8080"]
    securityContext: {capabilities: {add: ["NET_ADMIN"]}}
---
apiVersion: v1
kind: Service
metadata: {name: server}
spec: {selector: {app: server}, ports: [{port: 80, targetPort: 8080}]}
---
apiVersion: v1
kind: Pod
metadata: {name: client, labels: {role: client}}
spec:
  terminationGracePeriodSeconds: 1
  containers:
  - name: c
    image: $NETSHOOT
    imagePullPolicy: IfNotPresent
    command: ["sleep", "infinity"]
    securityContext: {capabilities: {add: ["NET_ADMIN", "NET_RAW"]}}
EOF
k wait --for=condition=Ready pod/server pod/client --timeout=180s > /dev/null
SERVER_IP="$(k get pod server -o jsonpath='{.status.podIP}')"
{
  echo "server_ip $SERVER_IP"
  echo "kernel $(uname -r)"
  echo "curl $(k exec client -- curl -V | head -1)"
  echo "libc $(k exec client -- apk info -e -v musl)"
  echo "curl_resolver $(k exec client -- curl -V | grep -o 'c-ares/[0-9.]*' || echo none)"
  echo "tcp_syn_retries $(k exec client -- cat /proc/sys/net/ipv4/tcp_syn_retries)"
  echo "resolv_conf $(k exec client -- cat /etc/resolv.conf | tr '\n' ';')"
} >> "$OUT/versions.txt"

# probe DIR NAME URL TIMEOUT: one captured request from the client, into DIR/NAME.txt.
probe() {
  k exec -i client -- env URL="$3" TIMEOUT="$4" bash -s < "$HERE/probe.sh" > "$1/$2.txt" 2>&1 || echo "exec_exit=$?" >> "$1/$2.txt"
}

# burst DIR NAME N: N requests one after another from the client, into DIR/NAME.txt.
burst() {
  k exec -i client -- env URL=http://server/ N="$3" bash -s < "$HERE/burst.sh" > "$1/$2.txt" 2>&1 || echo "exec_exit=$?" >> "$1/$2.txt"
}

# reject_rules COMMENT: how many of kube-proxy's REJECT rules on the node carry COMMENT, which it writes for a Service
# with no endpoints; read so a probe is not taken before kube-proxy has acted on the empty slice.
reject_rules() {
  docker exec "$CLUSTER-control-plane" iptables-save -t filter | grep -c -- "$1" || true
}

# dns_answers: whether the client gets an answer from the cluster DNS within 1 s, 0 or 1.
dns_answers() {
  if k exec client -- dig +time=1 +tries=1 +short kubernetes.default.svc.cluster.local > /dev/null; then echo 1; else echo 0; fi
}

# server_retrans: the server namespace's absolute TCP retransmit counter.
server_retrans() {
  k exec server -- nstat -asz TcpRetransSegs | awk '/TcpRetransSegs/{print $2}'
}

# ready_endpoints SERVICE NAMESPACE: how many ready endpoints the Service's EndpointSlices hold now.
ready_endpoints() {
  k -n "$2" get endpointslices -l "kubernetes.io/service-name=$1" -o json |
    python3 -c 'import json,sys; print(sum(1 for s in json.load(sys.stdin)["items"] for e in (s.get("endpoints") or []) if (e.get("conditions") or {}).get("ready")))'
}

# all_endpoints SERVICE NAMESPACE: how many endpoints the Service's EndpointSlices hold now, ready or not.
# A terminating Pod that still serves stays in the slice, and kube-proxy sends traffic to it once no endpoint is ready,
# so "no ready endpoint" is not yet "nothing answers" (seen on the first rehearsal: CoreDNS scaled to 0 still answered).
all_endpoints() {
  k -n "$2" get endpointslices -l "kubernetes.io/service-name=$1" -o json |
    python3 -c 'import json,sys; print(sum(len(s.get("endpoints") or []) for s in json.load(sys.stdin)["items"]))'
}

# until_endpoints SERVICE NAMESPACE WANT: polls up to 60 s for the Service to hold no endpoint at all (WANT 0) or a
# ready one (WANT 1).
until_endpoints() {
  local i
  for i in $(seq 1 60); do
    if [ "$3" = 0 ] && [ "$(all_endpoints "$1" "$2")" = 0 ]; then return 0; fi
    if [ "$3" != 0 ] && [ "$(ready_endpoints "$1" "$2")" -gt 0 ]; then return 0; fi
    sleep 1
  done
  return 1
}

run_case() {
  local case=$1 rep=$2 dir="$OUT/$1-r$2" t0
  mkdir -p "$dir"
  t0=$(date +%s)
  case "$case" in
    b)
      probe "$dir" probe http://server/ 10
      # The no-loss batch N2b's latency is read against.
      burst "$dir" burst 40
      ;;
    n1a)
      k -n kube-system scale deploy coredns --replicas=0 > /dev/null
      k -n kube-system wait --for=delete pod -l k8s-app=kube-dns --timeout=120s > /dev/null || true
      until_endpoints kube-dns kube-system 0 || true
      for _ in $(seq 1 30); do [ "$(reject_rules 'kube-system/kube-dns:dns has no endpoints')" -gt 0 ] && break; sleep 1; done
      echo "kube_dns_endpoints=$(all_endpoints kube-dns kube-system) kube_dns_pods=$(k -n kube-system get pod -l k8s-app=kube-dns -o name | wc -l) reject_rules=$(reject_rules 'kube-system/kube-dns:dns has no endpoints')" > "$dir/fault.txt"
      probe "$dir" probe http://server/ 20
      k -n kube-system scale deploy coredns --replicas=2 > /dev/null
      k -n kube-system rollout status deploy coredns --timeout=120s > /dev/null
      until_endpoints kube-dns kube-system 1 || true
      # A ready endpoint is not yet a dataplane without the REJECT rule (the second rehearsal's recovery hit it).
      for _ in $(seq 1 30); do [ "$(reject_rules 'kube-system/kube-dns:dns has no endpoints')" = 0 ] && break; sleep 1; done
      echo "reject_rules=$(reject_rules 'kube-system/kube-dns:dns has no endpoints') dns_answers=$(dns_answers)" > "$dir/removal.txt"
      probe "$dir" recovery http://server/ 10
      ;;
    n1b)
      k apply -f - > /dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: client-only-to-server}
spec:
  podSelector: {matchLabels: {role: client}}
  policyTypes: [Egress]
  egress:
  - to: [{podSelector: {matchLabels: {app: server}}}]
EOF
      # A policy object is not its enforcement: wait until DNS stops answering, and show the server is still reachable.
      local enforced=0
      for _ in $(seq 1 30); do [ "$(dns_answers)" = 0 ] && { enforced=1; break; }; sleep 1; done
      {
        k get networkpolicy client-only-to-server -o jsonpath='policy={.metadata.name}{"\n"}'
        echo "policy_enforced=$enforced"
        echo "direct_server_http=$(k exec client -- curl -q -s --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' "http://$SERVER_IP:8080/" || true)"
      } > "$dir/fault.txt"
      probe "$dir" probe http://server/ 30
      k delete networkpolicy client-only-to-server > /dev/null
      local restored=0
      for _ in $(seq 1 30); do [ "$(dns_answers)" = 1 ] && { restored=1; break; }; sleep 1; done
      echo "dns_restored=$restored" > "$dir/removal.txt"
      probe "$dir" recovery http://server/ 10
      ;;
    n2a | n2b)
      local loss=100%
      [ "$case" = n2b ] && loss=30%
      k exec server -- tc qdisc add dev eth0 root netem loss "$loss"
      k exec server -- tc qdisc show dev eth0 > "$dir/fault.txt"
      echo "server_retrans_before=$(server_retrans)" >> "$dir/fault.txt"
      if [ "$case" = n2a ]; then
        probe "$dir" probe http://server/ 8
      else
        burst "$dir" burst 40
      fi
      echo "server_retrans_after=$(server_retrans)" >> "$dir/fault.txt"
      k exec server -- tc qdisc del dev eth0 root
      k exec server -- tc qdisc show dev eth0 > "$dir/removal.txt"
      probe "$dir" recovery http://server/ 10
      [ "$case" = n2b ] && burst "$dir" recovery-burst 20
      ;;
    n3a)
      k label pod server app=elsewhere --overwrite > /dev/null
      until_endpoints server default 0 || true
      for _ in $(seq 1 30); do [ "$(reject_rules 'default/server has no endpoints')" -gt 0 ] && break; sleep 1; done
      echo "server_endpoints=$(all_endpoints server default) reject_rules=$(reject_rules 'default/server has no endpoints')" > "$dir/fault.txt"
      probe "$dir" probe http://server/ 8
      k label pod server app=server --overwrite > /dev/null
      until_endpoints server default 1 || true
      for _ in $(seq 1 30); do [ "$(reject_rules 'default/server has no endpoints')" = 0 ] && break; sleep 1; done
      echo "reject_rules=$(reject_rules 'default/server has no endpoints')" > "$dir/removal.txt"
      probe "$dir" recovery http://server/ 10
      ;;
    n3b)
      k exec server -- ss -ltnH > "$dir/fault.txt"
      probe "$dir" probe "http://$SERVER_IP:8081/" 8
      probe "$dir" recovery "http://$SERVER_IP:8080/" 10
      ;;
  esac
  printf '{"case": "%s", "rep": %s, "t_start": %s, "t_end": %s, "server_ip": "%s"}\n' "$case" "$rep" "$t0" "$(date +%s)" "$SERVER_IP" > "$dir/case.json"
  echo "case $case-r$rep done"
}

# A Ready server Pod is not yet a Service that answers: the third rehearsal's baseline met kube-proxy's REJECT rule for the
# new Service. The cases start only once the rule is gone and a request succeeds, both recorded.
for _ in $(seq 1 60); do [ "$(reject_rules 'default/server has no endpoints')" = 0 ] && break; sleep 1; done
warm=000
for _ in $(seq 1 30); do
  warm="$(k exec client -- curl -q -s --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' http://server/ || true)"
  [ "$warm" = 200 ] && break
  sleep 1
done
echo "warm_up reject_rules=$(reject_rules 'default/server has no endpoints') http=$warm" >> "$OUT/versions.txt"
if [ "$warm" != 200 ]; then
  echo "refuse: the server Service never answered before the cases" >&2
  exit 1
fi

# Written before the first case, so a run that stops early is scored against what it meant to do.
printf '{"cases": [%s], "reps": %s}\n' "$(printf '"%s",' "${CASES[@]}" | sed 's/,$//')" "$REPS" > "$OUT/schedule.json"

for rep in $(seq 1 "$REPS"); do
  for case in "${CASES[@]}"; do
    run_case "$case" "$rep"
  done
done

python3 "$HERE/check.py" "$OUT"
