#!/usr/bin/env bash
# Runs experiment A, prefix-aware routing: twelve cells, three routing policies over four frozen traces, two engines.
#
# The registration is docs/superpowers/specs/2026-10-27-prefix-aware-routing-design.md; score.py reads what this
# writes. It is called by hack/eks-gitops-session.sh with STUDY=prefixroute, inside the armed lifecycle once both
# GPU nodes are qualified, and by rehearse-kind.sh against two stub engines. It buys nothing and destroys nothing.
#
# Environment:
#   CONTEXT          kube context (required; never guessed)
#   EXDIR            the session's evidence directory (required); the study writes under $EXDIR/prefix-route-study
#   STUDY_DEADLINE   epoch seconds by which the session must begin its teardown (required)
#   GW_NS            default gpu-platform-control-plane-system
#   WAIT_ENGINE      seconds for two fresh engines to come up (default 1200)
#   FIRST_START      seconds for the engines' first start, before any cell (default 1500; the session budgets it)
#   TEARDOWN_RESERVE seconds kept free before STUDY_DEADLINE (default 2400; the session passes 600)
#   STUDY_REHEARSAL  set to 1 only by rehearse-kind.sh: status is written by that script for stub engines
#   SCORE_ARGS       passed to score.py; only the rehearsal sets it, to its stubs' cache capacity
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
: "${CONTEXT:?CONTEXT must name the cluster}" "${EXDIR:?EXDIR must be set}" "${STUDY_DEADLINE:?STUDY_DEADLINE must be set}"
GW_NS="${GW_NS:-gpu-platform-control-plane-system}"
WAIT_ENGINE="${WAIT_ENGINE:-1200}"
FIRST_START="${FIRST_START:-1500}"
TEARDOWN_RESERVE="${TEARDOWN_RESERVE:-2400}"
STUDY_REHEARSAL="${STUDY_REHEARSAL:-}"
SCORE_ARGS="${SCORE_ARGS:-}"
STUDY_ID=prefix-route-2026-10-27
NS=prefix-route
ENGINES=(qwen-a qwen-b)
COLLECTOR_NS=prefix-route-collector
COLLECTOR_IMAGE="busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
MODEL=Qwen/Qwen2.5-3B-Instruct
# The registered blocks and, per block, the Latin-square arm order (design page, "Each cell"; score.py's ORDER).
BLOCKS=(shared-941 shared-942 shared-943 control-944)
declare -A ORDER=(
  [shared-941]="RoundRobin LeastQueue PrefixAffinity"
  [shared-942]="LeastQueue PrefixAffinity RoundRobin"
  [shared-943]="PrefixAffinity RoundRobin LeastQueue"
  [control-944]="RoundRobin LeastQueue PrefixAffinity"
)
# A cell: two engine starts, 600 s of replay, the idle waits and the export; the registration's 1,500 s.
CELL_BUDGET=1500
OUT="$EXDIR/prefix-route-study"
mkdir -p "$OUT/cells" "$OUT/traces"
printf '%s\n' "$STUDY_ID" >"$OUT/study-id.txt"

k() { kubectl --context "$CONTEXT" --request-timeout=30s "$@"; }
log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$*" | tee -a "$OUT/run.log"; }
# A stop ends the study; the cells already written are kept, and score.py scores every block that completed.
stop() {
  log "STOP: $*"
  printf '%s\n' "$*" >"$OUT/STOPPED"
  # Scored even so: a failure a completed block shows stands whatever stopped the study (design, "Verdict rules").
  # shellcheck disable=SC2086
  python3 "$HERE/score.py" "$OUT" $SCORE_ARGS >"$OUT/verdict.txt" 2>"$OUT/score.err" || true
  exit 1
}
in_collector() { k -n "$COLLECTOR_NS" exec collector -- "$@"; }

# live_one prints "<name> <uid> <ip> <restarts> <ready> <node>" for the one live Pod in a list on stdin, or fails.
live_one() {
  python3 -c '
import json, sys
items = [p for p in json.load(sys.stdin)["items"]
         if not p["metadata"].get("deletionTimestamp") and p.get("status", {}).get("phase") not in ("Succeeded", "Failed")]
if len(items) != 1:
    sys.exit(1)
p = items[0]
cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in p.get("status", {}).get("conditions") or [])
print(p["metadata"]["name"], p["metadata"]["uid"], p.get("status", {}).get("podIP", "-"), cs.get("restartCount", 0),
      "ready" if ready else "notready", p.get("spec", {}).get("nodeName", "-"))
