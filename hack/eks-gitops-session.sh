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
#                     STUDY=prefixroute instead buys two g5.xlarge On-Demand in the `gpu` group and runs the prefix-aware
#                     routing study (docs/superpowers/specs/2026-10-27-prefix-aware-routing-design.md); only on a cluster
#                     this session creates, never with SERVE, TRAIN or KEEP_UP, and needs TTL_MINUTES of at least 415 and gh
#   PREFIX_MAX_PRICE  with STUDY=prefixroute, the most an On-Demand hour of one node may cost, or nothing is bought (default 1.40)
#   MAX_SPOT_PRICE    with STUDY, the most an hour of the card may cost in any zone, or nothing is bought (default 1.00)
#   SERVE             set to `yes` to buy one GPU and serve one request; needs TTL_MINUTES of about 180 and gh
#   TRAIN             set to `ddp` to buy two g5.xlarge in the `gpu` group and run the multi-Pod DDP arms on them with
#                     NCCL (docs/superpowers/specs/2026-10-16-nccl-groundwork-design.md, section 5); only on a cluster
#                     this session creates, never with SERVE or KEEP_UP, and needs TTL_MINUTES of about 180 and gh
#   APPROVED_TRAIN_SHA256  with TRAIN, the sha256 of experiments/cpu-ddp/train.py the run's registration approved
#   TRAIN_ARMS        with TRAIN, the arms to run, in order          (default: pass no-sync bad-address one-rank-fails)
#   TRAIN_MAX_PRICE   with TRAIN, the most an On-Demand hour of one node may cost, or nothing is bought (default 1.40)
#   TRAIN_AZ          with TRAIN, the one availability zone the nodes must be in, such as ap-northeast-2a; unset, they
#                     may land in any zone that offers the type, and the record says which (default: unset)
#   TRAIN=allreduce   instead buys ONE g5.12xlarge (four A10G) in the `gpu` group and runs experiment C's arms on it
#                     (docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md); the same conditions as ddp, and
#                     TTL_MINUTES of at least 310. TRAIN_MAX_PRICE defaults to 6.98 in this mode
#   APPROVED_BENCH_SHA256  with TRAIN=allreduce, the sha256 of experiments/multi-gpu-throughput/allreduce_bench.py
#   APPROVED_STEP_SHA256   with TRAIN=allreduce, the sha256 of experiments/multi-gpu-throughput/ddp_step_bench.py
#   NCCLTESTS_IMAGE   with TRAIN=allreduce, the nccl-tests image built from experiments/multi-gpu-throughput/nccl-tests,
#                     named by digest (repository@sha256:...)

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
# Absolute from here, because the watchdog below runs detached and writes into it by this path.
#
# The watchdog prefixed $PWD to a relative EXDIR, so an absolute one became $PWD//abs/...: its pid file was never
# written, the session died for want of a kill switch, and the watchdog it had just started lived on, due to destroy
# whatever cluster existed TTL_MINUTES later (found 2026-10-22 by hack/test/check-train-session-refusals.sh).
EXDIR="$(cd "$EXDIR" && pwd)" || exit 1
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
# sed, not head: head exits after its lines, a producer still writing then takes SIGPIPE, and under pipefail that
# status would end the session here, before the kill switch is armed, with no message saying why.
# No session is recorded as having stopped this way; a 20,000-line producer into head -2 exits 141 under this shell's options.
{
  kubectl version --client 2>&1 | sed -n 1,2p
  helm version --short 2>&1
  terraform version 2>&1 | sed -n 1p
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
  # Two engines on two cards: the `gpu` group at two nodes, bought and released by the same gates TRAIN=ddp uses,
  # because gpu_single's max_size is 1. Node join, plugin, 900 s of setup, the engines' first start outside every
  # cell (run.sh's FIRST_START, 1,500 s), twelve cells of 1,500 s and the scale-down.
  prefixroute)
    PREFIX_GPU_BUDGET=$((WAIT_GPU_NODE + WAIT_GPU_PLUGIN + 900 + 1500 + 12 * 1500 + WAIT_GPU_GONE + 300))
    ;;
  *) die "STUDY=$STUDY is not a study this session runs (holdcap, prefixroute)" ;;
esac
if [[ "$SERVE" == yes ]]; then
  # The build, the baseline and the destroy are measured at 25 minutes for the whole 2026-09-25 cycle; an hour
  # is allowed for them here, on top of the card's budget.
  if ((TTL_MINUTES * 60 < SERVE_BUDGET + 3600)); then
    die "SERVE=yes needs TTL_MINUTES of at least $(((SERVE_BUDGET + 3600 + 59) / 60)) for its waits; it is $TTL_MINUTES"
  fi
fi

