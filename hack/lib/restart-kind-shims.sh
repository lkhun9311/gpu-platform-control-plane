# shellcheck shell=bash
# The substitutions that let hack/lib/restart-session.sh run unmodified on kind, for hack/restart-lifecycle-kind.sh.
#
# Source it after hack/lib/train-session.sh, hack/lib/gpu-ttl.sh, hack/lib/gpu-fault.sh and hack/lib/restart-session.sh.
# Each substitution sits at the AWS or GPU boundary and nowhere else, and each is the real function with the smallest
# textual change, asserted to have applied, because a substitution that silently did not apply would rehearse the
# original against the wrong answer and read as a pass.
# hack/test/restart-kind/bin/aws answers the runner's AWS calls; this file gives the kind side of the same state.
#
# WHAT THE CALLER PROVIDES: RSTK_STATE (the state directory the aws stub shares), RESTART_CONTEXT, and the four
# libraries sourced.

# rstk_substitute FUNCTION FROM TO: FUNCTION redefined as its own body with FROM replaced by TO, which must occur exactly
# once in it and not at all afterwards.
rstk_substitute() {
  local fn="$1" from="$2" to="$3" src n
  src="$(declare -f "$fn")" || {
    echo "rstk_substitute: $fn is not defined; source the real libraries first" >&2
    return 1
  }
  n="$(grep -cF -- "$from" <<<"$src")"
  [[ "$n" == 1 ]] || {
    echo "rstk_substitute: '$from' occurs on $n line(s) of $fn, not once" >&2
    return 1
  }
  eval "${src/"$from"/"$to"}"
  src="$(declare -f "$fn")"
  if grep -qF -- "$from" <<<"$src" || ! grep -qF -- "$to" <<<"$src"; then
    echo "rstk_substitute: $fn still reads '$from' or lacks '$to' after the substitution" >&2
    return 1
  fi
}

# rstk_install: every substitution, each checked; non-zero and a reason if any did not apply.
rstk_install() {
  # The CPU build of the same torch 2.5.1 (experiments/distributed-restart/Dockerfile), already on every node: the
  # pinned CUDA image is 3.3 GB per node and there is no card for its CUDA to use.
  RESTART_IMAGE=distributed-restart:torch251
  declare -f rstk_real_render_job >/dev/null || {
    echo "rstk_install: the real restart_render_job was not captured; source hack/lib/restart-session.sh before this file" >&2
    return 1
  }
  # The simulator is the device plugin and the DCGM exporter here, so qualification reads its Pods where it would read
  # NVIDIA's device plugin; its refusal of a simulator then finds no Pod labelled gpu-simulator, which is this
  # substitution and not a pass of that refusal.
  rstk_substitute train_qualify_nodes 'app.kubernetes.io/component=nvidia-device-plugin' 'app.kubernetes.io/component=dcgm-exporter' || return 1
  # score_eks.py's own checks, with only the backend and the transport checks moved to gloo (score_kind_shim.py).
  rstk_substitute restart_verdict 'experiments/distributed-restart/score_eks.py' 'hack/test/restart-kind/score_kind_shim.py' || return 1
}

# The real rendering is kept under another name before the wrapper below replaces it, once, so sourcing this file twice
# cannot wrap the wrapper.
if ! declare -f rstk_real_render_job >/dev/null && declare -f restart_render_job >/dev/null; then
  eval "rstk_real_render_job() $(declare -f restart_render_job | tail -n +2)"
fi

# restart_render_job, as the runner calls it: the real rendering with CKPT_BACKEND=nccl replaced by gloo, exactly once,
# because the trainer's gloo mode trains the same model on the CPU and NCCL needs CUDA, which kind does not have.
restart_render_job() {
  local out
  out="$(rstk_real_render_job "$@")" || return 1
  python3 -c '
import json, sys
job = json.loads(sys.stdin.read())
body = job["spec"]["command"][2]
if body.count("CKPT_BACKEND=nccl") != 1:
    sys.exit("the rendered command names CKPT_BACKEND=nccl %d times, not once" % body.count("CKPT_BACKEND=nccl"))
job["spec"]["command"][2] = body.replace("CKPT_BACKEND=nccl", "CKPT_BACKEND=gloo")
print(json.dumps(job, indent=2))' <<<"$out"
}

rstk_k() { kubectl --context "$RESTART_CONTEXT" --request-timeout=20s "$@"; }

# rstk_alive: "instance container" of every launched instance not killed and not taken back, one per line.
rstk_alive() {
  local id c
  [[ -s "$RSTK_STATE/instances" ]] || return 0
  while read -r id c; do
    [[ -e "$RSTK_STATE/killed/$id" || -e "$RSTK_STATE/unlaunched/$id" ]] || echo "$id $c"
  done <"$RSTK_STATE/instances"
}

# rstk_unlaunch CONTAINER: the node leaves the group: its kubelet stopped, its pod sandboxes removed and its Node deleted,
# so the container is a machine not yet launched; the instance it held is marked taken back.
rstk_unlaunch() {
  local c="$1" id
  docker exec "$c" systemctl stop kubelet || return 1
  docker exec "$c" sh -c 'crictl rmp -fa' >>"$RSTK_STATE/asg.log" 2>&1 || return 1
  rstk_k delete node "$c" --ignore-not-found --wait=true >>"$RSTK_STATE/asg.log" 2>&1 || return 1
  while read -r id; do
    [[ -n "$id" ]] && date +%s >"$RSTK_STATE/unlaunched/$id"
  done <<<"$(awk -v c="$c" '$2 == c {print $1}' "$RSTK_STATE/instances" 2>>"$RSTK_STATE/asg.log")"
  return 0
}

