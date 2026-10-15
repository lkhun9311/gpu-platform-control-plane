#!/usr/bin/env bash
# Runs the hold-cap product transfer study's six cells on a cluster whose serving bundle is already in force.
#
# The registration is docs/superpowers/specs/2026-10-15-holdcap-on-the-product-path-design.md; score.py reads what
# this writes. It is called by hack/eks-gitops-session.sh with STUDY=holdcap, inside the armed lifecycle and after
# serve-ready, and by rehearse-kind.sh against a stub.
#
# Environment:
#   CONTEXT          kube context (required; never guessed)
#   EXDIR            the session's evidence directory (required); the study writes under $EXDIR/holdcap-study
#   STUDY_DEADLINE   epoch seconds by which the session must begin its teardown (required)
#   SERVE_NS         default serve-a;  SERVE_INFD default qwen25-3b-holdcap;  GW_NS default gpu-platform-control-plane-system
#   WAIT_ENGINE      seconds for a fresh engine to come up in its mode (default 1200)
#   STUDY_REHEARSAL  set to 1 only by rehearse-kind.sh: the mode is switched by that script against a stub engine
#   TEARDOWN_RESERVE seconds kept free before STUDY_DEADLINE (default 2400; the session passes 600)
#   STUDY_ID         which registered run this is (default the re-run, holdcap-product-transfer-r2-2026-10-15);
#                    every row is stamped with it and score.py reads it back from study-id.txt
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
: "${CONTEXT:?CONTEXT must name the cluster}" "${EXDIR:?EXDIR must be set}" "${STUDY_DEADLINE:?STUDY_DEADLINE must be set}"
SERVE_NS="${SERVE_NS:-serve-a}"
SERVE_INFD="${SERVE_INFD:-qwen25-3b-holdcap}"
GW_NS="${GW_NS:-gpu-platform-control-plane-system}"
WAIT_ENGINE="${WAIT_ENGINE:-1200}"
STUDY_REHEARSAL="${STUDY_REHEARSAL:-}"
COLLECTOR_NS=holdcap-study
COLLECTOR_IMAGE="busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
SEEDS=(851 852 853)
# The registration's per-cell budget and the teardown reserve; a cell is not started unless both still fit.
CELL_BUDGET=1500
TEARDOWN_RESERVE="${TEARDOWN_RESERVE:-2400}"
STUDY_ID="${STUDY_ID:-holdcap-product-transfer-r2-2026-10-15}"
OUT="$EXDIR/holdcap-study"
mkdir -p "$OUT/cells"
printf '%s\n' "$STUDY_ID" >"$OUT/study-id.txt"

k() { kubectl --context "$CONTEXT" --request-timeout=30s "$@"; }
log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$*" | tee -a "$OUT/run.log"; }
# A stop ends the study; the cells already written are kept and score.py reads the rest as missing.
stop() {
  log "STOP: $*"
  printf '%s\n' "$*" >"$OUT/STOPPED"
  exit 1
}
in_collector() { k -n "$COLLECTOR_NS" exec collector -- "$@"; }

# The arm order the registration fixes: sha256("<seed>/<arm>") ascending.
order() {
  local seed=$1
  for arm in Off HoldCap; do printf '%s %s\n' "$(printf '%s/%s' "$seed" "$arm" | sha256sum | cut -d' ' -f1)" "$arm"; done |
    sort | cut -d' ' -f2
}

engine_pods_json() { k -n "$SERVE_NS" get pod -l "app.kubernetes.io/instance=$SERVE_INFD" -o json; }
gateway_pods_json() { k -n "$GW_NS" get pod -l app.kubernetes.io/component=gateway -o json; }

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

metrics_of() { in_collector wget -qO- -T 10 "http://$1/metrics"; }

# rehearsal_ref returns an image reference unchanged, except that on kind a side-loaded image can report a bare
# sha256 ID with no repository; a rehearsal names it as local/<role> so the manifest's digest check still applies.
# On EKS every image is pulled by digest and the reference is never rewritten.
rehearsal_ref() {
  local ref=$1 role=$2
  if [[ -n "$STUDY_REHEARSAL" && "$ref" == sha256:* ]]; then
    printf 'local/%s@%s\n' "$role" "$ref"
  else
    printf '%s\n' "$ref"
  fi
}