# --- TRAIN=ddp: what must hold before anything is built ---------------------------------------------------
#
# docs/superpowers/specs/2026-10-16-nccl-groundwork-design.md, section 5. The gates are functions in
# hack/lib/train-session.sh, tested by hack/test/check-train-session-lib.sh; this file only orders them.
TRAIN="${TRAIN:-}"
TRAIN_GROUP=gpu
TRAIN_INSTANCE_TYPE=g5.xlarge
TRAIN_NODES=2
TRAIN_NS=train-a
TRAIN_QUEUE=gpu-train-a
TRAIN_APP=gpu-platform-training
# The class config/training's quota policy names, and the card a g5.xlarge carries; the admission policy requires one.
TRAIN_GPU_CLASS=a10g
# What each node must advertise, and how many Pods the qualification job has; TRAIN=allreduce changes both.
TRAIN_GPUS_PER_NODE=1
TRAIN_QUAL_PODS=2
# Whether the operator named a ceiling, so a mode's own default applies only when nobody did.
TRAIN_MAX_PRICE_SET="${TRAIN_MAX_PRICE:+1}"
TRAIN_MAX_PRICE="${TRAIN_MAX_PRICE:-1.40}"
# Experiment C (TRAIN=allreduce): its price ceiling is the g5.12xlarge On-Demand list price read on 2026-10-26,
# $6.97442, rounded up to the cent, so any rise in the price refuses and the budget the owner approved stays the one
# that is spent (docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md, "Budget").
AR_MAX_PRICE_DEFAULT=6.98
# The registered per-job budget, and the warm job's wait; both are conventions the registration states.
AR_JOB_BUDGET=240
WAIT_WARM="${WAIT_WARM:-900}"
TRAIN_ARMS="${TRAIN_ARMS:-pass no-sync bad-address one-rank-fails}"
TRAIN_AZ="${TRAIN_AZ:-}"
# pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime, the torch the CPU image installs, with CUDA; read from Docker Hub on
# 2026-10-22 as a single linux/amd64 manifest of 3,337,937,647 compressed bytes, which each node pulls once.
TRAIN_IMAGE=docker.io/pytorch/pytorch@sha256:c8268a92a69bd500f8be0e665b2630ee006dadaf7bfbc24249141b15ff622755
WAIT_TRAIN_SYNC="${WAIT_TRAIN_SYNC:-600}"
WAIT_TRAIN_QUEUE="${WAIT_TRAIN_QUEUE:-300}"
WAIT_QUAL_HELD="${WAIT_QUAL_HELD:-300}"
# The qualification job is the first to pull the image, so its wait covers the pull on both nodes.
WAIT_QUAL_RUN="${WAIT_QUAL_RUN:-1500}"
# The registered budget per arm, as the kind harness's, and a minute each for its submission and its collection.
TRAIN_ARM_BUDGET=300
TF_TRAIN_VARS=""
case "$TRAIN" in
  "") ;;
  ddp)
    [[ -z "$SERVE$STUDY" ]] || die "TRAIN=ddp with SERVE or STUDY would buy GPUs in two groups under one deadline; run one"
    # shellcheck source=hack/lib/train-session.sh
    . hack/lib/train-session.sh
    # shellcheck source=hack/lib/ddp-arms.sh
    . hack/lib/ddp-arms.sh
    # The code that runs is the code that was approved, checked before anything is bought for it; the analyzer
    # checks the same hash again, from what each rank recorded.
    [[ "${APPROVED_TRAIN_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] ||
      die "TRAIN=ddp needs APPROVED_TRAIN_SHA256, the train.py hash the run's registration approved"
    train_sha="$(sha256sum experiments/cpu-ddp/train.py | cut -d' ' -f1)"
    [[ "$train_sha" == "$APPROVED_TRAIN_SHA256" ]] ||
      die "experiments/cpu-ddp/train.py is $train_sha, not the approved $APPROVED_TRAIN_SHA256"
    why="$(train_node_count_refusal "$TRAIN_NODES")" || die "$why"
    why="$(train_zone_refusal "$TRAIN_AZ")" || die "$why"
    log "TRAIN_AZ: $why"
    n_arms=0
    for arm in $TRAIN_ARMS; do
      ddp_arm_env "$arm" >/dev/null || die "TRAIN_ARMS names $arm, which is not an arm (pass no-sync bad-address one-rank-fails)"
      n_arms=$((n_arms + 1))
    done
    ((n_arms > 0)) || die "TRAIN_ARMS names no arm"
    # Every bounded wait from the sync to the verified end of the nodes, so the deadline can be checked to cover them.
    TRAIN_GPU_BUDGET=$((WAIT_GPU_NODE + WAIT_GPU_PLUGIN + WAIT_QUAL_RUN + n_arms * (TRAIN_ARM_BUDGET + 60) + WAIT_GPU_GONE + 300))
    TRAIN_BUDGET=$((WAIT_TRAIN_SYNC + WAIT_TRAIN_QUEUE + WAIT_QUAL_HELD + TRAIN_GPU_BUDGET))
    if ((TTL_MINUTES * 60 < TRAIN_BUDGET + 3600)); then
      die "TRAIN=ddp needs TTL_MINUTES of at least $(((TRAIN_BUDGET + 3600 + 59) / 60)) for its waits; it is $TTL_MINUTES"
    fi
    why="$(train_require_new_cluster "$CLUSTER" "$REGION" "${KEEP_UP:-}")" || die "$why"
    log "$why"
    # Passed to every apply and destroy of the cluster root, the watchdog's included, so each plans the same groups.
    TF_TRAIN_VARS="-var=gpu_node_instance_type=$TRAIN_INSTANCE_TYPE -var=gpu_max_nodes=$TRAIN_NODES"
    # Empty passes nothing, so an unpinned session plans exactly the groups it planned before the pin existed.
    [[ -z "$TRAIN_AZ" ]] || TF_TRAIN_VARS="$TF_TRAIN_VARS -var=gpu_availability_zone=$TRAIN_AZ"
    ;;
  allreduce)
    # Experiment C: one g5.12xlarge, its four A10Gs in one Pod against four Pods of one.
    [[ -z "$SERVE$STUDY" ]] || die "TRAIN=allreduce with SERVE or STUDY would buy GPUs in two groups under one deadline; run one"
    # shellcheck source=hack/lib/train-session.sh
    . hack/lib/train-session.sh
    # shellcheck source=hack/lib/allreduce-arms.sh
    . hack/lib/allreduce-arms.sh
    TRAIN_INSTANCE_TYPE=g5.12xlarge
    TRAIN_NODES=1
    TRAIN_GPUS_PER_NODE=4
    TRAIN_QUAL_PODS=1
    [[ -n "${TRAIN_MAX_PRICE_SET:-}" ]] || TRAIN_MAX_PRICE="$AR_MAX_PRICE_DEFAULT"
    # The code that runs is the code that was approved, checked before anything is bought; the scorer checks the
    # same hashes again, from what each rank recorded.
    for pair in "APPROVED_BENCH_SHA256 experiments/multi-gpu-throughput/allreduce_bench.py" \
      "APPROVED_STEP_SHA256 experiments/multi-gpu-throughput/ddp_step_bench.py"; do
      var="${pair%% *}" file="${pair#* }"
      [[ "${!var:-}" =~ ^[0-9a-f]{64}$ ]] || die "TRAIN=allreduce needs $var, the sha256 of $file the registration approved"
      sha="$(sha256sum "$file" | cut -d' ' -f1)"
      [[ "$sha" == "${!var}" ]] || die "$file is $sha, not the approved ${!var}"
    done
    # By digest, or the image that runs is whatever the tag names on the day.
    [[ "${NCCLTESTS_IMAGE:-}" =~ ^[a-z0-9.:/_-]+@sha256:[0-9a-f]{64}$ ]] ||
      die "TRAIN=allreduce needs NCCLTESTS_IMAGE, the built nccl-tests image named by digest (repository@sha256:...)"
    why="$(train_node_count_refusal "$TRAIN_NODES")" || die "$why"
    why="$(train_zone_refusal "$TRAIN_AZ")" || die "$why"
    log "TRAIN_AZ: $why"
    # Five smoke jobs and the registered twenty-five, each with a minute for its submission and collection.
    n_jobs=$((5 + 25))
    TRAIN_GPU_BUDGET=$((WAIT_GPU_NODE + WAIT_GPU_PLUGIN + WAIT_QUAL_RUN + WAIT_WARM + n_jobs * (AR_JOB_BUDGET + 60) + WAIT_GPU_GONE + 300))
    TRAIN_BUDGET=$((WAIT_TRAIN_SYNC + WAIT_TRAIN_QUEUE + WAIT_QUAL_HELD + TRAIN_GPU_BUDGET))
    if ((TTL_MINUTES * 60 < TRAIN_BUDGET + 3600)); then
      die "TRAIN=allreduce needs TTL_MINUTES of at least $(((TRAIN_BUDGET + 3600 + 59) / 60)) for its waits; it is $TTL_MINUTES"
    fi
    why="$(train_require_new_cluster "$CLUSTER" "$REGION" "${KEEP_UP:-}")" || die "$why"
    log "$why"
    TF_TRAIN_VARS="-var=gpu_node_instance_type=$TRAIN_INSTANCE_TYPE -var=gpu_max_nodes=$TRAIN_NODES"
    [[ -z "$TRAIN_AZ" ]] || TF_TRAIN_VARS="$TF_TRAIN_VARS -var=gpu_availability_zone=$TRAIN_AZ"
    log "TRAIN=allreduce: $TRAIN_NODES x $TRAIN_INSTANCE_TYPE of $TRAIN_GPUS_PER_NODE GPUs, price ceiling \$$TRAIN_MAX_PRICE, GPU budget ${TRAIN_GPU_BUDGET}s"
    ;;
  *) die "TRAIN=$TRAIN is not a training mode this session runs (ddp, allreduce)" ;;
