#!/usr/bin/env bash
# Checks infra/aws/org/scp/scp_eval.py, which infra/aws/org/scp/simulate.sh uses to ask whether the SCPs would have
# denied a recorded CloudTrail event, against the policies as committed and events written for each branch.
# The events are SYNTHETIC, shaped as CloudTrail records them; none was recorded from this account.
set -uo pipefail
cd "$(dirname "$0")/../../infra/aws/org/scp" || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# judge MODE POLICY EVENT: the evaluator's output and status for one event.
judge() {
  printf '%s\n' "$3" >"$work/events.jsonl"
  python3 scp_eval.py "$1" "$2" "$work/events.jsonl"
  echo "rc=$?"
}
ev() { printf '{"eventSource": "%s.amazonaws.com", "eventName": "%s", "awsRegion": "%s", "requestParameters": %s}' "$1" "$2" "$3" "${4:-null}"; }

# The region policy: an exemption names one action, not its whole service.
out="$(judge region deny-region.json "$(ev kms DescribeKey us-west-2)")"
[[ "$out" == *"0 would have been denied"*"rc=0" ]] && ok "kms:DescribeKey outside the Regions is exempt" || bad "kms:DescribeKey: $out"
out="$(judge region deny-region.json "$(ev kms Decrypt us-west-2)")"
[[ "$out" == *"WOULD HAVE DENIED DenyOutsideApprovedRegions: kms:Decrypt in us-west-2"*"rc=1" ]] && ok "kms:Decrypt outside the Regions is denied" || bad "kms:Decrypt: $out"
out="$(judge region deny-region.json "$(ev ec2 RunInstances us-west-2)")"
[[ "$out" == *"WOULD HAVE DENIED"*"rc=1" ]] && ok "a launch outside the Regions is denied" || bad "the launch in us-west-2: $out"
out="$(judge region deny-region.json "$(ev ec2 RunInstances ap-northeast-2)")"
[[ "$out" == *"0 would have been denied"*"rc=0" ]] && ok "a launch in the workload Region passes" || bad "the launch in Seoul: $out"
# us-east-1 is no longer a workload Region (proposal P4): a launch or a key there is denied, and every call this
# repository makes there is still exempt by action. Mutation that turns these red: put us-east-1 back in the list, or
# drop the exemption of pricing, ce or cloudtrail:LookupEvents.
for denied in "ec2 RunInstances" "kms Decrypt" "eks CreateCluster" "lambda CreateFunction"; do
  out="$(judge region deny-region.json "$(ev ${denied% *} ${denied#* } us-east-1)")"
  [[ "$out" == *"WOULD HAVE DENIED"*"rc=1" ]] && ok "${denied/ /:} in us-east-1 is denied" || bad "${denied/ /:} in us-east-1: $out"
done
for allowed in "pricing GetProducts" "ce GetCostAndUsage" "freetier GetFreeTierUsage" "organizations DescribeOrganization" "cloudtrail LookupEvents" "sts GetCallerIdentity" "iam GetRole" "budgets ViewBudget"; do
  out="$(judge region deny-region.json "$(ev ${allowed% *} ${allowed#* } us-east-1)")"
  [[ "$out" == *"0 would have been denied"*"rc=0" ]] && ok "${allowed/ /:} in us-east-1 is still exempt" || bad "${allowed/ /:} in us-east-1: $out"
done
out="$(judge region deny-region.json "$(ev cloudtrail StopLogging us-east-1)")"
[[ "$out" == *"WOULD HAVE DENIED"*"rc=1" ]] && ok "the cloudtrail exemption is LookupEvents alone" || bad "cloudtrail:StopLogging in us-east-1: $out"
out="$(judge region deny-region.json "$(ev iam CreateRole us-west-2)")"
[[ "$out" == *"0 would have been denied"*"rc=0" ]] && ok "a wildcard exemption (iam:*) still exempts its service" || bad "iam:CreateRole: $out"

# The family policy: the recorded type is tested against the policy's own patterns.
out="$(judge family deny-instance-family.json "$(ev ec2 RunInstances ap-northeast-2 '{"instanceType": "m7i.large"}')")"
[[ "$out" == *"WOULD HAVE DENIED DenyUnapprovedInstanceTypesOnRunInstances: ec2:RunInstances of m7i.large"*"rc=1" ]] &&
  ok "an m7i.large launch is denied" || bad "m7i.large: $out"
out="$(judge family deny-instance-family.json "$(ev ec2 RunInstances ap-northeast-2 '{"instanceType": "g5.xlarge"}')")"
[[ "$out" == *"0 would have been denied, 0 not evaluated"*"rc=0" ]] && ok "a g5.xlarge launch passes" || bad "g5.xlarge: $out"
out="$(judge family deny-instance-family.json "$(ev ec2 RunInstances ap-northeast-2 '{"instanceType": "g5x.large"}')")"
[[ "$out" == *"WOULD HAVE DENIED"*"rc=1" ]] && ok "a type that merely starts like an approved family is denied" || bad "g5x.large: $out"
out="$(judge family deny-instance-family.json "$(ev ec2 RunInstances ap-northeast-2 '{"launchTemplate": {"launchTemplateId": "lt-0"}}')")"
[[ "$out" == *"NOT EVALUATED"*"records no instance type"*"1 not evaluated"*"rc=0" ]] &&
  ok "a launch whose request names no type is reported as not evaluated, not as approved" || bad "the launch template: $out"
out="$(judge family deny-instance-family.json "$(ev ec2 TerminateInstances ap-northeast-2)")"
[[ "$out" == *"0 would have been denied, 0 not evaluated"*"rc=0" ]] && ok "an action the policy does not name is not judged" || bad "TerminateInstances: $out"

printf 'not json\n' >"$work/events.jsonl"
python3 scp_eval.py region deny-region.json "$work/events.jsonl" >"$work/out" && bad "an unreadable event passed" || ok "an unreadable event fails the run"

grep -q 'python3 scp_eval.py region deny-region.json' simulate.sh && grep -q 'python3 scp_eval.py family deny-instance-family.json' simulate.sh &&
  ok "simulate.sh judges both policies with scp_eval.py" || bad "simulate.sh does not call scp_eval.py for both policies"
if grep -n '2>/dev/null' simulate.sh; then bad "simulate.sh still discards an error"; else ok "simulate.sh discards no error"; fi

if ((fails == 0)); then echo "check-scp-eval: all checks passed"; else echo "check-scp-eval: $fails check(s) failed"; exit 1; fi
