# shellcheck shell=bash
# The gates a training session (TRAIN=ddp in hack/eks-gitops-session.sh) passes before and after it buys two GPU
# nodes, as functions, so each can be tested by calling it with aws and kubectl replaced by stubs.
#
# The session runs `terraform apply` before most of these, so a test of the whole script could reach none of them
# without spending (docs/superpowers/specs/2026-10-16-nccl-groundwork-design.md, section 5).
# hack/test/check-train-session-lib.sh is that test.
#
# Every function prints one line saying what it found and returns 0, or prints why it refused and returns 1.
# A query that fails is a refusal, never an empty answer: a guard that reads an error as "nothing there" passes
# exactly when it cannot see.

# The account quota "Running On-Demand G and VT instances", in vCPU.
TRAIN_GPU_QUOTA_CODE="L-DB2E81BA"
# Seconds between polls; the test sets 0.
TRAIN_POLL="${TRAIN_POLL:-15}"

# train_node_count_refusal N: the node count is a whole number of nodes the cluster root accepts.
#
# Terraform validates the same range and integrality, but only once apply has begun; this refuses before.
train_node_count_refusal() {
  local n="$1"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "gpu_max_nodes '$n' is not a whole number of nodes"
    return 1
  fi
  # The same 1 to 3 as infra/aws/cluster/variables.tf, whose comment says why three.
  if ((n < 1 || n > 3)); then
    echo "gpu_max_nodes $n is outside the 1 to 3 the cluster root accepts"
    return 1
  fi
  echo "gpu_max_nodes $n"
}

# train_require_new_cluster CLUSTER REGION KEEP_UP: training runs only on a cluster this session creates.
#
# On an existing cluster the gpu group was built with the queuelab instance type, and changing it forces a
# replacement that can fail partway before any gate runs; and anything in a cluster that predates the session,
# a ClusterQueue or a stamp, could be read as this session's.
train_require_new_cluster() {
  local cluster="$1" region="$2" keep_up="$3" out
  if [[ "$keep_up" == yes ]]; then
    echo "TRAIN=ddp refuses KEEP_UP=yes: a cluster left up is one a later session would find already existing"
    return 1
  fi
  if out="$(aws eks describe-cluster --region "$region" --name "$cluster" --query cluster.status --output text 2>&1)"; then
    echo "cluster $cluster already exists ($out); TRAIN=ddp runs only on a cluster it creates"
    return 1
  fi
  # Only this answer means absent. Expired credentials or a throttle also fail, and say nothing about the cluster.
  if [[ "$out" == *ResourceNotFoundException* ]]; then
    echo "cluster $cluster does not exist"
    return 0
  fi
  echo "could not tell whether cluster $cluster exists: ${out:0:300}"
  return 1
}

# train_price_gate REGION INSTANCE_TYPE CEILING: the On-Demand list price, read now, at most the ceiling.
#
# The gpu group is On-Demand, so the Spot price the serving card is gated on says nothing about it.
# The Price List API answers only in us-east-1 (and two others), whatever region the price is for.
train_price_gate() {
  local region="$1" itype="$2" ceiling="$3" raw price
  raw="$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=$itype" "Type=TERM_MATCH,Field=regionCode,Value=$region" \
    "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
    "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --output json 2>&1)" || {
    echo "could not read the $itype On-Demand price in $region: ${raw:0:300}"
    return 1
  }
  # Exactly one product with one hourly USD price; anything else is a filter that matched the wrong thing.
  price="$(python3 -c '
import json, sys
try:
    products = [json.loads(p) for p in json.loads(sys.stdin.read())["PriceList"]]
except Exception as exc:
    sys.exit(f"the price answer does not parse: {exc}")
if len(products) != 1:
    sys.exit(f"{len(products)} products matched, want exactly 1")
dims = [d for t in products[0]["terms"].get("OnDemand", {}).values() for d in t["priceDimensions"].values()]
if len(dims) != 1 or dims[0].get("unit") != "Hrs" or "USD" not in dims[0].get("pricePerUnit", {}):
    found = [(d.get("unit"), d.get("pricePerUnit")) for d in dims]
    sys.exit(f"want one hourly USD price, found {found}")
print(dims[0]["pricePerUnit"]["USD"])
' <<<"$raw" 2>&1)" || {
    echo "the $itype On-Demand price in $region is not one hourly price: $price"
    return 1
  }
  # A zero is a price the filters did not mean, not a free instance.
  if ! awk -v p="$price" 'BEGIN { exit !(p + 0 > 0) }'; then
    echo "the $itype On-Demand price in $region read as \$$price an hour, which is not a positive price"
    return 1
  fi
  if ! awk -v p="$price" -v c="$ceiling" 'BEGIN { exit !(p + 0 <= c + 0) }'; then
    echo "the $itype On-Demand price in $region is \$$price an hour, above the ceiling of \$$ceiling"
    return 1
  fi
  echo "$itype On-Demand in $region at \$$price an hour, ceiling \$$ceiling"
}