esac

# --- STUDY=prefixroute: what must hold before anything is built -------------------------------------------
PREFIX_MAX_PRICE="${PREFIX_MAX_PRICE:-1.40}"
PREFIX_NODES=2
if [[ "$STUDY" == prefixroute ]]; then
  [[ -z "$SERVE$TRAIN" ]] || die "STUDY=prefixroute with SERVE or TRAIN would buy GPUs in two groups under one deadline; run one"
  # The node gates are the training session's, tested by hack/test/check-train-session-lib.sh.
  # shellcheck source=hack/lib/train-session.sh
  . hack/lib/train-session.sh
  if ((TTL_MINUTES * 60 < PREFIX_GPU_BUDGET + 3600)); then
    die "STUDY=prefixroute needs TTL_MINUTES of at least $(((PREFIX_GPU_BUDGET + 3600 + 59) / 60)) for its waits; it is $TTL_MINUTES"
  fi
  why="$(train_require_new_cluster "$CLUSTER" "$REGION" "${KEEP_UP:-}")" || die "$why"
  log "$why"
  # Passed to every apply and destroy of the cluster root, the watchdog's included, so each plans the same groups.
  TF_TRAIN_VARS="-var=gpu_node_instance_type=$TRAIN_INSTANCE_TYPE -var=gpu_max_nodes=$PREFIX_NODES"
fi

