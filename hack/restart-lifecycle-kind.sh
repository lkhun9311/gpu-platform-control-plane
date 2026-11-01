#!/usr/bin/env bash
# The free rehearsal of the paid distributed restart session: hack/lib/restart-session.sh's restart_run, unmodified,
# against a throwaway kind cluster `rstlife`, with CPU/gloo ranks sharing an NFS volume, and only what has no kind
# equivalent substituted (hack/lib/restart-kind-shims.sh, hack/test/restart-kind/stubs/aws).
#
#   bash hack/restart-lifecycle-kind.sh            # runs a, b, c and d on one cluster, about three hours
#   RUNS="a" bash hack/restart-lifecycle-kind.sh   # the smoke stage alone
#
# a  RESTART_STAGE=smoke as registered: reference, no-rng-control, dcgm-1, terminate-wait-1, with the replacement
#    joining 150 s after the termination, a plausible lower bound for a g5.xlarge on EKS.
# b  reference; rank-kill-1 whose attempt 2 the queue cannot admit (the tenant's quota lowered to one GPU once attempt 1
#    runs), so it must be FAILED censored at its budget; rank-kill-2, which must still run; terminate-wait-1 with a
#    replacement that joins at once, the replacement path when timing allows it.
# c  reference; rank-kill-1 with a finalizer nothing removes on an attempt-2 Pod, so its retirement cannot complete
#    though the MLTrainingJob goes; rank-kill-2, which must be recorded NOTRUN.
# d  reference; then every node's clock made unreadable, so rank-kill-1 and rank-kill-2 are VOID before their faults,
#    two VOIDs in a row stop the run, and dcgm-1 must be recorded NOTRUN.
# Evidence goes to hack/restart-lifecycle-kind-<UTC>/, one RESTART_OUT per run; KEEP=1 keeps the cluster.
#
# The cluster's setup is hack/distributed-restart-kind.sh's STORAGE=nfs setup with the same pins (cert-manager, the
# NFS-Ganesha server and its configuration, the EFS mount options, the controllers on the control plane), written out
# here rather than shared, because that script is the recorded harness of committed evidence runs.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=rstlife
CONTEXT=kind-$CLUSTER
SYS=gpu-platform-control-plane-system
TAG=rstlife
IMG=distributed-restart:torch251
CERT_MANAGER_VERSION=v1.21.1
RUNS="${RUNS:-a b c d}"
OUT=hack/restart-lifecycle-kind-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
export RSTK_STATE="$OUT/state"
mkdir -p "$RSTK_STATE/killed" "$RSTK_STATE/unlaunched" "$RSTK_STATE/gone"
: >"$RSTK_STATE/instances"
: >"$RSTK_STATE/launch_delays"
echo 0 >"$RSTK_STATE/desired"
# The host's inotify instances are shared with the other kind clusters, and kernel parameters are not changed here: with
# eight workers a kubelet never came up, and with six three kube-proxies crash-looped, so the cluster is five nodes.
# The control plane is also the CPU node the reader lands on; three workers are the purchased GPU nodes and the fourth
# the autoscaler's pool, which killed machines rejoin (rstk_recycle).
CPU_NODE=$CLUSTER-control-plane
export RSTK_GPU_CONTAINERS="$CLUSTER-worker $CLUSTER-worker2 $CLUSTER-worker3 $CLUSTER-worker4"
ALL_WORKERS="$RSTK_GPU_CONTAINERS"
GANESHA_IMG=registry.k8s.io/sig-storage/nfs-provisioner@sha256:c825f3d5e28bde099bd7a3daace28772d412c9157ad47fa752a9ad0baafc118d
EFS_OPTS="nfsvers=4.1 rsize=1048576 wsize=1048576 hard timeo=600 retrans=2 noresvport"
EXPORT=/var/local/rstlife-export
DELEG=/sys/module/nfsv4/parameters/directory_delegations
DELEG_WAS=""
set_deleg() { docker run --rm --privileged --network none --entrypoint sh "$IMG" -c "echo $1 > $DELEG"; }

