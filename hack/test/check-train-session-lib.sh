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
for a in "$@"; do
  case "$a" in --context|--request-timeout=*|--context=*) continue ;; esac
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
expect "three nodes" 1 "outside" -- train_node_count_refusal 3
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
expect "two qualified nodes" 0 "ip-a i-a0" -- train_qualify_nodes ctx gpu 2 0
grep -q "eks.amazonaws.com/nodegroup=gpu" "$STUB/calls.log" && ok "the nodes are selected by the gpu group" || bad "the nodes are not selected by the gpu group"
scenario
answer kubectl-get-nodes.1 "$(items "$(node ip-a True 1)")"
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
answer kubectl-get-pods-gpu-simulator ""
expect "the second node joins on a later poll" 0 "ip-b" -- train_qualify_nodes ctx gpu 2 5
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b False 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
expect "one node of two Ready at the deadline" 1 "ip-b: not Ready" -- train_qualify_nodes ctx gpu 2 0
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)")"
expect "a node without the device plugin" 1 "ip-b: no Ready device plugin" -- train_qualify_nodes ctx gpu 2 0
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 0)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
expect "a node advertising no GPU" 1 "ip-b: allocatable nvidia.com/gpu '0'" -- train_qualify_nodes ctx gpu 2 0
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)" "$(node ip-c True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)" "$(plugin ip-c)")"
expect "a third node" 1 "3 nodes in the group, want 2" -- train_qualify_nodes ctx gpu 2 60
scenario
answer kubectl-get-nodes "$(items "$(node ip-a True 1)" "$(node ip-b True 1)")"
answer kubectl-get-pods-nvidia-device-plugin "$(items "$(plugin ip-a)" "$(plugin ip-b)")"
answer kubectl-get-pods-gpu-simulator "pod/gpu-simulator-x"
expect "a simulator present" 1 "simulator is present" -- train_qualify_nodes ctx gpu 2 0
scenario
answer kubectl-get-nodes "error: You must be logged in to the server (Unauthorized)" 1
expect "an unreadable node list" 1 "unreadable" -- train_qualify_nodes ctx gpu 2 0

# --- the scale-down, followed by instance --------------------------------------------------------------------------
scenario
printf 'i-0aaa\ni-0bbb\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
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
scenario
printf 'i-0aaa\ni-0bbb\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated\ni-0bbb\trunning')"
expect "one instance still running at the deadline" 1 "i-0bbb(running)" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "An error occurred (ResourceInUseException)" 254
answer aws-ec2-describe-instances "$(printf 'i-0aaa\tterminated')"
expect "a scale-down refused six times" 1 "refused six times" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
[[ "$(grep -c update-nodegroup-config "$STUB/calls.log")" == 6 ]] && ok "the scale-down is tried six times" || bad "the scale-down was not tried six times"
scenario
printf 'i-0aaa\ni-0bbb\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
# A terminated instance ages out of the API, and asking for it by ID then fails the whole batch.
answer aws-ec2-describe-instances.1 "An error occurred (InvalidInstanceID.NotFound) when calling the DescribeInstances operation: The instance ID 'i-0aaa' does not exist" 254
answer aws-ec2-describe-instances "$(printf 'i-0bbb\tterminated')"
expect "an instance that aged out is gone, and the other is still followed" 0 "terminated" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 5
[[ "$(grep describe-instances "$STUB/calls.log" | tail -1)" == *"--instance-ids i-0bbb --"* ]] && ok "the aged-out ID is dropped and the other asked again" || bad "the retry did not ask for i-0bbb alone: $(grep describe-instances "$STUB/calls.log" | tail -1)"
scenario
printf 'i-0aaa\n' >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
answer aws-ec2-describe-instances ""
expect "an empty answer is not an instance without a state" 0 "terminated" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
: >"$STUB/ids"
answer aws-eks-update-nodegroup-config "{}"
expect "no instance recorded" 1 "no instance IDs recorded" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/ids" 0
scenario
answer aws-eks-update-nodegroup-config "{}"
expect "a missing instance record" 1 "is missing" -- train_scale_down gpu-platform ap-northeast-2 gpu "$STUB/nope" 0

if [[ $fails -ne 0 ]]; then
  echo "check-train-session-lib: $fails failure(s)"
  exit 1
fi
echo "check-train-session-lib: all checks passed"
