#!/usr/bin/env bash
# The paid EKS session that proves the GitOps path, from an empty account to an empty account.
#
# m5a-ephemeral-runbook.sh answers a different question. Its smoke test applies `config/` directly with
# kubectl, which demonstrates the operator and says nothing about whether Argo CD deploys it -- the gap two
# pre-spend reviews found. This one never touches `config/` by hand: it installs Argo CD, applies the root,
# and then asks the cluster what Argo produced.
#
# What it does NOT do, deliberately:
#   * it does not apply or destroy `infra/aws/bootstrap`. That root owns the state bucket, the state KMS key,
#     both ECR repositories and the budget; destroying it would take the state of everything else with it.
#     m5a destroys it because m5a is a "can this account build a cluster at all" test. This is not that.
#   * it does not scale up a GPU node. It does CREATE three GPU node groups, because the cluster root always
#     does -- `gpu`, `gpu_single` and `gpu_shared` all build at `desired_size = 0`, which is the repository's
#     stated cost discipline (infra/aws/cluster/eks.tf:127). A node group with no nodes bills nothing. An
#     earlier version of this comment claimed the groups were not deployed at all, which was wrong.
#     `hack/eks-gitops-runbook.sh verify` expects 403/404 because no GPU is running, not because none exists.
#
# COST, measured on the 2026-09-25 run: 99 resources, of which the hourly ones are one EKS control plane
# ($0.10/h), one t3.large in the `cpu` group at desired_size 1 ($0.1043/h), ONE NAT gateway ($0.059/h) and
# one EIP -- about $0.26/h before data processing. `single_nat_gateway = true` (infra/aws/cluster/vpc.tf:106)
# and the run created exactly one; an earlier version of this comment said two, having miscounted the plan.
# The whole session, apply through destroy, took 25 minutes.
#
# The account's budget alarms have ALL already fired this month ($45.04 against a $30 ceiling), so AWS will
# send no new warning -- the TTL kill switch below is the only thing standing between a hung step and an
# overnight bill.
#
# Usage:
#   AWS_PROFILE=gpu-lab SESSION_CONFIRM=yes hack/eks-gitops-session.sh
#
# Environment:
#   SESSION_CONFIRM   must be `yes`; nothing touches AWS otherwise
#   TTL_MINUTES       kill-switch deadline                        (default 120)
#   EGRESS_CIDR       this machine's address, /32                 (default: asked of checkip.amazonaws.com)
#   REGION            AWS region                                  (default ap-northeast-2)
#   KEEP_UP           set to `yes` to skip the destroy at the end (the kill switch still fires)

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
export PATH="$HOME/.local/bin:$PWD/bin:$PATH"

REGION="${REGION:-ap-northeast-2}"
CLUSTER="${CLUSTER:-gpu-platform}"
TTL_MINUTES="${TTL_MINUTES:-120}"
STATE_BUCKET="${STATE_BUCKET:-gpu-platform-tfstate-007635145730}"
STATE_KMS="${STATE_KMS:-arn:aws:kms:ap-northeast-2:007635145730:key/7402454f-937a-48fd-a192-89561efc1e0a}"
CLUSTER_DIR=infra/aws/cluster
ARGO_DIR=infra/aws/argo-bootstrap
EXDIR="${EXDIR:-ex/eks-session-$(date -u +%Y%m%dT%H%M%SZ)}"

