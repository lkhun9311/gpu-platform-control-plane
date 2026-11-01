#!/usr/bin/env bash
#
# Checks hack/lib/train-session.sh's gates by calling each with aws and kubectl replaced by stubs, without a cluster,
# credentials or money.
#
#   bash hack/test/check-train-session-lib.sh
#
# Each stub answers from a scenario directory and appends its arguments to calls.log, so a test can assert both what
# a gate concluded and what it asked: a scale-down that targets the wrong group must fail here, not on the meter.
# A response for the Nth call of a kind is <kind>.N, falling back to <kind>; its exit code is <kind>[.N].rc.
# The price and quota answers are shaped like the real ones read from gpu-lab on 2026-10-21.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/stub" <<'EOF'
#!/usr/bin/env bash
# kind: the CLI and its first two words that are not flags (aws eks describe-cluster, kubectl get nodes, ...).
tool=$(basename "$0")
words=()
skip=""
for a in "$@"; do
  [[ -n "$skip" ]] && { skip=""; continue; }
  case "$a" in --context|--request-timeout=*|--context=*) continue ;; esac
  # A namespace ahead of the verb is skipped with its value, so `kubectl -n ns get x` is kind kubectl-get-x.
  [[ "$a" == -n ]] && { skip=1; continue; }
  [[ "$a" == -* ]] && break
  words+=("$a")
done
# kubectl's first word after a flag value is the context's name; drop it.
[[ "$tool" == kubectl && "${1:-}" == --context ]] && words=("${words[@]:1}")
kind="$tool-${words[0]:-}-${words[1]:-}"
# Pods are told apart by the label they select.
if [[ "$kind" == kubectl-get-pods ]]; then
  for a in "$@"; do case "$a" in app.kubernetes.io/component=*) kind="$kind-${a#*=}" ;; esac; done
fi
printf '%s %s\n' "$tool" "$*" >>"$STUB/calls.log"
n=$(( $(grep -c "^$kind\$" "$STUB/counts" 2>/dev/null || true) + 1 ))
echo "$kind" >>"$STUB/counts"
out="$STUB/$kind.$n"; [[ -e "$out" ]] || out="$STUB/$kind"
rc="$out.rc"
[[ -e "$out" ]] && cat "$out"
[[ -e "$rc" ]] && exit "$(cat "$rc")"
[[ -e "$out" ]] || { echo "stub: no answer for $kind call $n" >&2; exit 97; }
exit 0
EOF
chmod +x "$work/bin/stub"
ln -s stub "$work/bin/aws"
ln -s stub "$work/bin/kubectl"
export PATH="$work/bin:$PATH" TRAIN_POLL=0
# shellcheck source=hack/lib/train-session.sh
source hack/lib/train-session.sh

# A fresh scenario directory per case, so no answer leaks from one case into the next.
scenario() { STUB="$work/s$((++case_n))"; export STUB; mkdir -p "$STUB"; : >"$STUB/calls.log"; : >"$STUB/counts"; }
case_n=0
answer() { printf '%s\n' "$2" >"$STUB/$1"; [[ -z "${3:-}" ]] || echo "$3" >"$STUB/$1.rc"; }

# expect NAME WANT(0|1) NEEDLE -- COMMAND...: the gate's status and a word its line must carry.
expect() {
  local name="$1" want="$2" needle="$3"
  shift 4
  local out status
  out=$("$@" 2>&1)
  status=$?
  if [[ "$want" == 0 && $status -ne 0 ]]; then bad "$name: refused: $out"; return; fi
  if [[ "$want" == 1 && $status -eq 0 ]]; then bad "$name: passed, it must refuse: $out"; return; fi
  if [[ "$out" != *"$needle"* ]]; then bad "$name: no '$needle' in: $out"; return; fi
  ok "$name: $(head -1 <<<"$out")"
}

# --- node count -------------------------------------------------------------------------------------------------
scenario
expect "two nodes" 0 "gpu_max_nodes 2" -- train_node_count_refusal 2
expect "a fractional count" 1 "not a whole number" -- train_node_count_refusal 1.5
expect "three nodes, the restart session's" 0 "gpu_max_nodes 3" -- train_node_count_refusal 3
expect "four nodes" 1 "outside the 1 to 3" -- train_node_count_refusal 4
expect "zero nodes" 1 "outside the 1 to 3" -- train_node_count_refusal 0
expect "no count" 1 "not a whole number" -- train_node_count_refusal ""

