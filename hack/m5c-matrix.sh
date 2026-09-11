#!/usr/bin/env bash
#
# The sharing matrix: does giving each tenant its own engine beat giving them one to share?
#
# That is the question, and it is the same mechanism M5-b measures seen from the other side. In the shared
# arm two tenants multiplex one vLLM, so they share a KV cache and the long-context tenant's occupancy is
# what costs the other one latency -- the pressure the admission guard exists to relieve. In the
# time-sliced arm each tenant gets its own engine with its own cache on half the card, so the KV coupling is
# gone and what remains is contention for the SMs. Neither is obviously better, which is why it is worth
# measuring rather than asserting.
#
#   shared        one engine, whole card, both tenants routed to it        (M5-b's topology)
#   timeSlicing   two engines, half card each, one tenant routed to each
#   mps           the same two engines, sharing through MPS instead
#
# MPS is not a third topology, it is a second mechanism for the same one, and the difference is worth
# stating because it is the reason both arms exist. Time-slicing interleaves kernels and does NOT partition
# memory -- the two engines draw on one pool and only convention keeps their utilizations summing below 1.
# MPS runs their kernels concurrently in one context AND caps each client's memory: the pinned control
# daemon issues set_default_device_pinned_mem_limit, read out of the binary rather than the documentation.
# So the arms differ in whether the tenants contend for SM time serially or concurrently, and in whether
# their memory ceiling is enforced or agreed.
#
# The routing is built from mechanisms this control plane already has: the gateway resolves a backend from
# the requesting tenant's GPUQuotaPolicy targetNamespace, so putting each engine in its own namespace and
# pointing one policy at each is all it takes. No new code, and the arm is a deployment difference rather
# than a code path.
#
# What this does NOT report is per-engine GPU utilisation. Under time-slicing a busy SM belongs to no single
# Pod and DCGM cannot attribute it -- config/nvidia-device-plugin/daemonset.yaml says so, and it is why the
# sharing node deliberately has no observer. The matrix reports what the CLIENTS measured, which is
# unambiguous and is also what a tenant actually experiences.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
export GOTOOLCHAIN=go1.26.0

# Where the card comes from, which is the only thing about this matrix that is not the experiment.
#
# eks is the original: a managed cluster with a GPU node group this script scales up and down, and an
# EventBridge deadline as the backstop for a shell that dies. kind is one rented Spot instance that is
# itself the node, with a kind cluster on it -- hack/queuelab-gpu-session.sh already builds exactly that on
# real A10Gs, and hack/m5c-gpu-session.sh is the wrapper that does it for this matrix.
#
# The reason both exist is that the cluster half of the AWS path has never been applied, so the eks branch
# below cannot be run today and cannot be tested. Its lines are therefore left exactly as they were and
# merely moved inside a function: a refactor of a paid-run path nobody can exercise is how a working script
# becomes a broken one silently. Everything the two platforms share -- the arms, the routing, the cells --
# is one copy, because a second written from memory of the first is the failure this repository has already
# paid for twice.
PLATFORM="${PLATFORM:-eks}"
KCTX="${KCTX:-$(kubectl config current-context 2>/dev/null)}"
NS_A="${NS_A:-m5c-a}"
NS_B="${NS_B:-m5c-b}"
MODEL="Qwen/Qwen2.5-3B-Instruct"
OUT="${OUT:-hack/m5c-run-$(date +%Y%m%d-%H%M%S)}"
LOG="$OUT/evidence.log"
GW_IMAGE="${GW_IMAGE:-gateway:m5c}"
# Four, matching hack/gpu-session.sh and the design.
#
# This defaulted to 2, and the session script it is meant to complement defaults to 4. The scripts do not
# read each other, so a re-run bought half the repetitions the study was designed around -- silently, and in
# the direction that weakens it. Two independent reviews scored the design's statistical power at 30% when
# n was 2 per cell and named the run count as the binding limit; that is the number this default was quietly
# restoring every time an arm was re-run.
#
# Below four the incremental interval is a bootstrap over very few blocks. Two is a floor the report will
# tolerate, not a target anything argued for.
REPS="${REPS:-4}"
# The arms, in the order they are run.
#
# R1 FIRST, and it is not a formality: it is the isolated baseline both bars are ratios against, so a run
# that is cut short after one cell should have the denominator rather than a numerator with nothing to
# divide by. It was absent from this default until the first paid run, whose readings then declined to
# evaluate anything for want of it.
#
# A session that only has time for a subset should say which rather than silently getting the default.
ARMS="${ARMS:-R1 shared timeSlicing mps}"

k() { kubectl --context "$KCTX" "$@"; }
# Both tee to the evidence log ONCE IT EXISTS, and only print before that.
#
# The preflight refusals run before $OUT is created, so tee'ing unconditionally printed
# `evidence.log: No such file or directory` underneath every one of them. A refusal that arrives with a
# spurious error beside it is how people learn to read past errors, which is the opposite of what a refusal
# is for.
say() { if [ -d "$OUT" ]; then echo "== $*" | tee -a "$LOG"; else echo "== $*"; fi; }
fail() { if [ -d "$OUT" ]; then echo "MATRIX FAILED: $*" | tee -a "$LOG" >&2; else echo "MATRIX FAILED: $*" >&2; fi; exit 1; }

case "$PLATFORM" in
  eks|kind) ;;
  *) fail "PLATFORM is ${PLATFORM@Q}; it must be eks or kind. Refusing rather than picking one: the two differ in what stops the card billing." ;;
esac

[ -n "${RATE:-}" ] || fail "RATE is unset. Measure it from a single contender prefill on THIS card, the way hack/m5b-gpu-session.sh does; the harness default of 20/s demands 3.8x an A10G's theoretical peak and would censor every arm."

# The whole load, passed rather than defaulted -- and RATE alone was never enough.
#
# hack/m5b-price-of-protection.sh says it in one line: "gen-trace's defaults are stub-calibrated and the
# first pilot ran them at a GPU at ten times its prefill capacity." This script asked for RATE and left the
# tenant MIX at those defaults, which is the larger half of the same mistake.
#
# The arithmetic, because it is the reason this is a refusal and not a default. gen-trace defaults to
# premium 1, noisy 1 and two probe tenants at 0.1, so the contender takes 45% of arrivals. Its prompt is
# 40,000 characters, about 7,744 tokens, which the paid evidence measured at roughly 1.03 s of engine each.
# At the price-of-protection run's RATE of 9.85 that is 4.5 contender arrivals a second against a card that
# can serve about one -- four to five times capacity, and every arm censored.
#
# AND NO RATE FIXES IT. Bringing the contender down to the ~0.5/s that run used means RATE near 1.1, which
# leaves the premium tenant at about 0.5/s too: fewer than a hundred premium requests in a trace of this
# length, under the MinTailSamples floor that reading 4b exists to enforce. The mix has to move, not the
# rate. The run that measured a workable one used premium 1, noisy 0.054, probe 0.0054.
#
# DURATION_MS is here for the same reason. It used to be derived as 500/(RATE/2), an arithmetic that assumes
# the two tenants split arrivals evenly -- true of the defaults above and false of any calibrated mix, so it
# would have sized the trace from a premise the run had just abandoned.
for v in PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT DURATION_MS; do
  [ -n "${!v:-}" ] || fail "$v is unset. RATE alone does not describe this load: gen-trace's default mix puts the 40,000-character contender at 45% of arrivals, which is four to five times an A10G's prefill capacity at any rate this study could use, and lowering RATE to compensate starves the premium tail below the MinTailSamples floor. Derive the mix on the card and pass all four. hack/m5b-price-of-protection.sh measured RATE=9.85 PREMIUM_WEIGHT=1 NOISY_WEIGHT=0.054 PROBE_WEIGHT=0.0054 DURATION_MS=420000 for ONE engine with the whole card; this run gives each engine half of one, so it is a starting point and not an answer."