# train_quota_gate REGION ADD_VCPU: the G and VT On-Demand instances running now, plus what this adds, fit the quota.
#
# Read from the instances themselves, not the CloudWatch usage metric the design first named: that metric has no
# datapoint at all while nothing runs (measured 2026-10-21 in gpu-lab), so a gate refusing on a missing datapoint
# would refuse exactly when the account is idle. This is a read, not a reservation: a launch between it and the
# scale-up can still take the headroom, and the per-node qualification is what shows the capacity arrived.
train_quota_gate() {
  local region="$1" add="$2" quota raw used
  quota="$(aws service-quotas get-service-quota --region "$region" --service-code ec2 --quota-code "$TRAIN_GPU_QUOTA_CODE" \
    --query Quota.Value --output text 2>&1)" || {
    echo "could not read quota $TRAIN_GPU_QUOTA_CODE: ${quota:0:300}"
    return 1
  }
  if [[ ! "$quota" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "quota $TRAIN_GPU_QUOTA_CODE read as '$quota', which is not a number"
    return 1
  fi
  raw="$(aws ec2 describe-instances --region "$region" --filters Name=instance-state-name,Values=pending,running \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle]' --output json 2>&1)" || {
    echo "could not list running instances: ${raw:0:300}"
    return 1
  }
  # Spot instances count against a different quota; the G and VT families are every type starting g or vt.
  local counted types_raw="[]"
  counted="$(python3 -c '
import json, sys
try:
    rows = json.loads(sys.stdin.read())
except Exception as exc:
    sys.exit(f"the instance list does not parse: {exc}")
for iid, itype, lifecycle in rows:
    if lifecycle != "spot" and (itype.startswith("g") or itype.startswith("vt")):
        print(iid, itype)
' <<<"$raw" 2>&1)" || {
    echo "could not read the instance list: $counted"
    return 1
  }
  # The quota is charged the type's default vCPU, whatever CPU options an instance was launched with, so the
  # count comes from the type and not from the instance's cores and threads, which undercount a customised one.
  if [[ -n "$counted" ]]; then
    # shellcheck disable=SC2046
    types_raw="$(aws ec2 describe-instance-types --region "$region" --instance-types $(awk '{print $2}' <<<"$counted" | sort -u) \
      --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus]' --output json 2>&1)" || {
      echo "could not read the default vCPU of $(awk '{print $2}' <<<"$counted" | sort -u | paste -sd' '): ${types_raw:0:300}"
      return 1
    }
  fi
  used="$(python3 -c '
import json, sys
try:
    vcpus = dict(json.loads(sys.argv[1]))
except Exception as exc:
    sys.exit(f"the instance types do not parse: {exc}")
total, seen = 0, []
for line in sys.argv[2].splitlines():
    iid, itype = line.split()
    if not vcpus.get(itype):
        sys.exit(f"{itype} has no default vCPU in the answer, so {iid} cannot be counted")
    total += vcpus[itype]
    seen.append(f"{iid} {itype} {vcpus[itype]}")
print(total, "; ".join(seen) or "none")
' "$types_raw" "$counted" 2>&1)" || {
    echo "could not count running G and VT vCPU: $used"
    return 1
  }
  local n="${used%% *}" which="${used#* }"
  if ! awk -v u="$n" -v a="$add" -v q="$quota" 'BEGIN { exit !(u + a <= q) }'; then
    echo "G and VT On-Demand vCPU in use $n ($which) plus $add is above the quota of $quota"
    return 1
  fi
  echo "G and VT On-Demand vCPU in use $n ($which) plus $add fits the quota of $quota"
}