'
}
engine_pods_json() { k -n "$NS" get pod -l "app.kubernetes.io/instance=$1" -o json; }
gateway_pods_json() { k -n "$GW_NS" get pod -l app.kubernetes.io/component=gateway -o json; }

metrics_of() {
  local secs="${2:-10}"
  timeout "$((secs + 1))" kubectl --context "$CONTEXT" -n "$COLLECTOR_NS" exec collector -- \
    wget -qO- -T "$secs" "http://$1/metrics"
}

# engine_load prints running + waiting from an engine's /metrics, or "-" when unreadable.
engine_load() {
  metrics_of "$1:8000" 4 2>>"$OUT/sampler.err" | python3 -c '
import sys
seen, total = set(), 0.0
for line in sys.stdin:
    for s in ("vllm:num_requests_running", "vllm:num_requests_waiting"):
        if line.startswith(s + "{") or line.startswith(s + " "):
            seen.add(s)
            total += float(line.split()[-1])
print(total if len(seen) == 2 else "-")
' || echo -
}

# engine_idle succeeds when the engine has reported nothing running or waiting for ten consecutive seconds.
engine_idle() {
  local ip=$1 limit=$2 quiet=0 t0=$SECONDS
  while ((SECONDS - t0 < limit)); do
    if [[ "$(engine_load "$ip")" == 0.0 ]]; then
      quiet=$((quiet + 1))
      ((quiet >= 10)) && return 0
    else
      quiet=0
    fi
    sleep 1
  done
  return 1
}

# identity writes what must not change across cells: Argo revisions, the gateway's and operator's images, the
# gateway's arguments, and the two GPU nodes the engines run on. The gateway Pod is replaced every cell by design,
# so its UID is not part of it.
identity() {
  {
    k -n argocd get applications.argoproj.io -o json 2>>"$OUT/run.log" || echo '{"items":[]}'
    printf '\n---\n'
    k -n "$GW_NS" get pod -o json
    printf '\n---\n'
    k -n "$NS" get pod -o json
    printf '\n---\n'
    k get nodes -o json
  } | python3 -c '
import json, sys
apps, sys_pods, eng_pods, nodes = (json.loads(x) for x in sys.stdin.read().split("\n---\n"))
out = {"argo": {a["metadata"]["name"]: (a.get("status", {}).get("sync") or {}).get("revision") for a in apps["items"]},
       "images": {}, "gatewayArgs": [], "gpuNodes": []}
for p in sys_pods["items"]:
    if p["metadata"].get("deletionTimestamp"):
        continue
    comp = p["metadata"].get("labels", {}).get("app.kubernetes.io/component") or p["metadata"]["name"]
    if comp == "gateway" or p["metadata"].get("labels", {}).get("control-plane") == "controller-manager":
        role = "gateway" if comp == "gateway" else "operator"
        out["images"][role] = sorted(c.get("imageID", "") for c in p.get("status", {}).get("containerStatuses") or [])
        if role == "gateway":
            out["gatewayArgs"] = [c.get("command", []) + c.get("args", []) for c in p["spec"]["containers"]]
ids = {n["metadata"]["name"]: n["spec"].get("providerID") or n["metadata"]["name"] for n in nodes["items"]}
out["gpuNodes"] = sorted({ids.get(p["spec"].get("nodeName"), "-") for p in eng_pods["items"]
                          if not p["metadata"].get("deletionTimestamp")})
json.dump(out, sys.stdout, sort_keys=True, indent=1)
'
}

# ---------------------------------------------------------------------------------------------------------------
log "study $STUDY_ID on $CONTEXT; tooling at $(git -C "$REPO" rev-parse HEAD), dirty files $(git -C "$REPO" status --porcelain | wc -l)"
git -C "$REPO" rev-parse HEAD >"$OUT/tooling-commit.txt"