# --- a cluster this session creates ------------------------------------------------------------------------------
scenario
answer aws-eks-describe-cluster "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found for name: gpu-platform." 254
expect "an absent cluster" 0 "does not exist" -- train_require_new_cluster gpu-platform ap-northeast-2 ""
scenario
answer aws-eks-describe-cluster "ACTIVE"
expect "an existing cluster" 1 "already exists" -- train_require_new_cluster gpu-platform ap-northeast-2 ""
scenario
answer aws-eks-describe-cluster "An error occurred (ExpiredTokenException): The security token included in the request is expired" 254
expect "expired credentials are not absence" 1 "could not tell" -- train_require_new_cluster gpu-platform ap-northeast-2 ""
scenario
answer aws-eks-describe-cluster "An error occurred (ResourceNotFoundException)" 254
expect "KEEP_UP=yes" 1 "KEEP_UP=yes" -- train_require_new_cluster gpu-platform ap-northeast-2 yes
grep -q "describe-cluster" "$STUB/calls.log" && bad "KEEP_UP=yes still asked AWS" || ok "KEEP_UP=yes refuses before asking AWS"

# --- the On-Demand price ------------------------------------------------------------------------------------------
price_list() {
  python3 -c '
import json, sys
def product(usd, unit="Hrs"):
    return json.dumps({"product": {"attributes": {"instanceType": "g5.xlarge"}}, "terms": {"OnDemand": {"T": {
        "priceDimensions": {"D": {"unit": unit, "pricePerUnit": {"USD": usd},
                                  "description": "$" + usd + " per On Demand Linux g5.xlarge Instance Hour"}}}}}})
print(json.dumps({"FormatVersion": "aws_v1", "PriceList": [product(*a.split(":")) for a in sys.argv[1:]]}))
' "$@"
}
scenario
answer aws-pricing-get-products "$(price_list 1.2370000000)"
expect "the listed price under the ceiling" 0 "1.2370000000 an hour" -- train_price_gate ap-northeast-2 g5.xlarge 1.50
for f in instanceType=g5.xlarge regionCode=ap-northeast-2 operatingSystem=Linux tenancy=Shared preInstalledSw=NA capacitystatus=Used; do
  grep -q "Field=${f%%=*},Value=${f#*=}" "$STUB/calls.log" || bad "the price query does not filter on $f"
done
grep -q -- "--region us-east-1" "$STUB/calls.log" && ok "the price is asked of us-east-1" || bad "the price is not asked of us-east-1"
scenario
answer aws-pricing-get-products "$(price_list 1.2370000000)"
expect "the price above the ceiling" 1 "above the ceiling" -- train_price_gate ap-northeast-2 g5.xlarge 1.00
scenario
answer aws-pricing-get-products "$(price_list)"
expect "no product" 1 "0 products" -- train_price_gate ap-northeast-2 g5.xlarge 1.50
scenario
answer aws-pricing-get-products "$(price_list 1.237 1.5)"
expect "two products" 1 "2 products" -- train_price_gate ap-northeast-2 g5.xlarge 1.50
scenario
answer aws-pricing-get-products "$(price_list 1.237:Quantity)"
expect "a price that is not hourly" 1 "hourly" -- train_price_gate ap-northeast-2 g5.xlarge 1.50
scenario
answer aws-pricing-get-products "$(price_list 0.0000000000)"
expect "a zero price" 1 "not a positive price" -- train_price_gate ap-northeast-2 g5.xlarge 1.50
scenario
answer aws-pricing-get-products "An error occurred (AccessDeniedException)" 254
expect "an unreadable price" 1 "could not read" -- train_price_gate ap-northeast-2 g5.xlarge 1.50

