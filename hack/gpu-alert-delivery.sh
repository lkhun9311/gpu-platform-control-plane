#!/usr/bin/env bash
# Does a GPU alert reach a receiver, and does its resolution reach it too?
#
# config/prometheus/gpu_rules_test.yaml shows each rule fires on the input it is given, and an earlier kind rehearsal
# showed Prometheus holding GPUFaultSignalPresent in the firing state.
# Neither shows a notification leaving the cluster: a rule that fires into an Alertmanager with no route, or a route
# whose receiver refuses the payload, pages nobody, and Prometheus's own alert page looks the same either way.
#
# WHAT THIS RUNS, on a throwaway kind cluster it creates and deletes:
#
#   kube-prometheus-stack (the chart version kind-platform runs) with its Alertmanager and kube-state-metrics on,
#   Alertmanager's only receiver a webhook into a Pod that prints each request body with its arrival time,
#   Kueue from config/kueue-controller, the deployment EKS gets, so the quota series are the ones it publishes,
#   gpu-simulator as the nvidia.com/gpu device plugin on the worker, and a second gpu-simulator serving the fake
#   DCGM exporter on the same worker, labelled so the PodMonitor from config/dcgm-exporter-ops scrapes it,
#   and config/prometheus/gpu_rules.yaml and kueue_monitor.yaml as they are.
#
# WHAT IT INDUCES, each with the time it did so:
#
#   Xid 13 (the control, which must not alert), Xid 79, then a double-bit ECC count, through the fake's /inject;
#   the exporter scaled to zero, which takes every DCGM series of the node away;
#   a ClusterQueue of one GPU holding one admitted Job while a second waits, for quota exhaustion and for pending
#   without admission; the admitted Job's deletion is what resolves both.
#
# WHAT IT RECORDS, under hack/gpu-alert-delivery-<UTC>/:
#
#   prometheus-transitions.jsonl, each change in Prometheus's active alerts, read every 5 s;
#   alerts-firing-series.json, the ALERTS{alertstate="firing"} samples, whose timestamps are rule evaluations;
#   sink.jsonl, every webhook body the receiver got, with its arrival time;
#   events.tsv, what this script did and when; summary.json, per alert, from those four.
#
# WHAT IT IS NOT: a card, an EKS cluster, or a human receiver. The webhook is the last hop shown; email, Slack or a
# pager would be one more configured receiver, and none is.
#
# Usage: KUSTOMIZE=/path/to/kustomize hack/gpu-alert-delivery.sh   (KEEP=1 leaves the cluster up)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=${CLUSTER:-mon}
CTX=kind-$CLUSTER
KEEP=${KEEP:-0}
KUSTOMIZE=${KUSTOMIZE:-bin/kustomize}
HELM=${HELM:-helm}
CHART=${CHART:-$HOME/.cache/helm/repository/kube-prometheus-stack-88.3.0.tgz}
TAG=alert-delivery
SIM=gpu-simulator:$TAG
BUSYBOX=busybox:1.37.0
OUT=${OUT:-hack/gpu-alert-delivery-$(date -u +%Y%m%dT%H%M%SZ)}
SYS=gpu-platform-control-plane-system
NS=rehearsal
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

# setns rewrites every object's namespace, because the repository's manifests carry the kubebuilder placeholder.
setns() {
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
for d in docs:
    d["metadata"]["namespace"] = sys.argv[1]
print(yaml.safe_dump_all(docs))' "$1"
}

# prom GETs a Prometheus API path through a busybox Pod in the cluster, so no port-forward can drop out halfway.
# Not from the Prometheus container: its image carries no wget, which this script's second run found.
# stderr goes to the log, so a failing exec is read there rather than as an empty answer.
prom() { k -n monitoring exec deploy/probe -- wget -qO- "$PROM_URL$1" 2>>"$LOG"; }
q() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