done
# Only EKS needs one. A kind node loads the image from the host daemon, and demanding a registry there would
# push an operator into standing one up for a cluster that can side-load.
[ "$PLATFORM" != eks ] || [ -n "${REGISTRY:-}" ] \
  || fail "REGISTRY is unset. EKS nodes cannot side-load an image, so the gateway must be pushed where they can pull it."

mkdir -p "$OUT" || fail "cannot create $OUT"
: > "$LOG"

WORK="$(mktemp -d)"
PF_PID=""
NODEGROUP=""

# Scaling the node group back to zero, which this file's header claimed and this function did not do.
#
# It printed a banner. A banner is not a control: it depends on a human reading a terminal that may have
# scrolled, or that no longer exists because the laptop closed. The node group keeps desiredSize=1, the ASG
# keeps a GPU node, and this matrix's g5.xlarge bills $1.237/hour with nothing scheduled on it.
#
# The names are derived rather than asked for, because a prompt in a trap is a prompt nobody answers:
# the cluster comes from the kubeconfig context's EKS ARN and the node group from the node's own
# eks.amazonaws.com/nodegroup label. If either cannot be derived the function says so and prints the manual
# command -- degrading to the old behaviour rather than failing silently.
#
# KEEP_NODE=1 skips it, for a re-run against a node that is already warm rather than paying for a fresh
# warmup. The matrix has no separate re-run script, so this matters less here than in m5b-gpu-session.sh.
#
# What this does NOT solve, stated so it is not mistaken for solved: a trap cannot run after the laptop dies,
# loses power, or has its shell killed with SIGKILL. The backstop for that is the nightly destroy workflow,
# and the deadline this script registers with EventBridge Scheduler is what covers those.
# See hack/lib/gpu-ttl.sh.
gpu_scale_down() {
  # The deadline is NOT dropped here, and the ordering is the whole point.
  #
  # Removing it first means a scale-down that then fails leaves the account with a billing GPU and no
  # remaining backstop -- the one arrangement worse than either failure alone. The schedule costs nothing
  # while it waits and does nothing once the node is already at zero, so there is no reason to trade it away
  # before the thing it protects against is known not to have happened. It comes off at the bottom of this
  # function, after desiredSize has been read back as 0, and nowhere else.
  #
  # KEEP_NODE=1 keeps the node up; the deadline stays armed, so a session someone walks away from still ends.
  if [ "${KEEP_NODE:-}" = "1" ]; then
    echo "KEEP_NODE=1: leaving $NODEGROUP up. The TTL deadline stays armed; it bills until then." >&2
    return 0
  fi

  CLUSTER="${CLUSTER:-$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's|.*cluster/||')}"

  # Ask EKS what is billing rather than trusting a flag set after the preflight checks. The same reasoning is
  # written out in m5b-gpu-session.sh: the refusals that run before the node group is identified used to exit
  # through a cleanup that believed nothing had been started.
  if [ -z "$NODEGROUP" ] && [ -n "$CLUSTER" ]; then
    for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" \
                  --query 'nodegroups[?starts_with(@, `gpu`)]' --output text 2>/dev/null); do
      size=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
               --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null)
      if [ -n "$size" ] && [ "$size" != "0" ] && [ "$size" != "None" ]; then
        echo "found $CLUSTER/$ng at desiredSize=$size without this session having recorded it" >&2
        # No break. The same fix went into hack/m5b-gpu-session.sh and this file was left with the old
        # shape, so a claim that "every stray group is scaled down" was true of one script and not the
        # other. Taking the first and stopping leaves the rest billing, in the function whose only job is
        # to find what is billing and stop it.
        if [ -z "$NODEGROUP" ]; then
          NODEGROUP="$ng"
        else
          aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
            --scaling-config minSize=0,maxSize=1,desiredSize=0 >/dev/null 2>&1 \
            && echo "also scaled $CLUSTER/$ng to zero" >&2 \
            || echo "WARNING: could not scale $CLUSTER/$ng down. IT IS STILL BILLING." >&2
        fi
      fi
    done
  fi

  if [ -z "$CLUSTER" ] || [ -z "${NODEGROUP:-}" ]; then
    echo
    echo "############################################################"
    echo "#  COULD NOT DERIVE cluster/nodegroup. SCALE TO 0 BY HAND. #"
    echo "#  It bills by the hour with nothing scheduled on it.      #"
    echo "#    aws eks update-nodegroup-config \\"
    echo "#      --cluster-name <cluster> --nodegroup-name <ng> \\"
    echo "#      --scaling-config minSize=0,maxSize=1,desiredSize=0  #"
    echo "############################################################"
    return 0
  fi

  echo "scaling $CLUSTER/$NODEGROUP to desiredSize=0" >&2
  # stderr is kept, so a failed scale-down says why rather than only that.
  if ! aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
        --scaling-config "minSize=0,maxSize=1,desiredSize=0" >/dev/null; then
    echo
    echo "############################################################"
    echo "#  SCALE-DOWN CALL FAILED. THE NODE IS STILL BILLING.      #"
    echo "#  Run this now:                                           #"
    echo "#    aws eks update-nodegroup-config --cluster-name $CLUSTER \\"
    echo "#      --nodegroup-name $NODEGROUP \\"
    echo "#      --scaling-config minSize=0,maxSize=1,desiredSize=0  #"
    echo "############################################################"
    return 0
  fi

  # Confirm it took. An accepted API call that left desiredSize at 1 is the failure this whole function
  # exists to make impossible, and it is silent unless something reads the value back.
  DESIRED=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null)
  if [ "$DESIRED" = "0" ]; then
    echo "$CLUSTER/$NODEGROUP is at desiredSize=0" >&2
    # Only now. The deadline has nothing left to protect, and this is the single place that knows that.
    command -v ttl_disarm >/dev/null 2>&1 && ttl_disarm
  else
    echo "WARNING: $CLUSTER/$NODEGROUP reports desiredSize=$DESIRED after the scale-down. It is billing." >&2
    echo "The TTL deadline is left armed on purpose. It is what remains." >&2
  fi
}

