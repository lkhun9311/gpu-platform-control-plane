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
  if ((n < 1 || n > 2)); then
    echo "gpu_max_nodes $n is outside the 1 to 2 the cluster root accepts"
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

# train_qualify_nodes CONTEXT GROUP WANT WAIT_SECONDS: exactly WANT nodes of the group, each qualified by name.
#
# Qualified is Ready, advertising nvidia.com/gpu 1, with a Ready device plugin Pod on that node; and no GPU
# simulator anywhere, since it also advertises a GPU and would satisfy the count alone. Every node, not the first:
# a session that qualified one and trained on two would be reading the second on trust.
# Prints "name instance-id" per node on success.
train_qualify_nodes() {
  # Assigned empty, because a failed first query leaves the second unrun and its variable otherwise unset.
  local ctx="$1" group="$2" want="$3" wait="$4" deadline=$((SECONDS + $4)) nodes="" plugins="" verdict sims
  while :; do
    verdict=""
    if nodes="$(kubectl --context "$ctx" --request-timeout=20s get nodes -l "eks.amazonaws.com/nodegroup=$group" -o json 2>&1)" &&
      plugins="$(kubectl --context "$ctx" --request-timeout=20s get pods -A -l app.kubernetes.io/component=nvidia-device-plugin -o json 2>&1)"; then
      verdict="$(python3 -c '
import json, sys
want = int(sys.argv[1])
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
    faults = [f for f, ok in (("not Ready", ready(n)), (f"allocatable nvidia.com/gpu {gpus!r}", gpus == "1"),
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
' "$want" "$nodes" "$plugins")"
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

# train_scale_down CLUSTER REGION GROUP INSTANCES_FILE WAIT_SECONDS: the group to zero, and every recorded instance
# followed to terminated.
#
# Followed by instance ID, not by the group's size: a size of 0 is a request, and an instance that has not
# terminated is still billing. An instance the API no longer returns has terminated and aged out.
train_scale_down() {
  local cluster="$1" region="$2" group="$3" file="$4" wait="$5" i out accepted="" ids states left
  for i in 1 2 3 4 5 6; do
    if out="$(aws eks update-nodegroup-config --region "$region" --cluster-name "$cluster" --nodegroup-name "$group" \
      --scaling-config minSize=0,maxSize=2,desiredSize=0 2>&1)"; then
      accepted=1
      break
    fi
    # An update still in progress answers ResourceInUseException; one refusal must not be the end.
    sleep "$TRAIN_POLL"
  done
  if [[ ! -r "$file" ]]; then
    echo "the instance record $file is missing, so nothing shows the nodes this session bought have gone"
    return 1
  fi
  ids="$(sort -u "$file" | grep -E '^i-[0-9a-f]+$' | paste -sd' ')"
  if [[ -z "$ids" ]]; then
    echo "no instance IDs recorded in $file, so nothing shows the nodes this session bought have gone"
    return 1
  fi
  local deadline=$((SECONDS + wait)) asking="$ids" gone
  while :; do
    # shellcheck disable=SC2086
    if [[ -z "$asking" ]]; then
      break
    elif states="$(aws ec2 describe-instances --region "$region" --instance-ids $asking \
      --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>&1)"; then
      # NF, because an empty answer is one empty line, not an instance without a state.
      left="$(awk 'NF && $2 != "terminated" {printf "%s(%s) ", $1, $2}' <<<"$states")"
      [[ -z "$left" ]] && break
    elif [[ "$states" == *InvalidInstanceID.NotFound* ]]; then
      # A terminated instance ages out of the API, and asking for it fails the whole batch; the IDs the error
      # names are gone, and the rest are asked again at once rather than waiting out the deadline unseen.
      gone="$(grep -oE 'i-[0-9a-f]+' <<<"$states" | sort -u | paste -sd'|')"
      asking="$(tr ' ' '\n' <<<"$asking" | grep -vxE "${gone:-^$}" | paste -sd' ')"
      [[ -n "$gone" ]] && continue
      left="unreadable: ${states:0:200}"
    else
      left="unreadable: ${states:0:200}"
    fi
    if ((SECONDS >= deadline)); then
      local also=""
      [[ -n "$accepted" ]] || also="; and the scale-down was refused six times: ${out:0:200}"
      echo "within ${wait}s not every instance terminated: $left$also"
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