# backend_modes prints "<backend mode> <process mode>" read from the gateway's own metrics.
backend_modes() {
  local gw_ip=$1
  metrics_of "$gw_ip:8081" | python3 -c '
import re, sys
ns, name = sys.argv[1], sys.argv[2]
backend = process = "-"
for line in sys.stdin:
    m = re.match(r"gpuaas_gateway_backend_admission_mode\{([^}]*)\}\s+1(\.0)?\s*$", line)
    if m:
        labels = dict(kv.split("=", 1) for kv in m.group(1).split(","))
        labels = {k: v.strip("\"") for k, v in labels.items()}
        if labels.get("namespace") == ns and labels.get("name") == name:
            backend = labels.get("mode", "-")
    m = re.match(r"gpuaas_gateway_admission_mode_active\{mode=\"([^\"]+)\"\}\s+1(\.0)?\s*$", line)
    if m:
        process = m.group(1)
print(backend, process)
' "$SERVE_NS" "$SERVE_INFD"
}

# engine_idle succeeds when the engine has reported nothing running or waiting for ten consecutive seconds.
engine_idle() {
  local ip=$1 limit=$2 quiet=0 t0=$SECONDS
  while ((SECONDS - t0 < limit)); do
    if metrics_of "$ip:8000" | python3 -c '
import sys
total = 0.0
seen = set()
for line in sys.stdin:
    for s in ("vllm:num_requests_running", "vllm:num_requests_waiting"):
        if line.startswith(s + "{") or line.startswith(s + " "):
            seen.add(s)
            total += float(line.split()[-1])
sys.exit(0 if len(seen) == 2 and total == 0 else 1)
'; then
      quiet=$((quiet + 1))
      ((quiet >= 10)) && return 0
    else
      quiet=0
    fi
    sleep 1
  done
  return 1
}

# identity writes what the registration freezes: Argo revisions, operator and gateway images, Pods and restarts,
# the gateway's arguments, and the node the engine runs on.
identity() {
  local node=$1
  {
    k -n argocd get applications.argoproj.io -o json 2>/dev/null || echo '{"items":[]}'
    printf '\n---\n'
    k -n "$GW_NS" get pod -o json
    printf '\n---\n'
    k get node "$node" -o json
  } | python3 -c '
import json, sys
apps, pods, node = sys.stdin.read().split("\n---\n")
out = {"argo": {a["metadata"]["name"]: (a.get("status", {}).get("sync") or {}).get("revision") for a in json.loads(apps)["items"]},
       "pods": {}, "node": json.loads(node)["spec"].get("providerID") or json.loads(node)["metadata"]["name"]}
for p in json.loads(pods)["items"]:
    if p["metadata"].get("deletionTimestamp"):
        continue
    comp = p["metadata"].get("labels", {}).get("app.kubernetes.io/component") or p["metadata"]["name"]
    cs = (p.get("status", {}).get("containerStatuses") or [{}])
    out["pods"][comp] = {"uid": p["metadata"]["uid"], "images": sorted(c.get("imageID", "") for c in cs),
                         "restarts": sum(c.get("restartCount", 0) for c in cs),
                         "args": [c.get("command", []) + c.get("args", []) for c in p["spec"]["containers"]]}
json.dump(out, sys.stdout, sort_keys=True, indent=1)
'
}

# ---------------------------------------------------------------------------------------------------------------
log "study $STUDY_ID on $CONTEXT; tooling at $(git -C "$REPO" rev-parse HEAD), dirty files $(git -C "$REPO" status --porcelain | wc -l)"
git -C "$REPO" rev-parse HEAD >"$OUT/tooling-commit.txt"