log() { echo -e "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
k() { kubectl --context "$CONTEXT" "$@"; }
retry() {
  for _ in $(seq 1 40); do "$@" && return 0; sleep 3; done
  return 1
}
BG=()
# Set only once this invocation has found no cluster of the name and is about to create one, so a refusal never removes
# a cluster it did not make (codex review of 69ec494f).
OWNED=""
cleanup() {
  local p listed
  for p in "${BG[@]}"; do kill "$p" 2>>"$LOG"; done
  if [ -n "$DELEG_WAS" ]; then
    set_deleg "$DELEG_WAS" >>"$LOG" 2>&1 || log "cleanup: restoring $DELEG to $DELEG_WAS FAILED"
    log "cleanup: $DELEG is now $(cat "$DELEG" 2>&1), was $DELEG_WAS"
  fi
  [ -n "$OWNED" ] || { log "cleanup: $CLUSTER was not created by this run, so it is left alone"; return; }
  [ "${KEEP:-0}" = 1 ] && { log "cleanup: KEEP=1, leaving $CLUSTER"; return; }
  # The control plane is an NFS client too, through the reader Pod, and the server runs on it: removed together, the
  # client's goodbye to its own dead server held the container for minutes (the first full rehearsal), so every Pod
  # mounting the volume goes while the server still answers.
  k -n "$RESTART_NS" delete pods --all --wait=true --timeout=120s >>"$LOG" 2>&1 || log "cleanup: the training namespace's Pods did not all go"
  # The workers go first, while the NFS server still answers (hack/distributed-restart-kind.sh, STORAGE=nfs).
  for p in $ALL_WORKERS; do
    docker rm -f "$p" >>"$LOG" 2>&1 || log "cleanup: removing $p failed"
  done
  listed=$(kind get clusters 2>>"$LOG") || log "cleanup: kind get clusters failed"
  if grep -qx "$CLUSTER" <<<"$listed"; then
    for p in 1 2 3 4 5; do
      kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 && break
      log "cleanup: kind delete failed (try $p), retrying in 60 s"
      sleep 60
    done
    listed=$(kind get clusters 2>>"$LOG")
    if grep -qx "$CLUSTER" <<<"$listed"; then log "cleanup: $CLUSTER STILL EXISTS"; else log "cleanup: deleted $CLUSTER"; fi
  fi
  log "cleanup: kind clusters now: $(tr '\n' ' ' <<<"$listed")"
}
trap cleanup EXIT
die() {
  log "VOID: $*"
  echo "$*" >"$OUT/VOID"
  { k get pods -A -o wide; k get nodes -o wide; k get events -A --sort-by=.lastTimestamp | tail -80; } >>"$OUT/failure-state.txt" 2>&1
  exit 1
}

for r in $RUNS; do case "$r" in a | b | c | d) ;; *) die "run '$r' is not a, b, c or d" ;; esac; done
for tool in docker kind kubectl python3 make; do command -v "$tool" >/dev/null || die "missing tool $tool"; done
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && die "a cluster $CLUSTER already exists; delete it by hand after checking it is not someone else's"

# No AWS call may reach AWS: the stub is first on PATH, and no profile or credential file is left for a real CLI.
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export PATH="$PWD/hack/test/restart-kind/stubs:$PATH"
[ "$(command -v aws)" = "$PWD/hack/test/restart-kind/stubs/aws" ] || die "aws resolves to $(command -v aws), not the stub"

# The four libraries the session sources, then the substitutions, sourced here at the top level, because
# hack/lib/gpu-fault.sh declares its associative arrays where it is sourced and a function would make them local.
# shellcheck source=hack/lib/train-session.sh
. hack/lib/train-session.sh
# shellcheck source=hack/lib/gpu-ttl.sh
. hack/lib/gpu-ttl.sh
# shellcheck source=hack/lib/gpu-fault.sh
. hack/lib/gpu-fault.sh
# shellcheck source=hack/lib/restart-session.sh
. hack/lib/restart-session.sh
# shellcheck source=hack/lib/restart-kind-shims.sh
. hack/lib/restart-kind-shims.sh
# In this shell, not a command substitution: a subshell would install them and throw them away (codex review of 69ec494f).
rstk_install 2>>"$LOG" || die "the substitutions did not apply; see $LOG"
[ "$RESTART_IMAGE" = "$IMG" ] && declare -f train_qualify_nodes | grep -qF component=dcgm-exporter ||
  die "the substitutions are not in force in the driver's shell"
# The registered case list, kept so a run of the registered stage uses it after a scenario run chose its own cases.
eval "rstk_registered_cases() $(declare -f restart_cases | tail -n +2)"

export RESTART_CONTEXT=$CONTEXT RESTART_REGION=ap-northeast-2 RESTART_CLUSTER=$CLUSTER RESTART_GROUP=gpu RESTART_NS=train-a
export RESTART_QUEUE=gpu-train-a RESTART_SYS=$SYS RESTART_FS_ID=fs-0000000000kind
# The session's own defaults (hack/eks-gitops-session.sh), which restart_gpu_budget adds up.
WAIT_GPU_NODE=900 WAIT_GPU_PLUGIN=600 WAIT_GPU_GONE=600 WAIT_QUAL_RUN=1500