# --- the quota -----------------------------------------------------------------------------------------------------
# EC2 charges a type's default vCPU against the quota whatever CPU options an instance runs with, so the stub's
# instances carry no CPU counts and the types answer carries the defaults.
types() { answer aws-ec2-describe-instance-types "$1"; }
scenario
answer aws-service-quotas-get-service-quota "52.0"
answer aws-ec2-describe-instances "[]"
expect "an idle account" 0 "in use 0 (none) plus 8 fits the quota of 52.0" -- train_quota_gate ap-northeast-2 8
grep -q -- "--quota-code L-DB2E81BA" "$STUB/calls.log" && ok "the quota read is L-DB2E81BA" || bad "the quota read is not L-DB2E81BA"
grep -q "describe-instance-types" "$STUB/calls.log" && bad "an idle account still asked for instance types" || ok "an idle account asks for no instance types"
scenario
answer aws-service-quotas-get-service-quota "52.0"
answer aws-ec2-describe-instances '[["i-0aaa", "g4dn.12xlarge", null], ["i-0bbb", "g5.xlarge", "spot"], ["i-0ccc", "t3.large", null]]'
types '[["g4dn.12xlarge", 48]]'
expect "a queuelab node running" 1 "in use 48 (i-0aaa g4dn.12xlarge 48) plus 8 is above" -- train_quota_gate ap-northeast-2 8
grep -q -- "--instance-types g4dn.12xlarge" "$STUB/calls.log" && ok "only the counted type is looked up" || bad "the counted type was not looked up alone: $(grep instance-types "$STUB/calls.log")"
scenario
answer aws-service-quotas-get-service-quota "52.0"
answer aws-ec2-describe-instances '[["i-0aaa", "g5.xlarge", null], ["i-0bbb", "vt1.3xlarge", null], ["i-0ccc", "g5.xlarge", null]]'
types '[["g5.xlarge", 4], ["vt1.3xlarge", 12]]'
expect "two serving cards and a VT instance" 0 "in use 20" -- train_quota_gate ap-northeast-2 8
scenario
answer aws-service-quotas-get-service-quota "52.0"
answer aws-ec2-describe-instances '[["i-0aaa", "g5.xlarge", null], ["i-0bbb", "g6.xlarge", null]]'
types '[["g5.xlarge", 4]]'
expect "a type with no default vCPU" 1 "g6.xlarge has no default vCPU" -- train_quota_gate ap-northeast-2 8
scenario
answer aws-service-quotas-get-service-quota "52.0"
answer aws-ec2-describe-instances '[["i-0aaa", "g5.xlarge", null]]'
answer aws-ec2-describe-instance-types "An error occurred (UnauthorizedOperation)" 254
expect "unreadable instance types" 1 "could not read the default vCPU" -- train_quota_gate ap-northeast-2 8
scenario
answer aws-service-quotas-get-service-quota "An error occurred (NoSuchResourceException)" 254
expect "an unreadable quota" 1 "could not read quota" -- train_quota_gate ap-northeast-2 8
scenario
answer aws-service-quotas-get-service-quota "None"
expect "a quota that is not a number" 1 "not a number" -- train_quota_gate ap-northeast-2 8
scenario
answer aws-service-quotas-get-service-quota "52.0"
answer aws-ec2-describe-instances "An error occurred (RequestLimitExceeded)" 254
expect "an unreadable instance list" 1 "could not list" -- train_quota_gate ap-northeast-2 8

# --- every node qualified by name --------------------------------------------------------------------------------
node() { # name ready gpus
  printf '{"metadata": {"name": "%s"}, "spec": {"providerID": "aws:///ap-northeast-2a/i-%s"}, "status": {"allocatable": {"nvidia.com/gpu": "%s"}, "conditions": [{"type": "Ready", "status": "%s"}]}}' \
    "$1" "${1//[^0-9a-f]/}0" "$3" "$2"
}
plugin() { printf '{"spec": {"nodeName": "%s"}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}}' "$1"; }
items() { local IFS=,; echo "{\"items\": [$*]}"; }
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
answer kubectl-get-pods-gpu-simulator ""
expect "two qualified nodes" 0 "ip-a i-a0" -- train_qualify_nodes ctx gpu 2 0 1
grep -q "eks.amazonaws.com/nodegroup=gpu" "$STUB/calls.log" && ok "the nodes are selected by the gpu group" || bad "the nodes are not selected by the gpu group"
scenario
answer kubectl-get-nodes.1 "$(items "$(node ip-a True 1)")"
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
answer kubectl-get-pods-gpu-simulator ""
expect "the second node joins on a later poll" 0 "ip-b" -- train_qualify_nodes ctx gpu 2 5 1
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b False 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
expect "one node of two Ready at the deadline" 1 "ip-b: not Ready" -- train_qualify_nodes ctx gpu 2 0 1
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)")"
expect "a node without the device plugin" 1 "ip-b: no Ready device plugin" -- train_qualify_nodes ctx gpu 2 0 1
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 0)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
expect "a node advertising no GPU" 1 "ip-b: allocatable nvidia.com/gpu '0', want '1'" -- train_qualify_nodes ctx gpu 2 0 1
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)" "$(node ip-c True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)" "$(plugin ip-c)")"
expect "a third node" 1 "3 nodes in the group, want 2" -- train_qualify_nodes ctx gpu 2 60 1
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
answer kubectl-get-pods-gpu-simulator "pod/gpu-simulator-x"
expect "a simulator present" 1 "simulator is present" -- train_qualify_nodes ctx gpu 2 0 1
scenario
answer kubectl-get-nodes "error: You must be logged in to the server (Unauthorized)" 1
expect "an unreadable node list" 1 "unreadable" -- train_qualify_nodes ctx gpu 2 0 1