# The product must carry the routing field, or every arm would route by the default ordering under a policy's name.
k get crd inferencedeployments.platform.lkhun9311.github.io -o json | python3 -c '
import json, sys
spec = json.load(sys.stdin)["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]
sys.exit(0 if "routing" in spec else 1)' || stop "the cluster's InferenceDeployment CRD has no spec.routing; the product under test predates the routing policies"

log "building the harness"
(cd "$REPO" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/benchharness" ./cmd/benchharness) || stop "harness build"
sha256sum "$OUT/benchharness" | cut -d' ' -f1 >"$OUT/benchharness.sha256"

log "traces"
for block in "${BLOCKS[@]}"; do
  seed="${block#*-}"
  ctl=()
  [[ "$block" == control-* ]] && ctl=(--prefix-control)
  "$OUT/benchharness" gen-trace --study "$STUDY_ID" --arm RoundRobin --seed "$seed" "${ctl[@]}" --model "$MODEL" \
    --trace-out "$OUT/traces/$block.jsonl" --manifest-out "$OUT/traces/$block.manifest.yaml" >>"$OUT/run.log" 2>&1 || stop "gen-trace $block"
done
(cd "$OUT/traces" && sha256sum -c --quiet "$HERE/frozen-traces.sha256") >>"$OUT/run.log" 2>&1 ||
  stop "the regenerated traces do not match frozen-traces.sha256"

log "study objects"
k apply -f "$HERE/study.yaml" >>"$OUT/run.log" 2>&1 || stop "apply study.yaml"
for e in "${ENGINES[@]}"; do
  if ! k -n "$NS" get inferencedeployment "$e" >/dev/null 2>>"$OUT/run.log"; then
    sed "s/NAME/$e/" "$HERE/engine.yaml.tmpl" | k apply -f - >>"$OUT/run.log" 2>&1 || stop "create $e"
    # creationTimestamp has one-second granularity, and the older engine is the gateway's head and fallback order.
    sleep 2
  fi
done
[[ "$(k -n "$NS" get inferencedeployment "${ENGINES[0]}" -o jsonpath='{.metadata.creationTimestamp}')" < \
  "$(k -n "$NS" get inferencedeployment "${ENGINES[1]}" -o jsonpath='{.metadata.creationTimestamp}')" ]] ||
  stop "${ENGINES[0]} is not older than ${ENGINES[1]}"
k get gpuquotapolicy prefix-study-premium -o yaml >"$OUT/tenant-applied.yaml" || stop "read the tenant"
k -n "$NS" get inferencedeployment -o yaml >"$OUT/engines-applied.yaml" || stop "read the engines"
KEY="study-r-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf 'premium-1=%s\n' "$KEY" >"$EXDIR/prefix-study-key.txt"
k -n "$GW_NS" patch secret gateway-api-keys --type merge -p "{\"stringData\":{\"$KEY\":\"premium-1\"}}" >>"$OUT/run.log" 2>&1 ||
  stop "add the study key to gateway-api-keys"

log "collector"
k create namespace "$COLLECTOR_NS" --dry-run=client -o yaml | k apply -f - >>"$OUT/run.log" 2>&1
cat <<EOF | k apply -f - >>"$OUT/run.log" 2>&1 || stop "collector Pod"
apiVersion: v1
kind: Pod
metadata:
  name: collector
  namespace: $COLLECTOR_NS
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
    - name: collector
      image: $COLLECTOR_IMAGE
      command: ["sleep", "86400"]
      resources:
        requests: {cpu: "1", memory: 1Gi}
        limits: {cpu: "1", memory: 1Gi}
EOF
if ! k -n "$COLLECTOR_NS" wait --for=condition=Ready pod/collector --timeout=300s >>"$OUT/run.log" 2>&1; then
  # The paid session of 2026-10-28 stopped here with nothing to say why, and its cluster was destroyed minutes later.
  # These are kept so the next refusal names its cause: scheduling, image pull or the container itself.
  # Each keeps its own error in its file, and a capture that fails must not skip the stop and its scoring.
  k -n "$COLLECTOR_NS" describe pod collector >"$OUT/collector-describe.txt" 2>&1 || true
  k -n "$COLLECTOR_NS" get events -o wide >"$OUT/collector-events.txt" 2>&1 || true
  k describe nodes >"$OUT/nodes-describe.txt" 2>&1 || true
  stop "collector not Ready"
fi
in_collector mkdir -p /study
k -n "$COLLECTOR_NS" cp "$OUT/benchharness" collector:/study/benchharness >>"$OUT/run.log" 2>&1 || stop "copy harness"
in_collector chmod +x /study/benchharness
[[ "$(in_collector sha256sum /study/benchharness | cut -d' ' -f1)" == "$(cat "$OUT/benchharness.sha256")" ]] ||
  stop "the harness in the collector is not the one built"
"$OUT/benchharness" print-prompt --chars 200 >"$OUT/.warmup-prompt.txt" || stop "print-prompt"
python3 -c '
import json, sys
prompt = open(sys.argv[1]).read().rstrip("\n")
json.dump({"model": sys.argv[2], "stream": True, "max_tokens": 16, "min_tokens": 16,
           "messages": [{"role": "user", "content": "Warm-up. " + prompt}]}, open(sys.argv[3], "w"))' \
  "$OUT/.warmup-prompt.txt" "$MODEL" "$OUT/warmup.json"
k -n "$COLLECTOR_NS" cp "$OUT/warmup.json" collector:/study/warmup.json >>"$OUT/run.log" 2>&1 || stop "copy warm-up"

GW_SVC="$(k -n "$GW_NS" get svc -l app.kubernetes.io/component=gateway -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$GW_SVC" ]] || stop "no gateway Service"
GW_URL="http://$GW_SVC.$GW_NS.svc:8080"
# The routing sizes are the gateway's defaults, so any argument means a treatment the registration did not register;
# refused here, before a cell is paid for, as well as by the scorer.
gw_args="$(k -n "$GW_NS" get deploy -l app.kubernetes.io/component=gateway -o json | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
print(json.dumps([c.get("command", []) + c.get("args", []) for d in items for c in d["spec"]["template"]["spec"]["containers"]]))')" ||
  stop "could not read the gateway's arguments"