# inject writes one field of the fake exporter's cache, as hack/lib/gpu-fault.sh does in fake mode.
inject() {
  local ip
  ip=$(k -n "$SYS" get pod -l app.kubernetes.io/component=dcgm-exporter -o jsonpath='{.items[0].status.podIP}')
  [ -n "$ip" ] || die "no fake exporter Pod to inject into"
  k -n monitoring exec deploy/probe -- \
    wget -qO- --post-data '' "http://$ip:9400/inject?gpu=0&field=$1&value=$2" >>"$LOG" 2>&1 || die "inject field $1 value $2"
}

# alert_state prints the state of the named alert in Prometheus, or "inactive".
alert_state() {
  prom /api/v1/alerts | python3 -c '
import json, sys
a = [x for x in json.load(sys.stdin)["data"]["alerts"] if x["labels"]["alertname"] == sys.argv[1]]
print(a[0]["state"] if a else "inactive")' "$1"
}

# received counts webhook bodies at the sink that carry the named alert with the given status.
received() {
  k -n monitoring logs deploy/alert-sink >"$WORK/sink.jsonl" || return 1
  python3 -c '
import json, sys
n = 0
for line in open(sys.argv[3]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    body = json.loads(line)["payload"]
    n += sum(1 for a in body.get("alerts", []) if a["labels"].get("alertname") == sys.argv[1] and a["status"] == sys.argv[2])
print(n)' "$1" "$2" "$WORK/sink.jsonl"
}

# wait_for polls a condition every 5 s until it holds or the deadline passes.
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
got() { local n; n=$(received "$1" "$2") && [ "${n:-0}" -gt 0 ]; }
got_more() { local n; n=$(received "$1" "$2") && [ "${n:-0}" -gt "$3" ]; }

# poll_alerts appends Prometheus's active alerts to the transitions file whenever their set or states change.
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
  echo "dirty_files=$(git status --porcelain -- config hack/gpu-alert-delivery.sh cmd internal | wc -l)"
  echo "kind=$(kind version)"
  echo "kubectl=$(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  echo "helm=$("$HELM" version --short)"
  echo "chart=$(basename "$CHART") sha256=$(sha256sum "$CHART" | cut -d' ' -f1)"
  echo "kueue=$(sed -n 's/^version=//p' config/kueue-controller/RELEASE) from config/kueue-controller"
} >"$OUT/provenance.txt"
log "provenance: $(tr '\n' ' ' <"$OUT/provenance.txt")"

# ---------------------------------------------------------------- cluster and images
log "== images"
docker build -q -t "$SIM" -f Dockerfile.gpu-simulator . >>"$LOG" 2>&1 || die "build $SIM"
echo "gpu_simulator_image=$(docker image inspect "$SIM" --format '{{.Id}}')" >>"$OUT/provenance.txt"

log "== cluster $CLUSTER"
cat >"$WORK/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
EOF
kind create cluster --name "$CLUSTER" --config "$WORK/kind.yaml" >>"$LOG" 2>&1 || die "kind create"
CREATED=1
WORKER=$CLUSTER-worker
echo "node_image=$(docker inspect "$WORKER" --format '{{.Config.Image}}')" >>"$OUT/provenance.txt"
# Only the local build is loaded; busybox and python are pulled by the node.
# A multi-platform image pulled into the host's Docker keeps index entries whose blobs it never fetched, and
# kind load then fails on the first missing digest, as it did on this script's first run with busybox:1.37.0.
kind load docker-image "$SIM" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $SIM"

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
kubeStateMetrics: {enabled: true}
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

# ---------------------------------------------------------------- kueue, from the deployed configuration
log "== kueue from config/kueue-controller"
capped "$KUSTOMIZE" build config/kueue-controller >"$WORK/kueue.yaml" || die "kustomize kueue"
# The gpu ResourceFlavor is refused until Kueue's own webhook answers, as on Argo's wave 1.
for i in $(seq 30); do
  k apply --server-side -f "$WORK/kueue.yaml" >>"$LOG" 2>&1 && break
  [ "$i" = 30 ] && die "kueue apply"
  sleep 10