# --- the GPU count each node must advertise ------------------------------------------------------------------------
# A g5.12xlarge advertising one card of its four is a node with three missing; a g5.xlarge advertising four is not one.
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 4)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)")"
answer kubectl-get-pods-gpu-simulator ""
expect "one node advertising its four GPUs" 0 "ip-a i-a0" -- train_qualify_nodes ctx gpu 1 0 4
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)")"
expect "one GPU of an expected four" 1 "allocatable nvidia.com/gpu '1', want '4'" -- train_qualify_nodes ctx gpu 1 0 4
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 4)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)")"
expect "four GPUs where one is expected" 1 "allocatable nvidia.com/gpu '4', want '1'" -- train_qualify_nodes ctx gpu 1 0 1
scenario
expect "no expected count" 1 "not a positive whole number" -- train_qualify_nodes ctx gpu 1 0
[[ -s "$STUB/calls.log" ]] && bad "a missing count still asked the cluster" || ok "a missing count refuses before asking the cluster"

# --- the zone pin ------------------------------------------------------------------------------------------------
scenario
expect "no pin" 0 "no zone pin" -- train_zone_refusal ""
expect "a zone name" 0 "pinned to ap-northeast-2a" -- train_zone_refusal ap-northeast-2a
expect "a zone letter alone" 1 "not a zone name" -- train_zone_refusal 2a
expect "a region" 1 "not a zone name" -- train_zone_refusal ap-northeast-2
expect "a zone ID" 1 "not a zone name" -- train_zone_refusal apne2-az1

# The subnets come from the group AWS holds; the second call resolves them to zones.
scenario
answer aws-eks-describe-nodegroup "subnet-2a"
answer aws-ec2-describe-subnets "ap-northeast-2a"
expect "a pinned group in its zone" 0 "subnets in ap-northeast-2a" -- train_group_subnet_zones gpu-platform ap-northeast-2 gpu ap-northeast-2a
grep -q -- "--nodegroup-name gpu" "$STUB/calls.log" && grep -q -- "--subnet-ids subnet-2a" "$STUB/calls.log" &&
  ok "the subnets read are the gpu group's own" || bad "the subnets were not read from the gpu group: $(cat "$STUB/calls.log")"
scenario
answer aws-eks-describe-nodegroup "subnet-2a	subnet-2c"
answer aws-ec2-describe-subnets "ap-northeast-2a	ap-northeast-2c"
expect "a pin that did not reach the group" 1 "the pin did not reach the group" -- train_group_subnet_zones gpu-platform ap-northeast-2 gpu ap-northeast-2a
scenario
answer aws-eks-describe-nodegroup "subnet-2a	subnet-2c"
answer aws-ec2-describe-subnets "ap-northeast-2a	ap-northeast-2c"
expect "an unpinned group across two zones" 0 "subnets in ap-northeast-2a ap-northeast-2c" -- train_group_subnet_zones gpu-platform ap-northeast-2 gpu ""
scenario
answer aws-eks-describe-nodegroup "subnet-2a	subnet-2c"
answer aws-ec2-describe-subnets "ap-northeast-2a"
expect "a subnet whose zone went unanswered" 1 "2 subnet(s) but 1 zone(s)" -- train_group_subnet_zones gpu-platform ap-northeast-2 gpu ap-northeast-2a
scenario
answer aws-eks-describe-nodegroup "None"
expect "a group listing no subnets" 1 "lists no subnets" -- train_group_subnet_zones gpu-platform ap-northeast-2 gpu ap-northeast-2a
scenario
answer aws-eks-describe-nodegroup "An error occurred (ExpiredTokenException)" 255
expect "an unreadable group" 1 "could not read the subnets" -- train_group_subnet_zones gpu-platform ap-northeast-2 gpu ap-northeast-2a
scenario
answer aws-eks-describe-nodegroup "subnet-2a"
answer aws-ec2-describe-subnets "An error occurred (UnauthorizedOperation)" 254
expect "unreadable subnets" 1 "could not read the zones" -- train_group_subnet_zones gpu-platform ap-northeast-2 gpu ap-northeast-2a