mkdir -p "$EXDIR"
log() { printf '%s  [session] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$EXDIR/session.log"; }
die() { printf '%s  [session] FATAL: %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$EXDIR/session.log" >&2; exit 1; }

failures=0
ok() { printf '   ok   %s\n' "$*" | tee -a "$EXDIR/session.log"; }
bad() {
  printf '   FAIL %s\n' "$*" | tee -a "$EXDIR/session.log" >&2
  failures=$((failures + 1))
}

[[ "${SESSION_CONFIRM:-}" == "yes" ]] || die "SESSION_CONFIRM=yes is required; this spends money"
[[ -n "${AWS_PROFILE:-}" ]] || die "AWS_PROFILE is required (gpu-lab; gpu-lab-ro cannot decrypt the state)"
export AWS_REGION="$REGION"

for t in terraform kubectl aws helm; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

# The endpoint is private by default, so this machine has to be named to reach the API at all.
#
# The address comes from AWS rather than from a variable, because a stale CIDR produces a cluster that builds
# perfectly and then refuses every request from here -- a failure that costs the full session to discover.
EGRESS_CIDR="${EGRESS_CIDR:-}"
if [[ -z "$EGRESS_CIDR" ]]; then
  ip="$(curl -fsS --max-time 15 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n' || true)"
  [[ -n "$ip" ]] || die "could not determine this machine's public address; set EGRESS_CIDR"
  EGRESS_CIDR="$ip/32"
fi
log "API endpoint will admit $EGRESS_CIDR only"

# --- The kill switch, armed before anything is created ------------------------------------------------
#
# Budgets are not a kill switch: their data updates a few times a day, and this month's thresholds have all
# been crossed already, so nothing will warn. A detached watchdog destroys the cluster after TTL_MINUTES
# whether this script finishes, hangs, or the terminal dies.
KILL_LOG="$EXDIR/ttl-kill-switch.log"
KILL_PIDFILE="$EXDIR/ttl.pid"
setsid nohup bash -c "
  echo \$\$ > '$PWD/$KILL_PIDFILE'
  sleep $((TTL_MINUTES * 60))
  echo \"[ttl] \$(date -u +%H:%M:%SZ) TTL reached; force-destroying\" >> '$PWD/$KILL_LOG' 2>&1
  cd '$PWD'
  # The cluster first, and only the cluster. It is what bills; the Helm release bills nothing and its destroy
  # needs a reachable API endpoint that, by the time this fires, may well be gone -- so attempting it first
  # would spend the watchdog's one chance on the cheap half.
  AWS_PROFILE='$AWS_PROFILE' AWS_REGION='$REGION' terraform -chdir='$CLUSTER_DIR' destroy -auto-approve \
    -var='region=$REGION' -var='cluster_name=$CLUSTER' >> '$PWD/$KILL_LOG' 2>&1
  ttl_rc=\$?
  if [ \"\$ttl_rc\" = 0 ]; then
    echo \"[ttl] \$(date -u +%H:%M:%SZ) force-destroy SUCCEEDED\" >> '$PWD/$KILL_LOG' 2>&1
  else
    echo \"[ttl] \$(date -u +%H:%M:%SZ) force-destroy FAILED rc=\$ttl_rc -- the cluster may still be billing\" >> '$PWD/$KILL_LOG' 2>&1
  fi
" >/dev/null 2>&1 &
# The watchdog reports its own pid, because `$!` here is the setsid process and not the watchdog.
#
# setsid forks the new session leader and exits, so `$!` names something that is already dead by the time the
# run ends -- and the disarm at the end killed it and nothing else. The first run of this script logged "kill
# switch disarmed" and left two watchdog processes alive, due to fire two hours later against whatever
# cluster existed then. So the watchdog writes its pid and the disarm reads it back, and refusing to build
# without one is deliberate: a session with no working kill switch is the thing this file exists to prevent.
KILL_PID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  KILL_PID="$(cat "$KILL_PIDFILE" 2>/dev/null || true)"
  [[ -n "$KILL_PID" ]] && break
  sleep 0.2
done
[[ -n "$KILL_PID" ]] || die "the TTL watchdog never reported its pid; refusing to create anything without a kill switch"
log "TTL kill switch armed: PID $KILL_PID, fires in ${TTL_MINUTES}m, log $KILL_LOG"
disarm() {
  kill -- -"$KILL_PID" 2>/dev/null || kill "$KILL_PID" 2>/dev/null || true
  if kill -0 "$KILL_PID" 2>/dev/null; then
    kill -9 -- -"$KILL_PID" 2>/dev/null || kill -9 "$KILL_PID" 2>/dev/null || true
  fi
  if kill -0 "$KILL_PID" 2>/dev/null; then
    bad "the TTL watchdog survived disarming; kill $KILL_PID by hand before the next session"
  fi
}

# --- Build ---------------------------------------------------------------------------------------------

log "terraform init (cluster)"
terraform -chdir="$CLUSTER_DIR" init -input=false -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="kms_key_id=$STATE_KMS" \
  >>"$EXDIR/terraform.log" 2>&1 || die "cluster init"

started=$(date +%s)
log "terraform apply (cluster) -- this is where the billing starts"
# CLUSTER is passed to Terraform, not only to kubectl.
#
# The name reached `aws eks update-kubeconfig` and never reached the root that creates the cluster, so both
# sides fell back to their own default and agreed by luck. Setting CLUSTER to anything else would have built
# one cluster and pointed every later step at another -- and the destroy below would have torn down the
# default rather than the one this session made.
terraform -chdir="$CLUSTER_DIR" apply -auto-approve -input=false \
  -var="region=$REGION" -var="cluster_name=$CLUSTER" -var="api_public_access_cidrs=[\"$EGRESS_CIDR\"]" \
  >>"$EXDIR/terraform.log" 2>&1 || die "cluster apply failed; the kill switch still holds at PID $KILL_PID"
log "cluster up in $(( $(date +%s) - started ))s"

endpoint="$(terraform -chdir="$CLUSTER_DIR" output -raw cluster_endpoint)"
ca="$(terraform -chdir="$CLUSTER_DIR" output -raw cluster_ca)"
[[ -n "$endpoint" && -n "$ca" ]] || die "cluster outputs are empty; argo-bootstrap cannot authenticate"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER" \
  >>"$EXDIR/terraform.log" 2>&1 || die "update-kubeconfig"

log "terraform init + apply (argo-bootstrap): the pinned argo-cd chart, installed by its own root"
terraform -chdir="$ARGO_DIR" init -input=false -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="kms_key_id=$STATE_KMS" \
  >>"$EXDIR/terraform.log" 2>&1 || die "argo init"
terraform -chdir="$ARGO_DIR" apply -auto-approve -input=false \
  -var="cluster_endpoint=$endpoint" -var="cluster_ca=$ca" \
  >>"$EXDIR/terraform.log" 2>&1 || die "argo apply"
ok "Argo CD installed by its own Terraform root"

# --- The claim -----------------------------------------------------------------------------------------
#
# Every step below is the same script the clean-kind rehearsal passed, against the same bars.
export CONTEXT="$CLUSTER"
for step in apply seed-key verify; do
  log "runbook: $step"
  if EXDIR="$EXDIR/runbook-$step" hack/eks-gitops-runbook.sh "$step" >>"$EXDIR/session.log" 2>&1; then
    ok "runbook $step"
  else
    bad "runbook $step (see $EXDIR/runbook-$step)"
  fi
done

# stderr to its own file, and a baseline nobody could read is marked as such rather than left to pass as one.
#
# `>file 2>&1 || true` wrote the ERROR TEXT into the baseline when the query failed, so the comparison after
# the destroy read that text as the set of resources that existed beforehand -- and reported every surviving
# ARN as one that had newly appeared. The after-side already guards this with its UNKNOWN sentinel; the
# before-side had no guard at all, which is the same unreadable-is-not-empty confusion in the other half.
if ! aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=project,Values=gpu-platform-control-plane" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text \
  >"$EXDIR/tagged-before-destroy.txt" 2>"$EXDIR/tagged-before-destroy.err"; then
  printf 'UNKNOWN\n' >"$EXDIR/tagged-before-destroy.txt"
  log "warning: could not read the pre-destroy tag baseline ($(tr '\n' ' ' <"$EXDIR/tagged-before-destroy.err" | cut -c1-110)); the appeared-since comparison will be skipped rather than computed against nothing"
fi

# --- Teardown ------------------------------------------------------------------------------------------

if [[ "${KEEP_UP:-}" == "yes" ]]; then
  log "KEEP_UP=yes: leaving the cluster running. The kill switch still fires at TTL."
  exit $((failures > 0 ? 1 : 0))
fi

log "destroy: argo-bootstrap, then cluster"
terraform -chdir="$ARGO_DIR" destroy -auto-approve -input=false \
  -var="cluster_endpoint=$endpoint" -var="cluster_ca=$ca" >>"$EXDIR/terraform.log" 2>&1 ||
  log "warning: argo destroy returned non-zero; the cluster destroy below removes it anyway"
terraform -chdir="$CLUSTER_DIR" destroy -auto-approve -input=false \
  -var="region=$REGION" -var="cluster_name=$CLUSTER" \
  >>"$EXDIR/terraform.log" 2>&1 || {
  bad "CLUSTER DESTROY FAILED -- the kill switch at PID $KILL_PID will retry at TTL. Do not walk away."
  exit 1
}

# Destroy reporting success is not the same fact as nothing being left -- and the tag API answers a
# different question from "what is still billing".
#
# Two corrections from this script's first run, where it failed a teardown that was in fact complete. The tag
# query returns resources the session deliberately keeps (the state bucket, both ECR repositories, three KMS
# keys), so comparing its output against "empty" can never pass. It is also eventually consistent: minutes
# after a destroy that really had removed them, it still listed the NAT gateway, the instance, the volume and
# an ENI that the EC2 API already reported gone. So the tag list is kept as context and compared against the
# pre-destroy set, while the verdict comes from asking each service that charges.
tag_now="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=project,Values=gpu-platform-control-plane" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || echo UNKNOWN)"
printf '%s\n' "$tag_now" | tr '\t' '\n' >"$EXDIR/tagged-after-destroy.txt"
if [[ "$tag_now" != "UNKNOWN" ]] && ! grep -qx UNKNOWN "$EXDIR/tagged-before-destroy.txt"; then
  appeared="$(comm -13 \
    <(tr '\t' '\n' <"$EXDIR/tagged-before-destroy.txt" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$tag_now" | tr '\t' '\n' | sed '/^$/d' | sort -u) | sed '/^$/d' || true)"
  if [[ -n "$appeared" ]]; then
    bad "resources tagged for this project exist that were not there before the run: $(printf '%s ' $appeared)"
  fi