done
k -n kueue-system rollout status deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue rollout"
k -n kueue-system get cm kueue-manager-config -o jsonpath='{.data.controller_manager_config\.yaml}' \
  >"$OUT/kueue-manager-config.yaml" || die "read kueue config"
grep -q '^  enableClusterQueueResources: true$' "$OUT/kueue-manager-config.yaml" || die "the deployed Kueue config does not enable ClusterQueue resources"

# ---------------------------------------------------------------- gpu capacity and the fake exporter
log "== device plugin and fake exporter on $WORKER"
k create namespace "$SYS" >>"$LOG" 2>&1 || die "namespace $SYS"
k label node "$WORKER" platform.lkhun9311.github.io/train=true >>"$LOG" 2>&1 || die "label worker"
# The device plugin only on the worker, so the control plane advertises no GPU and so needs no exporter.
"$KUSTOMIZE" build config/device-plugin | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
spec = d["spec"]["template"]["spec"]
spec["nodeSelector"] = {"kubernetes.io/hostname": sys.argv[2]}
spec["containers"][0]["image"] = sys.argv[1]
spec["containers"][0]["imagePullPolicy"] = "IfNotPresent"
print(yaml.safe_dump(d))' "$SIM" "$WORKER" | k apply -f - >>"$LOG" 2>&1 || die "device plugin"
# A separate Deployment for the exporter, so scaling it to zero leaves the node's nvidia.com/gpu in place.
# Its own resource name keeps its plugin socket off the device plugin's.
k apply -f - >>"$LOG" 2>&1 <<EOF || die "fake exporter"
apiVersion: apps/v1
kind: Deployment
metadata: {name: fake-dcgm-exporter, namespace: $SYS}
spec:
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: gpu-platform-control-plane, app.kubernetes.io/component: dcgm-exporter}
  template:
    metadata:
      labels: {app.kubernetes.io/name: gpu-platform-control-plane, app.kubernetes.io/component: dcgm-exporter}
    spec:
      nodeSelector: {kubernetes.io/hostname: $WORKER}
      tolerations: [{operator: Exists}]
      terminationGracePeriodSeconds: 1
      containers:
        - name: exporter
          image: $SIM
          imagePullPolicy: IfNotPresent
          command: ["/gpu-simulator"]
          env:
            - {name: FAKE_GPU_COUNT, value: "1"}
            - {name: FAKE_DCGM_ADDR, value: ":9400"}
            - {name: FAKE_RESOURCE_NAME, value: platform.lkhun9311.github.io/fake-dcgm}
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          ports: [{name: metrics, containerPort: 9400}]
          securityContext: {privileged: true, runAsUser: 0, runAsNonRoot: false}
          volumeMounts: [{name: device-plugins, mountPath: /var/lib/kubelet/device-plugins}]
      volumes:
        - name: device-plugins
          hostPath: {path: /var/lib/kubelet/device-plugins, type: Directory}
EOF
k -n "$SYS" rollout status deploy/fake-dcgm-exporter --timeout=300s >>"$LOG" 2>&1 || die "fake exporter rollout"

# ---------------------------------------------------------------- the repository's monitoring objects
log "== rules and monitors"
"$KUSTOMIZE" build config/dcgm-exporter-ops | python3 -c '
import sys, yaml
print(yaml.safe_dump_all([d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] == "PodMonitor"]))' |
  k apply -f - >>"$LOG" 2>&1 || die "podmonitor"
setns "$SYS" <config/prometheus/kueue_monitor.yaml | k apply -f - >>"$LOG" 2>&1 || die "kueue monitor"
setns "$SYS" <config/prometheus/gpu_rules.yaml | k apply -f - >>"$LOG" 2>&1 || die "gpu rules"

# ---------------------------------------------------------------- the queue
log "== ClusterQueue of one GPU"
k create namespace "$NS" >>"$LOG" 2>&1 || die "namespace $NS"
k apply -f - >>"$LOG" 2>&1 <<EOF || die "queues"
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata: {name: cq-gpu}
spec:
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["nvidia.com/gpu"]
      flavors:
        - name: gpu
          resources:
            - {name: nvidia.com/gpu, nominalQuota: 1}
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata: {name: lq, namespace: $NS}
spec: {clusterQueue: cq-gpu}
EOF