zoned() { # name zone, or no zone label when the second argument is empty
  local labels='"eks.amazonaws.com/nodegroup": "gpu"'
  [[ -z "$2" ]] || labels="$labels, \"topology.kubernetes.io/zone\": \"$2\""
  printf '{"metadata": {"name": "%s", "labels": {%s}}}' "$1" "$labels"
}
scenario
answer kubectl-get-nodes "$(items "$(zoned ip-a ap-northeast-2a)" "$(zoned ip-b ap-northeast-2a)")"
expect "both nodes in the pinned zone" 0 "ip-b ap-northeast-2a" -- train_node_zones ctx gpu ap-northeast-2a
grep -q "eks.amazonaws.com/nodegroup=gpu" "$STUB/calls.log" && ok "the zoned nodes are selected by the gpu group" || bad "the zoned nodes are not selected by the gpu group"
scenario
answer kubectl-get-nodes "$(items "$(zoned ip-a ap-northeast-2a)" "$(zoned ip-b ap-northeast-2c)")"
expect "a node outside the pinned zone" 1 "ip-b is in ap-northeast-2c, not ap-northeast-2a" -- train_node_zones ctx gpu ap-northeast-2a
scenario
answer kubectl-get-nodes "$(items "$(zoned ip-a ap-northeast-2a)" "$(zoned ip-b ap-northeast-2c)")"
expect "unpinned nodes across zones, recorded" 0 "ip-b ap-northeast-2c" -- train_node_zones ctx gpu ""
scenario
answer kubectl-get-nodes "$(items "$(zoned ip-a ap-northeast-2a)" "$(zoned ip-b "")")"
expect "a node with no zone label, unpinned" 1 "ip-b has no topology.kubernetes.io/zone label" -- train_node_zones ctx gpu ""
scenario
answer kubectl-get-nodes "$(items)"
expect "no nodes" 1 "no nodes" -- train_node_zones ctx gpu ap-northeast-2a
scenario
answer kubectl-get-nodes "error: You must be logged in to the server (Unauthorized)" 1
expect "an unreadable zoned node list" 1 "could not read the nodes" -- train_node_zones ctx gpu ap-northeast-2a

# env_path DIR COMMAND...: runs COMMAND, a function here, with DIR first on PATH.
env_path() { local PATH="$1:$PATH"; shift; "$@"; }

# --- a manual Application synced by an operation this request started ------------------------------------------------
app() { # startedAt phase sync
  printf '{"status": {"operationState": {"startedAt": "%s", "phase": "%s", "message": "m"}, "sync": {"status": "%s", "revision": "abc123"}}}' "$1" "$2" "$3"
}
future=2999-01-01T00:00:00Z
scenario
answer kubectl-patch-application "patched"
answer kubectl-get-application.1 "$(app 2000-01-01T00:00:00Z Succeeded Synced)"
answer kubectl-get-application.2 "$(app "$future" Running OutOfSync)"
answer kubectl-get-application "$(app "$future" Succeeded Synced)"
expect "a sync started after the request" 0 "synced at abc123" -- train_sync_app ctx gpu-platform-training 5
grep -q -- '-n argocd patch application gpu-platform-training --type json' "$STUB/calls.log" && ok "the sync is a JSON patch of the Application" || bad "the sync was not requested as a JSON patch: $(grep patch "$STUB/calls.log")"
[[ "$(grep -c 'get application' "$STUB/calls.log")" == 3 ]] && ok "an earlier operation's verdict is not taken for this one" || bad "the old operation was accepted: $(grep -c 'get application' "$STUB/calls.log") reads"
scenario
answer kubectl-patch-application "patched"
answer kubectl-get-application "$(app 2000-01-01T00:00:00Z Succeeded Synced)"
expect "only an earlier operation at the deadline" 1 "no operation started since" -- train_sync_app ctx gpu-platform-training 0
scenario
# An earlier operation that started in the request's own second is still the earlier one.
mkdir -p "$work/clock"
printf '#!/usr/bin/env bash\necho 2026-10-22T01:00:00Z\n' >"$work/clock/date"
chmod +x "$work/clock/date"
answer kubectl-patch-application "patched"
answer kubectl-get-application "$(app 2026-10-22T01:00:00Z Succeeded Synced)"
expect "an operation from the request's own second" 1 "no operation started since 2026-10-22T01:00:00Z" -- env_path "$work/clock" train_sync_app ctx gpu-platform-training 0
scenario
answer kubectl-patch-application "patched"
answer kubectl-get-application "$(app "$future" Succeeded OutOfSync)"
expect "succeeded but not Synced" 1 "sync OutOfSync" -- train_sync_app ctx gpu-platform-training 0
scenario
answer kubectl-patch-application "patched"
answer kubectl-get-application "$(app "$future" Failed OutOfSync)"
expect "a failed operation" 1 "ended Failed" -- train_sync_app ctx gpu-platform-training 60
scenario
answer kubectl-patch-application 'Error from server (NotFound): applications.argoproj.io "gpu-platform-training" not found' 1
expect "an Application that is not there" 1 "could not request a sync" -- train_sync_app ctx gpu-platform-training 60