# The frozen load, checked before anything is applied.
(cd "$HERE/diagnostic" && sha256sum -c --quiet SHA256SUMS) || stop "the diagnostic traces do not match their SHA256SUMS"
for i in 1 2 3; do
  want="$(python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1]))["traceChecksum"])' "$HERE/diagnostic/manifest-off-$i.yaml")"
  [[ "$(sha256sum "$HERE/diagnostic/trace-off-$i.jsonl" | cut -d' ' -f1)" == "$want" ]] || stop "trace-off-$i does not match its manifest"
done
for seed in "${SEEDS[@]}"; do log "block $seed order: $(order "$seed" | tr '\n' ' ')"; done
[[ "$(order 851 | tr '\n' ' ')$(order 852 | tr '\n' ' ')$(order 853 | tr '\n' ' ')" == "Off HoldCap HoldCap Off HoldCap Off " ]] ||
  stop "the computed order differs from the one the registration states"

log "building the harness"
(cd "$REPO" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/benchharness" ./cmd/benchharness) || stop "harness build"
sha256sum "$OUT/benchharness" | cut -d' ' -f1 >"$OUT/benchharness.sha256"
for chars in 200 40000; do
  "$OUT/benchharness" print-prompt --chars "$chars" >"$OUT/.prompt-$chars.txt" || stop "print-prompt $chars"
done
python3 - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
for name, chars, tokens in (("premium", 200, 64), ("contender", 40000, 16)):
    prompt = open(f"{out}/.prompt-{chars}.txt").read().rstrip("\n")
    body = {"model": "Qwen/Qwen2.5-3B-Instruct", "stream": True, "max_tokens": tokens, "min_tokens": tokens,
            "messages": [{"role": "user", "content": prompt}]}
    json.dump(body, open(f"{out}/warmup-{name}.json", "w"))
PY

log "tenants"
k apply -f "$HERE/tenants.yaml" >>"$OUT/run.log" 2>&1 || stop "apply tenants"
k get gpuquotapolicy study-premium-1 study-standard-noisy -o yaml >"$OUT/tenants-applied.yaml" || stop "read tenants"
PREMIUM_KEY="study-p-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CONTENDER_KEY="study-s-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf 'premium-1=%s\nstandard-noisy=%s\n' "$PREMIUM_KEY" "$CONTENDER_KEY" >"$EXDIR/study-keys.txt"
k -n "$GW_NS" patch secret gateway-api-keys --type merge \
  -p "{\"stringData\":{\"$PREMIUM_KEY\":\"premium-1\",\"$CONTENDER_KEY\":\"standard-noisy\"}}" >>"$OUT/run.log" 2>&1 ||
  stop "add study keys to gateway-api-keys"
for _ in $(seq 1 60); do
  n="$(k -n "$SERVE_NS" get resourcequota -o json | python3 -c 'import json,sys; print(sum(1 for q in json.load(sys.stdin)["items"] if "requests.nvidia.com/gpu" in (q.get("status",{}).get("hard") or {})))')"
  [[ "$n" -ge 3 ]] && break
  sleep 5
done
[[ "$n" -ge 3 ]] || stop "the study's two ResourceQuotas did not appear in $SERVE_NS beside serve-a's ($n with a GPU limit)"
k -n "$SERVE_NS" get resourcequota -o yaml >"$OUT/resourcequotas.yaml"

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
k -n "$COLLECTOR_NS" wait --for=condition=Ready pod/collector --timeout=300s >>"$OUT/run.log" 2>&1 || stop "collector not Ready"
k -n "$COLLECTOR_NS" get pod collector -o json >"$OUT/collector-pod.json"
in_collector mkdir -p /study
k -n "$COLLECTOR_NS" cp "$OUT/benchharness" collector:/study/benchharness >>"$OUT/run.log" 2>&1 || stop "copy harness"
for f in "$HERE"/diagnostic/trace-off-{1,2,3}.jsonl "$OUT"/warmup-{premium,contender}.json; do
  k -n "$COLLECTOR_NS" cp "$f" "collector:/study/$(basename "$f")" >>"$OUT/run.log" 2>&1 || stop "copy $(basename "$f")"
done
in_collector chmod +x /study/benchharness
[[ "$(in_collector sha256sum /study/benchharness | cut -d' ' -f1)" == "$(cat "$OUT/benchharness.sha256")" ]] || stop "the harness in the collector is not the one built"
for i in 1 2 3; do
  [[ "$(in_collector sha256sum "/study/trace-off-$i.jsonl" | cut -d' ' -f1)" == "$(sha256sum "$HERE/diagnostic/trace-off-$i.jsonl" | cut -d' ' -f1)" ]] ||
    stop "trace-off-$i in the collector is not the committed one"
done

read -r GW_POD GW_UID GW_IP _ _ _ <<<"$(gateway_pods_json | live_one)" || stop "not exactly one live gateway Pod"
GW_SVC="$(k -n "$GW_NS" get svc -l app.kubernetes.io/component=gateway -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$GW_SVC" ]] || stop "no gateway Service"
GW_URL="http://$GW_SVC.$GW_NS.svc:8080"
log "gateway $GW_POD at $GW_IP; replay target $GW_URL"

