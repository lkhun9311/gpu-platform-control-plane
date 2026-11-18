# shellcheck shell=bash
# Helpers shared by observe.sh and probes.sh: where the lab is, how to reach its EPP and simulator pods, and how to
# record a snapshot. A caller sets SAY_AS, calls lab_init, and then sets ARM (via fresh_arm) before snap or drive.

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LAB=$REPO/hack/llmd-kv-lab.sh
LAB_HOME=${LAB_HOME:-$REPO/tmp/llmd-kv-lab}
export KUBECONFIG=$LAB_HOME/kubeconfig
CLUSTER=gpuaas-llmd-kv-lab
CTX=kind-$CLUSTER
NODE=$CLUSTER-control-plane
EPP=tinyllama-1-1b-chat-v1-0-endpoint-picker
GATEWAY=http://127.0.0.1:${GATEWAY_HOST_PORT:-30598}
PROXY_PORT=${PROXY_PORT:-18598}
PROXY=http://127.0.0.1:$PROXY_PORT
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
RUN=$REPO/hack/llmd-kv-lab/runs/$STAMP
DRIVER=$LAB_HOME/driver

k() { kubectl --context "$CTX" --request-timeout=30s "$@"; }
say() { echo "${SAY_AS:-lab}: $*" | tee -a "$RUN/observe.log"; }

lab_init() {
  # Ownership is checked before any cleanup is armed, so a run refused on someone else's cluster leaves it untouched.
  k -n kube-system get configmap gpuaas-llmd-kv-lab-owner >/dev/null 2>&1 \
    || { echo "lab: $CTX has no gpuaas-llmd-kv-lab-owner marker; not running probes against a cluster this lab did not create" >&2; exit 1; }
  # A run's evidence is written once; a reused STAMP is refused before anything in it is touched.
  [ ! -e "$RUN" ] || { echo "lab: $RUN exists; use a new STAMP rather than overwrite a recorded run" >&2; exit 1; }
  mkdir -p "$RUN"
  go build -o "$DRIVER" "$REPO/hack/llmd-kv-lab/driver"
  "$LAB" pins >"$RUN/pins.txt"
  "$LAB" check >>"$RUN/pins.txt"
  # The API server proxy reaches the EPP's metrics port and each simulator pod without a port-forward per target.
  # kubectl is started directly, not through k, so $! is the proxy itself and cleanup stops it rather than a wrapper.
  kubectl --context "$CTX" proxy --port="$PROXY_PORT" >"$RUN/kubectl-proxy.log" 2>&1 &
  PROXY_PID=$!
  trap lab_cleanup EXIT
  # The proxy must be this run's and must reach this lab's cluster: a port already taken would leave every request to
  # whatever already listens there, possibly a proxy for another cluster.
  local _
  for _ in $(seq 1 20); do
    kill -0 "$PROXY_PID" 2>/dev/null || { echo "lab: kubectl proxy exited (port $PROXY_PORT taken?); see $RUN/kubectl-proxy.log" >&2; exit 1; }
    # Only this proxy's own "Starting to serve" line shows it holds the port; an answer alone could come from a listener
    # that was there first while this one is still failing to bind.
    if grep -q "Starting to serve on 127.0.0.1:$PROXY_PORT" "$RUN/kubectl-proxy.log" 2>/dev/null \
      && curl -sf -o /dev/null "$PROXY/api/v1/namespaces/kube-system/configmaps/gpuaas-llmd-kv-lab-owner"; then
      return 0
    fi
    sleep 0.5
  done
  echo "lab: the proxy on $PROXY_PORT never reached this lab's cluster" >&2
  exit 1
}

# FW_TAG marks this run's firewall rules, so cleanup removes exactly them and never an identical rule another run added.
FW_TAG=llmd-kv-lab-$STAMP-$$

lab_cleanup() {
  kill "$PROXY_PID" 2>/dev/null || true
  # A blocked ZMQ path must never outlive the run, or the next run would measure it without knowing.
  # A rule left behind turns the run's exit into a failure, so nobody reads a finished run as clean.
  fw_remove_own || { echo "lab: firewall cleanup failed; check $NODE's FORWARD chain for $FW_TAG" >&2; exit 1; }
}

# fw_block inserts this run's two DROP rules for the ZMQ port, each carrying FW_TAG; -w waits for the xtables lock.
fw_block() {
  docker exec "$NODE" iptables -w -I FORWARD -p tcp --dport 5557 -m comment --comment "$FW_TAG" -j DROP
  docker exec "$NODE" iptables -w -I FORWARD -p tcp --sport 5557 -m comment --comment "$FW_TAG" -j DROP
}

# fw_own_rules lists the FORWARD rules carrying FW_TAG, and fails when the chain cannot be read at all.
fw_own_rules() {
  local listing
  listing=$(docker exec "$NODE" iptables -w -S FORWARD) || return 1
  grep -F -- "--comment $FW_TAG " <<<"$listing" || true
}

