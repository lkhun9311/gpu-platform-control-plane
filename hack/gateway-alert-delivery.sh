#!/usr/bin/env bash
# Does a serving alert reach a receiver, and does its resolution reach it too?
#
# hack/alert-firing-verification.md showed GatewayUpstreamErrorsReachingClients reaching the firing state in
# Prometheus.
# It did not show a notification leaving Prometheus: a rule that fires into an Alertmanager with no route pages
# nobody, and Prometheus's alert page looks the same either way.
# hack/gpu-alert-delivery.sh closed that gap for the GPU rules; this does the same for one gateway rule.
#
# THE RULE, from config/prometheus/gateway_rules.yaml as committed:
#
#   GatewayUpstreamErrorsReachingClients
#   sum by (model) (rate(gpuaas_gateway_requests_total{code=~"5.."}[5m])) > 0.1, for: 5m
#
# A Pod kill that FR-002 recovers from in about 1.3 s cannot fire it: the condition has to hold for five
# minutes of evaluations, and a 5-minute rate needs more than 30 failed requests in its window to exceed 0.1/s.
# So the fault here is a serving backend with no Pod at all, held until the receiver has the firing
# notification.
#
# WHAT THIS RUNS, on a throwaway kind cluster it creates and deletes:
#
#   kube-prometheus-stack with Alertmanager, whose only receiver is a webhook into a Pod that prints each request
#   body with its arrival time;
#   the operator (config/operator) and the gateway (config/gateway), built from this checkout and side-loaded;
#   one InferenceDeployment running the benchharness stub, and a load Pod sending about two requests a second
#   through the gateway for the whole run;
#   config/prometheus/gateway_podmonitor.yaml and gateway_rules.yaml as they are.
#
# THE FAULT: the InferenceDeployment is patched to replicas 0, which the operator holds (scaling its Deployment
# instead is undone within one reconcile, hack/alert-firing-verification.md), and later back to 1.
#
# WHAT IT RECORDS, under hack/gateway-alert-delivery-<UTC>/:
#
#   events.tsv, what this script did and saw, and when;
#   prometheus-transitions.jsonl, each change in Prometheus's active alerts, read every 5 s;
#   alerts-firing-series.json, the ALERTS{alertstate="firing"} samples, whose timestamps are rule evaluations;
#   sink.jsonl, every webhook body the receiver got, with its arrival time;
#   summary.json, fault start and end beside the firing and resolved receipts.
#
# WHAT IT IS NOT: a GPU engine, an EKS cluster, or a human receiver.
# The webhook is the last hop shown; email, Slack or a pager would be one more configured receiver, and none is.
#
# Usage: hack/gateway-alert-delivery.sh   (KEEP=1 leaves the cluster up; KUSTOMIZE, HELM, CHART override tools)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=${CLUSTER:-gwalert}
CTX=kind-$CLUSTER
KEEP=${KEEP:-0}
KUSTOMIZE=${KUSTOMIZE:-bin/kustomize}
HELM=${HELM:-helm}
CHART=${CHART:-$HOME/.cache/helm/repository/kube-prometheus-stack-88.3.0.tgz}
TAG=alert-delivery
OP_IMG=controller:$TAG
GW_IMG=gateway:$TAG
STUB_IMG=benchharness:$TAG
OUT=${OUT:-hack/gateway-alert-delivery-$(date -u +%Y%m%dT%H%M%SZ)}
SYS=gpu-platform-control-plane-system
SERV=serving
MODEL=demo-llm
ALERT=GatewayUpstreamErrorsReachingClients
PROM_POD=prometheus-kps-kube-prometheus-stack-prometheus-0
PROM_URL=http://kps-kube-prometheus-stack-prometheus.monitoring.svc:9090

# Refused before the evidence directory exists, so a run that never started leaves no directory to be mistaken for one.
for tool in kind kubectl docker python3 "$HELM"; do
  command -v "$tool" >/dev/null || { echo "ABORT: $tool not found" >&2; exit 1; }
done
[ -x "$KUSTOMIZE" ] || { echo "ABORT: kustomize not found at $KUSTOMIZE; set KUSTOMIZE" >&2; exit 1; }
[ -f "$CHART" ] || { echo "ABORT: chart $CHART not found; set CHART" >&2; exit 1; }
clusters=$(kind get clusters) || { echo "ABORT: kind get clusters failed" >&2; exit 1; }
if grep -qx "$CLUSTER" <<<"$clusters"; then
  echo "ABORT: a kind cluster named $CLUSTER exists; this run creates its own and will not reuse one" >&2
  exit 1