read -r E_POD _ _ _ _ E_NODE <<<"$(engine_pods_json | live_one)" || stop "not exactly one live engine Pod at the start"
identity "$E_NODE" >"$OUT/identity-start.json" || stop "identity"
# The gateway's revision is the one its Argo Application synced, by the name config/argocd/gateway.yaml gives it.
# A cluster with Argo but no such Application is refused; only a cluster with no Argo at all (the kind rehearsal)
# falls back to the tooling's commit, so a wrong name cannot hide behind the fallback.
GATEWAY_APP=gpu-platform-gateway
GATEWAY_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["argo"].get(sys.argv[2]) or "")' "$OUT/identity-start.json" "$GATEWAY_APP")"
ARGO_APPS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["argo"]))' "$OUT/identity-start.json")"
if [[ "$ARGO_APPS" != 0 && -z "$GATEWAY_SHA" ]]; then
  stop "Argo runs $ARGO_APPS Application(s) but none named $GATEWAY_APP reports a synced revision"
fi
GATEWAY_IMAGE="$(python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))["pods"]["gateway"]["images"]; print(i[0].split("://")[-1] if len(i)==1 else "")' "$OUT/identity-start.json")"
[[ -n "$STUDY_REHEARSAL" && "$ARGO_APPS" == 0 ]] && GATEWAY_SHA="${GATEWAY_SHA:-$(git -C "$REPO" rev-parse HEAD)}"
GATEWAY_IMAGE="$(rehearsal_ref "$GATEWAY_IMAGE" gateway)"
[[ "$GATEWAY_SHA" =~ ^[0-9a-f]{40}$ && "$GATEWAY_IMAGE" == *@sha256:* ]] || stop "cannot name the gateway build (sha '$GATEWAY_SHA', image '$GATEWAY_IMAGE')"

# set_arm brings a fresh engine up in the arm's mode: a mode change Recreates it, the same mode deletes its Pod.
set_arm() {
  local arm=$1 before_uid=$2 current
  if [[ -n "$STUDY_REHEARSAL" ]]; then
    "$HERE/rehearse-kind.sh" set-arm "$arm" >>"$OUT/run.log" 2>&1 || return 1
  else
    current="$(k -n "$SERVE_NS" get inferencedeployment "$SERVE_INFD" -o jsonpath='{.spec.admission.mode}')"
    if [[ "$current" == "$arm" ]]; then
      k -n "$SERVE_NS" delete pod -l "app.kubernetes.io/instance=$SERVE_INFD" --wait=false >>"$OUT/run.log" 2>&1 || return 1
    elif [[ "$arm" == HoldCap ]]; then
      k -n "$SERVE_NS" patch inferencedeployment "$SERVE_INFD" --type merge \
        -p '{"spec":{"admission":{"mode":"HoldCap","maxHold":"25s"}}}' >>"$OUT/run.log" 2>&1 || return 1
    else
      k -n "$SERVE_NS" patch inferencedeployment "$SERVE_INFD" --type merge \
        -p '{"spec":{"admission":{"mode":"Off","maxHold":null}}}' >>"$OUT/run.log" 2>&1 || return 1
    fi
  fi
  # The engine may take what the cell's budget leaves after the 420 s replay, the idle and drain waits and the
  # export (about 800 s together), and never more than WAIT_ENGINE: a slow start fails the cell instead of eating
  # the margin before the card's deadline.
  local budget=$((CELL_END - $(date +%s) - 800))
  ((budget > WAIT_ENGINE)) && budget=$WAIT_ENGINE
  ((budget > 0)) || return 1
  local deadline=$((SECONDS + budget)) line st
  while ((SECONDS < deadline)); do
    sleep 10
    st="$(k -n "$SERVE_NS" get inferencedeployment "$SERVE_INFD" -o jsonpath='{.status.admission.mode} {.status.admission.observedGeneration} {.metadata.generation}' 2>/dev/null)" || continue
    read -r m og g <<<"$st"
    [[ "$m" == "$arm" && "$og" == "$g" ]] || continue
    line="$(engine_pods_json | live_one)" || continue
    read -r _ uid _ _ ready _ <<<"$line"
    [[ "$ready" == ready && "$uid" != "$before_uid" ]] && return 0
  done
  return 1
}