job() {
  k apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $1
  namespace: $NS
  labels: {kueue.x-k8s.io/queue-name: lq}
spec:
  suspend: true
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: 1
      containers:
        - name: hold
          image: $BUSYBOX
          imagePullPolicy: IfNotPresent
          command: ["sleep", "7200"]
          resources:
            limits: {nvidia.com/gpu: 1}
EOF
}

# ---------------------------------------------------------------- inputs present before anything is induced
log "== waiting for every input series"
series() { prom "/api/v1/query?query=$(q "$1")" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["data"]["result"]))'; }
has() { local n; n=$(series "$1") && [ "${n:-0}" -gt 0 ]; }
has_rule() {
  prom /api/v1/rules | python3 -c '
import json, sys
names = {r["name"] for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"]}
sys.exit(0 if sys.argv[1] in names else 1)' "$1"
}
wait_for "the gpu rules loaded" 300 has_rule GPUExporterNotReporting || die "rules not loaded"
wait_for "fake DCGM series" 300 has "DCGM_FI_DEV_XID_ERRORS{Hostname=\"$WORKER\"}" || die "fake exporter not scraped"
wait_for "GPU capacity from kube-state-metrics" 300 has "kube_node_status_capacity{node=\"$WORKER\",resource=\"nvidia_com_gpu\"} > 0" ||
  die "no nvidia_com_gpu capacity series"
wait_for "the quota series" 300 has 'kueue_cluster_queue_nominal_quota{cluster_queue="cq-gpu",resource="nvidia.com/gpu"}' ||
  die "Kueue publishes no nominal quota series; enableClusterQueueResources did not take"
for s in "up{job=~\".*dcgm-exporter.*\"}" 'up{job=~".*kueue.*"}' "kube_node_status_capacity{resource=\"nvidia_com_gpu\"}" \
  'kueue_cluster_queue_nominal_quota' 'kueue_cluster_queue_status{cluster_queue="cq-gpu"}' "DCGM_FI_DEV_XID_ERRORS"; do
  prom "/api/v1/query?query=$(q "$s")" >>"$OUT/inputs-before.jsonl" && echo >>"$OUT/inputs-before.jsonl"
done
prom /api/v1/status/config | python3 -c '
import json, sys, re
cfg = json.load(sys.stdin)["data"]["yaml"]
print("\n".join(l for l in cfg.splitlines() if re.search(r"^\s*(scrape_interval|evaluation_interval|scrape_timeout):", l)))' \
  >"$OUT/prometheus-intervals.txt"
prom /api/v1/alerts >"$OUT/alerts-before.json" || die "read alerts"
python3 -c '
import json, sys
names = {"GPUFaultSignalPresent", "GPUFaultFieldsNotCollected", "GPUExporterNotReporting", "KueueClusterQueueGPUQuotaExhausted",
         "KueueGPUQuotaMetricsNotReported", "KueueWorkloadsPendingTooLong"}
a = [x["labels"]["alertname"] for x in json.load(open(sys.argv[1]))["data"]["alerts"] if x["labels"]["alertname"] in names]
sys.exit("already active before anything was induced: %s" % a if a else 0)' "$OUT/alerts-before.json" || die "a GPU alert is active at baseline"

poll_alerts &
POLLER=$!
T0=$(date +%s)
event "start"

# ---------------------------------------------------------------- quota and pending: started first, they take longest
job hold-a >>"$LOG" 2>&1 || die "job hold-a"
event "created job hold-a"
wait_for "hold-a admitted" 120 bash -c "[ \"\$(kubectl --context $CTX -n $NS get job hold-a -o jsonpath='{.spec.suspend}')\" = false ]" ||
  die "hold-a was not admitted"
event "hold-a admitted (spec.suspend false)"
job hold-b >>"$LOG" 2>&1 || die "job hold-b"
event "created job hold-b, which cannot fit: quota exhausted with a workload pending"
sleep 15
k -n "$NS" get workloads -o wide >"$OUT/workloads-while-held.txt" 2>&1
k get clusterqueue cq-gpu -o yaml >"$OUT/clusterqueue-while-held.yaml" 2>&1

# ---------------------------------------------------------------- fault signals
log "== Xid and ECC"
inject 230 13
event "injected Xid 13 (control: an application Xid)"
sleep 90
[ "$(alert_state GPUFaultSignalPresent)" = inactive ] || die "Xid 13 raised GPUFaultSignalPresent"
event "90 s after Xid 13, GPUFaultSignalPresent inactive"

inject 230 79
event "injected Xid 79"
wait_for "GPUFaultSignalPresent firing" 180 is_state GPUFaultSignalPresent firing || die "Xid 79 did not fire"
event "observed GPUFaultSignalPresent firing (xid)"
wait_for "the xid notification" 180 got GPUFaultSignalPresent firing || die "no firing notification for Xid 79"
event "sink holds a firing GPUFaultSignalPresent"
inject 230 0
event "injected Xid 0"
wait_for "the xid resolution" 300 got GPUFaultSignalPresent resolved || die "no resolved notification for Xid"
event "sink holds a resolved GPUFaultSignalPresent"

firing_before=$(received GPUFaultSignalPresent firing)
inject 311 1
event "injected double-bit ECC 1"
wait_for "the ecc notification" 240 got_more GPUFaultSignalPresent firing "$firing_before" || die "no firing notification for ECC"
event "sink holds a second firing GPUFaultSignalPresent"
resolved_before=$(received GPUFaultSignalPresent resolved)
inject 311 0
event "injected double-bit ECC 0"
wait_for "the ecc resolution" 300 got_more GPUFaultSignalPresent resolved "$resolved_before" || die "no resolved notification for ECC"
event "sink holds a second resolved GPUFaultSignalPresent"

# ---------------------------------------------------------------- the exporter goes away
log "== exporter scaled to zero"
k -n "$SYS" scale deploy/fake-dcgm-exporter --replicas=0 >>"$LOG" 2>&1 || die "scale exporter down"
event "scaled fake-dcgm-exporter to 0"
k -n "$SYS" wait --for=delete pod -l app.kubernetes.io/component=dcgm-exporter --timeout=120s >>"$LOG" 2>&1
event "exporter Pod gone"
wait_for "GPUExporterNotReporting firing" 900 is_state GPUExporterNotReporting firing || die "the vanished exporter did not alert"
event "observed GPUExporterNotReporting firing"
wait_for "the exporter notification" 180 got GPUExporterNotReporting firing || die "no firing notification for the exporter"
event "sink holds a firing GPUExporterNotReporting"
k -n "$SYS" scale deploy/fake-dcgm-exporter --replicas=1 >>"$LOG" 2>&1 || die "scale exporter up"
event "scaled fake-dcgm-exporter to 1"
k -n "$SYS" rollout status deploy/fake-dcgm-exporter --timeout=300s >>"$LOG" 2>&1 || die "exporter back"
event "exporter rollout complete"
wait_for "the exporter resolution" 300 got GPUExporterNotReporting resolved || die "no resolved notification for the exporter"
event "sink holds a resolved GPUExporterNotReporting"

# ---------------------------------------------------------------- back to the queue
log "== waiting for the queue alerts"
wait_for "KueueClusterQueueGPUQuotaExhausted firing" 1800 is_state KueueClusterQueueGPUQuotaExhausted firing || die "quota did not fire"
event "observed KueueClusterQueueGPUQuotaExhausted firing"
wait_for "the quota notification" 180 got KueueClusterQueueGPUQuotaExhausted firing || die "no firing notification for quota"
event "sink holds a firing KueueClusterQueueGPUQuotaExhausted"
wait_for "KueueWorkloadsPendingTooLong firing" 2400 is_state KueueWorkloadsPendingTooLong firing || die "pending did not fire"
event "observed KueueWorkloadsPendingTooLong firing"
wait_for "the pending notification" 180 got KueueWorkloadsPendingTooLong firing || die "no firing notification for pending"
event "sink holds a firing KueueWorkloadsPendingTooLong"
[ "$(alert_state KueueGPUQuotaMetricsNotReported)" = inactive ] || die "KueueGPUQuotaMetricsNotReported is active while the quota series exist"
event "KueueGPUQuotaMetricsNotReported inactive throughout the queue phase"

k -n "$NS" delete job hold-a --wait=false >>"$LOG" 2>&1 || die "delete hold-a"
event "deleted job hold-a, so hold-b is admitted and nothing waits"
wait_for "the quota resolution" 300 got KueueClusterQueueGPUQuotaExhausted resolved || die "no resolved notification for quota"
event "sink holds a resolved KueueClusterQueueGPUQuotaExhausted"
wait_for "the pending resolution" 300 got KueueWorkloadsPendingTooLong resolved || die "no resolved notification for pending"
event "sink holds a resolved KueueWorkloadsPendingTooLong"
k -n "$NS" get workloads -o wide >"$OUT/workloads-after.txt" 2>&1

# ---------------------------------------------------------------- record
log "== recording"
kill "$POLLER" >>"$LOG" 2>&1
POLLER=""
END=$(date +%s)
k -n monitoring logs deploy/alert-sink >"$OUT/sink.jsonl" || die "sink log"
# A range selector at one instant returns the raw samples, stamped with the evaluations that wrote them; query_range
# would return them moved onto its own step grid.
prom "/api/v1/query?query=$(q "ALERTS{alertstate=\"firing\"}[$((END - T0 + 60))s]")&time=$END" \
  >"$OUT/alerts-firing-series.json" || die "ALERTS samples"
k get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu' >"$OUT/nodes.txt" 2>&1
k -n monitoring get pods -o wide >"$OUT/monitoring-pods.txt" 2>&1
python3 - "$OUT" <<'PY' || die "summary"
import json, sys, datetime
out = sys.argv[1]
def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
events = [l.rstrip("\n").split("\t", 1) for l in open(out + "/events.tsv")]
sink = [json.loads(l) for l in open(out + "/sink.jsonl") if l.startswith("{")]
series = json.load(open(out + "/alerts-firing-series.json"))["data"]["result"]
rows = []
for s in series:
    m = s["metric"]
    key = {k: v for k, v in m.items() if k not in ("__name__", "alertstate")}
    first = datetime.datetime.fromtimestamp(float(s["values"][0][0]), datetime.timezone.utc)
    last = datetime.datetime.fromtimestamp(float(s["values"][-1][0]), datetime.timezone.utc)
    def match(a):
        return all(a["labels"].get(k) == v for k, v in key.items())
    fired = [(ts(b["received_at"]), a) for b in sink for a in b["payload"].get("alerts", []) if a["status"] == "firing" and match(a)]
    resolved = [(ts(b["received_at"]), a) for b in sink for a in b["payload"].get("alerts", []) if a["status"] == "resolved" and match(a)]
    row = {"labels": key, "prometheus_first_firing_eval": first.isoformat(), "prometheus_last_firing_eval": last.isoformat()}
    if fired:
        r, a = min(fired, key=lambda x: x[0])
        row.update(received_firing_at=r.isoformat(), startsAt=a["startsAt"], firing_to_received_s=round((r - first).total_seconds(), 1))
    if resolved:
        r, a = min(resolved, key=lambda x: x[0])
        row.update(received_resolved_at=r.isoformat(), endsAt=a["endsAt"],
                   resolved_to_received_s=round((r - ts(a["endsAt"])).total_seconds(), 1))
    rows.append(row)
rows.sort(key=lambda r: r["prometheus_first_firing_eval"])
json.dump({"events": events, "alerts": rows}, open(out + "/summary.json", "w"), indent=2)
for r in rows:
    print(r["labels"]["alertname"], r.get("firing_to_received_s"), r.get("resolved_to_received_s"))
PY
log "done; evidence in $OUT"