# A signal must also END the script, and these traps did not.
#
# `trap cleanup INT` runs cleanup and then RESUMES where the signal arrived. During the ten-minute wait for
# a node to join, Ctrl-C therefore scaled the node group to zero, dropped the deadline, and went back to
# waiting for the node it had just cancelled -- for another ten minutes, on a card the operator had just
# asked to stop. The cost was cleaned up; the session was not.
#
# EXIT still runs cleanup for ordinary exits and for `fail`. The signal handlers do their own cleanup and
# exit with the conventional 128+signal status, and the guard makes the second call a no-op so the EXIT
# trap that follows does not repeat the work.
CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  k delete namespace "$NS_A" "$NS_B" --wait=false >/dev/null 2>&1
  k delete gpuquotapolicy m5c-premium m5c-standard >/dev/null 2>&1
  k delete clusterrolebinding m5c-gateway-role >/dev/null 2>&1
  rm -rf "$WORK"
  release_card
}

# What stops the card billing, which is the one thing the two platforms cannot share.
#
# Under eks this is gpu_scale_down above, unchanged.
#
# Under kind the card IS the rented instance and this script does not own it: hack/m5c-gpu-session.sh rents
# it, arms a shutdown backstop inside it, and terminates it from outside. There is no node group to scale,
# and printing the COULD NOT DERIVE banner for a cluster that was never meant to have one would teach an
# operator to read past the banner on the day it means something. So it says plainly what it is not doing
# and which thing is.
release_card() {
  case "$PLATFORM" in
    eks) gpu_scale_down ;;
    kind)
      echo "the card is the rented instance, so nothing is scaled down here: hack/m5c-gpu-session.sh terminates it, and the instance's own shutdown backstop covers a shell that dies in this script" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

say "preflight"

# The EKS card: scale a managed node group up, and register the deadline before it exists.
#
# Every line of this function is the code that was here before, moved and indented and otherwise
# untouched. `git diff -w` on the commit that introduced it shows only the wrapper, which is the point:
# the cluster half of the AWS path has never been applied, so nothing here can be exercised, and a
# path nobody can run is a path nobody can prove a refactor kept working.
acquire_card_eks() {
  case "$KCTX" in kind-*) fail "context $KCTX is a kind cluster; this is the paid matrix" ;; esac

  # The sharing node, and it must be the sharing one: the exclusive plugin advertises one device per card, so
  # the second engine would sit Pending and the arm would silently become a one-engine arm with half the memory.
  # The deadline is registered BEFORE the card exists, which is why this script scales the group up itself.
  #
  # It used to refuse when no sharing node was present, print the aws command, and wait to be re-run -- so a
  # person scaled up, the node billed and took minutes to join, and only a re-run registered a deadline. This
  # is the longest run in the repository and therefore the one most likely to outlive the shell that started
  # it; starting it with an unbacked card was the wrong end to be careless at.
  #
  # The name cannot come off a node label before a node exists, so it comes from a default verified against
  # EKS. A name that does not resolve would produce a schedule that is accepted and then fires into nothing.
  CLUSTER="${CLUSTER:-$(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's|.*cluster/||')}"
  [ -n "$CLUSTER" ] || fail "could not determine the cluster name from the kubeconfig context"
  # Named into a candidate first, and promoted to NODEGROUP only once EKS confirms it exists.
  #
  # Assigning NODEGROUP before the check meant that when the check refused, the EXIT trap's scale-down saw a
  # node group name, skipped discovery, and called update-nodegroup-config against a group just proven not to
  # exist -- then printed THE NODE IS STILL BILLING for a session that had started nothing. A commit claimed
  # no refusal path calls update-nodegroup-config; this was the path that did.
  NG_CANDIDATE="${NODEGROUP:-gpu_shared}"
  aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG_CANDIDATE" >/dev/null 2>&1 \
    || fail "no node group $NG_CANDIDATE in $CLUSTER. The deadline must name a group that exists, or it fires into nothing. Set NODEGROUP if the name is different."
  NODEGROUP="$NG_CANDIDATE"

  # One schedule names one node group, so a second GPU group left running is not covered by anything this
  # session registers. The deadline would fire, scale down the group it names, and leave the other billing --
  # and nothing in the run would look wrong.
  #
  # Refusing here rather than trying to cover both is deliberate. A session that finds another card already
  # running does not know whose it is: it may be another session mid-run, and scaling it down would destroy
  # someone else's paid work. Naming it and stopping is the only answer that is right in both cases.
  # Every AWS call here is checked, because the previous shape failed OPEN. It ran the listing inside a
  # command substitution, threw away stderr and the exit status, and iterated the result -- so expired
  # credentials, a permissions error, or a network failure all produced an empty list, which reads exactly
  # like "no other card is running". The same held one level down: a describe that failed left sz empty,
  # which the case treated as zero.
  #
  # That is the wrong direction for this particular guard. It exists for the moments when something is wrong
  # with the account, and those are the moments an unchecked call returns nothing.
  if ! ng_list=$(aws eks list-nodegroups --cluster-name "$CLUSTER" \
                   --query 'nodegroups[?starts_with(@, `gpu`)]' --output text 2>&1); then
    fail "could not list the node groups in $CLUSTER, so this session cannot tell whether another card is already running: $ng_list"
  fi
  others=""
  for ng in $ng_list; do
    [ "$ng" = "$NODEGROUP" ] && continue
    if ! sz=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
                --query 'nodegroup.scalingConfig.desiredSize' --output text 2>&1); then
      fail "could not read the size of $CLUSTER/$ng: $sz. An unreadable node group is not a stopped one."
    fi
    case "$sz" in
      0|None) ;;
      ''|*[!0-9]*) fail "the size of $CLUSTER/$ng came back as ${sz@Q}, which is not a number. Refusing rather than reading it as zero." ;;
      *) others="$others $ng($sz)" ;;
    esac
  done
  [ -z "$others" ] || fail "another GPU node group is already running:$others. This session's deadline names only $NODEGROUP, so that card would keep billing after the deadline fires. Scale it to zero, or if another session owns it, wait for it."

  TTL_ROLE_ARN="${TTL_ROLE_ARN:-$(terraform -chdir=infra/aws/bootstrap output -raw ttl_scaledown_role_arn 2>/dev/null)}"
  export TTL_ROLE_ARN
  # shellcheck source=hack/lib/gpu-ttl.sh
  . "$(dirname "$0")/lib/gpu-ttl.sh"
  if true; then
    ttl_arm "$CLUSTER" "$NODEGROUP" "${TTL_MINUTES:-240}" \
      || fail "could not register the TTL scale-down; refusing to start a card with no deadline"

    # What is checked here, and what is not.
    #
    # The first shape of this check multiplied the per-cell TIMEOUT budget by the cell count and refused if
    # the product exceeded the deadline. At the shipped defaults that is 456 minutes against 240, so the
    # design's own repetition count -- four, which a unit test pins because below it the incremental interval
    # is a bootstrap over very few blocks -- could never start. Lowering REPS to make the arithmetic work was
    # the wrong repair: it traded a statistical property for a scheduling one, quietly.
    #
    # Those 1800 seconds are two rollout TIMEOUTS, not two expected rollouts. A budget is what the script
    # waits before giving up, and refusing a run because the worst case does not fit refuses most runs that
    # would have finished. So the pessimistic product is gone and only the floor stays here: a deadline that
    # cannot hold even one cell is a session with nothing to gain. The real bound is measured per cell, in
    # the loop, where a slow matrix stops on a cell boundary with everything before it intact.
    ttl_min="${TTL_MINUTES:-240}"
    cell_floor_min=$(( (1800 + 180 + ${REPLAY_SECONDS:-300} + 59) / 60 ))
    if [ "$ttl_min" -lt "$cell_floor_min" ]; then
      ttl_disarm
      fail "the deadline is ${ttl_min} min but one cell can take up to ${cell_floor_min} min, so this session could not finish even a single cell. Raise TTL_MINUTES."
    fi
  fi

  # The card starts here, after the deadline exists.
  shared_nodes=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' -o name 2>/dev/null | wc -l)
  if [ "$shared_nodes" -eq 0 ]; then
    say "no sharing node present; scaling $NODEGROUP to 1 -- the card starts billing here, and the deadline is already registered"
    aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
      --scaling-config minSize=0,maxSize=1,desiredSize=1 >/dev/null || fail "could not scale $NODEGROUP up"
    say "wait for the node to join (this takes a few minutes)"
    for i in $(seq 1 60); do
      shared_nodes=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' -o name 2>/dev/null | wc -l)
      [ "$shared_nodes" -gt 0 ] && break
      [ "$i" = 60 ] && fail "the node never joined after ten minutes. The deadline will scale it down; to do it now: aws eks update-nodegroup-config --cluster-name $CLUSTER --nodegroup-name $NODEGROUP --scaling-config minSize=0,maxSize=1,desiredSize=0"
      sleep 10
    done
  fi

  # Cross-check, not re-derive: a node from a different group means the deadline would scale down a group this
  # matrix is not using while the one it is using bills on.
  node_ng=$(k get node -l 'platform.lkhun9311.github.io/gpu-sharing=true' \
    -o jsonpath='{.items[0].metadata.labels.eks\.amazonaws\.com/nodegroup}' 2>/dev/null)
  if [ -n "$node_ng" ] && [ "$node_ng" != "$NODEGROUP" ]; then
    fail "the deadline names $NODEGROUP but the sharing node belongs to $node_ng. Re-run with NODEGROUP=$node_ng."
  fi

  [ "$shared_nodes" -eq 1 ] || fail "$shared_nodes sharing nodes are up; two engines on two nodes are not sharing a card, and nothing downstream could tell that apart from a sharing result"
}