# --- the training ClusterQueue, Active and alone -------------------------------------------------------------------
cq() { # name active
  printf '{"metadata": {"name": "%s"}, "status": {"conditions": [{"type": "Active", "status": "%s", "reason": "Ready"}]}}' "$1" "$2"
}
scenario
answer kubectl-get-clusterqueues.1 "$(items)"
answer kubectl-get-clusterqueues.2 "$(items "$(cq gpu-train-a False)")"
answer kubectl-get-clusterqueues "$(items "$(cq gpu-train-a True)")"
expect "the queue appears and becomes Active" 0 "Active and the only one" -- train_only_clusterqueue ctx gpu-train-a 5
scenario
answer kubectl-get-clusterqueues "$(items "$(cq gpu-train-a True)" "$(cq gpu-tenant-a True)")"
expect "another ClusterQueue beside it" 1 "gpu-tenant-a" -- train_only_clusterqueue ctx gpu-train-a 60
scenario
answer kubectl-get-clusterqueues "$(items "$(cq gpu-train-a False)")"
expect "a queue never Active" 1 "is not Active" -- train_only_clusterqueue ctx gpu-train-a 0
scenario
answer kubectl-get-clusterqueues 'error: the server does not have a resource type "clusterqueues"' 1
expect "no ClusterQueue API" 1 "unreadable" -- train_only_clusterqueue ctx gpu-train-a 0