COMMIT=$(git rev-parse HEAD)
# Every change but this run's own evidence directory, which is untracked while it is written.
DIRTY=$(git status --porcelain -- . ":(exclude)$OUT" | wc -l)
{
  echo "commit=$COMMIT"
  echo "dirty_files=$DIRTY"
  echo "kind=$(kind version)"
  echo "cert_manager=$CERT_MANAGER_VERSION"
  echo "nfs_server_image=$GANESHA_IMG"
  echo "nfs_efs_options=$EFS_OPTS"
  echo "host_kernel=$(uname -r)"
  echo "runs=$RUNS"
} >"$OUT/provenance.txt"
log "provenance: $(tr '\n' ' ' <"$OUT/provenance.txt")"
[ "$DIRTY" = 0 ] || log "WARNING: the tree has $DIRTY uncommitted change(s); the scorer will refuse every run"

log "== images"
docker build -q -t "$IMG" experiments/distributed-restart >>"$LOG" 2>&1 || die "image build"
make docker-build IMG=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$LOG" 2>&1 || die "simulator image"
docker pull -q "$RESTART_READER_IMAGE" >>"$LOG" 2>&1 || die "busybox"
echo "workload_image=$(docker image inspect "$IMG" --format '{{.Id}}')" >>"$OUT/provenance.txt"

log "== cluster $CLUSTER"
{
  echo "kind: Cluster"
  echo "apiVersion: kind.x-k8s.io/v1alpha4"
  echo "nodes:"
  echo "  - role: control-plane"
  for _ in $ALL_WORKERS; do echo "  - role: worker"; done
} >"$OUT/kind-config.yaml"
OWNED=1
kind create cluster --name "$CLUSTER" --config "$OUT/kind-config.yaml" >>"$LOG" 2>&1 || die "kind create"
echo "node_image=$(docker inspect "$CPU_NODE" --format '{{.Config.Image}}')" >>"$OUT/provenance.txt"
for img in controller:$TAG gpu-simulator:$TAG "$IMG"; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"
done
k label node "$CPU_NODE" eks.amazonaws.com/nodegroup=cpu >>"$LOG" 2>&1 || die "label the CPU node"
# Untainted, so restart_reader's Pod, which tolerates nothing, can land on it; the ranks select the GPU nodes' train label.
k taint node "$CPU_NODE" node-role.kubernetes.io/control-plane:NoSchedule- >>"$LOG" 2>&1 || die "untaint the CPU node"
# A kube-proxy that cannot start is a node whose Services do not work, which is how the host's inotify limit showed.
for _ in $(seq 1 40); do
  bad=$(k -n kube-system get pods -l k8s-app=kube-proxy -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>>"$LOG" | grep -vc true)
  [ "$bad" = 0 ] && break
  sleep 3
done
[ "$bad" = 0 ] || die "$bad kube-proxy Pod(s) not ready; the host's inotify instances may be exhausted"
k apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml" >>"$LOG" 2>&1 || die "cert-manager"
k -n cert-manager wait --for=condition=Available deploy --all --timeout=300s >>"$LOG" 2>&1 || die "cert-manager Available"
# Kueue as EKS deploys it: the vendored release and this repository's gpu ResourceFlavor with the train label and the
# GPU taint's toleration, so the ranks land only on GPU nodes and tolerate their taint as on EKS.
# Kueue's webhook validates the flavor, so everything but the flavor goes first, as Argo's sync waves order it on EKS.
kubectl kustomize config/kueue-controller >"$OUT/kueue.yaml" 2>>"$LOG" || die "rendering config/kueue-controller"
python3 -c '
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
print("\n---\n".join(d for d in docs if "\nkind: ResourceFlavor\n" not in "\n" + d + "\n"))' "$OUT/kueue.yaml" >"$OUT/kueue-without-flavor.yaml" || die "splitting the flavor out"
k apply --server-side -f "$OUT/kueue-without-flavor.yaml" >>"$LOG" 2>&1 || die "kueue"
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue Available"
# shellcheck disable=SC2317  # called through retry
apply_kueue() { k apply --server-side -f "$OUT/kueue.yaml" >>"$LOG" 2>&1; }
retry apply_kueue || die "kueue's flavor once its webhook answers"
k get resourceflavor gpu -o jsonpath='{.spec.nodeLabels}' 2>>"$LOG" | grep -q train || die "the gpu flavor carries no train nodeLabel"
kubectl kustomize config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
# shellcheck disable=SC2317  # called through retry
apply_operator() { kubectl kustomize config/operator-webhook | k apply --server-side -f - >>"$LOG" 2>&1; }
retry apply_operator || die "operator"
OPDEP=$(k -n "$SYS" get deploy -o name | grep controller-manager | head -1)
[ -n "$OPDEP" ] || die "no controller-manager deployment"
k -n "$SYS" set image "$OPDEP" manager=controller:$TAG >>"$LOG" 2>&1 || die "operator image set"
# The fault flags exactly as restart_enable_fault_path adds them; its Argo half has nothing to act on here.
k -n "$SYS" patch "$OPDEP" --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"IfNotPresent\"},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"${RESTART_FAULT_FLAGS[0]}\"},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"${RESTART_FAULT_FLAGS[1]}\"}]" >>"$LOG" 2>&1 ||
  die "operator pull policy and fault flags"