fi

billing_left=""
# Three answers, not two: none, some, and COULD NOT ASK.
#
# This discarded stderr and forced rc=0, so a query refused on expired credentials or a denied policy came
# back empty and read as "nothing left" -- and the kill switch was disarmed on the strength of it. A teardown
# nobody could verify is not a verified teardown, and it is the one mistake here that bills by the hour.
unasked=""
still() {
  local label="$1"
  shift
  # The status has to be collected in the same list as the command that produced it.
  #
  # `rc=$?` on its own line never ran: under `set -e` a plain assignment whose command substitution fails
  # takes that status and ends the shell right there. So the three answers below were unreachable for the one
  # input they were written for -- an expired token -- and this function had never once classified a failure.
  local out rc=0
  out="$("$@" 2>"$EXDIR/aws-$label.err")" || rc=$?
  out="$(printf '%s' "$out" | tr '\t' ' ')"
  if ((rc != 0)); then
    unasked="$unasked$label(rc=$rc: $(tr '\n' ' ' <"$EXDIR/aws-$label.err" 2>/dev/null | cut -c1-110)); "
  elif [[ -n "${out// /}" ]]; then
    billing_left="$billing_left$label=$out; "
  fi
  return 0
}
still eks aws eks list-clusters --region "$REGION" --query 'clusters' --output text
still ec2 aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
  --query 'Reservations[].Instances[].InstanceId' --output text