if [[ "$SERVE" == yes || -n "$TRAIN" || "$STUDY" == prefixroute ]]; then
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
  echo \$\$ > '$KILL_PIDFILE'
  sleep $((TTL_MINUTES * 60))
  echo \"[ttl] \$(date -u +%H:%M:%SZ) TTL reached; force-destroying\" >> '$KILL_LOG' 2>&1
  cd '$PWD'
  # The cluster first, and only the cluster. It is what bills; the Helm release bills nothing and its destroy
  # needs a reachable API endpoint that, by the time this fires, may well be gone -- so attempting it first
  # would spend the watchdog's one chance on the cheap half.
  # Waits on the state lock and tries three times: its one attempt used to be spent on a lock the foreground
  # destroy, or the nightly one, still held.
  for attempt in 1 2 3; do
    AWS_PROFILE='$AWS_PROFILE' AWS_REGION='$REGION' terraform -chdir='$CLUSTER_DIR' destroy -auto-approve \
      -lock-timeout=10m -var='region=$REGION' -var='cluster_name=$CLUSTER' $TF_TRAIN_VARS >> '$KILL_LOG' 2>&1
    ttl_rc=\$?
    [ \"\$ttl_rc\" = 0 ] && break
    echo \"[ttl] attempt \$attempt failed rc=\$ttl_rc\" >> '$KILL_LOG' 2>&1
    sleep 60
  done
  if [ \"\$ttl_rc\" = 0 ]; then
    echo \"[ttl] \$(date -u +%H:%M:%SZ) force-destroy SUCCEEDED\" >> '$KILL_LOG' 2>&1
    # The GPU deadline is removed only after a destroy that succeeded: with the cluster gone it can only fire
    # against nothing, and left in place it makes the next session refuse to arm its own.
    gpu_ttl=\$(cat '$EXDIR/gpu-ttl-schedule.txt' 2>/dev/null)
    [ -n \"\$gpu_ttl\" ] && AWS_PROFILE='$AWS_PROFILE' AWS_REGION='$REGION' aws scheduler delete-schedule --name \"\$gpu_ttl\" >> '$KILL_LOG' 2>&1
  else
    echo \"[ttl] \$(date -u +%H:%M:%SZ) force-destroy FAILED rc=\$ttl_rc -- the cluster may still be billing\" >> '$KILL_LOG' 2>&1
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
  -var="region=$REGION" -var="cluster_name=$CLUSTER" -var="api_public_access_cidrs=[\"$EGRESS_CIDR\"]" $TF_TRAIN_VARS \
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

# --- Training on two GPUs with NCCL (TRAIN=ddp) -------------------------------------------------------------
#
# train_run runs as a condition, which switches errexit off inside it, so every step's status is checked by hand.
# Nothing is bought until T1 to T5 hold, and those are what the cluster can show with no GPU node at all.
TRAIN_DIR="$EXDIR/train"
train_run() {
  local why ids
  mkdir -p "$TRAIN_DIR" "$EXDIR/ddp"
  why="$(train_sync_app "$CLUSTER" "$TRAIN_APP" "$WAIT_TRAIN_SYNC")" || { bad "T1: $why"; return 1; }
  ok "T1: $why"
  why="$(train_only_clusterqueue "$CLUSTER" "$TRAIN_QUEUE" "$WAIT_TRAIN_QUEUE")" || { bad "T2: $why"; return 1; }
  ok "T2: $why"

  if [[ "$TRAIN" == allreduce ]]; then
    AR_CONTEXT="$CLUSTER" AR_NS="$TRAIN_NS" AR_QUEUE="$TRAIN_QUEUE" AR_TORCH_IMAGE="$TRAIN_IMAGE"
    AR_NCCLTESTS_IMAGE="$NCCLTESTS_IMAGE" AR_GPU_CLASS="$TRAIN_GPU_CLASS" AR_OUT="$EXDIR/c" AR_BUDGET="$AR_JOB_BUDGET"
    AR_BENCH_FILE=experiments/multi-gpu-throughput/allreduce_bench.py AR_STEP_FILE=experiments/multi-gpu-throughput/ddp_step_bench.py
    AR_SCORER=experiments/multi-gpu-throughput/analyze.py
    mkdir -p "$AR_OUT/qualification"
    # The qualification job: one Pod of four GPUs in the nccl-tests image, submitted while no GPU node exists, so
    # T3 shows Kueue and the operator answering before anything is bought; once the node exists it records what Q
    # reads (docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md, "The session").
    ar_render_job train-qualify nccltests-1pod4gpu "$(ar_qualification_body)" \
      >"$TRAIN_DIR/qualification.json" || { bad "could not render the qualification job"; return 1; }
  else
    DDP_CONTEXT="$CLUSTER" DDP_NS="$TRAIN_NS" DDP_QUEUE="$TRAIN_QUEUE" DDP_IMAGE="$TRAIN_IMAGE"
    DDP_SCRIPT=/tmp/train.py DDP_OUT="$EXDIR/ddp" DDP_BUDGET="$TRAIN_ARM_BUDGET" DDP_GPU_CLASS="$TRAIN_GPU_CLASS"
    DDP_PRELUDE="$(ddp_prelude_for experiments/cpu-ddp/train.py "$DDP_SCRIPT" nccl)" || { bad "could not encode train.py"; return 1; }
    # The qualification job: two ranks of one GPU each, submitted while no GPU node exists (design, correction 2).
    # Each rank only asks whether CUDA answers, so a pass is about admission, placement and the image, not training.
    # A rank that finds CUDA stays up sixty seconds: the operator records Running only while it sees both ranks Ready,
    # and does not backfill it on completion, so a rank that exited at once could leave T7 refusing a healthy cluster
    # (codex review of c649f2b). A rank that finds none exits at once.
    ddp_render_job train-qualify "exec python -c 'import sys, time, torch; ok = torch.cuda.is_available(); ok and time.sleep(60); sys.exit(0 if ok else 3)'" \
      >"$TRAIN_DIR/qualification.json" || { bad "could not render the qualification job"; return 1; }
  fi
  why="$(kc apply -f "$TRAIN_DIR/qualification.json" 2>&1)" || { bad "T3: the qualification job was refused: $why"; return 1; }
  why="$(train_qualification_held "$CLUSTER" "$TRAIN_NS" train-qualify "$WAIT_QUAL_HELD" "$TRAIN_QUAL_PODS")" || { bad "T3: $why"; return 1; }
  ok "T3: $why"
  why="$(train_price_gate "$REGION" "$TRAIN_INSTANCE_TYPE" "$TRAIN_MAX_PRICE")" || { bad "T4: $why"; return 1; }
  ok "T4: $why"
  printf '%s\n' "$why" >"$TRAIN_DIR/price.txt"
  local vcpu
  vcpu="$(aws ec2 describe-instance-types --region "$REGION" --instance-types "$TRAIN_INSTANCE_TYPE" \
    --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>&1)"
  [[ "$vcpu" =~ ^[1-9][0-9]*$ ]] || { bad "T5: could not read $TRAIN_INSTANCE_TYPE's default vCPU: ${vcpu:0:200}"; return 1; }
  why="$(train_quota_gate "$REGION" $((vcpu * TRAIN_NODES)))" || { bad "T5: $why"; return 1; }
  ok "T5: $why"
  # Z1: the zones of the subnets the group was created with, read from AWS before anything bills.
  why="$(train_group_subnet_zones "$CLUSTER" "$REGION" "$TRAIN_GROUP" "$TRAIN_AZ")" || { bad "Z1: $why"; return 1; }
  ok "Z1: $why"

  # The AWS deadline fires before the laptop watchdog, so the nodes are the first thing to go whichever clock wins,
  # and it must leave the GPU steps their whole budget.
  local left_min gpu_min
  left_min=$(((KILL_AT - $(date +%s)) / 60))
  gpu_min=$((left_min - 10))
  if ((gpu_min * 60 < TRAIN_GPU_BUDGET)); then
    bad "the watchdog fires in ${left_min} min, leaving the nodes ${gpu_min} min against the ${TRAIN_GPU_BUDGET}s their steps may take; raise TTL_MINUTES"
    return 1
  fi
  # Experiment C registers its GPU bound as the GPU budget itself, so its deadline is set there rather than at
  # whatever the watchdog leaves: a setup that ran fast would otherwise leave the node a longer leash than the
  # registration's bound (the registration's review, finding 4).
  if [[ "$TRAIN" == allreduce ]]; then
    gpu_min=$(((TRAIN_GPU_BUDGET + 59) / 60))
  fi
  TTL_ROLE_ARN="${TTL_ROLE_ARN:-$(terraform -chdir=infra/aws/bootstrap output -raw ttl_scaledown_role_arn 2>>"$EXDIR/session.log")}"
  export TTL_ROLE_ARN
  # shellcheck source=hack/lib/gpu-ttl.sh
  . hack/lib/gpu-ttl.sh
  if ! ttl_arm "$CLUSTER" "$TRAIN_GROUP" "$gpu_min" 2>>"$EXDIR/session.log"; then
    bad "could not register the GPU deadline; no node is bought without one"
    return 1
  fi
  GPU_ARMED=1
  if ! printf '%s\n' "$TTL_SCHEDULE_NAME" >"$GPU_TTL_FILE"; then
    bad "could not record the GPU deadline's name; the watchdog could not remove it later"
    return 1
  fi
  ok "GPU deadline armed for ${gpu_min} min: $TTL_SCHEDULE_NAME"

  log "scaling $TRAIN_GROUP to $TRAIN_NODES -- the nodes start billing here"
  # Marked before the call, not after: a response lost after AWS accepted it would otherwise leave nothing to
  # scale back down. The record exists before it too, because the scale-down refuses without one.
  : >>"$GPU_INSTANCES_FILE"
  SCALED_UP=1
  aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$TRAIN_GROUP" \
    --scaling-config "minSize=0,maxSize=$TRAIN_NODES,desiredSize=$TRAIN_NODES" >>"$EXDIR/session.log" 2>&1 || {
    bad "could not scale $TRAIN_GROUP up"
    return 1
  }
  ids="$(train_qualify_nodes "$CLUSTER" "$TRAIN_GROUP" "$TRAIN_NODES" $((WAIT_GPU_NODE + WAIT_GPU_PLUGIN)) "$TRAIN_GPUS_PER_NODE")" || {
    bad "T6: $ids"
    return 1
  }
  awk '{print $2}' <<<"$ids" >>"$GPU_INSTANCES_FILE"
  ok "T6: $(paste -sd';' <<<"$ids")"
  kc get nodes -o json >"$TRAIN_DIR/nodes.json" 2>>"$EXDIR/session.log" || true
  # Z2: the zone each qualified node runs in, which every rank's figure inherits; with TRAIN_AZ, all of them in it.
  local zones
  zones="$(train_node_zones "$CLUSTER" "$TRAIN_GROUP" "$TRAIN_AZ")" || { bad "Z2: $zones"; return 1; }
  printf '%s\n' "$zones" >"$TRAIN_DIR/node-zones.txt"
  ok "Z2: $(paste -sd';' <<<"$zones")"
  why="$(train_qualification_released "$CLUSTER" "$TRAIN_NS" train-qualify "$WAIT_QUAL_RUN")" || { bad "T7: $why"; return 1; }
  ok "T7: $why"
  kc -n "$TRAIN_NS" get mltrainingjob train-qualify -o json >"$TRAIN_DIR/qualification-final.json" 2>>"$EXDIR/session.log" || true
  if [[ "$TRAIN" == allreduce ]]; then
    train_run_allreduce "$ids" "$zones"
    return
  fi

  # The arms, as experiments/multi-pod-ddp/ registers them, with the provenance the analyzer reads its bar from.
  {
    echo "commit=$(git rev-parse HEAD)"
    echo "dirty_files=$(git status --porcelain | wc -l)"
    echo "kubectl=$(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
    echo "kueue=$(sed -n 's/^version=//p' config/kueue-controller/RELEASE)"
    echo "train_py_sha256=$train_sha"
    echo "approved_train_py_sha256=$APPROVED_TRAIN_SHA256"
    echo "workload_image=$TRAIN_IMAGE"
    echo "nodes=$(paste -sd' ' <<<"$ids")"
    echo "train_az=${TRAIN_AZ:-unpinned}"
    echo "node_zones=$(paste -sd' ' <<<"$zones")"
    echo "profile=nccl"
    echo "arms=$TRAIN_ARMS"
  } >"$EXDIR/ddp/provenance.txt"
  local arm
  for arm in $TRAIN_ARMS; do
    ddp_run_arm "$arm" || bad "arm $arm could not be run: $(cat "$EXDIR/ddp/$arm/VOID" 2>/dev/null)"
  done
  if python3 experiments/multi-pod-ddp/analyze.py --profile nccl --script-sha256 "$APPROVED_TRAIN_SHA256" "$EXDIR/ddp" \
    >"$EXDIR/ddp/verdict.txt" 2>&1; then
    ok "T8: every arm PASS under the nccl profile ($EXDIR/ddp/verdict.txt)"
  else
    bad "T8: not every arm passed under the nccl profile: $(grep -E '^(PASS|FAIL|VOID)' "$EXDIR/ddp/verdict.txt" | paste -sd';')"
  fi
}

# Reached on every exit once the nodes or their deadline exist, from the normal path and from the EXIT trap.
# Errexit is off inside, because a cleanup that stops at its first failed command is the one that leaves nodes billing.
# train_run_allreduce IDS ZONES: experiment C on the qualified node, from Q through the scorer.
#
# Q is read from the qualification job's own log; T7b pulls the torch image and shows torch sees four devices; then
# the smoke jobs and the registered jobs (hack/lib/allreduce-arms.sh), and the scorer over all of it.
train_run_allreduce() {
  local ids="$1" zones="$2" node why
  node="$(awk 'NR == 1 {print $1}' <<<"$ids")"
  if ! kc -n "$TRAIN_NS" logs -l batch.kubernetes.io/job-name=train-qualify --tail=-1 \
    >"$AR_OUT/qualification/qualification.log" 2>>"$EXDIR/session.log"; then
    bad "Q: the qualification job's log could not be read"
    return 1
  fi
  cp "$TRAIN_DIR/qualification-final.json" "$AR_OUT/qualification/" 2>>"$EXDIR/session.log"
  why="$(python3 - "$AR_OUT/qualification" <<'PY'
import sys
sys.path.insert(0, "experiments/multi-gpu-throughput")
import analyze
from pathlib import Path
faults = analyze.judge_qualification(Path(sys.argv[1]))
print("; ".join(faults) or "four distinct UUIDs, one driver, a 4 x 4 topology and 1 GiB of /dev/shm")
sys.exit(1 if faults else 0)
PY
)" || { bad "Q: $why"; return 1; }
  ok "Q: $why"
  # The warm job pulls the torch image, so it is given the warm wait rather than a measured job's budget.
  AR_BUDGET="$WAIT_WARM" ar_run_job c-warm allreduce-1pod4gpu "$AR_OUT/warm" "$(ar_warm_body)"
  if [[ "$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("status") or {}).get("phase"))' "$AR_OUT/warm/final-mltj.json" 2>&1)" != Succeeded ]]; then
    bad "T7b: the warm job did not succeed ($(grep -h AR_WARM "$AR_OUT"/warm/log-*.txt 2>&1 | head -1))"
    return 1
  fi
  ok "T7b: $(grep -h AR_WARM "$AR_OUT"/warm/log-*.txt | head -1)"
  {
    echo "commit=$(git rev-parse HEAD)"
    echo "dirty_files=$(git status --porcelain | wc -l)"
    echo "kueue=$(sed -n 's/^version=//p' config/kueue-controller/RELEASE)"
    echo "approved_bench_sha256=$APPROVED_BENCH_SHA256"
    echo "approved_step_sha256=$APPROVED_STEP_SHA256"
    echo "torch_image=$TRAIN_IMAGE"
    echo "nccltests_image=$NCCLTESTS_IMAGE"
    echo "node=$node"
    echo "nodes=$(paste -sd' ' <<<"$ids")"
    echo "train_az=${TRAIN_AZ:-unpinned}"
    echo "node_zones=$(paste -sd' ' <<<"$zones")"
    echo "order_seed=$AR_ORDER_SEED"
    echo "job_budget_seconds=$AR_BUDGET"
    echo "nodegroup_release=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$TRAIN_GROUP" \
      --query 'nodegroup.releaseVersion' --output text 2>&1 | head -1)"
  } >"$AR_OUT/provenance.txt"
  AR_SCORER_ARGS="--bench-sha256 $APPROVED_BENCH_SHA256 --step-sha256 $APPROVED_STEP_SHA256 --node $node"
  if ar_run_all; then
    ok "the smoke jobs passed and every registered job ran"
  else
    bad "the arms stopped: $(cat "$AR_OUT/STOPPED" 2>&1)"
  fi
  if python3 "$AR_SCORER" "$AR_OUT" --bench-sha256 "$APPROVED_BENCH_SHA256" --step-sha256 "$APPROVED_STEP_SHA256" \
    >"$AR_OUT/verdict.txt" 2>&1; then
    ok "T8: every registered job valid ($AR_OUT/verdict.txt)"
  else
    bad "T8: not every job was valid: $(grep -cE '^INVALID' "$AR_OUT/verdict.txt") invalid line(s), see $AR_OUT/verdict.txt"
  fi
}