# The controllers run on the control plane, so terminating a GPU node can only take ranks with it.
pin='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},
  "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
for dep in "$SYS/${OPDEP#*/}" kueue-system/kueue-controller-manager cert-manager/cert-manager \
  cert-manager/cert-manager-webhook cert-manager/cert-manager-cainjector kube-system/coredns; do
  retry k -n "${dep%%/*}" patch deploy "${dep#*/}" --type=strategic -p "$pin" >>"$LOG" 2>&1 || die "pin $dep"
  k -n "${dep%%/*}" rollout status deploy "${dep#*/}" --timeout=240s >>"$LOG" 2>&1 || die "rollout of pinned $dep"
done

log "== nfs server"
# Kernel 7.0's NFS client asks for directory delegations, ganesha 4.0.8 answers NFS4ERR_OP_ILLEGAL and the client then
# fails directory reads with EREMOTEIO (hack/distributed-restart-kind.sh); the host parameter is put back on exit.
[ -d /sys/module/nfsv4 ] || docker exec "$CLUSTER-control-plane" sh -c "modprobe nfsv4" >>"$LOG" 2>&1 || die "loading nfsv4"
if [ -e "$DELEG" ]; then
  DELEG_WAS=$(cat "$DELEG" 2>>"$LOG") || die "reading $DELEG"
  set_deleg N >>"$LOG" 2>&1 || die "setting $DELEG"
  [ "$(cat "$DELEG")" = N ] || die "$DELEG is not N after setting it"
fi
echo "directory_delegations_was=${DELEG_WAS:-absent}" >>"$OUT/provenance.txt"
# shellcheck disable=SC2317  # called through retry
apply_nfs() {
  cat <<EOF | k apply -f - >>"$LOG" 2>&1
apiVersion: v1
kind: Namespace
metadata:
  name: nfs
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ganesha
  namespace: nfs
data:
  ganesha.conf: |
    NFS_CORE_PARAM {
      Protocols = 4;
      NFS_Port = 2049;
      Enable_NLM = false;
      Enable_RQUOTA = false;
    }
    NFSV4 {
      Graceless = true;
      Minor_Versions = 1, 2;
      Allow_Numeric_Owners = true;
      Only_Numeric_Owners = true;
      Delegations = false;
      RecoveryRoot = /var/lib/nfs/ganesha;
    }
    EXPORT {
      Export_Id = 1;
      Path = /export;
      Pseudo = /;
      Access_Type = RW;
      Squash = No_Root_Squash;
      Protocols = 4;
      Transports = TCP;
      SecType = sys;
      FSAL { Name = VFS; }
    }
    LOG { Default_Log_Level = EVENT; }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ganesha
  namespace: nfs
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: ganesha}
  template:
    metadata:
      labels: {app: ganesha}
    spec:
      nodeSelector: {node-role.kubernetes.io/control-plane: ""}
      tolerations:
        - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
      containers:
        - name: ganesha
          image: $GANESHA_IMG
          command: ["sh", "-c", "mkdir -p /usr/local/var/run/ganesha /var/lib/nfs/ganesha && exec ganesha.nfsd -F -L /dev/stdout -f /etc/ganesha/ganesha.conf -p /usr/local/var/run/ganesha/ganesha.pid"]
          securityContext: {privileged: true}
          ports: [{containerPort: 2049}]
          volumeMounts:
            - {name: export, mountPath: /export}
            - {name: config, mountPath: /etc/ganesha}
            - {name: state, mountPath: /var/lib/nfs/ganesha}
      volumes:
        - name: export
          hostPath: {path: $EXPORT, type: DirectoryOrCreate}
        - name: config
          configMap: {name: ganesha}
        - name: state
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ganesha
  namespace: nfs
spec:
  selector: {app: ganesha}
  ports: [{name: nfs, port: 2049}]
EOF
}
retry apply_nfs || die "nfs server"
k -n nfs rollout status deploy/ganesha --timeout=240s >>"$LOG" 2>&1 || die "nfs server rollout"
NFS_IP=$(k -n nfs get svc ganesha -o jsonpath='{.spec.clusterIP}' 2>>"$LOG")
[ -n "$NFS_IP" ] || die "no ClusterIP for the nfs server"
echo "nfs_server=$NFS_IP" >>"$OUT/provenance.txt"