# train_qualify_nodes CONTEXT GROUP WANT WAIT_SECONDS GPUS: exactly WANT nodes of the group, each qualified by name.
#
# Qualified is Ready, advertising exactly GPUS nvidia.com/gpu, with a Ready device plugin Pod on that node; and no GPU
# simulator anywhere, since it also advertises a GPU and would satisfy the count alone. Every node, not the first:
# a session that qualified one and trained on two would be reading the second on trust.
# Prints "name instance-id" per node on success.
train_qualify_nodes() {
  # Assigned empty, because a failed first query leaves the second unrun and its variable otherwise unset.
  local ctx="$1" group="$2" want="$3" wait="$4" gpus="${5:-}" deadline=$((SECONDS + $4)) nodes="" plugins="" verdict sims
  # Required, not defaulted: a g5.12xlarge advertising one card of four is a node with three missing, and a default of
  # 1 would qualify exactly that.
  if [[ ! "$gpus" =~ ^[1-9][0-9]*$ ]]; then
    echo "the expected GPUs per node '$gpus' is not a positive whole number"
    return 1
  fi
  while :; do
    verdict=""
    if nodes="$(kubectl --context "$ctx" --request-timeout=20s get nodes -l "eks.amazonaws.com/nodegroup=$group" -o json 2>&1)" &&
      plugins="$(kubectl --context "$ctx" --request-timeout=20s get pods -A -l app.kubernetes.io/component=nvidia-device-plugin -o json 2>&1)"; then
      verdict="$(python3 -c '
import json, sys
want, per_node = int(sys.argv[1]), sys.argv[4]
try:
    nodes = json.loads(sys.argv[2]).get("items", [])
    plugins = json.loads(sys.argv[3]).get("items", [])
except Exception as exc:
    print(f"WAIT unreadable: {exc}"); sys.exit()
def ready(o):
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in (o.get("status") or {}).get("conditions") or [])
with_plugin = {p["spec"].get("nodeName") for p in plugins if ready(p)}
good, why = [], []
for n in nodes:
    name = n["metadata"]["name"]
    gpus = ((n.get("status") or {}).get("allocatable") or {}).get("nvidia.com/gpu")
    faults = [f for f, ok in (("not Ready", ready(n)), (f"allocatable nvidia.com/gpu {gpus!r}, want {per_node!r}", gpus == per_node),
                              ("no Ready device plugin", name in with_plugin)) if not ok]
    if faults:
        why.append(name + ": " + ", ".join(faults))
    else:
        good.append(name + " " + n["spec"].get("providerID", "").rsplit("/", 1)[-1])
if len(nodes) > want:
    print(f"REFUSE {len(nodes)} nodes in the group, want {want}: a node this session did not ask for is a finding")
elif len(good) == want:
    print("OK " + " | ".join(good))
else:
    print(f"WAIT {len(good)} of {want} qualified; " + ("; ".join(why) or f"{len(nodes)} node(s) joined"))