fi

mkdir -p "$OUT"
LOG=$OUT/run.log
EVENTS=$OUT/events.tsv
: >"$EVENTS"
WORK=$(mktemp -d)

now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
log() { echo "$(now) $*" | tee -a "$LOG"; }
event() { printf '%s\t%s\n' "$(now)" "$*" | tee -a "$EVENTS" >>"$LOG"; }
die() { log "ABORT: $*"; exit 1; }
k() { kubectl --context "$CTX" "$@"; }
capped() { systemd-run --user --scope -q -p MemoryMax=6G "$@"; }

CREATED=0
POLLER=""
cleanup() {
  [ -n "$POLLER" ] && kill "$POLLER" >>"$LOG" 2>&1
  rm -rf "$WORK"
  if [ "$CREATED" = 1 ] && [ "$KEEP" != 1 ]; then
    log "deleting kind cluster $CLUSTER"
    kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || log "kind delete failed; delete $CLUSTER by hand"
  fi
}
trap cleanup EXIT

# setns rewrites every object's namespace, because the repository's monitoring manifests carry the kubebuilder
# placeholder.
setns() {
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
for d in docs:
    d["metadata"]["namespace"] = sys.argv[1]
print(yaml.safe_dump_all(docs))' "$1"
}

# setimage points a rendered Deployment's first container at a side-loaded image.
# The kustomizations pin ECR digests that kind has no credentials for, so the image is replaced after rendering
# rather than by editing a committed kustomization.
setimage() {
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
for d in docs:
    if d["kind"] == "Deployment":
        c = d["spec"]["template"]["spec"]["containers"][0]
        c["image"] = sys.argv[1]
        c["imagePullPolicy"] = "IfNotPresent"
print(yaml.safe_dump_all(docs))' "$1"
}

# prom GETs a Prometheus API path through a busybox Pod in the cluster, so no port-forward can drop out halfway.
# stderr goes to the log, so a failing exec is read there rather than as an empty answer.
prom() { k -n monitoring exec deploy/probe -- wget -qO- "$PROM_URL$1" 2>>"$LOG"; }
q() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

# alert_state prints the state of the named alert in Prometheus, or "inactive".
alert_state() {
  prom /api/v1/alerts | python3 -c '
import json, sys
a = [x for x in json.load(sys.stdin)["data"]["alerts"] if x["labels"]["alertname"] == sys.argv[1]]
print(a[0]["state"] if a else "inactive")' "$1"
}

# received counts the alerts at the sink with the given name and status, through hack/alert-receipts.py.
received() {
  k -n monitoring logs deploy/alert-sink >"$WORK/sink.jsonl" || return 1
  python3 hack/alert-receipts.py "$WORK/sink.jsonl" "$@"
}

wait_for() {
  local what=$1 timeout=$2; shift 2
  local end=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$end" ]; do
    "$@" && return 0
    sleep 5
  done
  log "timed out after ${timeout}s waiting for $what"
  return 1
}
is_state() { [ "$(alert_state "$1")" = "$2" ]; }
got() { local n; n=$(received "$@") && [ "${n:-0}" -gt 0 ]; }
# value prints the first sample of an instant query, or nothing.
value() {
  prom "/api/v1/query?query=$(q "$1")" | python3 -c '
import json, sys
r = json.load(sys.stdin)["data"]["result"]
print(r[0]["value"][1] if r else "")'
}
above() { local v; v=$(value "$1") && [ -n "$v" ] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)' "$v" "$2"; }

poll_alerts() {
  local prev="" cur
  while :; do
    cur=$(prom /api/v1/alerts | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]["alerts"]
print(json.dumps(sorted([{"labels": x["labels"], "state": x["state"], "activeAt": x["activeAt"]} for x in a],
                        key=lambda x: json.dumps(x["labels"], sort_keys=True)), sort_keys=True))')
    if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then
      printf '{"observed_at":"%s","alerts":%s}\n' "$(now)" "$cur" >>"$OUT/prometheus-transitions.jsonl"
      prev=$cur
    fi
    sleep 5
  done
}