log "== training namespace, queue and volume"
# shellcheck disable=SC2317  # called through retry
apply_training() { kubectl kustomize config/training | k apply -f - >>"$LOG" 2>&1; }
retry apply_training || die "config/training"
# The registered claim's name and binding, on the NFS server with the EFS options instead of the EFS CSI driver.
{
  cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $RESTART_CLAIM-$RESTART_NS
spec:
  capacity:
    storage: 100Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
EOF
  for o in $EFS_OPTS; do echo "    - $o"; done
  cat <<EOF
  nfs:
    server: $NFS_IP
    path: /
  claimRef:
    namespace: $RESTART_NS
    name: $RESTART_CLAIM
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $RESTART_CLAIM
  namespace: $RESTART_NS
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  volumeName: $RESTART_CLAIM-$RESTART_NS
  resources:
    requests:
      storage: 100Gi
EOF
} >"$OUT/volume.yaml"
k apply -f "$OUT/volume.yaml" >>"$LOG" 2>&1 || die "volume"
k -n "$RESTART_NS" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$RESTART_CLAIM" --timeout=120s >>"$LOG" 2>&1 || die "claim not Bound"
lq=""
for _ in $(seq 1 60); do
  lq=$(k -n "$RESTART_NS" get localqueue "$RESTART_QUEUE" -o name 2>>"$LOG") && [ -n "$lq" ] && break
  sleep 3
done
[ -n "$lq" ] || die "no LocalQueue $RESTART_QUEUE"

log "== the GPU device and DCGM path"
# The gpu-simulator is the device plugin and the DCGM exporter of each GPU node: labelled as the exporter the operator,
# restart_exporters and gf_exporter_pod select, with two sidecars named as the EKS exporter Pod's containers:
# `exporter` answers the clock probe's date, and `hostengine` has a dcgmi that writes and reads the simulator's fake
# DCGM over the Pod's own loopback.
# The sidecars run the CPU trainer image, already on every node, because the pinned busybox prints a literal %N.
cat >"$OUT/dcgmi" <<'EOF'
#!/usr/local/bin/python
"""dcgmi as hack/lib/restart-session.sh and hack/lib/gpu-fault.sh call it, answered by the gpu-simulator's fake DCGM."""
import sys
import urllib.request