' "$want" "$nodes" "$plugins" "$gpus")"
    else
      verdict="WAIT unreadable: ${nodes:0:200} ${plugins:0:200}"
    fi
    case "$verdict" in
      REFUSE*) echo "${verdict#REFUSE }"; return 1 ;;
      OK*) break ;;
    esac
    if ((SECONDS >= deadline)); then
      echo "within ${wait}s: ${verdict#WAIT }"
      return 1
    fi
    sleep "$TRAIN_POLL"
  done
  sims="$(kubectl --context "$ctx" --request-timeout=20s get pods -A -l app.kubernetes.io/component=gpu-simulator -o name 2>&1)" || {
    echo "could not tell whether a GPU simulator runs: ${sims:0:200}"
    return 1
  }
  if [[ -n "$sims" ]]; then
    echo "a GPU simulator is present ($sims), so the advertised GPUs cannot be attributed to the device plugin"
    return 1
  fi
  echo "${verdict#OK }" | tr '|' '\n' | sed 's/^ *//; s/ *$//'
}

# train_zone_refusal ZONE: empty, or the name of one availability zone the gpu group is pinned to.
#
# The cluster root validates the same shape, but only once apply has begun; this refuses before.
# Empty is not a refusal: the group may then use every zone that offers its type, and train_node_zones records
# which zones it used.
train_zone_refusal() {
  local zone="$1"
  if [[ -z "$zone" ]]; then
    echo "no zone pin: the nodes may land in any zone that offers the type, and the record says which they did"
    return 0
  fi
  if [[ ! "$zone" =~ ^[a-z]{2}-[a-z]+-[0-9][a-z]$ ]]; then
    echo "TRAIN_AZ '$zone' is not a zone name such as ap-northeast-2a"
    return 1
  fi
  echo "pinned to $zone"
}

# train_group_subnet_zones CLUSTER REGION GROUP ZONE: the zones of the subnets the node group was created with, and
# with ZONE, every one of them must be it.
#
# Read from the group AWS holds, not from the variable the session passed, because a variable that did not reach
# the apply pins nothing and looks exactly like one that did. It runs before the scale-up, so a pin that did not take
# is refused before anything bills.
train_group_subnet_zones() {
  local cluster="$1" region="$2" group="$3" zone="$4" subnets zones
  subnets="$(aws eks describe-nodegroup --region "$region" --cluster-name "$cluster" --nodegroup-name "$group" \
    --query 'nodegroup.subnets' --output text 2>&1)" || {
    echo "could not read the subnets of node group $group: ${subnets:0:200}"
    return 1
  }
  if [[ -z "${subnets//[[:space:]]/}" || "$subnets" == None ]]; then
    echo "node group $group lists no subnets"
    return 1
  fi
  # shellcheck disable=SC2086
  zones="$(aws ec2 describe-subnets --region "$region" --subnet-ids $subnets \
    --query 'Subnets[].AvailabilityZone' --output text 2>&1)" || {
    echo "could not read the zones of subnets $(xargs <<<"$subnets"): ${zones:0:200}"
    return 1
  }
  # One zone per subnet, or a subnet went unanswered and its zone is unknown.
  if (($(wc -w <<<"$zones") != $(wc -w <<<"$subnets"))); then
    echo "$(wc -w <<<"$subnets") subnet(s) but $(wc -w <<<"$zones") zone(s) answered: $(xargs <<<"$zones")"
    return 1
  fi
  zones="$(tr -s '[:space:]' '\n' <<<"$zones" | sed '/^$/d' | sort -u | paste -sd' ')"
  if [[ -n "$zone" && "$zones" != "$zone" ]]; then
    echo "node group $group has subnets in $zones, not only $zone: the pin did not reach the group"
    return 1
  fi
  echo "node group $group has subnets in $zones"
}

