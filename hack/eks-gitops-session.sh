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
#   * it does not scale up a GPU node unless SERVE=yes, which buys one g5.xlarge in `gpu_single` under an AWS
#     deadline and serves one request through the gateway to a controller-rendered engine
#     (docs/superpowers/specs/2026-10-12-serve-one-request-on-eks-design.md). It does CREATE three GPU node groups, because the cluster root always
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
#   STUDY             set to `holdcap` to run the hold-cap product transfer study on the card instead of the one
#                     request and recovery; implies SERVE=yes and needs TTL_MINUTES of about 300
#   MAX_SPOT_PRICE    with STUDY, the most an hour of the card may cost in any zone, or nothing is bought (default 1.00)
#   SERVE             set to `yes` to buy one GPU and serve one request; needs TTL_MINUTES of about 180 and gh

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

# The session installs no tools, so the ones that ran are part of the record: a rehearsal on other versions
# rehearses a different script, which is how a kubectl wait cost a paid run before.
{
  kubectl version --client 2>&1 | head -2
  helm version --short 2>&1
  terraform version 2>&1 | head -1
  aws --version 2>&1
} >"$EXDIR/tool-versions.txt"

# --- SERVE=yes: what must hold before anything is built ---------------------------------------------------
SERVE="${SERVE:-}"
NODEGROUP="${NODEGROUP:-gpu_single}"
SERVE_INSTANCE_TYPE="${SERVE_INSTANCE_TYPE:-g5.xlarge}"
export SERVE_INSTANCE_TYPE SERVE_NODEGROUP="$NODEGROUP"
WAIT_GPU_NODE="${WAIT_GPU_NODE:-900}"
WAIT_GPU_PLUGIN="${WAIT_GPU_PLUGIN:-600}"
WAIT_GPU_GONE="${WAIT_GPU_GONE:-600}"
# Every bounded wait from the card's purchase to its verified end, so the deadline can be checked to cover them
# all: node, plugin, HoldCap, request, recovery, request again, scale-down. The runbook's defaults are read here
# so the sum is of the waits that will actually run.
SERVE_BUDGET=$((WAIT_GPU_NODE + WAIT_GPU_PLUGIN + ${WAIT_SERVE_READY:-1500} + 300 + ${WAIT_SERVE_RECOVER:-1500} + 300 + WAIT_GPU_GONE + 300))
# The study replaces the request and the recovery with six cells of at most 25 minutes each and 15 minutes of
# setup (docs/superpowers/specs/2026-10-15-holdcap-on-the-product-path-design.md); the deadline must cover them.
STUDY="${STUDY:-}"
MAX_SPOT_PRICE="${MAX_SPOT_PRICE:-1.00}"
case "$STUDY" in
  "") ;;
  holdcap)
    SERVE=yes
    SERVE_BUDGET=$((WAIT_GPU_NODE + WAIT_GPU_PLUGIN + ${WAIT_SERVE_READY:-1500} + 900 + 6 * 1500 + WAIT_GPU_GONE + 300))
    ;;
  *) die "STUDY=$STUDY is not a study this session runs (holdcap)" ;;