train_down() {
  local - why p
  set +e
  for p in "${DDP_COLLECTORS[@]}" "${AR_COLLECTORS[@]}"; do kill "$p" 2>>"$EXDIR/session.log"; done
  DDP_COLLECTORS=()
  AR_COLLECTORS=()
  [[ -n "$SCALED_UP$GPU_ARMED" ]] || return 0
  if [[ -n "$SCALED_UP" ]]; then
    log "scaling $TRAIN_GROUP to 0"
    if why="$(train_scale_down "$CLUSTER" "$REGION" "$TRAIN_GROUP" "$GPU_INSTANCES_FILE" "$WAIT_GPU_GONE")"; then
      ok "S6 (GPU half): $why"
      SCALED_UP=""
    else
      bad "S6: $why; the GPU deadline stays armed"
      return 0
    fi
  fi
  # Removed only once the nodes are verifiably gone; a leftover schedule makes the next session refuse to arm.
  if ttl_disarm 2>>"$EXDIR/session.log"; then
    rm -f "$GPU_TTL_FILE"
    GPU_ARMED=""
  else
    bad "the GPU deadline $(cat "$GPU_TTL_FILE" 2>/dev/null) could not be removed; delete it before the next session"
  fi
}

if [[ -n "$TRAIN" ]]; then
  # From here an error or a signal ends the run through train_down, as SERVE's does through gpu_down.
  trap 'train_down' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if ((failures > 0)); then
    # The GitOps baseline is the ground the training claim stands on; a failure there buys no node.
    bad "the GitOps baseline failed ($failures check(s)), so no GPU is bought and nothing is trained"
  else
    train_run || true
  fi
  train_down