# The kind card: one rented Spot instance that IS the node, with a kind cluster on it.
#
# hack/m5c-gpu-session.sh rents it, installs the driver and the container toolkit, builds the cluster and
# runs this script inside it. Nothing here scales anything, because there is nothing to scale: the card
# arrived with the instance and leaves with it.
acquire_card_kind() {
  case "$KCTX" in
    kind-*) ;;
    *) fail "PLATFORM=kind but the context is ${KCTX@Q}. This path labels nodes and expects to own the cluster it is pointed at, and finding out afterwards that it was a real one is not a way to learn it." ;;
  esac

  # The node whose card this is. kind's control plane carries its own NoSchedule taint and the session
  # script deliberately leaves the worker untainted, so the worker is where every engine runs.
  GPU_NODE="${GPU_NODE:-$(k get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)}"
  [ -n "$GPU_NODE" ] || fail "no non-control-plane node in $KCTX; hack/m5c-gpu-session.sh builds a cluster with one worker and the engines have nowhere else to run"

  # Nobody applies this label on kind, and the failure it causes is silent and expensive.
  #
  # Under EKS it comes off the node group (infra/aws/cluster/eks.tf). Here the cluster was built minutes ago
  # by the session script and the label is this script's to set. Without it every device-plugin overlay sits
  # Pending, the node advertises nothing, and the first arm fails at its 900-second rollout timeout having
  # billed for the card throughout. hack/queuelab-gpu-session.sh learned exactly this about the exclusive
  # plugin's own label and says so at the line that applies it.
  k label node "$GPU_NODE" platform.lkhun9311.github.io/gpu-sharing=true --overwrite >/dev/null \
    || fail "could not label $GPU_NODE; without platform.lkhun9311.github.io/gpu-sharing=true no device plugin will schedule and the node will advertise nothing"

  shared_nodes=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' -o name 2>/dev/null | wc -l)
  [ "$shared_nodes" -eq 1 ] || fail "$shared_nodes nodes carry the sharing label; two engines on two nodes are not sharing a card, and nothing downstream could tell that apart from a sharing result"
  say "card node $GPU_NODE labelled for sharing"

  # The deadline is the INSTANCE's, and this script only reads it.
  #
  # Under EKS the backstop is an EventBridge schedule this script registers, because the thing that bills is
  # a node group that outlives the shell. Here the thing that bills is the instance, the session script arms
  # its shutdown before handing over, and a second deadline registered here would be a second opinion about
  # when the money stops. So this refuses to run without being told when that is, rather than defaulting to
  # a number and reporting cell budgets against a deadline nobody set.
  [ -n "${DEADLINE_EPOCH:-}" ] || fail "DEADLINE_EPOCH is unset. hack/m5c-gpu-session.sh sets it to the instance's shutdown time; without it the per-cell budget check has no deadline to measure against and would let the matrix be cut mid-cell."
}

# Minutes left before the card stops, however this platform knows that.
#
# Both branches print nothing and return non-zero when they cannot tell, because cell_deadline_check treats
# an unreadable deadline as "carry on" -- a budget check that refused on a transient API error would end a
# paid run for no reason.
deadline_remaining_minutes() {
  case "$PLATFORM" in
    eks) ttl_remaining_minutes "$CLUSTER" "$NODEGROUP" ;;
    kind)
      local now
      now=$(date +%s)
      [ -n "${DEADLINE_EPOCH:-}" ] || return 1
      echo $(( (DEADLINE_EPOCH - now) / 60 ))
      ;;
  esac
}

# The card, from whichever platform this session is on. Everything below is the experiment and is one copy.
say "acquiring the card on $PLATFORM"
case "$PLATFORM" in
  eks)  acquire_card_eks ;;
  kind) acquire_card_kind ;;
esac