# train_node_zones CONTEXT GROUP ZONE: each node of the group with the zone it runs in, and with ZONE, every node must
# be in it.
#
# Pinned or not, a node without a topology.kubernetes.io/zone label is refused, because the record would then not
# say where its rank ran; run 3's ranks crossed zones and only these labels showed it.
# Prints "name zone" per node on success.
train_node_zones() {
  local ctx="$1" group="$2" zone="$3" nodes
  nodes="$(kubectl --context "$ctx" --request-timeout=20s get nodes -l "eks.amazonaws.com/nodegroup=$group" -o json 2>&1)" || {
    echo "could not read the nodes of group $group: ${nodes:0:200}"
    return 1
  }
  python3 -c '
import json, sys
zone = sys.argv[1]
try:
    nodes = json.loads(sys.argv[2]).get("items", [])
except Exception as exc:
    print(f"the node list is unreadable: {exc}"); sys.exit(1)
if not nodes:
    print("the group has no nodes"); sys.exit(1)
rows, faults = [], []
for n in nodes:
    name = n["metadata"]["name"]
    z = (n["metadata"].get("labels") or {}).get("topology.kubernetes.io/zone", "")
    if not z:
        faults.append(f"{name} has no topology.kubernetes.io/zone label")
    elif zone and z != zone:
        faults.append(f"{name} is in {z}, not {zone}")
    rows.append(f"{name} {z}")
if faults:
    print("; ".join(faults)); sys.exit(1)
print("\n".join(rows))
' "$zone" "$nodes"
}

# train_sync_app CONTEXT APP WAIT_SECONDS: a manual Argo CD Application synced, judged by an operation started after
# the request.
#
# The way hack/eks-gitops-runbook.sh's serve_sync does it, for its reasons: the whole operation is replaced, not
# merged, so an earlier operation's fields cannot narrow this one; status.operationState holds the previous verdict
# until Argo picks the new request up; and a succeeded operation is not yet a Synced Application.
# It names no revision, so Argo syncs the Application's own targetRevision: main on EKS, the rehearsal's branch on kind.
train_sync_app() {
  local ctx="$1" app="$2" wait="$3" deadline=$((SECONDS + $3)) requested out verdict=""
  requested="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The API server stamps whole seconds, so an operation started in the request's own second could be the old one:
  # only a later second is accepted, and the request waits a second so its own operation starts in one.
  sleep 1
  out="$(kubectl --context "$ctx" --request-timeout=20s -n argocd patch application "$app" --type json -p \
    '[{"op":"add","path":"/operation","value":{"initiatedBy":{"username":"eks-gitops-session"},"sync":{}}}]' 2>&1)" || {
    echo "could not request a sync of $app: ${out:0:300}"
    return 1
  }
  while :; do
    if out="$(kubectl --context "$ctx" --request-timeout=20s -n argocd get application "$app" -o json 2>&1)"; then
      verdict="$(python3 -c '
import json, sys
try:
    st = json.loads(sys.argv[1]).get("status") or {}
except Exception as exc:
    print(f"WAIT unreadable: {exc}"); sys.exit()
op = st.get("operationState") or {}
started, phase = op.get("startedAt") or "", op.get("phase") or "?"
sync = (st.get("sync") or {}).get("status") or "?"
revision = (st.get("sync") or {}).get("revision") or "?"
if not started or started <= sys.argv[2]:
    print("WAIT no operation started since " + sys.argv[2] + " (last started " + (started or "never") + ")")
elif phase in ("Failed", "Error"):
    print("REFUSE the sync operation started " + started + " ended " + phase + ": " + (op.get("message") or "")[:200])
elif phase == "Succeeded" and sync == "Synced":
    print("OK " + revision)
else:
    print("WAIT operation started " + started + " is " + phase + ", sync " + sync)
' "$out" "$requested")"
    else
      verdict="WAIT unreadable: ${out:0:200}"
    fi
    case "$verdict" in
      REFUSE*) echo "$app: ${verdict#REFUSE }"; return 1 ;;
      OK*) echo "$app synced at ${verdict#OK }"; return 0 ;;
    esac
    if ((SECONDS >= deadline)); then
      echo "$app did not sync within ${wait}s: ${verdict#WAIT }"
      return 1
    fi
    sleep "$TRAIN_POLL"
  done
}