esac
if [[ "$SERVE" == yes ]]; then
  # The build, the baseline and the destroy are measured at 25 minutes for the whole 2026-09-25 cycle; an hour
  # is allowed for them here, on top of the card's budget.
  if ((TTL_MINUTES * 60 < SERVE_BUDGET + 3600)); then
    die "SERVE=yes needs TTL_MINUTES of at least $(((SERVE_BUDGET + 3600 + 59) / 60)) for its waits; it is $TTL_MINUTES"
  fi
  # The nightly destroy removes the whole cluster and neither deadline covers it. Its cron has been seen to drift
  # by hours, so a time window is not enough: a destroy run queued or in progress refuses too, and the residual
  # risk -- a late cron firing inside the session -- is the operator's to rule out by disabling the schedule.
  now_min=$((10#$(date -u +%H) * 60 + 10#$(date -u +%M)))
  destroy_min=$((18 * 60))
  ((destroy_min <= now_min - 120)) && destroy_min=$((destroy_min + 1440))
  if ((destroy_min - now_min < TTL_MINUTES + 120 && destroy_min - now_min > -120)); then
    die "the nightly destroy (.github/workflows/destroy.yml, 18:00 UTC) falls within two hours of this session's ${TTL_MINUTES} min; disable its schedule for today or start later"
  fi
  if command -v gh >/dev/null 2>&1; then
    destroy_runs="$(gh run list --workflow destroy.yml --limit 5 --json status --jq '[.[] | select(.status != "completed")] | length' 2>&1)" ||
      die "could not ask GitHub whether a destroy run is pending ($destroy_runs)"
    [[ "$destroy_runs" == 0 ]] || die "$destroy_runs destroy workflow run(s) are queued or in progress; wait for them"
  else
    die "gh is needed to check for a pending destroy workflow run before buying a card"
  fi
fi

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
  # Waits on the state lock and tries three times: its one attempt used to be spent on a lock the foreground
  # destroy, or the nightly one, still held.
  for attempt in 1 2 3; do
    AWS_PROFILE='$AWS_PROFILE' AWS_REGION='$REGION' terraform -chdir='$CLUSTER_DIR' destroy -auto-approve \
      -lock-timeout=10m -var='region=$REGION' -var='cluster_name=$CLUSTER' >> '$PWD/$KILL_LOG' 2>&1
    ttl_rc=\$?
    [ \"\$ttl_rc\" = 0 ] && break
    echo \"[ttl] attempt \$attempt failed rc=\$ttl_rc\" >> '$PWD/$KILL_LOG' 2>&1
    sleep 60
  done
  if [ \"\$ttl_rc\" = 0 ]; then
    echo \"[ttl] \$(date -u +%H:%M:%SZ) force-destroy SUCCEEDED\" >> '$PWD/$KILL_LOG' 2>&1
    # The GPU deadline is removed only after a destroy that succeeded: with the cluster gone it can only fire
    # against nothing, and left in place it makes the next session refuse to arm its own.
    gpu_ttl=\$(cat '$PWD/$EXDIR/gpu-ttl-schedule.txt' 2>/dev/null)
    [ -n \"\$gpu_ttl\" ] && AWS_PROFILE='$AWS_PROFILE' AWS_REGION='$REGION' aws scheduler delete-schedule --name \"\$gpu_ttl\" >> '$PWD/$KILL_LOG' 2>&1
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
# When it fires, so the GPU deadline can be set to beat it rather than to a fresh TTL of its own.
KILL_AT=$(($(date +%s) + TTL_MINUTES * 60))
# watchdog_alive reports whether the watchdog still runs. A zombie does not: kill -0 succeeds on a process that
# has exited and not yet been reaped, and asking that immediately after the kill reported a watchdog that was
# already gone as one that survived (2026-10-12, hack/eks-serve/runs/20261012T095840Z).
watchdog_alive() {
  kill -0 "$KILL_PID" 2>/dev/null || return 1
  [[ "$(awk '{print $3}' "/proc/$KILL_PID/stat" 2>/dev/null)" != Z ]]
}

# watchdog_gone waits up to five seconds for the watchdog to leave.
watchdog_gone() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    watchdog_alive || return 0
    sleep 0.5
  done
  return 1
}

disarm() {
  kill -- -"$KILL_PID" 2>/dev/null || kill "$KILL_PID" 2>/dev/null || true
  if ! watchdog_gone; then
    kill -9 -- -"$KILL_PID" 2>/dev/null || kill -9 "$KILL_PID" 2>/dev/null || true
  fi
  if ! watchdog_gone; then
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

# --- Serving one request on a GPU (SERVE=yes) ------------------------------------------------------------
#
# docs/superpowers/specs/2026-10-12-serve-one-request-on-eks-design.md, section 2. Off unless asked for, because
# it buys a card on top of the cluster.
GPU_TTL_FILE="$EXDIR/gpu-ttl-schedule.txt"
GPU_INSTANCES_FILE="$EXDIR/gpu-instances.txt"
SCALED_UP=""
GPU_ARMED=""
kc() { kubectl --context "$CLUSTER" --request-timeout=20s "$@"; }

# ready_names reads a list of objects as JSON on stdin and prints the names of those whose Ready condition is
# True. kubectl's JSONPath cannot do this: a filter nested inside a filter is refused as "unterminated filter",
# and with stderr discarded that refusal read as "nothing is Ready".
ready_names() {
  python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    sys.exit(3)
for o in items:
    conds = (o.get("status") or {}).get("conditions") or []
    if any(c.get("type") == "Ready" and c.get("status") == "True" for c in conds):
        print(o["metadata"]["name"])
'
}

# The serving steps run with one evidence directory, because serve-sync records the tenant key the later steps
# send: a fresh directory per step would leave them with no key and read as the chain failing.
serve_step() {
  log "runbook: $1"
  if EXDIR="$EXDIR/runbook-serve" hack/eks-gitops-runbook.sh "$1" >>"$EXDIR/session.log" 2>&1; then
    ok "runbook $1"
    return 0
  fi
  bad "runbook $1 (see $EXDIR/runbook-serve)"
  return 1
}

# gpu_up runs as a condition, which switches errexit off inside it, so every command here is checked by hand:
# a guard whose query failed must refuse, never read the failure as an empty answer.
gpu_up() {
  # Another GPU group already billing would outlive this session's deadline, which names only $NODEGROUP.
  local ng_list ng sz others=""
  ng_list="$(aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[?starts_with(@, `gpu`)]' --output text 2>&1)" || {
    bad "could not list $CLUSTER's node groups, so whether another card is running is unknown: $ng_list"
    return 1
  }
  for ng in $ng_list; do
    sz="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --query 'nodegroup.scalingConfig.desiredSize' --output text 2>&1)" || {
      bad "could not read $ng's size; an unreadable node group is not a stopped one"
      return 1
    }
    [[ "$ng" == "$NODEGROUP" || "$sz" == 0 ]] || others="$others $ng($sz)"
  done
  [[ -z "$others" ]] || { bad "another GPU node group is already running:$others"; return 1; }

  # The price is read at purchase, because the figures in the repository disagree with each other; a session
  # that cannot say what it paid does not buy.
  if ! aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$SERVE_INSTANCE_TYPE" \
    --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text >"$EXDIR/spot-price.txt" 2>&1 ||
    [[ ! -s "$EXDIR/spot-price.txt" ]]; then
    bad "could not read the $SERVE_INSTANCE_TYPE Spot price ($(head -c 200 "$EXDIR/spot-price.txt")); no card is bought unpriced"
    return 1
  fi
  # A study holds the card for hours, so its price is a gate, not a record. Every zone is judged, because the
  # node group chooses the zone and this script does not.
  if [[ -n "$STUDY" ]]; then
    local dear
    dear="$(awk -v max="$MAX_SPOT_PRICE" 'NF == 2 && $2 + 0 > max + 0 {printf "%s %s; ", $1, $2}' "$EXDIR/spot-price.txt")"
    if [[ -n "$dear" ]]; then
      bad "the $SERVE_INSTANCE_TYPE Spot price exceeds the study's ceiling of \$$MAX_SPOT_PRICE an hour in: $dear; nothing is bought"
      return 1
    fi
    ok "Spot price at most \$$MAX_SPOT_PRICE an hour in every zone ($(tr '\t\n' ' ;' <"$EXDIR/spot-price.txt"))"
  fi

  # The AWS deadline fires before the laptop watchdog, so the card is the first thing to go whichever clock
  # wins, and it must leave the serving steps their whole budget.
  local left_min gpu_min
  left_min=$(((KILL_AT - $(date +%s)) / 60))
  gpu_min=$((left_min - 10))
  if ((gpu_min * 60 < SERVE_BUDGET)); then
    bad "the watchdog fires in ${left_min} min, leaving the card ${gpu_min} min against the ${SERVE_BUDGET}s its steps may take; raise TTL_MINUTES"
    return 1
  fi
  TTL_ROLE_ARN="${TTL_ROLE_ARN:-$(terraform -chdir=infra/aws/bootstrap output -raw ttl_scaledown_role_arn 2>/dev/null)}"
  export TTL_ROLE_ARN
  # shellcheck source=hack/lib/gpu-ttl.sh
  . hack/lib/gpu-ttl.sh
  if ! ttl_arm "$CLUSTER" "$NODEGROUP" "$gpu_min" 2>>"$EXDIR/session.log"; then
    bad "could not register the GPU deadline; no card is bought without one"
    return 1
  fi
  GPU_ARMED=1
  GPU_DEADLINE=$(($(date +%s) + gpu_min * 60))
  if ! printf '%s\n' "$TTL_SCHEDULE_NAME" >"$GPU_TTL_FILE"; then
    bad "could not record the GPU deadline's name; the watchdog could not remove it later"
    return 1
  fi
  ok "GPU deadline armed for ${gpu_min} min: $TTL_SCHEDULE_NAME"

  log "scaling $NODEGROUP to 1 -- the card starts billing here"
  # Marked before the call, not after: a response lost after AWS accepted it would otherwise leave nothing to
  # scale back down.
  SCALED_UP=1
  aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --scaling-config minSize=0,maxSize=1,desiredSize=1 >>"$EXDIR/session.log" 2>&1 || {
    bad "could not scale $NODEGROUP up"
    return 1
  }

  # Accepted is not arrived: a Spot refusal leaves the request standing with no node. A Ready node, not the
  # first name listed, since a replaced Spot node can linger NotReady.
  local deadline=$((SECONDS + WAIT_GPU_NODE)) node=""
  while ((SECONDS < deadline)); do
    node="$(kc get nodes -l "eks.amazonaws.com/nodegroup=$NODEGROUP" \
      -o json 2>/dev/null | ready_names | head -1)"
    [[ -n "$node" ]] && break
    sleep 15
  done
  [[ -n "$node" ]] || { bad "no Ready $NODEGROUP node within ${WAIT_GPU_NODE}s (Spot capacity, or the bootstrap)"; return 1; }
  # The instance this session bought, by its own ID, so the scale-down can follow that instance to terminated.
  # printf, not the pipeline's own output: jsonpath ends without a newline, and the next ID appended to the file
  # would be glued onto this one.
  local iid
  iid="$(kc get node "$node" -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*/||')"
  [[ -n "$iid" ]] && printf '%s\n' "$iid" >>"$GPU_INSTANCES_FILE"
  ok "GPU node joined: $node ($(tail -1 "$GPU_INSTANCES_FILE" 2>/dev/null))"

  # S1: the real plugin's Pod Ready on this node and the card advertised, with no simulator anywhere, since the
  # simulator also advertises one GPU and would satisfy the count alone.
  deadline=$((SECONDS + WAIT_GPU_PLUGIN))
  local gpus="" plugin="" sims=""
  while ((SECONDS < deadline)); do
    gpus="$(kc get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
    plugin="$(kc get pods -A -l app.kubernetes.io/component=nvidia-device-plugin --field-selector "spec.nodeName=$node" \
      -o json 2>/dev/null | ready_names | head -1)"
    [[ "$gpus" == 1 && -n "$plugin" ]] && break
    sleep 10
  done
  sims="$(kc get pods -A -l app.kubernetes.io/component=gpu-simulator -o name 2>&1)" || sims="unreadable: $sims"
  kc get node "$node" -o json >"$EXDIR/gpu-node.json" 2>/dev/null || true
  kc get pods -A -l app.kubernetes.io/component=nvidia-device-plugin -o wide >"$EXDIR/gpu-plugin-pods.txt" 2>&1 || true
  if [[ "$gpus" != 1 || -z "$plugin" ]]; then
    bad "S1: within ${WAIT_GPU_PLUGIN}s the node advertised nvidia.com/gpu=${gpus:-none} with Ready plugin Pod '${plugin:-none}' (gpu-plugin-pods.txt)"
    return 1
  fi
  if [[ -n "$sims" ]]; then
    bad "S1: the simulator is present ($sims), so the advertised GPU cannot be attributed to the real plugin"
    return 1
  fi
  ok "S1: plugin $plugin Ready on $node, which advertises nvidia.com/gpu: 1, and no simulator runs"
}

# Reached on every exit once the card or its deadline exists: from the normal path, and from the EXIT trap after
# an error or a signal. Errexit is off inside, because a cleanup that stops at its first failed command is the
# one that leaves the card billing.
gpu_down() {
  local -
  set +e
  [[ -n "$SCALED_UP$GPU_ARMED" ]] || return 0
  if [[ -n "$SCALED_UP" ]]; then
    log "scaling $NODEGROUP to 0"
    # Retried: an update still in progress answers ResourceInUseException, and one refusal must not be the end.
    local i out accepted=""
    for i in 1 2 3 4 5 6; do
      if out="$(aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
        --scaling-config minSize=0,maxSize=1,desiredSize=0 2>&1)"; then
        accepted=1
        break
      fi
      printf 'scale-down attempt %s: %s\n' "$i" "$out" >>"$EXDIR/session.log"
      sleep 20
    done
    [[ -n "$accepted" ]] || bad "the scale-down of $NODEGROUP was refused six times; the GPU deadline and the cluster destroy still stand"
  fi
  # Followed by instance, not by a tag search: the ones this session recorded at join, together with whatever
  # the node group's Auto Scaling group holds now, which also covers a launch that never became a Ready node
  # and a Spot replacement. A terminated instance reads terminated or not at all; stopped is not terminated,
  # since a stopped instance keeps its volume. A group that cannot be read is not an empty one.
  local deadline=$((SECONDS + WAIT_GPU_GONE)) ids left="" st asg_names asg_ids unreadable
  while ((SECONDS < deadline)); do
    unreadable=""
    asg_ids=""
    if asg_names="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
      --query 'nodegroup.resources.autoScalingGroups[].name' --output text 2>&1)"; then
      if [[ -n "${asg_names// /}" && "$asg_names" != None ]]; then
        # shellcheck disable=SC2086
        asg_ids="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asg_names \
          --query 'AutoScalingGroups[].Instances[].InstanceId' --output text 2>&1)" || {
          unreadable="the Auto Scaling group: $asg_ids"
          asg_ids=""
        }
      fi
    else
      unreadable="the node group: $asg_names"
    fi
    [[ "$asg_ids" == None ]] && asg_ids=""
    # Kept once seen: the group stops listing an instance as it goes, before it is terminated, and an ID
    # dropped at that point would leave the instance unchecked.
    [[ -n "$asg_ids" ]] && printf '%s\n' $asg_ids >>"$GPU_INSTANCES_FILE"
    ids="$(sort -u "$GPU_INSTANCES_FILE" 2>/dev/null | sed '/^$/d' | tr '\n' ' ')"
    left=""
    for i in $ids; do
      st="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$i" \
        --query 'Reservations[].Instances[].State.Name' --output text 2>&1)"
      case "$st" in
        terminated | *InvalidInstanceID.NotFound*) ;;
        *) left="$left $i(${st//$'\n'/ })" ;;
      esac
    done
    [[ -z "$left" && -z "$asg_ids" && -z "$unreadable" ]] && break
    sleep 15
  done
  local desired
  desired="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --query 'nodegroup.scalingConfig.desiredSize' --output text 2>&1)"
  printf 'desiredSize=%s instances=%s still-up=%s group-holds=%s unreadable=%s\n' "$desired" "${ids:-none}" "${left:-none}" "${asg_ids:-none}" "${unreadable:-none}" >"$EXDIR/gpu-down.txt"
  if [[ -n "$SCALED_UP" && ( "$desired" != 0 || -n "$left" || -n "$asg_ids" || -n "$unreadable" ) ]]; then
    bad "S6: $NODEGROUP at desiredSize=$desired, instances still up:${left:- none}, group holds:${asg_ids:- none}${unreadable:+, could not read $unreadable}; the GPU deadline stays armed"
    return 0
  fi
  [[ -n "$SCALED_UP" ]] && ok "S6 (GPU half): $NODEGROUP at desiredSize 0 and instance(s) ${ids:-none recorded} terminated"
  SCALED_UP=""
  # Removed only once the card is verifiably gone; a leftover schedule makes the next session refuse to arm.
  if ttl_disarm 2>>"$EXDIR/session.log"; then
    rm -f "$GPU_TTL_FILE"
    GPU_ARMED=""
  else
    bad "the GPU deadline $(cat "$GPU_TTL_FILE" 2>/dev/null) could not be removed; delete it before the next session"
  fi
}