[[ "$gw_args" == '[["/gateway"]]' ]] || stop "the gateway runs $gw_args, not the registered [[\"/gateway\"]]"

# fresh_engines replaces both engine Pods and the gateway Pod and waits for all three to come back ready, so the cell
# starts with empty KV caches and an empty gateway index. It prints "<a uid> <b uid> <gateway uid>".
fresh_pods() {
  local before_a before_b before_g budget deadline line ua ub ug rda rdb rdg st g c og ok e
  before_a="$(engine_pods_json qwen-a | live_one | cut -d' ' -f2)" || before_a=-
  before_b="$(engine_pods_json qwen-b | live_one | cut -d' ' -f2)" || before_b=-
  before_g="$(gateway_pods_json | live_one | cut -d' ' -f2)" || before_g=-
  for e in "${ENGINES[@]}"; do
    k -n "$NS" delete pod -l "app.kubernetes.io/instance=$e" --wait=false >>"$OUT/run.log" 2>&1 || return 1
  done
  k -n "$GW_NS" delete pod -l app.kubernetes.io/component=gateway --wait=false >>"$OUT/run.log" 2>&1 || return 1
  budget=$((CELL_END - $(date +%s) - 900))
  ((budget > WAIT_ENGINE)) && budget=$WAIT_ENGINE
  ((budget > 0)) || return 1
  deadline=$((SECONDS + budget))
  while ((SECONDS < deadline)); do
    sleep 10
    [[ -n "$STUDY_REHEARSAL" ]] && "$HERE/rehearse-kind.sh" write-status >>"$OUT/run.log" 2>&1
    ok=1
    for e in "${ENGINES[@]}"; do
      st="$(k -n "$NS" get inferencedeployment "$e" \
        -o jsonpath='{.metadata.generation} {.status.conditions[?(@.type=="EngineInForce")].status} {.status.conditions[?(@.type=="EngineInForce")].observedGeneration}' 2>>"$OUT/run.log")" || { ok=""; break; }
      read -r g c og <<<"$st"
      [[ "$c" == True && "$og" == "$g" ]] || { ok=""; break; }
    done
    [[ -n "$ok" ]] || continue
    line="$(engine_pods_json qwen-a | live_one)" || continue
    read -r _ ua _ _ rda _ <<<"$line"
    line="$(engine_pods_json qwen-b | live_one)" || continue
    read -r _ ub _ _ rdb _ <<<"$line"
    line="$(gateway_pods_json | live_one)" || continue
    read -r _ ug _ _ rdg _ <<<"$line"
    if [[ "$rda $rdb $rdg" == "ready ready ready" && "$ua" != "$before_a" && "$ub" != "$before_b" && "$ug" != "$before_g" ]]; then
      return 0
    fi
  done
  return 1
}