# ---------------------------------------------------------------- provenance
{
  echo "commit=$(git rev-parse HEAD)"
  echo "dirty_files=$(git status --porcelain -- config hack/gateway-alert-delivery.sh cmd internal api | wc -l)"
  # The images also read go.mod, go.sum, the Dockerfiles and .dockerignore, and the receipts come through
  # hack/alert-receipts.py, so the narrow count above can read 0 while a build input is modified.
  # Tracked changes anywhere are counted too; untracked files are left out, because earlier runs' evidence
  # directories are untracked until committed.
  echo "dirty_tracked_files_whole_tree=$(git status --porcelain --untracked-files=no | wc -l)"
  echo "kind=$(kind version)"
  echo "kubectl=$(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  echo "helm=$("$HELM" version --short)"
  echo "chart=$(basename "$CHART") sha256=$(sha256sum "$CHART" | cut -d' ' -f1)"
  echo "kueue=$(sed -n 's/^version=//p' config/kueue-controller/RELEASE) from config/kueue-controller"
} >"$OUT/provenance.txt"
log "provenance: $(tr '\n' ' ' <"$OUT/provenance.txt")"

# ---------------------------------------------------------------- images and cluster
log "== images"
docker build -q -t "$OP_IMG" . >>"$LOG" 2>&1 || die "build $OP_IMG"
docker build -q -t "$GW_IMG" -f Dockerfile.gateway . >>"$LOG" 2>&1 || die "build $GW_IMG"
docker build -q -t "$STUB_IMG" -f Dockerfile.benchharness . >>"$LOG" 2>&1 || die "build $STUB_IMG"
for img in "$OP_IMG" "$GW_IMG" "$STUB_IMG"; do
  echo "image $img=$(docker image inspect "$img" --format '{{.Id}}')" >>"$OUT/provenance.txt"
done

log "== cluster $CLUSTER"
kind create cluster --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind create"
CREATED=1
echo "node_image=$(docker inspect "$CLUSTER-control-plane" --format '{{.Config.Image}}')" >>"$OUT/provenance.txt"
for img in "$OP_IMG" "$GW_IMG" "$STUB_IMG"; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"
done

# ---------------------------------------------------------------- receiver
log "== webhook sink"
k create namespace monitoring >>"$LOG" 2>&1 || die "namespace monitoring"
k apply -f - >>"$LOG" 2>&1 <<'EOF' || die "sink"
apiVersion: v1
kind: ConfigMap
metadata: {name: alert-sink, namespace: monitoring}
data:
  sink.py: |
    # Prints every request body as one JSON line with the time it arrived, and answers 200.
    import datetime, http.server, json
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            at = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")
            try:
                payload = json.loads(body)
            except ValueError:
                payload = {"unparsed": body.decode("utf-8", "replace")}
            print(json.dumps({"received_at": at, "path": self.path, "payload": payload}), flush=True)
            self.send_response(200)
            self.end_headers()
        def log_message(self, *args):
            pass
    http.server.ThreadingHTTPServer(("", 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: alert-sink, namespace: monitoring}
spec:
  replicas: 1
  selector: {matchLabels: {app: alert-sink}}
  template:
    metadata: {labels: {app: alert-sink}}
    spec:
      containers:
        - name: sink
          image: python:3.12-slim
          imagePullPolicy: IfNotPresent
          command: ["python", "-u", "/sink/sink.py"]
          ports: [{containerPort: 8080}]
          volumeMounts: [{name: sink, mountPath: /sink}]
      volumes: [{name: sink, configMap: {name: alert-sink}}]
---
apiVersion: v1
kind: Service
metadata: {name: alert-sink, namespace: monitoring}
spec:
  selector: {app: alert-sink}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: probe, namespace: monitoring}