still nat aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=available,pending" --query 'NatGateways[].NatGatewayId' --output text
still eip aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].PublicIp' --output text
still ebs aws ec2 describe-volumes --region "$REGION" --query 'Volumes[].VolumeId' --output text
still asg aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query 'AutoScalingGroups[].AutoScalingGroupName' --output text
still elb aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerName' --output text
printf '%s\n' "${billing_left:-none}" >"$EXDIR/billing-after-destroy.txt"
printf '%s\n' "${unasked:-none}" >"$EXDIR/billing-unasked.txt"
if [[ -n "${unasked// /}" ]]; then
  bad "could not ask whether these still charge: $unasked -- the teardown is unverified, not confirmed"
fi
if [[ -n "${billing_left// /}" ]]; then
  bad "something that charges is still alive: $billing_left"
fi
if [[ -z "${unasked// /}" && -z "${billing_left// /}" ]]; then
  ok "nothing that charges remains: no EKS cluster, instance, NAT gateway, EIP, volume, ASG or load balancer"
fi

# Disarmed only on a VERIFIED teardown, never on an attempted one -- and "verified" is a fact about the
# teardown, not about the session.
#
# Leaving the watchdog armed after an unverified teardown costs one more destroy attempt at TTL. Disarming it
# after one costs an instance running until somebody notices. Gating on the session-wide failure count
# conflated the two: a runbook bar that went red while the destroy returned zero and every residue query came
# back empty left a destroy timer armed over an account with nothing left to destroy, and whatever the next
# session built into this same state before the TTL would have been torn down under it.
#
# The cluster destroy is already fatal above, so reaching this line means it returned zero. What is left to
# decide is whether the residue check could ask, and what it found.
if [[ -z "${unasked// /}" && -z "${billing_left// /}" ]]; then
  disarm
  log "kill switch disarmed: destroy returned zero, every residue query was answered, and all were empty"
else
  log "kill switch LEFT ARMED (pid $KILL_PID, fires at TTL): the teardown could not be verified"
fi
log "evidence in $EXDIR"
((failures == 0)) || { log "$failures check(s) failed"; exit 1; }
exit 0