# fw_remove_own deletes every FORWARD rule carrying FW_TAG and nothing else, then fails unless none is left.
#
# No tagged rule left is the normal end of a run, so an empty match is success; a rule that stays, or a chain that
# cannot be read, is a failure, because a recovery measured behind a DROP rule would be measuring the block.
fw_remove_own() {
  local rules rule
  rules=$(fw_own_rules) || { echo "lab: cannot read $NODE's FORWARD chain; the ZMQ path may still be blocked" >&2; return 1; }
  while read -r rule; do
    [ -n "$rule" ] || continue
    # shellcheck disable=SC2086 # the rule spec is split into iptables arguments on purpose
    docker exec "$NODE" iptables -w ${rule/#-A /-D } || true
  done <<<"$rules"
  rules=$(fw_own_rules) || { echo "lab: cannot re-read $NODE's FORWARD chain after removal" >&2; return 1; }
  [ -z "$rules" ] || { echo "lab: tagged DROP rules remain in $NODE: $rules" >&2; return 1; }
}

svc() { echo "$PROXY/api/v1/namespaces/default/services/http:$EPP:9090/proxy"; }
pod_url() { echo "$PROXY/api/v1/namespaces/default/pods/http:$1:8000/proxy"; }
sim_pods() { k get pods -l llm-d.ai/component=decode --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort; }

# snap NAME: the EPP's KV-event and index counters and its plugin state, plus each simulator's prefix-cache counters.
snap() {
  local dir=$RUN/$ARM/snap-$1
  mkdir -p "$dir"
  curl -sf "$(svc)/metrics" | grep -E '^llm_d_epp_kv_cache_(events|index)_' | grep -v '_bucket' >"$dir/epp-kv-metrics.txt" || true
  curl -sf "$(svc)/debug/plugins/state" >"$dir/epp-plugin-state.json" || echo '{}' >"$dir/epp-plugin-state.json"
  for p in $(sim_pods); do
    curl -sf "$(pod_url "$p")/metrics" | grep -E '^vllm:(prefix_cache_(hits|queries)_total|kv_cache_usage_perc)' \
      | sed "s/^/$p /" >>"$dir/sim-metrics.txt" || true
  done
  # Each simulator's TCP state on port 5557, read in its own network namespace, because a connection to a vanished
  # EPP pod stays ESTABLISHED with a growing Send-Q and nothing else reports it.
  docker exec "$NODE" sh -c 'for c in $(crictl ps --name vllm -q); do
      pod=$(crictl inspect --output go-template --template "{{index .status.labels \"io.kubernetes.pod.name\"}}" $c)
      pid=$(crictl inspect --output go-template --template "{{.info.pid}}" $c)
      nsenter -t $pid -n ss -tnH "( dport = :5557 or sport = :5557 )" | sed "s/^/$pod /"
    done' >"$dir/sim-zmq-sockets.txt" 2>&1 || true
}

drive() { # drive STEP TARGET_URL TARGET_LABEL PLAN [GAP]
  "$DRIVER" -url "$2" -target "$3" -plan "$4" -gap "${5:-300ms}" -tag "$ARM-$1" -out "$RUN/$ARM/requests.jsonl" \
    || say "driver reported failed requests in step $1"
}

# The newest EPP pod, because during a restart the label also matches the one that is terminating.
epp_pod() { k get pods -l app=$EPP --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}'; }

eof_count() { k logs "$(epp_pod)" | grep -c 'Failed to receive message from zmq subscriber' || true; }

wait_epp_ready() {
  k rollout status deployment/$EPP --timeout=180s >/dev/null
  # The EPP serves only after it has listed the pool's endpoints; a request before that is routed by nothing.
  local _
  for _ in $(seq 1 60); do
    curl -sf -o /dev/null "$GATEWAY/v1/models" && return 0
    sleep 2
  done
  say "gateway never answered /v1/models after the EPP became ready"
  return 1
}

fresh_arm() {
  ARM=$1
  # An arm's evidence is written once: a reused STAMP would append to its requests and overwrite its logs and snapshots.
  [ ! -e "$RUN/$ARM" ] || { echo "lab: $RUN/$ARM exists; use a new STAMP rather than mixing two executions" >&2; exit 1; }
  mkdir -p "$RUN/$ARM"
  say "=== arm $ARM: EPP on the $ARM config, then fresh simulator pods"
  # mode restarts the EPP first and the simulators second; the reverse order left every push-mode simulator
  # connected to the EPP pod that mode had just replaced (run 20261115-run1).
  "$LAB" mode "$ARM" | tee -a "$RUN/observe.log"
  # Terminating pods still answer the label selector for a while; wait until only the new ReplicaSet's pods remain.
  local _
  for _ in $(seq 1 60); do
    [ "$(k get pods -l llm-d.ai/component=decode --no-headers | wc -l)" = "${LAB_SIM_REPLICAS:-3}" ] && break
    sleep 2
  done
  wait_epp_ready
  sim_pods >"$RUN/$ARM/sim-pods.txt"
  epp_pod >"$RUN/$ARM/epp-pod-1.txt"
  sleep 5
}

save_epp_log() { k logs "$1" >"$RUN/$ARM/epp-$2.log" 2>&1 || true; }

family_pod() { # the pod that served the last gateway request of family $1 in this arm
  python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
rows=[r for r in rows if r["family"]==sys.argv[2] and r["target"]=="gateway" and r["pod"]]
print(rows[-1]["pod"] if rows else "")' "$RUN/$ARM/requests.jsonl" "$1"
}

other_pod() { # a simulator pod that is none of the pods given
  local p
  for p in $(sim_pods); do
    case " $* " in *" $p "*) ;; *) echo "$p"; return ;; esac
  done
}