# The gateway's ClusterRole has to already exist, and this is checked because the failure is silent.
#
# Below, this script runs `kubectl create clusterrolebinding --clusterrole=gateway-role`. Kubernetes accepts
# a binding to a ClusterRole that does not exist -- it is a forward reference, not an error -- so the binding
# is created, the gateway starts, and every request then fails authorization when it tries to list the
# policies it routes from. Nothing before the first replay would look wrong.
#
# It is not applied here because it is not this run's to own: config/gateway/rbac.yaml is deployed with the
# gateway, by GitOps on EKS and by hack/m5c-gpu-session.sh on kind. Naming the file in the refusal is what
# turns this from a puzzle into a command.
k get clusterrole gateway-role >/dev/null 2>&1 \
  || fail "no ClusterRole gateway-role in this cluster. The gateway would start and then fail to list the GPUQuotaPolicy and InferenceDeployment it routes from, on every request, with nothing before the first replay looking wrong. Apply it: kubectl apply -f config/gateway/rbac.yaml"


# Every overlay here selects the SAME node, so exactly one may be applied at a time: two plugins registering
# nvidia.com/gpu against one kubelet socket is not a configuration worth debugging on a rented card.
# Deleting the others first is the mechanism; remembering is not.
#
# THREE modes, not two, and the third is why the `shared` arm could never have run.
#
# `shared` needs ONE device advertised on the sharing node, and nothing advertised one. The exclusive plugin
# selects a label the sharing node group deliberately does not carry, and the two sharing overlays advertise
# two. So the control arm's engine would have sat Pending to its 900-second timeout on a fresh node -- or,
# worse, scheduled onto a leftover replica from the previous arm and produced numbers for a control running
# on half a card. config/nvidia-device-plugin-whole-card is the plugin that was missing.
PLUGIN_NS="${PLUGIN_NS:-gpu-platform-control-plane-system}"
apply_device_plugin() {
  local mode="$1" keep ds want other
  case "$mode" in
    shared)      keep=config/nvidia-device-plugin-whole-card;  ds=nvidia-device-plugin-whole-card;  want=1 ;;
    timeSlicing) keep=config/nvidia-device-plugin-timeslicing; ds=nvidia-device-plugin-timeslicing; want=2 ;;
    mps)         keep=config/nvidia-device-plugin-mps;         ds=nvidia-device-plugin-mps;         want=2 ;;
    *) fail "apply_device_plugin: unknown mode $mode" ;;
  esac
  for other in config/nvidia-device-plugin-whole-card config/nvidia-device-plugin-timeslicing config/nvidia-device-plugin-mps; do
    [ "$other" = "$keep" ] && continue
    k delete -k "$other" --ignore-not-found --wait=true >/dev/null 2>&1
  done
  k apply -k "$keep" >/dev/null || fail "apply the $mode plugin"

  # The KEPT plugin has to be running before its advertisement is believed, and this is not belt-and-braces.
  #
  # Time-slicing and MPS both advertise two, so a count check alone is satisfied by the outgoing arm's stale
  # advertisement: switching timeSlicing -> mps would have passed on the devices the time-slicing plugin was
  # still registering, and the MPS arm would have begun as time-slicing under another name. Waiting for THIS
  # DaemonSet is what tells the two apart, and the count check below then confirms what it registered.
  k rollout status "ds/$ds" -n "$PLUGIN_NS" --timeout=180s >/dev/null \
    || fail "the $mode device plugin never became ready in $PLUGIN_NS; whatever the node is advertising belongs to the previous arm"

  say "wait for the card to advertise exactly $want device(s) under $mode"
  for i in $(seq 1 60); do
    adv=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' \
      -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
    # Exactly, not at least. `-ge` reads the previous arm's larger number as success, which is how a
    # one-device arm would have started on a card the last arm had already split in two.
    [ "${adv:-0}" -eq "$want" ] 2>/dev/null && break
    [ "$i" = 60 ] && fail "the node advertises ${adv:-0} device(s) after applying a $mode config that asks for $want: the plugin is ignoring CONFIG_FILE, and the arm would be running a topology other than the one it is labelled with"
    sleep 10
  done
  say "node advertises $adv device(s) for one physical card under $mode"

  # MPS has a second failure that time-slicing does not: the control daemon can be absent or unreachable
  # while the plugin still advertises, and every client then silently runs WITHOUT MPS. An arm that fell
  # back that way is the time-slicing arm under another name, and nothing downstream could tell.
  if [ "$mode" = mps ]; then
    k rollout status ds/nvidia-mps-control-daemon -n "$PLUGIN_NS" --timeout=180s >/dev/null \
      || fail "the MPS control daemon never became ready; clients would fall back to running without MPS and the arm would be time-slicing under another name"
  fi
}

# Built here, or shipped in. The GPU AMI carries a driver, not a toolchain.
#
# `go build` on the instance fails with `go: command not found`, and it fails AFTER the driver, the cluster
# and the device plugin have all been paid for -- which is precisely the loss hack/queuelab-gpu-session.sh
# describes and answers by building on the laptop and shipping the binary. This is the same answer, and
# building stays the default so a run driven from a development machine needs nothing extra.
say "the gateway and the harness"
if [ -n "${GATEWAY_BIN:-}" ]; then
  [ -x "$GATEWAY_BIN" ] || fail "GATEWAY_BIN=$GATEWAY_BIN is not an executable file"
  cp "$GATEWAY_BIN" "$WORK/gateway" || fail "could not take the shipped gateway binary"
  say "  gateway: shipped, $(sha256sum "$WORK/gateway" | cut -c1-12)"
else
  command -v go >/dev/null || fail "no Go toolchain and GATEWAY_BIN is unset. On a rented GPU instance there is no compiler: build the binaries on the machine that has one and pass GATEWAY_BIN and BENCHHARNESS_BIN."
  CGO_ENABLED=0 GOOS=linux go build -o "$WORK/gateway" ./cmd/gateway || fail "build gateway"
fi
if [ -n "${BENCHHARNESS_BIN:-}" ]; then
  [ -x "$BENCHHARNESS_BIN" ] || fail "BENCHHARNESS_BIN=$BENCHHARNESS_BIN is not an executable file"
  cp "$BENCHHARNESS_BIN" "$WORK/benchharness" || fail "could not take the shipped benchharness binary"
  say "  benchharness: shipped, $(sha256sum "$WORK/benchharness" | cut -c1-12)"
else
  go build -o "$WORK/benchharness" ./cmd/benchharness || fail "build benchharness"
fi
printf 'FROM gcr.io/distroless/static:nonroot\nCOPY gateway /gateway\nUSER 65532:65532\nENTRYPOINT ["/gateway"]\n' > "$WORK/Dockerfile"
docker build -q -t "$GW_IMAGE" "$WORK" >/dev/null || fail "build gateway image"