# rstk_launch CONTAINER: a new instance on CONTAINER, joined as a new Node: a fresh instance ID as its providerID, the GPU
# group's labels and taint as EKS registers them, and so a Node UID no earlier node had.
rstk_launch() {
  local c="$1" n id flags
  n=$(($(wc -l <"$RSTK_STATE/instances") + 1))
  id="$(printf 'i-0c%015x' "$n")"
  rstk_unlaunch "$c" || return 1
  # The pristine flags are kept at the first launch, so each launch writes its own and never edits an earlier one's.
  docker exec "$c" sh -c '[ -e /var/lib/kubelet/kubeadm-flags.env.kind ] || cp /var/lib/kubelet/kubeadm-flags.env /var/lib/kubelet/kubeadm-flags.env.kind' || return 1
  flags="--provider-id=aws:///ap-northeast-2a/$id --node-labels=eks.amazonaws.com/nodegroup=gpu,platform.lkhun9311.github.io/gpu=true,platform.lkhun9311.github.io/train=true --register-with-taints=nvidia.com/gpu=present:NoSchedule"
  docker exec "$c" sh -c "sed -e 's|--provider-id=[^ \"]*||; s|--node-labels=[^ \"]*||; s|\"\$| $flags\"|' /var/lib/kubelet/kubeadm-flags.env.kind >/var/lib/kubelet/kubeadm-flags.env" || return 1
  docker exec "$c" grep -qF -- "--provider-id=aws:///ap-northeast-2a/$id " /var/lib/kubelet/kubeadm-flags.env || {
    echo "the kubelet flags of $c do not carry $id" >&2
    return 1
  }
  echo "$id $c" >>"$RSTK_STATE/instances"
  docker exec "$c" systemctl start kubelet || return 1
  printf '%s launched %s on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$c" >>"$RSTK_STATE/asg.log"
}

# rstk_asg_loop: the group's autoscaler and EKS's removal of terminated nodes, until killed.
#
# A killed instance's Node is deleted RSTK_NODE_GONE_S after the kill, as the cloud node lifecycle controller removes a
# terminated instance's Node; a deficit below the desired size launches a pool container after the next delay of
# $RSTK_STATE/launch_delays (one per line, consumed), else RSTK_LAUNCH_DELAY_S; an excess takes back an idle node.
rstk_asg_loop() {
  local desired alive n since="" delay="" id c killed_at pool busy
  while :; do
    for killed_at in "$RSTK_STATE"/killed/*; do
      [[ -e "$killed_at" ]] || continue
      id="${killed_at##*/}"
      [[ -e "$RSTK_STATE/gone/$id" ]] && continue
      (($(date +%s) - $(cat "$killed_at") >= ${RSTK_NODE_GONE_S:-20})) || continue
      c="$(awk -v i="$id" '$1 == i {print $2}' "$RSTK_STATE/instances")"
      if rstk_k delete node "$c" --ignore-not-found --wait=false >>"$RSTK_STATE/asg.log" 2>&1; then
        date +%s >"$RSTK_STATE/gone/$id"
        printf '%s deleted the Node of terminated %s (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$c" >>"$RSTK_STATE/asg.log"
      fi
    done
    desired="$(cat "$RSTK_STATE/desired")"
    alive="$(rstk_alive)"
    n="$(grep -c . <<<"$alive")"
    if ((n < desired)); then
      if [[ -z "$since" ]]; then
        since="$(date +%s)"
        delay="$(head -1 "$RSTK_STATE/launch_delays" 2>>"$RSTK_STATE/asg.log")"
        [[ -n "$delay" ]] && sed -i 1d "$RSTK_STATE/launch_delays"
        delay="${delay:-${RSTK_LAUNCH_DELAY_S:-60}}"
        printf '%s %s of %s alive: launching one in %s s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" "$desired" "$delay" >>"$RSTK_STATE/asg.log"
      fi
      if (($(date +%s) - since >= delay)); then
        pool="$(rstk_pool | head -1)"
        if [[ -z "$pool" ]]; then
          printf '%s no pool container is left to launch\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$RSTK_STATE/asg.log"
        elif rstk_launch "$pool" >>"$RSTK_STATE/asg.log" 2>&1; then
          since=""
        fi
      fi
    elif ((n > desired)); then
      since=""
      # The newest idle node goes, one with no Pod of the training namespace on it.
      while read -r id c; do
        busy="$(rstk_k get pods -A --field-selector "spec.nodeName=$c" -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>&1)" || continue
        grep -qx "$RESTART_NS" <<<"$busy" && continue
        printf '%s %s of %s alive: taking back %s (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" "$desired" "$id" "$c" >>"$RSTK_STATE/asg.log"
        rstk_unlaunch "$c" >>"$RSTK_STATE/asg.log" 2>&1
        break
      done <<<"$(tac <<<"$alive")"
    else
      since=""
    fi
    sleep 2
  done
}

# rstk_pool: the GPU containers that are running and hold no launched instance, in name order.
rstk_pool() {
  local c alive
  alive="$(rstk_alive | awk '{print $2}')"
  for c in $RSTK_GPU_CONTAINERS; do
    grep -qx "$c" <<<"$alive" && continue
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>>"$RSTK_STATE/asg.log")" == true ]] || continue
    echo "$c"
  done
}