# set_policy writes the arm onto both engines' spec and reads it back.
set_policy() {
  local arm=$1 e got
  for e in "${ENGINES[@]}"; do
    k -n "$NS" patch inferencedeployment "$e" --type merge -p "{\"spec\":{\"routing\":{\"policy\":\"$arm\"}}}" >>"$OUT/run.log" 2>&1 || return 1
    got="$(k -n "$NS" get inferencedeployment "$e" -o jsonpath='{.spec.routing.policy}')" || return 1
    [[ "$got" == "$arm" ]] || return 1
  done
}

# The engines' first start pulls the 9.1 GiB image onto both new nodes through one NAT gateway, and one node alone took
# 451 to 493 s in the hold-cap sessions; inside a cell that leaves the replay no room before the cell's end, and a
# failed cell stops the study.
# It is waited for here, outside every cell, and each cell still replaces both engines, so none starts warm.
log "first start of both engines, outside every cell"
first_start_ok=""
first_deadline=$((SECONDS + FIRST_START))
while ((SECONDS < first_deadline)); do
  sleep 10
  [[ -n "$STUDY_REHEARSAL" ]] && "$HERE/rehearse-kind.sh" write-status >>"$OUT/run.log" 2>&1
  line_a="$(engine_pods_json qwen-a | live_one)" || continue
  line_b="$(engine_pods_json qwen-b | live_one)" || continue
  read -r _ _ _ _ rda _ <<<"$line_a"
  read -r _ _ _ _ rdb _ <<<"$line_b"
  if [[ "$rda $rdb" == "ready ready" ]]; then
    first_start_ok=1
    break
  fi
done
[[ -n "$first_start_ok" ]] || stop "the engines' first start did not finish within ${FIRST_START} s"
log "both engines started once"