fi

# --- The prefix-aware routing study on two GPUs (STUDY=prefixroute) -------------------------------------------
#
# prefix_run runs as a condition, which switches errexit off inside it, so every gate's status is checked by hand.
# It buys the two nodes with the training session's gates and releases them through train_down, whose group is gpu.
prefix_run() {
  local why vcpu left_min gpu_min ids
  why="$(train_price_gate "$REGION" "$TRAIN_INSTANCE_TYPE" "$PREFIX_MAX_PRICE")" || { bad "P1: $why"; return 1; }
  ok "P1: $why"
  mkdir -p "$EXDIR/prefix-route-study"
  printf '%s\n' "$why" >"$EXDIR/prefix-route-study/price.txt"
  vcpu="$(aws ec2 describe-instance-types --region "$REGION" --instance-types "$TRAIN_INSTANCE_TYPE" \
    --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text 2>&1)"
  [[ "$vcpu" =~ ^[1-9][0-9]*$ ]] || { bad "P2: could not read $TRAIN_INSTANCE_TYPE's default vCPU: ${vcpu:0:200}"; return 1; }
  why="$(train_quota_gate "$REGION" $((vcpu * PREFIX_NODES)))" || { bad "P2: $why"; return 1; }
  ok "P2: $why"
  # P4: the collector runs on a CPU node and was the first thing run 1 of 2026-10-28 could not start, after two GPUs had
  # been bought; whether a CPU node has room for it is known before any GPU is, so it is asked here.
  # shellcheck source=hack/eks-serve/prefix-route-study/collector.env
  . hack/eks-serve/prefix-route-study/collector.env
  why="$( (kc get nodes -o json && echo '---' && kc get pods -A -o json) 2>&1 | python3 -c '
import json, sys
text = sys.stdin.read()
if "\n---\n" not in text:
    sys.exit("could not read the nodes and Pods: " + text[:300])
nodes, pods = (json.loads(part) for part in text.split("\n---\n", 1))
def milli(q):
    q = str(q)
    return int(q[:-1]) if q.endswith("m") else int(float(q) * 1000)
used = {}
for p in pods["items"]:
    if p["status"].get("phase") in ("Succeeded", "Failed") or not p["spec"].get("nodeName"):
        continue
    req = sum(milli(c.get("resources", {}).get("requests", {}).get("cpu", "0")) for c in p["spec"]["containers"])
    init = max([milli(c.get("resources", {}).get("requests", {}).get("cpu", "0")) for c in p["spec"].get("initContainers", [])] or [0])
    used[p["spec"]["nodeName"]] = used.get(p["spec"]["nodeName"], 0) + max(req, init)
need = int(sys.argv[1])
free = {}
for n in nodes["items"]:
    # The collector tolerates nothing, so a node it cannot schedule onto offers it no CPU, the GPU nodes included.
    ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in n["status"].get("conditions") or [])
    blocked = any(t.get("effect") in ("NoSchedule", "NoExecute") for t in n["spec"].get("taints") or [])
    if n["spec"].get("unschedulable") or not ready or blocked:
        continue
    name = n["metadata"]["name"]
    free[name] = milli(n["status"]["allocatable"]["cpu"]) - used.get(name, 0)