if [[ "$SERVE" == yes ]]; then
  # From the deadline's arming on, an error or a signal ends the run through gpu_down; a handler that only
  # cleans up would return to the interrupted step and carry on.
  trap 'gpu_down' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if ((failures > 0)); then
    # The GitOps baseline is the ground the serving claim stands on; a failure there buys no card.
    bad "the GitOps baseline failed ($failures check(s)), so no GPU is bought and nothing is served"
  elif ! serve_step serve-sync || ! serve_step serve-rehearse; then
    # What a cluster with no GPU node can show -- the engine Pod admitted and charged, status Off -- is checked
    # here, before the card, because the pins main carries can differ from what the kind rehearsal ran.
    bad "the serving bundle failed what this cluster can show without a GPU, so no card is bought"
  elif gpu_up; then
    if [[ "$STUDY" == holdcap ]]; then
      # The cells must end before the card's own deadline, with ten minutes for the last one's export; the
      # whole-cluster teardown after gpu_down is covered by the watchdog's later deadline, not by this margin.
      if serve_step serve-ready; then
        log "study: holdcap, until $(date -u -d "@$GPU_DEADLINE" +%H:%M:%SZ) less a 10 min margin"
        if CONTEXT="$CLUSTER" EXDIR="$EXDIR" STUDY_DEADLINE="$GPU_DEADLINE" TEARDOWN_RESERVE=600 \
          hack/eks-serve/holdcap-study/run.sh >>"$EXDIR/session.log" 2>&1; then
          ok "study: all six cells ran; $(head -1 "$EXDIR/holdcap-study/verdict.txt" 2>/dev/null || echo 'no verdict file')"
        else
          bad "study stopped: $(cat "$EXDIR/holdcap-study/STOPPED" 2>/dev/null || echo 'no reason recorded'); the cells written are kept"
        fi
      fi
    else
      serve_step serve-ready && serve_step serve-request && serve_step serve-recover || true
    fi
  fi
  gpu_down