# How the node gets the image, which is the second thing the two platforms cannot share.
#
# EKS nodes pull, so the image has to exist somewhere they can reach. A kind node is a container on the same
# daemon that just built it, so `kind load` hands it over directly -- and the Deployment must then NOT say
# `imagePullPolicy: Always`, or the kubelet would go looking for a registry that was never involved. The tag
# is unqualified on purpose for the same reason: a `docker.io/` prefix would send it to a real registry.
case "$PLATFORM" in
  eks)
    say "push the gateway to $REGISTRY"
    docker tag "$GW_IMAGE" "$REGISTRY/$GW_IMAGE" && docker push "$REGISTRY/$GW_IMAGE" >/dev/null || fail "push gateway image"
    GW_IMAGE="$REGISTRY/$GW_IMAGE"
    ;;
  kind)
    say "load the gateway into the kind cluster"
    kind load docker-image "$GW_IMAGE" --name "${KCTX#kind-}" >/dev/null \
      || fail "could not load $GW_IMAGE into kind cluster ${KCTX#kind-}; the node cannot pull it from anywhere else"
    ;;
esac

# One routing record per engine namespace, replicas 0 and a no-op image for the reason
# hack/m5b-gpu-session.sh gives: InferenceDeploymentSpec has no args and no volumes, so it cannot describe a
# vLLM container. The engine Deployment must exist FIRST or the operator takes the name.
routing_record() {
  local ns="$1" name="$2"
  k apply -f - >/dev/null <<EOF || fail "routing record in $ns"
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata: {name: $name, namespace: $ns}
spec:
  model: {name: $MODEL, storageUri: "hf://$MODEL"}
  image: registry.k8s.io/pause:3.9
  gpuCount: 0
  replicas: 0
  port: 8000
EOF
}

# What an engine that never became ready was actually doing, captured before the refusal.
#
# `MATRIX FAILED: engine b never became ready` is what the first paid run of this matrix printed, and the
# whole log said nothing else about it. Whether the Pod was Pending for want of a device, CrashLooping on a
# CUDA error, still pulling fifteen gigabytes of image, or killed for memory are four different faults with
# four different fixes, and telling them apart cost a card.
#
# It goes to stdout so it lands in the run log the instance uploads, which is the only thing that outlives
# the machine. Everything here is best-effort: this function runs on the failure path, so a kubectl that
# also fails must not replace the diagnosis with its own error.
# What the engine ACTUALLY allocated, asked of the engine rather than computed.
#
# internal/bench/sharing.go sizes this run and says of its own arithmetic: "ESTIMATED, and the only
# estimated input here. vLLM prints the block count it actually allocated; compare KVTokensPerEngine against
# it at session start rather than trusting this." Nothing was doing the comparing.
#
# It matters most for the split arms and it is cheap everywhere, so it runs for every engine. Two engines at
# --gpu-memory-utilization=0.475 claim 21,877 of an A10G's 23,028 MiB and leave 1,151 for two CUDA contexts
# and the driver's reserve, which is the leading hypothesis for the engine b that would not start on
# 2026-09-11 -- and a hypothesis is all it is, because that run captured nothing that could settle it. These
# lines are what settle it next time, whether the arm succeeds or fails.
engine_kv_report() {
  local ns="$1" deploy="$2"
  echo "--- $ns/$deploy: what the engine says it allocated ---"
  k logs -n "$ns" "deploy/$deploy" --tail=400 2>/dev/null \
    | grep -iE "KV cache|GPU blocks|gpu_memory_utilization|memory profiling|Available KV cache" \
    | tail -8 | sed 's/^/  /' \
    || echo "  (the engine printed no line naming its KV cache, which is itself worth knowing)"
}

engine_diagnosis() {
  local ns="$1" deploy="$2"
  echo "=== why $ns/$deploy never became ready ==="
  k get pods -n "$ns" -o wide 2>&1 | sed 's/^/  /'
  echo "--- deployment conditions ---"
  k get deploy "$deploy" -n "$ns" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>&1 | sed 's/^/  /'
  echo "--- pod events, which name a scheduling or image failure ---"
  k get events -n "$ns" --sort-by=.lastTimestamp 2>&1 | tail -20 | sed 's/^/  /'
  echo "--- the engine's own output, which names a CUDA or memory failure ---"
  k logs -n "$ns" "deploy/$deploy" --tail=40 --all-containers 2>&1 | sed 's/^/  /'
  k logs -n "$ns" "deploy/$deploy" --tail=40 --all-containers --previous 2>/dev/null | sed 's/^/  [previous] /'
  echo "--- what the node had left to give ---"
  k get node "${GPU_NODE:-}" -o jsonpath='{.status.allocatable}' 2>&1 | sed 's/^/  /'
  echo
  echo "=== end of diagnosis ==="
}