IDENTITY_DONE=""
for block in "${BLOCKS[@]}"; do
  seed="${block#*-}"
  for arm in ${ORDER[$block]}; do
    name="$block-$arm"
    D="$OUT/cells/$name"
    if (($(date +%s) + CELL_BUDGET + TEARDOWN_RESERVE > STUDY_DEADLINE)); then
      stop "cell $name would not finish before the teardown reserve; the remaining cells are not started"
    fi
    mkdir -p "$D"
    CELL_END=$(($(date +%s) + CELL_BUDGET))
    log "== cell $name, to end by $(date -u -d "@$CELL_END" +%H:%M:%SZ)"
    fail_cell() {
      printf '{"cell":"%s","outcome":"failed: %s"}\n' "$name" "$1" >"$D/cell.json"
      { k -n "$NS" get pod -o wide; k -n "$NS" get events --sort-by=.lastTimestamp; } >"$D/failure-state.txt" 2>&1 || true
      stop "cell $name: $1"
    }
    set_policy "$arm" || fail_cell "could not set routing policy $arm on both engines"
    fresh_pods || fail_cell "no two fresh ready engines and a fresh gateway within the cell's budget"
    read -r A_POD A_UID A_IP A_RS _ _ <<<"$(engine_pods_json qwen-a | live_one)"
    read -r B_POD B_UID B_IP B_RS _ _ <<<"$(engine_pods_json qwen-b | live_one)"
    read -r _ G_UID G_IP G_RS _ _ <<<"$(gateway_pods_json | live_one)"
    # The study's identity is read once both engines exist on their nodes, and every cell after must match it.
    if [[ -z "$IDENTITY_DONE" ]]; then
      identity >"$OUT/identity-start.json" || fail_cell "identity"
      IDENTITY_DONE=1
    fi
    for f in a b; do
      pod="$([[ $f == a ]] && echo "$A_POD" || echo "$B_POD")"
      # The log is saved before it is searched: grep -m1 on a streamed kubectl logs exits at the match, the next write
      # takes SIGPIPE, and pipefail then fails the cell although the line was there, which a 59 KB engine log does.
      k -n "$NS" logs "$pod" >"$D/engine-$f.log" 2>>"$OUT/run.log" || fail_cell "engine $f's log is unreadable"
      grep -m1 'non-default args' "$D/engine-$f.log" >"$D/engine-$f-args.txt" ||
        fail_cell "engine $f logged no non-default args"
    done
    # Readiness of the gateway is its cache sync; its first metrics read is what shows it is serving.
    metrics_of "$G_IP:8081" >/dev/null || fail_cell "the fresh gateway's metrics are unreadable"

    for ip in "$A_IP" "$B_IP"; do
      in_collector wget -qO "/study/warmup-$name-$ip.out" -T 120 --header "Content-Type: application/json" \
        --post-file /study/warmup.json "http://$ip:8000/v1/chat/completions" || fail_cell "the warm-up of $ip failed"
      [[ "$(in_collector grep -c 'data: \[DONE\]' "/study/warmup-$name-$ip.out")" == 1 ]] || fail_cell "the warm-up of $ip did not complete"
    done
    engine_idle "$A_IP" 120 || fail_cell "engine a was not idle before the replay"
    engine_idle "$B_IP" 120 || fail_cell "engine b was not idle before the replay"
    metrics_of "$A_IP:8000" >"$D/metrics-engine-a-before.prom" || fail_cell "engine a metrics before"
    metrics_of "$B_IP:8000" >"$D/metrics-engine-b-before.prom" || fail_cell "engine b metrics before"
    metrics_of "$G_IP:8081" >"$D/metrics-gateway-before.prom" || fail_cell "gateway metrics before"

    ctl=()
    [[ "$block" == control-* ]] && ctl=(--prefix-control)
    E_IMAGE="$(engine_pods_json qwen-a | python3 -c 'import json,sys; p=[p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")][0]; print(p["status"]["containerStatuses"][0]["imageID"].split("://")[-1])')"
    "$OUT/benchharness" gen-trace --study "$STUDY_ID" --arm "$arm" --seed "$seed" "${ctl[@]}" --model "$MODEL" \
      --gateway-url "$GW_URL" --engine-image "$E_IMAGE" \
      --trace-out "$D/trace.jsonl" --manifest-out "$D/manifest.yaml" >>"$OUT/run.log" 2>&1 || fail_cell "gen-trace"
    cmp -s "$D/trace.jsonl" "$OUT/traces/$block.jsonl" || fail_cell "the cell's trace differs from the frozen one"
    k -n "$COLLECTOR_NS" cp "$D/trace.jsonl" "collector:/study/trace-$name.jsonl" >>"$OUT/run.log" 2>&1 || fail_cell "copy trace"
    sed "s|tracePath: .*|tracePath: trace-$name.jsonl|" "$D/manifest.yaml" >"$D/manifest-collector.yaml"
    k -n "$COLLECTOR_NS" cp "$D/manifest-collector.yaml" "collector:/study/manifest-$name.yaml" >>"$OUT/run.log" 2>&1 || fail_cell "copy manifest"

    : >"$D/samples.jsonl"
    (
      while [[ ! -f "$D/.stop-sampling" ]]; do
        t="$(date +%s%N)"
        a="$(engine_pods_json qwen-a 2>>"$D/sampler.err" | live_one 2>>"$D/sampler.err" || echo "- - - - - -")"
        b="$(engine_pods_json qwen-b 2>>"$D/sampler.err" | live_one 2>>"$D/sampler.err" || echo "- - - - - -")"
        g="$(gateway_pods_json 2>>"$D/sampler.err" | live_one 2>>"$D/sampler.err" || echo "- - - - - -")"
        la="$(engine_load "$A_IP")"
        lb="$(engine_load "$B_IP")"
        python3 -c '
import json, sys
t, a, b, g, la, lb = sys.argv[1:7]
a, b, g = a.split(), b.split(), g.split()
num = lambda x: float(x) if x != "-" else None
print(json.dumps({"t": int(t), "engineAUID": a[1], "engineARestarts": a[3], "engineBUID": b[1], "engineBRestarts": b[3],
                  "gatewayUID": g[1], "gatewayRestarts": g[3], "engineALoad": num(la), "engineBLoad": num(lb)}))' \
          "$t" "$a" "$b" "$g" "$la" "$lb" >>"$D/samples.jsonl" || true
        sleep 5
      done
    ) &
    SAMPLER=$!
    python3 -c 'import json,sys; json.dump(dict(cell=sys.argv[1], outcome="running", startedUnixNanos=int(sys.argv[2]),
        engineAUID=sys.argv[3], engineARestarts=sys.argv[4], engineBUID=sys.argv[5], engineBRestarts=sys.argv[6],
        gatewayUID=sys.argv[7], gatewayRestarts=sys.argv[8]), open(sys.argv[9], "w"), indent=1, sort_keys=True)' \
      "$name" "$(date +%s%N)" "$A_UID" "$A_RS" "$B_UID" "$B_RS" "$G_UID" "$G_RS" "$D/cell.json"
    in_collector sh -c "cd /study && rm -f replay-$name.rc && (nohup ./benchharness replay --manifest manifest-$name.yaml \
      --request-id-prefix study-$name --target $GW_URL --api-keys premium-1=$KEY \
      --raw-out raw-$name.jsonl >replay-$name.log 2>&1; echo \$? >replay-$name.rc) >/dev/null 2>&1 &" ||
      { touch "$D/.stop-sampling"; wait "$SAMPLER"; fail_cell "could not start the replay"; }
    rc=""
    while (($(date +%s) < CELL_END - 300)); do
      sleep 10
      rc="$(in_collector cat "/study/replay-$name.rc" 2>/dev/null || true)"
      [[ -n "$rc" ]] && break
    done
    touch "$D/.stop-sampling"
    wait "$SAMPLER" || true
    rm -f "$D/.stop-sampling"
    [[ "$rc" == 0 ]] || fail_cell "the replay exited '${rc:-without finishing}'"
    engine_idle "$A_IP" 120 || log "cell $name: engine a was not idle 120 s after the replay; the after metrics are read anyway"
    engine_idle "$B_IP" 120 || log "cell $name: engine b was not idle 120 s after the replay; the after metrics are read anyway"
    metrics_of "$A_IP:8000" >"$D/metrics-engine-a-after.prom" || fail_cell "engine a metrics after"
    metrics_of "$B_IP:8000" >"$D/metrics-engine-b-after.prom" || fail_cell "engine b metrics after"
    metrics_of "$G_IP:8081" >"$D/metrics-gateway-after.prom" || fail_cell "gateway metrics after"
    for f in "raw-$name.jsonl:raw.jsonl" "raw-$name.jsonl.sender.json:raw.jsonl.sender.json" "replay-$name.log:replay.log"; do
      k -n "$COLLECTOR_NS" cp "collector:/study/${f%%:*}" "$D/${f##*:}" >>"$OUT/run.log" 2>&1 || fail_cell "copy ${f%%:*}"
    done
    [[ "$(in_collector sha256sum "/study/raw-$name.jsonl" | cut -d' ' -f1)" == "$(sha256sum "$D/raw.jsonl" | cut -d' ' -f1)" ]] ||
      fail_cell "the copied raw rows differ from the collector's"
    identity >"$D/identity-after.json" || fail_cell "identity after"
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["outcome"]="complete"; d["endedUnixNanos"]=int(sys.argv[2]); json.dump(d, open(sys.argv[1],"w"), indent=1, sort_keys=True)' \
      "$D/cell.json" "$(date +%s%N)"
    (cd "$D" && sha256sum raw.jsonl raw.jsonl.sender.json samples.jsonl metrics-*.prom engine-*-args.txt manifest.yaml trace.jsonl identity-after.json cell.json >SHA256SUMS)
    log "cell $name complete: $(wc -l <"$D/raw.jsonl") rows, $(wc -l <"$D/samples.jsonl") samples"
    if ! cmp -s <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({k: d[k] for k in ("argo","images","gatewayArgs","gpuNodes")}, sort_keys=True))' "$D/identity-after.json") \
      <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({k: d[k] for k in ("argo","images","gatewayArgs","gpuNodes")}, sort_keys=True))' "$OUT/identity-start.json"); then
      stop "the product's identity changed after cell $name"
    fi
  done
done

log "all twelve cells complete; scoring"
# score.py exits 0 for "observed on these traces" and 1 for any other verdict: both are verdicts, and the run that
# produced them succeeded. Anything else, or no verdict line, means the evidence could not be scored.
set +e
# shellcheck disable=SC2086
python3 "$HERE/score.py" "$OUT" $SCORE_ARGS >"$OUT/verdict.txt" 2>"$OUT/score.err"
rc=$?
set -e
tee -a "$OUT/run.log" <"$OUT/verdict.txt"
if [[ "$rc" != 0 && "$rc" != 1 ]] || ! head -1 "$OUT/verdict.txt" | grep -q '^verdict: '; then
  stop "the scorer exited $rc without a verdict; see score.err"
fi
exit 0