args = sys.argv[1:]
if args[:2] == ["test", "--inject"]:
    opts = dict(zip(args[2::2], args[3::2]))
    unknown = set(opts) - {"--gpuid", "-f", "-v", "--offset"}
    if unknown or len(args[2:]) % 2:
        sys.exit(f"dcgmi shim: {' '.join(args)} has options it does not implement")
    q = f"gpu={opts.get('--gpuid', '0')}&field={opts['-f']}&value={opts['-v']}&offset={opts.get('--offset', '1')}"
    print(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:9400/inject?{q}", data=b"", method="POST"), timeout=10).read().decode().strip())
elif args[:2] == ["dmon", "-e"] and args[3:] == ["-i", "0", "-c", "1"]:
    v = urllib.request.urlopen(f"http://127.0.0.1:9400/introspect?gpu=0&field={args[2]}", timeout=10).read().decode().strip()
    print("#Entity   FIELD\nID\nGPU 0     " + v)
else:
    sys.exit(f"dcgmi shim: {' '.join(args)} is not implemented")
EOF
k -n "$SYS" create configmap rstk-dcgmi --from-file=dcgmi="$OUT/dcgmi" --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1 || die "dcgmi configmap"
cat >"$OUT/gpu-simulator.yaml" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gpu-simulator
  namespace: $SYS
spec:
  selector:
    matchLabels: {rehearsal.lkhun9311.github.io/role: gpu}
  template:
    metadata:
      labels:
        rehearsal.lkhun9311.github.io/role: gpu
        app.kubernetes.io/component: dcgm-exporter
    spec:
      priorityClassName: system-node-critical
      nodeSelector: {eks.amazonaws.com/nodegroup: gpu}
      tolerations: [{operator: Exists}]
      terminationGracePeriodSeconds: 5
      containers:
        - name: gpu-simulator
          image: gpu-simulator:$TAG
          imagePullPolicy: IfNotPresent
          command: ["/gpu-simulator"]
          env:
            - {name: FAKE_GPU_COUNT, value: "1"}
            - {name: FAKE_DCGM_ADDR, value: ":9400"}
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
          securityContext: {privileged: true, runAsUser: 0, runAsNonRoot: false}
          volumeMounts: [{name: device-plugins, mountPath: /var/lib/kubelet/device-plugins}]
        - name: exporter
          image: $IMG
          imagePullPolicy: IfNotPresent
          command: ["sleep", "infinity"]
          # /ctl comes first, so run d can make this node's date fail without restarting the Pod.
          env: [{name: PATH, value: "/ctl:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}]
          volumeMounts: [{name: ctl, mountPath: /ctl}]
        - name: hostengine
          image: $IMG
          imagePullPolicy: IfNotPresent
          command: ["sleep", "infinity"]
          env: [{name: PATH, value: "/shim:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}]
          volumeMounts: [{name: dcgmi, mountPath: /shim}]
      volumes:
        - name: device-plugins
          hostPath: {path: /var/lib/kubelet/device-plugins, type: Directory}
        - name: dcgmi
          configMap: {name: rstk-dcgmi, defaultMode: 0755}
        - name: ctl
          emptyDir: {}
EOF
k apply -f "$OUT/gpu-simulator.yaml" >>"$LOG" 2>&1 || die "gpu simulator"

log "== the GPU nodes"
# Every GPU container leaves the cluster first, so each node of the group is a Node object made by a launch, and the
# first three are launched as the purchase.
for c in $RSTK_GPU_CONTAINERS; do rstk_unlaunch "$c" >>"$LOG" 2>&1 || die "taking back $c"; done
for c in $CLUSTER-worker $CLUSTER-worker2 $CLUSTER-worker3; do rstk_launch "$c" >>"$LOG" 2>&1 || die "launching $c"; done
echo 3 >"$RSTK_STATE/desired"
rstk_asg_loop >>"$RSTK_STATE/asg.log" 2>&1 &
BG+=($!)

# Every event of the training namespace's MLTrainingJobs, Jobs, Pods and Workloads, as received, so check_lifecycle.py
# can replay what existed when each case was submitted.
for res in mltrainingjobs jobs.batch pods workloads.kueue.x-k8s.io; do
  python3 hack/test/restart-kind/watch_events.py "$CONTEXT" "$RESTART_NS" "$res" "$OUT/events-${res%%.*}.jsonl" 2>>"$LOG" &
  BG+=($!)
done
echo "host_nfs_mounts_at_start=$(grep -c ' nfs4\? ' /proc/mounts)" >>"$OUT/provenance.txt"

# run_stage NAME CASES: one session's worth of restart_run over CASES (registered names in the registered order) into
# $OUT/run-NAME, as train_run_restart in hack/eks-gitops-session.sh runs it.
run_stage() {
  local name="$1" cases="$2" warmed budget dl
  export RESTART_OUT="$OUT/run-$name"
  mkdir -p "$RESTART_OUT"
  export RESTART_INSTANCES_FILE="$RESTART_OUT/instances.txt"
  warmed="$RESTART_OUT/warmed.txt"
  : >"$warmed"
  if [ "$cases" = smoke ]; then
    export RESTART_STAGE=smoke
    eval "restart_cases() $(declare -f rstk_registered_cases | tail -n +2)"
  else
    # A subset of full, in full's order; overriding restart_cases chooses the cases and changes nothing else.
    export RESTART_STAGE=full
    eval "restart_cases() { printf '%s\n' $cases; }"
  fi
  # The purchase: the group back at three, which the session's scale-up does.
  echo 3 >"$RSTK_STATE/desired"
  # The GPU deadline the session arms after the purchase, as the stub's one schedule.
  budget=$(restart_gpu_budget) || die "run $name: no GPU budget"
  dl=$(date -u -d "+$((budget + 3600)) seconds" +%Y-%m-%dT%H:%M:%S)
  echo "$dl" >"$RSTK_STATE/deadline"
  log "run $name: cases $(restart_cases | paste -sd' '), GPU budget ${budget}s, deadline $dl"
  out=$(restart_wait_group 3 $((WAIT_GPU_NODE + WAIT_GPU_PLUGIN))) || die "run $name: T6/T7: $out"
  log "run $name: $out"
  {
    echo "commit=$COMMIT"
    echo "dirty_files=$DIRTY"
    echo "train_py_sha256=$(sha256sum "$RESTART_TRAIN_PY" | cut -d' ' -f1)"
    # No registration approves a hash on kind; the approved hash is the one run, which is a substitution.
    echo "approved_train_py_sha256=$(sha256sum "$RESTART_TRAIN_PY" | cut -d' ' -f1)"
    echo "workload_image=$RESTART_IMAGE"
    echo "steps=$RESTART_STEPS"
    echo "step_sleep=$RESTART_STEP_SLEEP"
    echo "ballast_mb=$RESTART_BALLAST_MB"
    echo "collective_timeout=$RESTART_COLLECTIVE_TIMEOUT"
    echo "case_budget=$RESTART_CASE_BUDGET"
    echo "stage=$RESTART_STAGE"
    echo "gpu_budget_s=$budget"
    echo "efs=none: NFS-Ganesha $NFS_IP with $EFS_OPTS"
    echo "nodes=$(paste -sd' ' "$RESTART_INSTANCES_FILE")"
    echo "cases=$(restart_cases | paste -sd' ')"
  } >"$RESTART_OUT/provenance.txt"
  out=$(restart_reader) || die "run $name: R3: $out"
  log "run $name: R3: $out"
  out=$(restart_prepare_nodes "$warmed" $((SECONDS + RESTART_WARM_BUDGET))) || die "run $name: R5: $out"
  log "run $name: R5: $out"
  out=$(restart_fault_path_ready "$RESTART_SIGNAL_BUDGET") || die "run $name: R6: $out"
  log "run $name: R6: $out"
  restart_run "$warmed" 2>&1 | tee -a "$RESTART_OUT/run.log" "$LOG"
  python3 hack/test/restart-kind/score_kind_shim.py "$RESTART_OUT" >"$RESTART_OUT/verdict.txt" 2>&1
  echo "exit=$?" >>"$RESTART_OUT/verdict.txt"
  python3 experiments/distributed-restart/score_eks.py "$RESTART_OUT" >"$RESTART_OUT/verdict-unmodified-scorer.txt" 2>&1
  echo "exit=$?" >>"$RESTART_OUT/verdict-unmodified-scorer.txt"
  log "run $name: verdict (kind shim scorer):"
  tee -a "$LOG" <"$RESTART_OUT/verdict.txt"
  log "run $name: verdict (score_eks.py unmodified):"
  tee -a "$LOG" <"$RESTART_OUT/verdict-unmodified-scorer.txt"
}

# mltj_of CASE: the MLTrainingJob name of CASE in this run, once it exists.
mltj_of() {
  local m=""
  while [ -z "$m" ]; do
    m=$(k -n "$RESTART_NS" get mltrainingjobs -o name 2>>"$LOG" | grep "/rst-$1-" | head -1)
    [ -n "$m" ] || sleep 1
  done
  echo "${m#*/}"
}

# hold_quota CASE: the tenant's quota lowered to one GPU once CASE's attempt 1 runs on two, so its attempt 2 cannot be
# admitted; restored to four once CASE's MLTrainingJob is gone.
hold_quota() {
  local m n=0 cq
  m=$(mltj_of "$1")
  until [ "$n" = 2 ]; do
    n=$(k -n "$RESTART_NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$m" --field-selector status.phase=Running -o name 2>>"$LOG" | grep -c .)
    sleep 1
  done
  k patch gpuquotapolicy train-a-quota --type=merge -p '{"spec":{"limits":{"gpuCount":1}}}' >>"$LOG" 2>&1 || log "hold_quota: lowering failed"
  sleep 5
  cq=$(k get clusterqueues -o json 2>>"$LOG" | python3 -c 'import json,sys; print([(c["metadata"]["name"], c["spec"]["resourceGroups"]) for c in json.load(sys.stdin)["items"]])')
  log "hold_quota: $m running on two GPUs, quota lowered to 1 at $(date -u +%H:%M:%S); clusterqueues: $cq; resourcequotas: $(k -n "$RESTART_NS" get resourcequota -o jsonpath='{range .items[*]}{.metadata.name}={.spec.hard}{" "}{end}' 2>&1)"
  echo "lowered $(date -u +%Y-%m-%dT%H:%M:%SZ) $m" >>"$OUT/quota-hold.txt"
  while k -n "$RESTART_NS" get mltrainingjob "$m" -o name >/dev/null 2>>"$OUT/quota-hold.err"; do sleep 1; done
  k patch gpuquotapolicy train-a-quota --type=merge -p '{"spec":{"limits":{"gpuCount":4}}}' >>"$LOG" 2>&1 || log "hold_quota: restoring failed"
  echo "restored $(date -u +%Y-%m-%dT%H:%M:%SZ) $m" >>"$OUT/quota-hold.txt"
  log "hold_quota: $m gone, quota restored to 4 at $(date -u +%H:%M:%S)"
}

# stick_pod CASE: a finalizer nothing removes on CASE's first attempt-2 Pod, so the case can finish while its retirement
# cannot, with the MLTrainingJob itself free to go.
STUCK=rehearsal.lkhun9311.github.io/stuck
stick_pod() {
  local m pod=""
  m=$(mltj_of "$1")
  while [ -z "$pod" ]; do
    pod=$(k -n "$RESTART_NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$m,platform.lkhun9311.github.io/mltrainingjob-attempt=2" -o name 2>>"$LOG" | head -1)
    [ -n "$pod" ] || sleep 1
  done
  # Appended, never set: a Job's Pod carries the Job controller's tracking finalizer, and replacing the list once made the
  # controller lose the Pod and start a second rank 0, so attempt 2 failed instead of finishing (the first rehearsal).
  k -n "$RESTART_NS" patch "$pod" --type=json -p "[{\"op\":\"add\",\"path\":\"/metadata/finalizers/-\",\"value\":\"$STUCK\"}]" >>"$LOG" 2>&1 ||
    { log "stick_pod: could not add $STUCK to $pod"; return 1; }
  echo "$pod" >"$OUT/stuck.txt"
  log "stick_pod: $STUCK on $pod of $m at $(date -u +%H:%M:%S)"
}

# break_clocks: once the run's reference is scored, every exporter sidecar's date fails, so no node's clock can be read.
break_clocks() {
  local p
  until [ -e "$RESTART_OUT/run.log" ] && grep -q '^reference: ' "$RESTART_OUT/run.log"; do sleep 1; done
  for p in $(k -n "$SYS" get pods -l app.kubernetes.io/component=dcgm-exporter -o name); do
    k -n "$SYS" exec "${p#*/}" -c exporter -- sh -c 'printf "#!/bin/sh\necho rehearsal: this clock is made unreadable >&2\nexit 1\n" >/ctl/date && chmod +x /ctl/date' >>"$LOG" 2>&1 ||
      log "break_clocks: $p not broken"
  done
  log "break_clocks: every exporter's date fails from $(date -u +%H:%M:%S)"
  echo "broken $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$OUT/clocks-broken.txt"
}

mend_clocks() {
  local p
  for p in $(k -n "$SYS" get pods -l app.kubernetes.io/component=dcgm-exporter -o name); do
    k -n "$SYS" exec "${p#*/}" -c exporter -- rm -f /ctl/date >>"$LOG" 2>&1 || log "mend_clocks: $p not mended"
  done
}

for r in $RUNS; do
  case "$r" in
    a)
      echo 150 >"$RSTK_STATE/launch_delays"
      run_stage a smoke
      ;;
    b)
      # The purchase's top-up and terminate-wait-1's replacement both at once.
      printf '5\n5\n' >"$RSTK_STATE/launch_delays"
      export RESTART_OUT="$OUT/run-b"
      hold_quota rank-kill-1 &
      BG+=($!)
      run_stage b "reference rank-kill-1 rank-kill-2 terminate-wait-1"
      ;;
    c)
      echo 5 >"$RSTK_STATE/launch_delays"
      stick_pod rank-kill-1 &
      BG+=($!)
      run_stage c "reference rank-kill-1 rank-kill-2"
      if [ -s "$OUT/stuck.txt" ]; then
        stuck=$(cat "$OUT/stuck.txt")
        fins=$(k -n "$RESTART_NS" get "$stuck" -o json 2>>"$LOG" | python3 -c '
import json, sys
print(json.dumps([f for f in json.load(sys.stdin)["metadata"].get("finalizers", []) if f != sys.argv[1]]))' "$STUCK")
        k -n "$RESTART_NS" patch "$stuck" --type=merge -p "{\"metadata\":{\"finalizers\":${fins:-[]}}}" >>"$LOG" 2>&1 || log "could not remove $STUCK from $stuck"
        if k -n "$RESTART_NS" wait --for=delete "$stuck" --timeout=120s >>"$LOG" 2>&1; then log "removed $STUCK from $stuck, and it is gone"; else log "removed $STUCK from $stuck, and it is STILL there"; fi
      fi
      ;;
    d)
      echo 5 >"$RSTK_STATE/launch_delays"
      export RESTART_OUT="$OUT/run-d"
      mkdir -p "$RESTART_OUT"
      break_clocks &
      BG+=($!)
      run_stage d "reference rank-kill-1 rank-kill-2 dcgm-1"
      mend_clocks
      ;;
  esac
done

log "== what the runner's own files cannot show (check_lifecycle.py)"
python3 hack/test/restart-kind/check_lifecycle.py "$OUT" >"$OUT/lifecycle-check.txt" 2>&1
CHECK_RC=$?
echo "exit=$CHECK_RC" >>"$OUT/lifecycle-check.txt"
tee -a "$LOG" <"$OUT/lifecycle-check.txt"
k -n "$RESTART_NS" get mltrainingjobs,jobs.batch,pods,workloads.kueue.x-k8s.io -o wide >"$OUT/train-a-at-end.txt" 2>&1
cp "$RSTK_STATE/calls.log" "$OUT/aws-calls.log" 2>>"$LOG"
log "unimplemented aws calls: $(grep -c '^UNIMPLEMENTED' "$RSTK_STATE/calls.log")"
echo "host_nfs_mounts_at_end=$(grep -c ' nfs4\? ' /proc/mounts)" >>"$OUT/provenance.txt"
# The rehearsal fails when what the runner's files cannot show did not hold (codex review of 69ec494f).
exit "$CHECK_RC"