deploy_arm() {
  local arm="$1"
  k delete namespace "$NS_A" "$NS_B" --wait=true >/dev/null 2>&1
  # The policies go too, and they are NOT covered by deleting the namespaces.
  #
  # GPUQuotaPolicy is cluster-scoped, so it outlives both namespaces, and its targetNamespace is immutable:
  # api/v1/gpuquotapolicy_types.go carries `XValidation: self == oldSelf` with the message "targetNamespace
  # is immutable", because a policy enforces quota in exactly one namespace for its lifetime.
  #
  # Pointing one policy at each engine's namespace is this matrix's whole routing mechanism, and moving the
  # contending tenant from NS_A to NS_B is exactly what the split arms do. Re-applying over a surviving
  # object is therefore refused by the API, every time, on the first sharing arm -- `MATRIX FAILED: policies
  # for timeSlicing`. The exclusive arms never hit it because both of their policies name NS_A.
  #
  # The paid run of 2026-09-11 did not reach this: its engine b timed out first, one step earlier in this
  # same function. hack/test/rehearse-m5c-matrix.sh found it on a kind cluster for nothing.
  k delete gpuquotapolicy m5c-premium m5c-standard --ignore-not-found --wait=true >/dev/null 2>&1
  k create ns "$NS_A" >/dev/null; k create ns "$NS_B" >/dev/null
  case "$arm" in
    R1|shared)
      # One engine with the whole card. Both policies point at the same namespace, so both tenants resolve
      # to it -- which is exactly M5-b's topology and exactly what makes their KV caches one cache.
      #
      # R1 IS THIS TOPOLOGY, and it differs only in the trace. `benchharness gen-trace --arm R1` filters the
      # contending tenant out of the SAME trace, so premium arrives on the identical schedule it has in the
      # contended arms and the baseline is not inflated by running premium at twice its share. The matrix
      # already passes --arm "$arm", so nothing else here has to know.
      #
      # It was missing entirely. deploy_arm had cases for shared and for the sharing pair and none for R1,
      # so the runner could not produce the isolated baseline that is the DENOMINATOR of both of this
      # study's bars. The first paid run made that concrete: the readings declined to evaluate anything,
      # correctly, for want of an R1 the matrix had no way to measure.
      #
      # The plugin comes first and is not optional. This arm's engine asks for one nvidia.com/gpu, and until
      # config/nvidia-device-plugin-whole-card existed nothing advertised one on this node -- so the arm
      # either timed out Pending or inherited the previous arm's split card.
      apply_device_plugin shared
      k apply -f config/vllm/deployment.yaml -n "$NS_A" >/dev/null || fail "apply the exclusive engine"
      k apply -f config/vllm/service.yaml -n "$NS_A" >/dev/null || fail "apply the exclusive service"
      k rollout status deploy/vllm-qwen25-3b -n "$NS_A" --timeout=900s >/dev/null \
        || { engine_diagnosis "$NS_A" vllm-qwen25-3b; fail "the exclusive engine never became ready -- the diagnosis above says what it was doing"; }
      engine_kv_report "$NS_A" vllm-qwen25-3b
      routing_record "$NS_A" vllm-qwen25-3b
      PREMIUM_NS="$NS_A"; STANDARD_NS="$NS_A"
      ;;
    timeSlicing|mps)
      apply_device_plugin "$arm"
      k apply -f config/vllm-shared/engine-a.yaml -n "$NS_A" >/dev/null || fail "apply engine a"
      k apply -f config/vllm-shared/engine-b.yaml -n "$NS_B" >/dev/null || fail "apply engine b"
      # Both are diagnosed on failure, and BOTH are diagnosed when either fails.
      #
      # The engines share one card, so the one that came up is half the explanation for the one that did
      # not: what engine a reserved is what engine b did not get. Reporting only the failing Pod would leave
      # the reader with the symptom and not the arithmetic.
      k rollout status deploy/vllm-shared-a -n "$NS_A" --timeout=900s >/dev/null \
        || { engine_diagnosis "$NS_A" vllm-shared-a; fail "engine a never became ready -- the diagnosis above says what it was doing"; }
      k rollout status deploy/vllm-shared-b -n "$NS_B" --timeout=900s >/dev/null \
        || { engine_diagnosis "$NS_B" vllm-shared-b; engine_diagnosis "$NS_A" vllm-shared-a; fail "engine b never became ready -- the diagnosis above says what it and engine a were doing, and on one card those are the same question"; }
      # Both engines must be on the SAME node or they are not sharing a card. max_size 1 should guarantee
      # it; checking is cheap and the failure is invisible in the numbers.
      na=$(k get pod -n "$NS_A" -l app.kubernetes.io/component=vllm-shared -o jsonpath='{.items[0].spec.nodeName}')
      nb=$(k get pod -n "$NS_B" -l app.kubernetes.io/component=vllm-shared -o jsonpath='{.items[0].spec.nodeName}')
      [ -n "$na" ] && [ "$na" = "$nb" ] || fail "the two engines are on different nodes ($na, $nb); that is not sharing a card"
      engine_kv_report "$NS_A" vllm-shared-a
      engine_kv_report "$NS_B" vllm-shared-b
      routing_record "$NS_A" vllm-shared-a
      routing_record "$NS_B" vllm-shared-b
      PREMIUM_NS="$NS_A"; STANDARD_NS="$NS_B"
      ;;
  esac

  k apply -f - >/dev/null <<EOF || fail "policies for $arm"
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: m5c-premium
  annotations: {platform.lkhun9311.github.io/tier: premium}
spec: {tenant: premium-1, targetNamespace: $PREMIUM_NS, gpuClass: a10g, limits: {gpuCount: 1}}
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata: {name: m5c-standard}
spec: {tenant: standard-noisy, targetNamespace: $STANDARD_NS, gpuClass: a10g, limits: {gpuCount: 1}}
EOF

  k create secret generic gateway-api-keys -n "$NS_A" \
    --from-literal=premium-key=premium-1 --from-literal=standard-key=standard-noisy \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create serviceaccount gateway -n "$NS_A" --dry-run=client -o yaml | k apply -f - >/dev/null
  k create clusterrolebinding m5c-gateway-role --clusterrole=gateway-role \
    --serviceaccount="$NS_A:gateway" --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f - >/dev/null <<EOF || fail "secret-reader role"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: gateway-secret-reader, namespace: $NS_A}
rules: [{apiGroups: [""], resources: ["secrets"], verbs: ["get","list","watch"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: gateway-secret-reader, namespace: $NS_A}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: gateway-secret-reader}
subjects: [{kind: ServiceAccount, name: gateway, namespace: $NS_A}]
EOF

  # Admission OFF in both arms. The matrix varies the TOPOLOGY; leaving the guard on would vary two things
  # and hand the difference to whichever one the reader already believed.
  k apply -f - >/dev/null <<EOF || fail "gateway for $arm"
apiVersion: apps/v1
kind: Deployment
metadata: {name: gateway, namespace: $NS_A}
spec:
  replicas: 1
  selector: {matchLabels: {app: m5c-gateway}}
  template:
    metadata:
      labels: {app: m5c-gateway}
      annotations: {arm: "$arm"}
    spec:
      serviceAccountName: gateway
      containers:
        - name: gateway
          image: $GW_IMAGE
          args: ["-admission-mode=off"]
          env:
            - {name: GATEWAY_NAMESPACE, value: $NS_A}
            - {name: GATEWAY_API_KEY_SECRET, value: gateway-api-keys}
          ports: [{containerPort: 8080, name: http}]
EOF
  k rollout status deploy/gateway -n "$NS_A" --timeout=180s >/dev/null || fail "gateway never became ready for $arm"
}

# The load is REPORTED here, not derived here. It arrives whole from the caller and is refused if it does
# not, for the reasons written out beside that refusal.
#
# This line used to recompute DURATION_MS as 500/(RATE/2), which silently overwrote whatever was passed --
# so a caller that had derived a trace length on the card would have had it replaced by an arithmetic that
# assumes an even tenant split.
say "load: rate ${RATE}/s, ${DURATION_MS}ms per arm, weights premium=$PREMIUM_WEIGHT noisy=$NOISY_WEIGHT probe=$PROBE_WEIGHT"
say "run:  ${REPS} repetitions of [$ARMS] on $PLATFORM, output $OUT"