# --- the qualification job, held in Admitted, then released ----------------------------------------------------------
mltj() { # phase admittedAt runningObservedAt seconds
  python3 -c 'import json,sys; a=sys.argv[1:]; print(json.dumps({"status": {k: v for k, v in zip(("phase","admittedAt","runningObservedAt","admitToRunningSeconds"), a) if v}}))' "$@"
}
pod() { printf '{"metadata": {"name": "%s"}, "spec": {%s}}' "$1" "${2:+\"nodeName\": \"$2\"}"; }
scenario
answer kubectl-get-mltrainingjob.1 "$(mltj Pending)"
answer kubectl-get-mltrainingjob "$(mltj Admitted 2026-10-22T01:00:00Z)"
answer kubectl-get-pods "$(items "$(pod q-0)" "$(pod q-1)")"
expect "admitted with no node to go to" 0 "admitted at 2026-10-22T01:00:00Z, both Pods unplaced" -- train_qualification_held ctx train-a q 5 2
grep -q -- "-l batch.kubernetes.io/job-name=q" "$STUB/calls.log" && ok "the job's own Pods are the ones read" || bad "the Pods were not selected by the Job controller's job-name label, which a one-Pod job carries too"
scenario
answer kubectl-get-mltrainingjob "$(mltj Admitted)"
answer kubectl-get-pods "$(items "$(pod q-0)" "$(pod q-1)")"
expect "admitted without the stamp" 1 "admittedAt absent" -- train_qualification_held ctx train-a q 0 2
scenario
answer kubectl-get-mltrainingjob "$(mltj Admitted 2026-10-22T01:00:00Z)"
answer kubectl-get-pods "$(items "$(pod q-0)" "$(pod q-1 ip-x)")"
expect "a Pod placed with nothing bought" 1 "q-1 on ip-x" -- train_qualification_held ctx train-a q 60 2
scenario
answer kubectl-get-mltrainingjob "$(mltj Running 2026-10-22T01:00:00Z)"
answer kubectl-get-pods "$(items "$(pod q-0)" "$(pod q-1)")"
expect "Running with nothing bought" 1 "is Running with no GPU node" -- train_qualification_held ctx train-a q 60 2
scenario
answer kubectl-get-mltrainingjob "$(mltj Admitted 2026-10-22T01:00:00Z)"
answer kubectl-get-pods "$(items "$(pod q-0)")"
expect "one rank's Pod only" 1 "1 Pod(s)" -- train_qualification_held ctx train-a q 0 2
scenario
answer kubectl-get-mltrainingjob "$(mltj Admitted 2026-10-22T01:00:00Z)"
answer kubectl-get-pods "$(items "$(pod q-0)")"
expect "one Pod of four GPUs, held" 0 "1 Pod(s) unplaced" -- train_qualification_held ctx train-a q 0 1
scenario
answer kubectl-get-mltrainingjob "$(mltj Admitted 2026-10-22T01:00:00Z)"
answer kubectl-get-pods "$(items "$(pod q-0)" "$(pod q-1)")"
expect "two Pods where one is expected" 1 "2 Pod(s) of 1" -- train_qualification_held ctx train-a q 0 1
scenario
expect "no expected Pod count" 1 "not a positive whole number" -- train_qualification_held ctx train-a q 0
scenario
answer kubectl-get-mltrainingjob "$(mltj Pending)"
answer kubectl-get-pods "$(items)"
expect "never admitted" 1 "not held admitted: phase Pending" -- train_qualification_held ctx train-a q 0 2
scenario
answer kubectl-get-mltrainingjob.1 "$(mltj Admitted 2026-10-22T01:00:00Z)"
answer kubectl-get-mltrainingjob.2 "$(mltj Running 2026-10-22T01:00:00Z 2026-10-22T01:04:00Z 240.000)"
answer kubectl-get-mltrainingjob "$(mltj Succeeded 2026-10-22T01:00:00Z 2026-10-22T01:04:00Z 240.000)"
expect "released, run and succeeded" 0 "admitToRunningSeconds 240.000" -- train_qualification_released ctx train-a q 5
scenario
answer kubectl-get-mltrainingjob "$(mltj Succeeded 2026-10-22T01:00:00Z)"
expect "succeeded without a running stamp" 1 "without ['runningObservedAt', 'admitToRunningSeconds']" -- train_qualification_released ctx train-a q 60
scenario
answer kubectl-get-mltrainingjob "$(mltj Failed 2026-10-22T01:00:00Z)"
expect "the qualification job failed" 1 "failed" -- train_qualification_released ctx train-a q 60
scenario
answer kubectl-get-mltrainingjob "$(mltj Running 2026-10-22T01:00:00Z 2026-10-22T01:04:00Z 240.000)"
expect "still running at the deadline" 1 "did not succeed: phase Running" -- train_qualification_released ctx train-a q 0

# --- the scale-down, followed by instance --------------------------------------------------------------------------
# group_holds IDS: the gpu group's Auto Scaling group, holding IDS (none when empty).
group_holds() {
  answer aws-eks-describe-nodegroup "eks-gpu-asg"
  answer aws-autoscaling-describe-auto-scaling-groups "$1"
}
scenario
printf 'i-0aaa\ni-0bbb\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
group_holds ""
answer aws-ec2-describe-instances.1 "$(printf 'i-0aaa\tshutting-down\ni-0bbb\trunning')"
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated\ni-0bbb\tterminated')"
expect "both instances followed to terminated" 0 "i-0aaa i-0bbb terminated" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 5
if grep -q -- "update-nodegroup-config .*--nodegroup-name gpu .*desiredSize=0" "$STUB/calls.log" &&
  ! grep -q -- "--nodegroup-name gpu_single" "$STUB/calls.log"; then
  ok "the scale-down is update-nodegroup-config on gpu to desired 0"
else
  bad "the scale-down did not target gpu at desired 0: $(grep update-nodegroup "$STUB/calls.log")"