report = ", ".join(f"{k} {v}m unrequested" for k, v in sorted(free.items())) or "no CPU node"
if not any(v >= need for v in free.values()):
    sys.exit(f"the collector requests {need}m and no CPU node has it: {report}")
print(f"the collector requests {need}m: {report}")
' "$COLLECTOR_CPU_M" 2>&1)" || { bad "P4: $why"; return 1; }
  ok "P4: $why"
  printf '%s\n' "$why" >"$EXDIR/prefix-route-study/cpu-capacity.txt"
  # The AWS deadline fires before the laptop watchdog, so the nodes are the first thing to go whichever clock wins,
  # and it must leave the study its whole budget.
  left_min=$(((KILL_AT - $(date +%s)) / 60))
  gpu_min=$((left_min - 10))
  if ((gpu_min * 60 < PREFIX_GPU_BUDGET)); then
    bad "the watchdog fires in ${left_min} min, leaving the nodes ${gpu_min} min against the ${PREFIX_GPU_BUDGET}s the study may take; raise TTL_MINUTES"
    return 1
  fi
  TTL_ROLE_ARN="${TTL_ROLE_ARN:-$(terraform -chdir=infra/aws/bootstrap output -raw ttl_scaledown_role_arn 2>>"$EXDIR/session.log")}"
  export TTL_ROLE_ARN
  # shellcheck source=hack/lib/gpu-ttl.sh
  . hack/lib/gpu-ttl.sh
  if ! ttl_arm "$CLUSTER" "$TRAIN_GROUP" "$gpu_min" 2>>"$EXDIR/session.log"; then
    bad "could not register the GPU deadline; no node is bought without one"
    return 1
  fi
  GPU_ARMED=1
  GPU_DEADLINE=$(($(date +%s) + gpu_min * 60))
  if ! printf '%s\n' "$TTL_SCHEDULE_NAME" >"$GPU_TTL_FILE"; then
    bad "could not record the GPU deadline's name; the watchdog could not remove it later"
    return 1
  fi
  ok "GPU deadline armed for ${gpu_min} min: $TTL_SCHEDULE_NAME"
  log "scaling $TRAIN_GROUP to $PREFIX_NODES -- the nodes start billing here"
  : >>"$GPU_INSTANCES_FILE"
  SCALED_UP=1
  aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$TRAIN_GROUP" \
    --scaling-config "minSize=0,maxSize=$PREFIX_NODES,desiredSize=$PREFIX_NODES" >>"$EXDIR/session.log" 2>&1 || {
    bad "could not scale $TRAIN_GROUP up"
    return 1
  }
  # One card per g5.xlarge; the gate requires the count, so a node advertising none is refused rather than qualified.
  ids="$(train_qualify_nodes "$CLUSTER" "$TRAIN_GROUP" "$PREFIX_NODES" $((WAIT_GPU_NODE + WAIT_GPU_PLUGIN)) 1)" || {
    bad "P3: $ids"
    return 1
  }
  awk '{print $2}' <<<"$ids" >>"$GPU_INSTANCES_FILE"
  ok "P3: $(paste -sd';' <<<"$ids")"
  log "study: prefixroute, until $(date -u -d "@$GPU_DEADLINE" +%H:%M:%SZ) less a 10 min margin"
  if CONTEXT="$CLUSTER" EXDIR="$EXDIR" STUDY_DEADLINE="$GPU_DEADLINE" TEARDOWN_RESERVE=600 \
    hack/eks-serve/prefix-route-study/run.sh >>"$EXDIR/session.log" 2>&1; then
    ok "study: all twelve cells ran; $(head -1 "$EXDIR/prefix-route-study/verdict.txt" 2>/dev/null || echo 'no verdict file')"
  else
    bad "study stopped: $(cat "$EXDIR/prefix-route-study/STOPPED" 2>/dev/null || echo 'no reason recorded'); the cells written are kept"
  fi
}