# Measured, like the M6 wrapper's: after the first cell, the elapsed time IS the budget, and it knows the
# node's real speed and how long the rollouts actually took rather than how long they were allowed to take.
cells_total=0; for _a in $ARMS; do cells_total=$(( cells_total + REPS )); done
cell_secs=0; cells_done=0; cell_n=0
cell_deadline_check() {
  local remain per projected
  [ "$cells_done" -eq 0 ] && return 0
  remain=$(deadline_remaining_minutes 2>/dev/null) || return 0
  [ -n "$remain" ] || return 0
  per=$(( (cell_secs + cells_done - 1) / cells_done ))
  # A fifth of headroom, because cells differ by arm -- the sharing arms roll out two engines and the
  # exclusive arm rolls out one -- and a projection that only just fits is one slow cell from being cut.
  projected=$(( ((cells_total - cells_done) * per * 12 / 10 + 59) / 60 ))
  if [ "$projected" -ge "$remain" ]; then
    echo >&2
    echo "STOPPING: $(( cells_total - cells_done )) cells left at ~$(( per / 60 )) min each needs about ${projected} min," >&2
    echo "  and the deadline fires in ${remain} min. Being cut mid-cell would waste that cell's rollouts and" >&2
    echo "  leave a matrix missing one of the topologies it exists to compare, so it stops on a boundary." >&2
    echo "  ${cells_done} of ${cells_total} cells are complete. Re-arm with a longer TTL_MINUTES to continue." >&2
    return 1
  fi
  return 0
}

for rep in $(seq 1 "$REPS"); do
  for arm in $ARMS; do
    cell_n=$(( cell_n + 1 ))
    cell_deadline_check || exit 1
    CELL_T0=$(date +%s)
    say "rep $rep arm $arm  (cell $cell_n/$cells_total)"
    deploy_arm "$arm"
    # The tunnel every request of this cell goes through, replaced between cells and then PROVED.
    #
    # This was `kill $PF_PID` followed immediately by a new port-forward and `sleep 3`. kill does not wait,
    # so the new forward raced the old one's release of 18080, lost, and exited -- and because its output
    # went to /dev/null nothing said so. The replay then sent every request of that cell into a port nothing
    # was listening on and recorded them all with httpStatus 0, which the report describes as a censored
    # tail: a plumbing failure wearing a load failure's name.
    #
    # It alternated, which is the signature. Cell 1 bound cleanly, cell 2 lost the race and died, cell 3
    # found the port free because cell 2's forward was already gone, cell 4 lost it again. Two of four arms
    # produced nothing. hack/test/rehearse-m5c-matrix.sh saw R1 and timeSlicing complete every request while
    # shared and mps completed none; the paid runs never reached a second cell, so it had never been visible.
    if [ -n "$PF_PID" ]; then
      kill "$PF_PID" 2>/dev/null
      # WAIT for it. This is the line whose absence caused the race.
      wait "$PF_PID" 2>/dev/null
    fi
    # stderr is kept, because "why is the tunnel not up" is unanswerable without it.
    k port-forward -n "$NS_A" deploy/gateway 18080:8080 >"$OUT/port-forward-$arm-$rep.log" 2>&1 &
    PF_PID=$!
    # Proved rather than slept for. A fixed sleep is a guess about a machine's speed, and the failure it
    # misses is silent.
    pf_up=0
    for _ in $(seq 1 40); do
      if (exec 3<>/dev/tcp/127.0.0.1/18080) 2>/dev/null; then pf_up=1; exec 3<&- 2>/dev/null; break; fi
      kill -0 "$PF_PID" 2>/dev/null || break
      sleep 1
    done
    [ "$pf_up" = "1" ] || fail "the port-forward to the gateway never accepted a connection for $arm rep $rep. Every request of this cell would have been recorded with no HTTP status at all, and the report would have called the result a censored tail. See $OUT/port-forward-$arm-$rep.log"

    # The arm is the SHARING MODE, and it is now spelled that way in the manifest.
    #
    # It used to be spelled "off" -- the admission vocabulary's name for a disabled guard -- because that was
    # the only arm name the harness would accept here, and the run then had to ship a README telling readers
    # never to run `benchharness report` over its own evidence, since pooling would collapse three topologies
    # into one row. internal/bench now carries a study whose arms ARE the topologies, so the evidence says
    # what it is and the pre-registered readings can be evaluated by the code that was written for them.
    # --model is not optional, and its absence would have been silent until the first request.
    #
    # gen-trace defaults to "llama-3-8b" and writes it into the manifest; replay sends it as the requested
    # model; internal/gateway resolves a backend by matching that name against the InferenceDeployment index
    # in the tenant's target namespace. The routing records this script writes serve Qwen2.5-3B, so every
    # request of every arm would have come back ErrNoRoute -- after both engines had loaded.
    "$WORK/benchharness" gen-trace --seed 11 --duration-ms "$DURATION_MS" --rate "$RATE" \
      --study sharing-matrix-2026-09-10 --arm "$arm" --model "$MODEL" --gateway-url "http://127.0.0.1:18080" \
      --premium-weight "$PREMIUM_WEIGHT" --noisy-weight "$NOISY_WEIGHT" --probe-weight "$PROBE_WEIGHT" \
      --trace-out "$OUT/trace-$arm-$rep.jsonl" --manifest-out "$OUT/manifest-$arm-$rep.yaml" || fail "gen-trace $arm"
    "$WORK/benchharness" replay --manifest "$OUT/manifest-$arm-$rep.yaml" \
      --target "http://127.0.0.1:18080" \
      --api-keys "premium-1=premium-key,standard-noisy=standard-key" \
      --raw-out "$OUT/raw-$arm-$rep.jsonl" || fail "replay $arm"
    [ -s "$OUT/raw-$arm-$rep.jsonl" ] || fail "no raw evidence for $arm rep $rep"
    say "  $(wc -l < "$OUT/raw-$arm-$rep.jsonl") rows"
    cell_secs=$(( cell_secs + $(date +%s) - CELL_T0 ))
    cells_done=$(( cells_done + 1 ))
  done
done

# The raw files are NOT report inputs, and saying so here is cheaper than the confusion. Both arms replay
# with --arm off, because the harness's arm vocabulary is the ADMISSION arms and the sharing mode is this
# run's variable; feeding both files to `benchharness report` would pool them into one arm and produce a
# number for a comparison that was never made.
cat > "$OUT/README.txt" <<EOF
Raw evidence from the M5-c sharing matrix.

The variable is the SHARING MODE, and every row now carries it as its arm: R1, shared, timeSlicing or mps,
under study sharing-matrix-2026-09-10. Admission was off in every arm, which is a constant of this run
rather than its variable, so it is not what the arm field names.

  for f in $OUT/raw-*.jsonl; do args="\$args --raw \$f"; done; benchharness report \$args

The study is read from the evidence rows themselves, not passed as a flag, so the arm names above are what
select the readings. That evaluates the pre-registered readings from
docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md, in the registered order, and
prints the first that fires. Do not evaluate them by hand: a run whose readings are read off a table by a
person is not the instrument the pre-registration describes.

This file used to say the opposite -- that these files must never be passed to \`benchharness report\` --
because every arm was replayed as "off" and pooling would have collapsed three topologies into one row.
EOF

say "MATRIX DONE. Raw evidence in $OUT (see its README.txt before analysing)."
say "The comparison is premium TTFT p99 across the sharing modes at equal offered load."
say "Per-engine GPU utilisation is deliberately absent: under time-slicing nothing can attribute it."