fi
grep -q -- "--instance-ids i-0aaa i-0bbb" "$STUB/calls.log" && ok "both recorded instances are followed" || bad "not both instances followed"
grep -q -- "describe-nodegroup .*--nodegroup-name gpu --query nodegroup.resources.autoScalingGroups" "$STUB/calls.log" && ok "the gpu group's Auto Scaling group is read" || bad "the group's Auto Scaling group was not read: $(grep describe-nodegroup "$STUB/calls.log")"
scenario
printf 'i-0aaa\ni-0bbb\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
group_holds ""
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated\ni-0bbb\trunning')"
expect "one instance still running at the deadline" 1 "i-0bbb(running)" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "An error occurred (ResourceInUseException)" 254
group_holds ""
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated')"
expect "a scale-down refused six times" 1 "refused six times" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
[[ "$(grep -c update-nodegroup-config "$STUB/calls.log")" == 6 ]] && ok "the scale-down is tried six times" || bad "the scale-down was not tried six times"
scenario
printf 'i-0aaa\ni-0bbb\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
group_holds ""
# A terminated instance ages out of the API, and asking for it by ID then fails the whole batch.
answer aws-ec2-describe-instances.1 "An error occurred (InvalidInstanceID.NotFound) when calling the DescribeInstances operation: The instance ID 'i-0aaa' does not exist" 254
answer aws-ec2-describe-instances "$(printf 'i-0bbb\tterminated')"
expect "an instance that aged out is gone, and the other is still followed" 0 "terminated" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 5
[[ "$(grep describe-instances "$STUB/calls.log" | tail -1)" == *"--instance-ids i-0bbb --"* ]] && ok "the aged-out ID is dropped and the other asked again" || bad "the retry did not ask for i-0bbb alone: $(grep describe-instances "$STUB/calls.log" | tail -1)"
scenario
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
group_holds ""
answer aws-ec2-describe-instances ""
expect "an empty answer is not an instance without a state" 0 "terminated" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
# A launch that never became a qualified node is in no record but the group's.
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
answer aws-eks-describe-nodegroup "eks-gpu-asg"
answer aws-autoscaling-describe-auto-scaling-groups.1 "$(printf 'i-0aaa\ti-0ccc')"
answer aws-autoscaling-describe-auto-scaling-groups ""
answer aws-ec2-describe-instances.1 "$(printf 'i-0aaa\tshutting-down\ni-0ccc\trunning')"
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated\ni-0ccc\tterminated')"
expect "an instance only the group knew is followed too" 0 "i-0aaa i-0ccc terminated" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 5
grep -qx i-0ccc "$STUB/ids" && ok "the group's instance is added to the record" || bad "the group's instance is not in the record"
scenario
# The scale-down can take an instance out of the group's listing before the first poll reads it.
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
answer aws-eks-describe-nodegroup "eks-gpu-asg"
answer aws-autoscaling-describe-auto-scaling-groups.1 "i-0ccc"
answer aws-autoscaling-describe-auto-scaling-groups ""
answer aws-ec2-describe-instances.1 "$(printf 'i-0aaa\tterminated\ni-0ccc\tshutting-down')"
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated\ni-0ccc\tterminated')"
expect "an instance the group listed only before the request" 0 "i-0aaa i-0ccc terminated" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 5
first_two="$(grep -E 'describe-auto-scaling-groups|update-nodegroup-config' "$STUB/calls.log" | head -2 | awk '{print $3}' | paste -sd' ')"
[[ "$first_two" == "describe-auto-scaling-groups update-nodegroup-config" ]] && ok "the group is read before the scale-down is asked for" || bad "the order was: $first_two"
scenario
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
group_holds "i-0ddd"
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated\ni-0ddd\tterminated')"
expect "the group still lists an instance at the deadline" 1 "the group still holds i-0ddd" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
answer aws-eks-describe-nodegroup "An error occurred (ExpiredTokenException)" 254
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated')"
expect "an unreadable group is not an empty one" 1 "could not read the node group" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
answer aws-eks-describe-nodegroup "eks-gpu-asg"
answer aws-autoscaling-describe-auto-scaling-groups "An error occurred (Throttling)" 254
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated')"
expect "an unreadable Auto Scaling group" 1 "could not read the Auto Scaling group" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
: >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
group_holds ""
expect "no instance recorded and none in the group" 1 "no instance IDs recorded" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
answer aws-eks-update-nodegroup-config "{}"
expect "a missing instance record" 1 "is missing" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/nope" 0

if [[ $fails -ne 0 ]]; then
  echo "check-train-session-lib: $fails failure(s)"
  exit 1
fi
echo "check-train-session-lib: all checks passed"