PREV_ENGINE_UID="$(engine_pods_json | live_one | cut -d' ' -f2)"
CELL_NO=0
for seed in "${SEEDS[@]}"; do
  for arm in $(order "$seed"); do
    CELL_NO=$((CELL_NO + 1))
    name="$seed-$arm"
    D="$OUT/cells/$name"
    if (($(date +%s) + CELL_BUDGET + TEARDOWN_RESERVE > STUDY_DEADLINE)); then
      stop "cell $name would not finish before the teardown reserve; the remaining cells are not started"
    fi
    mkdir -p "$D"
    CELL_END=$(($(date +%s) + CELL_BUDGET))
    log "== cell $CELL_NO: $name, to end by $(date -u -d "@$CELL_END" +%H:%M:%SZ)"
    meta() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); json.dump(d, open(sys.argv[2],"w"), indent=1, sort_keys=True)' "$1" "$D/cell.json"; }
    fail_cell() {
      meta "{\"cell\":\"$name\",\"outcome\":\"failed: $1\"}"
      { engine_pods_json; k -n "$SERVE_NS" get events --sort-by=.lastTimestamp; } >"$D/failure-state.txt" 2>&1 || true
      stop "cell $name: $1"
    }

    set_arm "$arm" "$PREV_ENGINE_UID" || fail_cell "no fresh engine in mode $arm within ${WAIT_ENGINE}s"
    read -r E_POD E_UID E_IP E_RESTARTS _ E_NODE <<<"$(engine_pods_json | live_one)"
    PREV_ENGINE_UID="$E_UID"
    modes=""
    for _ in $(seq 1 30); do
      modes="$(backend_modes "$GW_IP")"
      [[ "$modes" == "$([[ $arm == HoldCap ]] && echo hold-cap || echo gateway) off" ]] && break
      sleep 2
    done
    [[ "$modes" == "$([[ $arm == HoldCap ]] && echo hold-cap || echo gateway) off" ]] || fail_cell "the gateway reports '$modes' for the backend"
    args="$(k -n "$SERVE_NS" logs "$E_POD" 2>/dev/null | grep -m1 'non-default args' || true)"
    [[ -n "$args" ]] || fail_cell "the engine logged no non-default args"
    [[ "$(k get gpuquotapolicy -o json | python3 -c '
import json, sys
items = json.load(sys.stdin)["items"]
t = {}
for p in items:
    t.setdefault(p["spec"]["tenant"], []).append((p.get("metadata", {}).get("annotations") or {}).get("platform.lkhun9311.github.io/tier", ""))
print(t.get("premium-1") == ["premium"] and t.get("standard-noisy") == [""])')" == True ]] || fail_cell "the study tenants do not resolve to one policy each with the registered tiers"
    [[ "$(k -n "$SERVE_NS" get endpointslices -l "kubernetes.io/service-name=$SERVE_INFD" -o json | python3 -c '
import json, sys
uids = {e.get("targetRef", {}).get("uid") for s in json.load(sys.stdin)["items"] for e in s.get("endpoints") or []}
print(uids == {sys.argv[1]})' "$E_UID")" == True ]] || fail_cell "the Service does not resolve to exactly the cell's engine Pod"

    for w in premium contender; do
      key="$([[ $w == premium ]] && echo "$PREMIUM_KEY" || echo "$CONTENDER_KEY")"
      want="$([[ $w == premium ]] && echo 64 || echo 16)"
      in_collector wget -qO "/study/warmup-$name-$w.out" -T 60 --header "Authorization: Bearer $key" \
        --header "Content-Type: application/json" --post-file "/study/warmup-$w.json" "$GW_URL/v1/chat/completions" ||
        fail_cell "the $w warm-up request failed"
      frames="$(in_collector sh -c "grep -c '\"content\":\"[^\"]' /study/warmup-$name-$w.out; grep -c 'data: \[DONE\]' /study/warmup-$name-$w.out" | tr '\n' ' ')"
      read -r n done_n <<<"$frames"
      [[ "$done_n" == 1 && "$n" -ge "$want" ]] || fail_cell "the $w warm-up did not complete in full ($frames)"
    done
    engine_idle "$E_IP" 120 || fail_cell "the engine was not idle before the replay"
    metrics_of "$E_IP:8000" >"$D/metrics-engine-before.prom" || fail_cell "engine metrics before"
    metrics_of "$GW_IP:8081" >"$D/metrics-gateway-before.prom" || fail_cell "gateway metrics before"

    case "$seed" in 851) i=1 ;; 852) i=2 ;; 853) i=3 ;; esac
    archived="$HERE/diagnostic/manifest-$([[ $arm == HoldCap ]] && echo hold-cap || echo off)-$i.yaml"
    E_IMAGE="$(rehearsal_ref "$(engine_pods_json | python3 -c 'import json,sys; p=[p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")][0]; print(p["status"]["containerStatuses"][0]["imageID"].split("://")[-1])')" engine)"
    python3 "$HERE/derive_manifest.py" "$archived" "$D/manifest.json" --arm "$arm" --gateway-url "$GW_URL" \
      --gateway-sha "$GATEWAY_SHA" --gateway-image "$GATEWAY_IMAGE" --engine-image "$E_IMAGE" --study "$STUDY_ID" ||
      fail_cell "derive manifest"
    k -n "$COLLECTOR_NS" cp "$D/manifest.json" "collector:/study/manifest-$name.json" >>"$OUT/run.log" 2>&1 || fail_cell "copy manifest"

    # Samples every 5 s until the replay returns, in the background; each is one JSON line.
    : >"$D/samples.jsonl"
    (
      while [[ ! -f "$D/.stop-sampling" ]]; do
        t="$(date +%s%N)"
        e="$(engine_pods_json 2>>"$D/sampler.err" | live_one 2>>"$D/sampler.err" || echo "- - - - - -")"
        g="$(gateway_pods_json 2>>"$D/sampler.err" | live_one 2>>"$D/sampler.err" || echo "- - - - - -")"
        st="$(k -n "$SERVE_NS" get inferencedeployment "$SERVE_INFD" -o jsonpath='{.status.admission.mode} {.status.admission.observedGeneration} {.metadata.generation}' 2>>"$D/sampler.err" || echo "- - -")"
        # Retried within the tick: the first run lost one sample of 59 to a single failed read of the gateway's
        # metrics, and the registration counts a sample that cannot show the arm against validity. The rule is
        # unchanged; a read that fails three times is still written as unreadable. Failures go to sampler.err.
        bm="- -"
        for _ in 1 2 3; do
          bm="$(backend_modes "$GW_IP" 2>>"$D/sampler.err")" && [[ "$bm" != "- -" && -n "$bm" ]] && break
          bm="- -"
          sleep 0.5
        done
        python3 -c '
import json, sys
t, e, g, st, bm = sys.argv[1:6]
e, g, st, bm = e.split(), g.split(), st.split(), bm.split()
print(json.dumps({"t": int(t), "statusMode": st[0], "statusObservedGeneration": st[1], "generation": st[2],
                  "backendMode": bm[0], "processMode": bm[1], "engineUID": e[1], "engineRestarts": e[3],
                  "gatewayUID": g[1], "gatewayRestarts": g[3]}))' "$t" "$e" "$g" "$st" "$bm" >>"$D/samples.jsonl" || true
        sleep 5
      done
    ) &
    SAMPLER=$!

    meta "{\"cell\":\"$name\",\"outcome\":\"running\",\"startedUnixNanos\":$(date +%s%N),\"enginePodUID\":\"$E_UID\",\"engineNode\":\"$E_NODE\",\"engineNonDefaultArgs\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$args")}"
    in_collector sh -c "cd /study && rm -f replay-$name.rc && (nohup ./benchharness replay --manifest manifest-$name.json --require-provenance \
      --request-id-prefix study-$name --target $GW_URL --api-keys premium-1=$PREMIUM_KEY,standard-noisy=$CONTENDER_KEY \
      --raw-out raw-$name.jsonl >replay-$name.log 2>&1; echo \$? >replay-$name.rc) >/dev/null 2>&1 &" ||
      { touch "$D/.stop-sampling"; wait "$SAMPLER"; fail_cell "could not start the replay"; }
    # The replay may run until 300 s before the cell's end, which leaves the drain and the export their time.
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
    engine_idle "$E_IP" 120 || log "cell $name: the engine was not idle 120 s after the replay; the after metrics are read anyway"
    metrics_of "$E_IP:8000" >"$D/metrics-engine-after.prom" || fail_cell "engine metrics after"
    metrics_of "$GW_IP:8081" >"$D/metrics-gateway-after.prom" || fail_cell "gateway metrics after"
    for f in "raw-$name.jsonl:raw.jsonl" "raw-$name.jsonl.sender.json:raw.jsonl.sender.json" "replay-$name.log:replay.log"; do
      k -n "$COLLECTOR_NS" cp "collector:/study/${f%%:*}" "$D/${f##*:}" >>"$OUT/run.log" 2>&1 || fail_cell "copy ${f%%:*}"
    done
    [[ "$(in_collector sha256sum "/study/raw-$name.jsonl" | cut -d' ' -f1)" == "$(sha256sum "$D/raw.jsonl" | cut -d' ' -f1)" ]] || fail_cell "the copied raw rows differ from the collector's"
    identity "$E_NODE" >"$D/identity-after.json" || fail_cell "identity after"
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["outcome"]="complete"; d["endedUnixNanos"]=int(sys.argv[2]); json.dump(d, open(sys.argv[1],"w"), indent=1, sort_keys=True)' "$D/cell.json" "$(date +%s%N)"
    (cd "$D" && sha256sum raw.jsonl raw.jsonl.sender.json samples.jsonl metrics-*.prom manifest.json identity-after.json cell.json >SHA256SUMS)
    log "cell $name complete: $(wc -l <"$D/raw.jsonl") rows, $(wc -l <"$D/samples.jsonl") samples"
    if ! cmp -s <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({k: d[k] for k in ("argo","node")}, sort_keys=True))' "$D/identity-after.json") \
      <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({k: d[k] for k in ("argo","node")}, sort_keys=True))' "$OUT/identity-start.json"); then
      stop "the frozen identity changed after cell $name"
    fi
  done
done

log "all six cells complete; scoring"
# score.py exits 0 for "observed on these traces" and 1 for "not met" or "inconclusive": both are verdicts, and the
# run that produced them succeeded. Anything else, or no verdict line, means the evidence could not be scored.
set +e
python3 "$HERE/score.py" "$OUT" >"$OUT/verdict.txt" 2>"$OUT/score.err"
rc=$?
set -e
cat "$OUT/verdict.txt" | tee -a "$OUT/run.log"
if [[ "$rc" != 0 && "$rc" != 1 ]] || ! head -1 "$OUT/verdict.txt" | grep -q '^verdict: '; then
  stop "the scorer exited $rc without a verdict; see score.err"
fi
exit 0