# train_only_clusterqueue CONTEXT NAME WAIT_SECONDS: NAME is Active, and it is the only ClusterQueue on the cluster.
#
# The training ClusterQueue joins a shared cohort with reclaim, so its GPUs are an admission quota and not a
# ceiling: any other ClusterQueue in the cohort could lend to it. On the fresh cluster the session requires, none
# should exist, and one that does is a finding, refused at once rather than waited out.
train_only_clusterqueue() {
  local ctx="$1" name="$2" wait="$3" deadline=$((SECONDS + $3)) out verdict
  while :; do
    if out="$(kubectl --context "$ctx" --request-timeout=20s get clusterqueues -o json 2>&1)"; then
      verdict="$(python3 -c '
import json, sys
try:
    items = json.loads(sys.argv[1]).get("items", [])
except Exception as exc:
    print(f"WAIT unreadable: {exc}"); sys.exit()
want = sys.argv[2]
others = sorted(o["metadata"]["name"] for o in items if o["metadata"]["name"] != want)
mine = [o for o in items if o["metadata"]["name"] == want]
conds = ((mine[0].get("status") or {}).get("conditions") or []) if mine else []
if others:
    print(f"REFUSE other ClusterQueues exist beside {want}: {others}")
elif not mine:
    print(f"WAIT no ClusterQueue {want} yet")
elif any(c.get("type") == "Active" and c.get("status") == "True" for c in conds):
    print("OK")
else:
    print(f"WAIT {want} is not Active: " + str([(c.get("type"), c.get("status"), c.get("reason")) for c in conds]))
' "$out" "$name")"
    else
      verdict="WAIT unreadable: ${out:0:200}"
    fi
    case "$verdict" in
      REFUSE*) echo "${verdict#REFUSE }"; return 1 ;;
      OK*) echo "ClusterQueue $name is Active and the only one"; return 0 ;;
    esac
    if ((SECONDS >= deadline)); then
      echo "within ${wait}s: ${verdict#WAIT }"
      return 1
    fi
    sleep "$TRAIN_POLL"
  done
}

# train_qualification_held CONTEXT NAMESPACE NAME WAIT_SECONDS PODS: the qualification job admitted, unplaced, and
# stamped, with exactly PODS Pods (two ranks of one GPU for TRAIN=ddp, one Pod of four for TRAIN=allreduce).
#
# Submitted before any GPU node exists, so Kueue admits it on quota alone and its Pods can go nowhere: the job sits
# in Admitted, the one state in which the operator writes admittedAt (design, correction 2). Admitted with the stamp
# shows Kueue and the operator answering on this cluster before anything is bought.
# A Pod with a node, or a phase past Admitted, means a GPU node existed that this session did not buy, and refuses.
train_qualification_held() {
  local ctx="$1" ns="$2" name="$3" wait="$4" want="${5:-}" deadline=$((SECONDS + $4)) job="" pods="" verdict
  if [[ ! "$want" =~ ^[1-9][0-9]*$ ]]; then
    echo "the expected Pod count '$want' is not a positive whole number"
    return 1
  fi
  while :; do
    if job="$(kubectl --context "$ctx" --request-timeout=20s -n "$ns" get mltrainingjob "$name" -o json 2>&1)" &&
      pods="$(kubectl --context "$ctx" --request-timeout=20s -n "$ns" get pods -l "batch.kubernetes.io/job-name=$name" -o json 2>&1)"; then
      verdict="$(python3 -c '
import json, sys
try:
    st = json.loads(sys.argv[1]).get("status") or {}
    pods = json.loads(sys.argv[2]).get("items", [])
except Exception as exc:
    print(f"WAIT unreadable: {exc}"); sys.exit()
phase, stamp = st.get("phase") or "none", st.get("admittedAt")
placed = sorted(p["metadata"]["name"] + " on " + p["spec"]["nodeName"] for p in pods if p["spec"].get("nodeName"))
if placed:
    print(f"REFUSE a qualification Pod was placed before any GPU node was bought: {placed}")
elif phase in ("Running", "Succeeded", "Failed"):
    print(f"REFUSE the qualification job is {phase} with no GPU node bought")
elif phase == "Admitted" and stamp and len(pods) == int(sys.argv[3]):
    print(f"OK admitted at {stamp}, " + ("both Pods" if len(pods) == 2 else f"{len(pods)} Pod(s)") + " unplaced")
else:
    print(f"WAIT phase {phase}, admittedAt " + (stamp or "absent") + f", {len(pods)} Pod(s) of {sys.argv[3]}")
' "$job" "$pods" "$want")"
    else
      verdict="WAIT unreadable: ${job:0:200} ${pods:0:200}"
    fi
    case "$verdict" in
      REFUSE*) echo "${verdict#REFUSE }"; return 1 ;;
      OK*) echo "qualification job $name ${verdict#OK }"; return 0 ;;
    esac
    if ((SECONDS >= deadline)); then
      echo "within ${wait}s the qualification job was not held admitted: ${verdict#WAIT }"
      return 1
    fi
    sleep "$TRAIN_POLL"
  done
}