fi

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
terraform -chdir="$CLUSTER_DIR" destroy -auto-approve -input=false -lock-timeout=10m \
  -var="region=$REGION" -var="cluster_name=$CLUSTER" \
  >>"$EXDIR/terraform.log" 2>&1 || {
  if kill -0 "$KILL_PID" 2>/dev/null; then
    bad "CLUSTER DESTROY FAILED -- the kill switch at PID $KILL_PID will retry at TTL. Do not walk away."
  else
    bad "CLUSTER DESTROY FAILED and the kill switch has already fired or died (see $KILL_LOG) -- nothing will retry; destroy by hand now."
  fi
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
still schedule aws scheduler list-schedules --region "$REGION" --name-prefix "gpu-ttl-$CLUSTER-" \
  --query 'Schedules[].Name' --output text
still logs aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "/aws/eks/$CLUSTER/" \
  --query 'logGroups[].logGroupName' --output text
printf '%s\n' "${billing_left:-none}" >"$EXDIR/billing-after-destroy.txt"
printf '%s\n' "${unasked:-none}" >"$EXDIR/billing-unasked.txt"
if [[ -n "${unasked// /}" ]]; then
  bad "could not ask whether these still charge: $unasked -- the teardown is unverified, not confirmed"
fi
if [[ -n "${billing_left// /}" ]]; then
  bad "something that charges is still alive: $billing_left"
fi
if [[ -z "${unasked// /}" && -z "${billing_left// /}" ]]; then
  ok "nothing that charges remains: no EKS cluster, instance, NAT gateway, EIP, volume, ASG, load balancer cluster log group or GPU deadline schedule"
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