if [[ "$STUDY" == prefixroute ]]; then
  # train_down iterates the training collectors, which this mode never starts.
  DDP_COLLECTORS=()
  trap 'train_down' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if ((failures > 0)); then
    bad "the GitOps baseline failed ($failures check(s)), so no GPU is bought and nothing is measured"
  else
    prefix_run || true
  fi
  train_down
fi

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
destroy_cluster() {
  terraform -chdir="$CLUSTER_DIR" destroy -auto-approve -input=false -lock-timeout=10m \
    -var="region=$REGION" -var="cluster_name=$CLUSTER" $TF_TRAIN_VARS \
    >>"$EXDIR/terraform.log" 2>&1
}
# sweep_leaked_cni_enis deletes the network interfaces the VPC CNI left detached in this cluster's VPC.
#
# The CNI's interfaces outlive their node when it is terminated before the CNI releases them, and one detached
# interface holds its subnet and security group: four-GPU run 3's destroy failed on exactly that (DependencyViolation,
# 2026-10-29) with nothing left billing, and finished once the interface was deleted by hand.
# They appear only after the node group is gone, which is inside the destroy, so the sweep runs after a failed
# destroy and before its one retry. It returns non-zero when it deleted nothing, so a retry is made only when
# something changed; an interface it cannot delete is named and stops the sweep.
sweep_leaked_cni_enis() {
  local vpc enis eni err
  if ! vpc=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:project,Values=gpu-platform-control-plane" \
    --query 'Vpcs[].VpcId' --output text 2>&1); then
    log "the CNI sweep could not list the cluster's VPC: $vpc"
    return 1
  fi
  if [[ -z "$vpc" || "$vpc" == None ]]; then
    log "the CNI sweep found no VPC left, so no interface can be holding it"
    return 1
  fi
  if [[ "$vpc" == *[[:space:]]* ]]; then
    log "the CNI sweep found more than one project VPC ($vpc) and deletes nothing it cannot attribute"
    return 1
  fi
  if ! enis=$(aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$vpc" \
    "Name=status,Values=available" "Name=description,Values=aws-K8S-*" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>&1); then
    log "the CNI sweep could not list $vpc's interfaces: $enis"
    return 1
  fi
  if [[ -z "$enis" || "$enis" == None ]]; then
    log "the CNI sweep found no detached aws-K8S interface in $vpc"
    return 1
  fi
  for eni in $enis; do
    if ! err=$(aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>&1); then
      log "the CNI sweep could not delete $eni: $err"
      return 1
    fi
    log "deleted $eni, a detached interface the VPC CNI left in $vpc"
  done
}
if ! destroy_cluster; then
  log "cluster destroy failed; looking for interfaces the VPC CNI left detached, which hold subnets and security groups"
  sweep_leaked_cni_enis && log "retrying the cluster destroy" && destroy_cluster
fi || {
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