# train_qualification_released CONTEXT NAMESPACE NAME WAIT_SECONDS: the held job, once nodes exist, ran and succeeded,
# with every timestamp the operator owes it.
#
# Its Pods pull the training image, so this also leaves the image on both nodes before the first measured arm.
train_qualification_released() {
  local ctx="$1" ns="$2" name="$3" wait="$4" deadline=$((SECONDS + $4)) job verdict
  while :; do
    if job="$(kubectl --context "$ctx" --request-timeout=20s -n "$ns" get mltrainingjob "$name" -o json 2>&1)"; then
      verdict="$(python3 -c '
import json, sys
try:
    st = json.loads(sys.argv[1]).get("status") or {}
except Exception as exc:
    print(f"WAIT unreadable: {exc}"); sys.exit()
phase = st.get("phase") or "none"
stamps = {k: st.get(k) for k in ("admittedAt", "runningObservedAt", "admitToRunningSeconds")}
missing = [k for k, v in stamps.items() if not v]
if phase == "Failed":
    print(f"REFUSE the qualification job failed: {stamps}")
elif phase == "Succeeded" and missing:
    print(f"REFUSE the qualification job succeeded without {missing}")
elif phase == "Succeeded":
    print("OK " + ", ".join(f"{k} {v}" for k, v in stamps.items()))
else:
    print(f"WAIT phase {phase}")
' "$job")"
    else
      verdict="WAIT unreadable: ${job:0:200}"
    fi
    case "$verdict" in
      REFUSE*) echo "${verdict#REFUSE }"; return 1 ;;
      OK*) echo "qualification job $name succeeded: ${verdict#OK }"; return 0 ;;
    esac
    if ((SECONDS >= deadline)); then
      echo "within ${wait}s the qualification job did not succeed: ${verdict#WAIT }"
      return 1
    fi
    sleep "$TRAIN_POLL"
  done
}

# train_group_instances CLUSTER REGION GROUP: the instance IDs the group's Auto Scaling group holds, one line, or
# nothing when it holds none; fails, naming what could not be read, when either the group or its Auto Scaling group
# cannot be read.
train_group_instances() {
  local cluster="$1" region="$2" group="$3" names ids
  names="$(aws eks describe-nodegroup --region "$region" --cluster-name "$cluster" --nodegroup-name "$group" \
    --query 'nodegroup.resources.autoScalingGroups[].name' --output text 2>&1)" || {
    echo "the node group: ${names:0:200}"
    return 1
  }
  [[ -n "${names//[[:space:]]/}" && "$names" != None ]] || return 0
  # shellcheck disable=SC2086
  ids="$(aws autoscaling describe-auto-scaling-groups --region "$region" --auto-scaling-group-names $names \
    --query 'AutoScalingGroups[].Instances[].InstanceId' --output text 2>&1)" || {
    echo "the Auto Scaling group: ${ids:0:200}"
    return 1
  }
  [[ "$ids" == None ]] && ids=""
  xargs <<<"${ids//[[:space:]]/ }"
}