spec:
  replicas: 1
  selector: {matchLabels: {app: probe}}
  template:
    metadata: {labels: {app: probe}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: probe
          image: busybox:1.37.0
          imagePullPolicy: IfNotPresent
          command: ["sleep", "86400"]
EOF

# ---------------------------------------------------------------- prometheus and alertmanager
log "== kube-prometheus-stack"
# group_by '...' gives every alert its own notification, so each arrival is attributable to one alert.
# group_wait and group_interval are short so the measured latency is the pipeline's, not a batching window's;
# the chart's defaults are 30 s and 5 min, and an operator's receiver would add them.
cat >"$OUT/kps-values.yaml" <<'EOF'
defaultRules: {create: false}
grafana: {enabled: false}
nodeExporter: {enabled: false}
prometheus-node-exporter: {enabled: false}
kubeStateMetrics: {enabled: false}
prometheus:
  prometheusSpec:
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    retention: 6h
alertmanager:
  enabled: true
  config:
    global: {resolve_timeout: 5m}
    inhibit_rules: []
    templates: []
    route:
      receiver: sink
      group_by: ['...']
      group_wait: 10s
      group_interval: 30s
      repeat_interval: 12h
      routes: []
    receivers:
      - name: sink
        webhook_configs:
          - url: http://alert-sink.monitoring.svc:8080/
            send_resolved: true
EOF
capped "$HELM" --kube-context "$CTX" install kps "$CHART" -n monitoring -f "$OUT/kps-values.yaml" --wait --timeout 15m \
  >>"$LOG" 2>&1 || die "helm install"
k -n monitoring rollout status deploy/alert-sink --timeout=300s >>"$LOG" 2>&1 || die "sink not ready"
k -n monitoring rollout status deploy/probe --timeout=300s >>"$LOG" 2>&1 || die "probe not ready"
k -n monitoring wait --for=condition=Ready "pod/$PROM_POD" --timeout=300s >>"$LOG" 2>&1 || die "prometheus not ready"

# ---------------------------------------------------------------- kueue, operator and gateway
# Kueue is not exercised; the operator's GPUQuotaPolicy controller watches Kueue kinds and does not start without them.
log "== kueue from config/kueue-controller"
capped "$KUSTOMIZE" build config/kueue-controller >"$WORK/kueue.yaml" || die "kustomize kueue"
for i in $(seq 30); do
  k apply --server-side -f "$WORK/kueue.yaml" >>"$LOG" 2>&1 && break
  [ "$i" = 30 ] && die "kueue apply"
  sleep 10
done
k -n kueue-system rollout status deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue rollout"
for i in $(seq 30); do
  k apply -f config/kueue/resourceflavor.yaml >>"$LOG" 2>&1 && break
  [ "$i" = 30 ] && die "resourceflavor"
  sleep 10
done

log "== operator and gateway"
"$KUSTOMIZE" build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
"$KUSTOMIZE" build config/operator | setimage "$OP_IMG" | k apply --server-side -f - >>"$LOG" 2>&1 || die "operator"
k -n "$SYS" rollout status deploy/gpu-platform-control-plane-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "operator rollout"
# Each Secret KEY is an API key and its VALUE is the tenant (resolveTenant in tenant.go).
k -n "$SYS" create secret generic gateway-api-keys --from-literal=premium-key=premium-1 >>"$LOG" 2>&1 || die "api keys"
"$KUSTOMIZE" build config/gateway | setimage "$GW_IMG" | k apply --server-side -f - >>"$LOG" 2>&1 || die "gateway"
k -n "$SYS" rollout status deploy/gateway --timeout=300s >>"$LOG" 2>&1 || die "gateway rollout"

log "== tenant and backend"
k create namespace "$SERV" >>"$LOG" 2>&1 || die "namespace $SERV"
# trainingQuota keeps the GPU ceiling in a ClusterQueue; a namespace ResourceQuota on nvidia.com/gpu would refuse
# the stub Pods, which declare no GPU (hack/m5b-gateway-path.sh).
# rateLimit is unset, which the limiter reads as unlimited, so the load ends at the backend and not in a 429.
k apply -f - >>"$LOG" 2>&1 <<EOF || die "policy and backend"
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata: {name: premium-1-quota}
spec:
  tenant: premium-1
  targetNamespace: $SERV
  gpuClass: l40s
  limits: {gpuCount: 4}
  trainingQuota: true
---
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata: {name: $MODEL, namespace: $SERV}
spec:
  model:
    name: $MODEL
    storageUri: "stub://profile?tokens=4&ttft-ms=5&itl-ms=2"
  image: $STUB_IMG
  gpuCount: 0
  replicas: 1
  port: 8090
EOF
wait_for "the backend Deployment" 120 k -n "$SERV" get deploy "$MODEL" || die "the operator made no Deployment"
k -n "$SERV" rollout status "deploy/$MODEL" --timeout=300s >>"$LOG" 2>&1 || die "backend rollout"

# ---------------------------------------------------------------- monitoring objects and load
log "== rules, PodMonitor and load"
setns "$SYS" <config/prometheus/gateway_podmonitor.yaml | k apply -f - >>"$LOG" 2>&1 || die "podmonitor"
setns "$SYS" <config/prometheus/gateway_rules.yaml | k apply -f - >>"$LOG" 2>&1 || die "rules"
# About two requests a second, steady through the whole run, so the fault is the only thing that changes.
# The client's own view is not the measurement here; the gateway's counter is what the rule reads.
k -n "$SERV" apply -f - >>"$LOG" 2>&1 <<EOF || die "load"
apiVersion: apps/v1
kind: Deployment
metadata: {name: load, namespace: $SERV}
spec:
  replicas: 1
  selector: {matchLabels: {app: load}}
  template:
    metadata: {labels: {app: load}}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: load
          image: busybox:1.37.0
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              while true; do
                wget -q -O /dev/null -T 2 --header 'Authorization: Bearer premium-key' \
                  --header 'Content-Type: application/json' \
                  --post-data '{"model":"$MODEL","messages":[{"role":"user","content":"hi"}]}' \
                  http://gateway.$SYS.svc:8080/v1/chat/completions
                sleep 0.5
              done
EOF
k -n "$SERV" rollout status deploy/load --timeout=300s >>"$LOG" 2>&1 || die "load rollout"

log "== waiting for the inputs"
has_rule() {
  prom /api/v1/rules | python3 -c '
import json, sys
names = {r["name"] for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"]}
sys.exit(0 if sys.argv[1] in names else 1)' "$1"
}
wait_for "the gateway rules loaded" 300 has_rule "$ALERT" || die "rules not loaded"
wait_for "200s through the gateway" 300 above "sum(rate(gpuaas_gateway_requests_total{code=\"200\",model=\"$MODEL\"}[1m]))" 0.5 ||
  die "the gateway is not serving the load"
prom /api/v1/status/config | python3 -c '
import json, sys, re
cfg = json.load(sys.stdin)["data"]["yaml"]
print("\n".join(l for l in cfg.splitlines() if re.search(r"^\s*(scrape_interval|evaluation_interval|scrape_timeout):", l)))' \
  >"$OUT/prometheus-intervals.txt"
prom /api/v1/rules >"$OUT/rules-loaded.json" || die "read rules"
[ "$(alert_state "$ALERT")" = inactive ] || die "$ALERT is active before the fault"
event "baseline: $ALERT inactive, 200 rate $(value "sum(rate(gpuaas_gateway_requests_total{code=\"200\",model=\"$MODEL\"}[1m]))")/s"

poll_alerts &
POLLER=$!
T0=$(date +%s)

# ---------------------------------------------------------------- the fault
log "== fault"
k -n "$SERV" patch inferencedeployment "$MODEL" --type=merge -p '{"spec":{"replicas":0}}' >>"$LOG" 2>&1 || die "scale down"
event "FAULT START: InferenceDeployment $MODEL patched to replicas 0"
k -n "$SERV" wait --for=delete pod -l "app.kubernetes.io/instance=$MODEL" --timeout=120s >>"$LOG" 2>&1 ||
  k -n "$SERV" get pods -o wide >>"$LOG" 2>&1
event "backend Pods: $(k -n "$SERV" get pods --no-headers 2>/dev/null | grep -v '^load-' | wc -l) left besides the load"
wait_for "5xx in the gateway counter" 300 above "sum(rate(gpuaas_gateway_requests_total{code=~\"5..\",model=\"$MODEL\"}[1m]))" 0 ||
  die "the fault produced no 5xx"
event "gateway 5xx observed in Prometheus: $(value "sum by (code) (rate(gpuaas_gateway_requests_total{code=~\"5..\",model=\"$MODEL\"}[1m]))")/s"
wait_for "$ALERT pending" 300 is_state "$ALERT" pending || die "the rule never matched"
event "observed $ALERT pending"
wait_for "$ALERT firing" 900 is_state "$ALERT" firing || die "the rule never fired"
event "observed $ALERT firing"
wait_for "the firing notification" 300 got "$ALERT" firing || die "no firing notification"
event "sink holds a firing $ALERT"

k -n "$SERV" patch inferencedeployment "$MODEL" --type=merge -p '{"spec":{"replicas":1}}' >>"$LOG" 2>&1 || die "scale up"
event "FAULT END: InferenceDeployment $MODEL patched to replicas 1"
k -n "$SERV" rollout status "deploy/$MODEL" --timeout=300s >>"$LOG" 2>&1 || die "backend back"
event "backend rollout complete"
wait_for "200s again" 300 above "sum(rate(gpuaas_gateway_requests_total{code=\"200\",model=\"$MODEL\"}[1m]))" 0.5 ||
  die "the gateway did not recover"
event "gateway 200 rate back above 0.5/s in Prometheus"
wait_for "$ALERT inactive" 900 is_state "$ALERT" inactive || die "the alert never resolved"
event "observed $ALERT inactive"
wait_for "the resolved notification" 300 got "$ALERT" resolved || die "no resolved notification"
event "sink holds a resolved $ALERT"

# ---------------------------------------------------------------- record
log "== recording"
kill "$POLLER" >>"$LOG" 2>&1
POLLER=""
END=$(date +%s)
k -n monitoring logs deploy/alert-sink >"$OUT/sink.jsonl" || die "sink log"
# A range selector at one instant returns the raw samples, stamped with the evaluations that wrote them.
prom "/api/v1/query?query=$(q "ALERTS{alertstate=\"firing\"}[$((END - T0 + 60))s]")&time=$END" \
  >"$OUT/alerts-firing-series.json" || die "ALERTS samples"
prom "/api/v1/query?query=$(q "sum by (code) (gpuaas_gateway_requests_total{model=\"$MODEL\"})")" \
  >"$OUT/requests-by-code-at-end.json" || die "requests by code"
k -n monitoring get pods -o wide >"$OUT/monitoring-pods.txt" 2>&1
python3 - "$OUT" "$ALERT" <<'PY' || die "summary"
import json, sys, datetime
out, name = sys.argv[1], sys.argv[2]
def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
events = [l.rstrip("\n").split("\t", 1) for l in open(out + "/events.tsv")]
def at(prefix):
    hit = [t for t, what in events if what.startswith(prefix)]
    return ts(hit[0]) if hit else None
fault_start, fault_end = at("FAULT START"), at("FAULT END")
sink = [json.loads(l) for l in open(out + "/sink.jsonl") if l.startswith("{")]
mine = [(ts(b["received_at"]), a) for b in sink for a in b["payload"].get("alerts", []) if a["labels"].get("alertname") == name]
fired = sorted([x for x in mine if x[1]["status"] == "firing"], key=lambda x: x[0])
resolved = sorted([x for x in mine if x[1]["status"] == "resolved"], key=lambda x: x[0])
series = [s for s in json.load(open(out + "/alerts-firing-series.json"))["data"]["result"] if s["metric"].get("alertname") == name]
evals = sorted(float(v[0]) for s in series for v in s["values"])
def iso(t):
    return t.isoformat() if t else None
row = {
    "alert": name,
    "fault_start": iso(fault_start),
    "fault_end": iso(fault_end),
    "prometheus_first_firing_eval": iso(datetime.datetime.fromtimestamp(evals[0], datetime.timezone.utc)) if evals else None,
    "prometheus_last_firing_eval": iso(datetime.datetime.fromtimestamp(evals[-1], datetime.timezone.utc)) if evals else None,
    "received_firing_at": iso(fired[0][0]) if fired else None,
    "startsAt": fired[0][1]["startsAt"] if fired else None,
    "received_resolved_at": iso(resolved[0][0]) if resolved else None,
    "endsAt": resolved[0][1]["endsAt"] if resolved else None,
    "firing_notifications": len(fired),
    "resolved_notifications": len(resolved),
}
if fault_start and fired:
    row["fault_start_to_firing_received_s"] = round((fired[0][0] - fault_start).total_seconds(), 1)
if fault_end and resolved:
    row["fault_end_to_resolved_received_s"] = round((resolved[0][0] - fault_end).total_seconds(), 1)
json.dump({"events": events, "timeline": row}, open(out + "/summary.json", "w"), indent=2)
print(json.dumps(row, indent=2))
PY
log "done; evidence in $OUT"
