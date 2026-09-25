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
# COST, from the plan rather than from memory: 99 resources, of which the hourly ones are one EKS control
# plane ($0.10/h), one t3.large in the `cpu` group at desired_size 1 ($0.1043/h), TWO NAT gateways
# ($0.059/h each) and one EIP. That is about $0.32/h before data processing, so two to three hours is
# $0.8-1.2 plus traffic -- consistent with the $1.5-2 the pre-spend reviews estimated.
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
setsid nohup bash -c "
  sleep $((TTL_MINUTES * 60))
  echo \"[ttl] \$(date -u +%H:%M:%SZ) TTL reached; force-destroying\" >> '$PWD/$KILL_LOG' 2>&1
  cd '$PWD'
  # The cluster first, and only the cluster. It is what bills; the Helm release bills nothing and its destroy
  # needs a reachable API endpoint that, by the time this fires, may well be gone -- so attempting it first
  # would spend the watchdog's one chance on the cheap half.
  AWS_PROFILE='$AWS_PROFILE' AWS_REGION='$REGION' terraform -chdir='$CLUSTER_DIR' destroy -auto-approve \
    -var='region=$REGION' >> '$PWD/$KILL_LOG' 2>&1
  echo \"[ttl] \$(date -u +%H:%M:%SZ) force-destroy finished\" >> '$PWD/$KILL_LOG' 2>&1
" >/dev/null 2>&1 &
KILL_PID=$!
log "TTL kill switch armed: PID $KILL_PID, fires in ${TTL_MINUTES}m, log $KILL_LOG"
disarm() { kill -- -"$KILL_PID" 2>/dev/null || kill "$KILL_PID" 2>/dev/null || true; }

# --- Build ---------------------------------------------------------------------------------------------

log "terraform init (cluster)"
terraform -chdir="$CLUSTER_DIR" init -input=false -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="kms_key_id=$STATE_KMS" \
  >>"$EXDIR/terraform.log" 2>&1 || die "cluster init"

started=$(date +%s)
log "terraform apply (cluster) -- this is where the billing starts"
terraform -chdir="$CLUSTER_DIR" apply -auto-approve -input=false \
  -var="region=$REGION" -var="api_public_access_cidrs=[\"$EGRESS_CIDR\"]" \
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

aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=project,Values=gpu-platform-control-plane" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text \
  >"$EXDIR/tagged-before-destroy.txt" 2>&1 || true

# --- Teardown ------------------------------------------------------------------------------------------

if [[ "${KEEP_UP:-}" == "yes" ]]; then
  log "KEEP_UP=yes: leaving the cluster running. The kill switch still fires at TTL."
  exit $((failures > 0 ? 1 : 0))
fi

log "destroy: argo-bootstrap, then cluster"
terraform -chdir="$ARGO_DIR" destroy -auto-approve -input=false \
  -var="cluster_endpoint=$endpoint" -var="cluster_ca=$ca" >>"$EXDIR/terraform.log" 2>&1 ||
  log "warning: argo destroy returned non-zero; the cluster destroy below removes it anyway"
terraform -chdir="$CLUSTER_DIR" destroy -auto-approve -input=false -var="region=$REGION" \
  >>"$EXDIR/terraform.log" 2>&1 || {
  bad "CLUSTER DESTROY FAILED -- the kill switch at PID $KILL_PID will retry at TTL. Do not walk away."
  exit 1
}

# Destroy reporting success is not the same fact as nothing being left.
remaining="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=project,Values=gpu-platform-control-plane" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || echo UNKNOWN)"
printf '%s\n' "$remaining" >"$EXDIR/tagged-after-destroy.txt"
if [[ "$remaining" == "UNKNOWN" ]]; then
  bad "could not list tagged resources after destroy; billing state is unverified"
elif [[ -n "${remaining// /}" ]]; then
  bad "tagged resources still exist after destroy: $remaining"
else
  ok "no tagged resources remain"
fi

disarm
log "kill switch disarmed"
log "evidence in $EXDIR"
((failures == 0)) || { log "$failures check(s) failed"; exit 1; }
exit 0