# train_scale_down CLUSTER REGION GROUP INSTANCES_FILE WAIT_SECONDS: the group to zero, and every instance it launched
# followed to terminated.
#
# Followed by instance ID, not by the group's size: a size of 0 is a request, and an instance that has not
# terminated is still billing. An instance the API no longer returns has terminated and aged out.
# The IDs are those the session recorded at join together with whatever the group's Auto Scaling group holds, which
# also covers a launch that never became a qualified node; each is added to the record once seen, because the group
# stops listing an instance as it goes, before it has terminated. A group that cannot be read is not an empty one.
train_scale_down() {
  local cluster="$1" region="$2" group="$3" file="$4" wait="$5" i out accepted="" ids states left held
  # Read before the request as well as after it: an instance the scale-down removes from the group's listing before
  # the first poll would otherwise never be recorded, and so never be followed. An unreadable answer here is not
  # fatal, because the polls below read the group again and refuse on an unreadable one.
  if [[ -w "$file" ]] && held="$(train_group_instances "$cluster" "$region" "$group")" && [[ -n "$held" ]]; then
    # shellcheck disable=SC2086
    printf '%s\n' $held >>"$file"
  fi
  for i in 1 2 3 4 5 6; do
    if out="$(aws eks update-nodegroup-config --region "$region" --cluster-name "$cluster" --nodegroup-name "$group" \
      --scaling-config minSize=0,maxSize=2,desiredSize=0 2>&1)"; then
      accepted=1
      break
    fi
    # An update still in progress answers ResourceInUseException; one refusal must not be the end.
    sleep "$TRAIN_POLL"
  done
  if [[ ! -w "$file" ]]; then
    echo "the instance record $file is missing, so nothing shows the nodes this session bought have gone"
    return 1
  fi
  local deadline=$((SECONDS + wait)) gone="" named asg_ids unreadable asking
  while :; do
    unreadable=""
    asg_ids=""
    asg_ids="$(train_group_instances "$cluster" "$region" "$group")" || {
      unreadable="$asg_ids"
      asg_ids=""
    }
    # shellcheck disable=SC2086
    [[ -n "$asg_ids" ]] && printf '%s\n' $asg_ids >>"$file"
    ids="$(sort -u "$file" | grep -E '^i-[0-9a-f]+$' | paste -sd' ')"
    asking="$(tr ' ' '\n' <<<"$ids" | grep -vxE "${gone:-^$}" | paste -sd' ')"
    left=""
    if [[ -n "$asking" ]]; then
      # shellcheck disable=SC2086
      if states="$(aws ec2 describe-instances --region "$region" --instance-ids $asking \
        --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>&1)"; then
        # NF, because an empty answer is one empty line, not an instance without a state.
        left="$(awk 'NF && $2 != "terminated" {printf "%s(%s) ", $1, $2}' <<<"$states")"
      else
        # A terminated instance ages out of the API, and asking for it fails the whole batch; the IDs the error
        # names are gone, and the rest are asked again at once rather than waiting out the deadline unseen.
        named=""
        [[ "$states" == *InvalidInstanceID.NotFound* ]] && named="$(grep -oE 'i-[0-9a-f]+' <<<"$states" | sort -u | paste -sd'|')"
        if [[ -n "$named" ]]; then
          gone="${gone:+$gone|}$named"
          continue
        fi
        left="unreadable: ${states:0:200}"
      fi
    fi
    if [[ -z "$ids" && -z "$unreadable" ]]; then
      echo "no instance IDs recorded in $file and none in the group, so nothing shows the nodes this session bought have gone"
      return 1
    fi
    [[ -z "$left" && -z "$asg_ids" && -z "$unreadable" ]] && break
    if ((SECONDS >= deadline)); then
      local also=""
      [[ -n "$accepted" ]] || also="; and the scale-down was refused six times: ${out:0:200}"
      echo "within ${wait}s not every instance terminated:${left:+ $left}${asg_ids:+ the group still holds $asg_ids}${unreadable:+ could not read $unreadable}$also"
      return 1
    fi
    sleep "$TRAIN_POLL"
  done
  if [[ -z "$accepted" ]]; then
    echo "the instances $ids terminated, but the scale-down of $group was refused six times: ${out:0:200}"
    return 1
  fi
  echo "$group scaled to 0 and $ids terminated"
}
