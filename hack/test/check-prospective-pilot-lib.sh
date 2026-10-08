#!/usr/bin/env bash
#
# Checks hack/lib/prospective-pilot.sh's renderer, engine validator and gateway arguments, without a cluster.
#
#   bash hack/test/check-prospective-pilot-lib.sh
#
# The validator's lines are shaped like real vLLM v0.27.1 output: the keys and quoting are those of the
# non-default args lines archived under docs/superpowers/specs/data/, so a validator that refused a correct engine
# would fail here rather than on a rented card.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=hack/lib/prospective-pilot.sh
source hack/lib/prospective-pilot.sh

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$(( fails + 1 )); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rev=$(printf 'b%.0s' $(seq 1 40))

# The renderer: four changes to the real base manifest, and refusal on a base without its anchors.
if out=$(pp_render_manifest config/vllm/deployment.yaml "$work/engine.yaml" "$rev"); then
  ok "the real manifest renders"
  python3 - "$work/engine.yaml" "$rev" <<'PY' && ok "the rendered manifest carries the pilot's arguments, mounts and host-path cache" || bad "the rendered manifest is not the pilot's"
import sys, yaml
d = list(yaml.safe_load_all(open(sys.argv[1])))[0]
pod = d["spec"]["template"]["spec"]
c = pod["containers"][0]
want = ["--max-num-batched-tokens=512", "--scheduling-policy=priority", "--no-async-scheduling",
        "--enable-logging-iteration-details", "--scheduler-cls=pilot_step_logger.PilotStepLoggingScheduler",
        "--revision=" + sys.argv[2], "--tokenizer-revision=" + sys.argv[2]]
assert all(a in c["args"] for a in want), c["args"]
assert "--max-num-batched-tokens=2048" not in c["args"]
assert {e["name"] for e in c["env"]} == {"PYTHONPATH", "STEP_LOG_PATH"}
vols = {v["name"]: v for v in pod["volumes"]}
assert vols["hf-cache"]["hostPath"]["path"] == "/var/lib/pilot-hf-cache"
assert vols["step-plugin"]["configMap"]["name"] == "pilot-step-plugin"
PY
else
  bad "the real manifest did not render: $out"
fi
sed 's/--max-num-batched-tokens=2048/--max-num-batched-tokens=1024/' config/vllm/deployment.yaml > "$work/nobudget.yaml"
if out=$(pp_render_manifest "$work/nobudget.yaml" "$work/x.yaml" "$rev"); then
  bad "a base without the 2048 budget line rendered"
else
  ok "a base without the budget line refuses: $out"
fi
if out=$(pp_render_manifest config/vllm/deployment.yaml "$work/x.yaml" main); then
  bad "a branch name was accepted as the revision pin"
else
  ok "a non-SHA revision refuses"
fi

# The validator, on a line shaped like the real one, and on astra's specimen from the design's round 4.
good="non-default args: {'model_tag': 'Qwen/Qwen2.5-3B-Instruct', 'model': 'Qwen/Qwen2.5-3B-Instruct', 'dtype': 'half', 'max_model_len': 16384, 'gpu_memory_utilization': 0.9, 'enable_prefix_caching': False, 'enable_logging_iteration_details': True, 'max_num_batched_tokens': 512, 'max_num_seqs': 64, 'scheduling_policy': 'priority', 'scheduler_cls': 'pilot_step_logger.PilotStepLoggingScheduler', 'async_scheduling': False, 'revision': '$rev', 'tokenizer_revision': '$rev'}"
if out=$(pp_process_args_refusal "$good" "$rev"); then ok "the registered engine passes"; else bad "the registered engine was refused: $out"; fi
check_refused() {
  local name="$1" line="$2" out
  if out=$(pp_process_args_refusal "$line" "$rev"); then bad "$name passed"; else ok "$name refuses: $out"; fi
}
check_refused "prefix caching on, bfloat16, one sequence, context 8192, memory 0.5" "$(printf '%s' "$good" | sed \
  -e "s/'enable_prefix_caching': False/'enable_prefix_caching': True/" -e "s/'dtype': 'half'/'dtype': 'bfloat16'/" \
  -e "s/'max_num_seqs': 64/'max_num_seqs': 1/" -e "s/'max_model_len': 16384/'max_model_len': 8192/" \
  -e "s/'gpu_memory_utilization': 0.9/'gpu_memory_utilization': 0.5/")"
check_refused "fcfs scheduling" "$(printf '%s' "$good" | sed "s/'scheduling_policy': 'priority'/'scheduling_policy': 'fcfs'/")"
check_refused "the base manifest's budget" "$(printf '%s' "$good" | sed "s/'max_num_batched_tokens': 512/'max_num_batched_tokens': 2048/")"
check_refused "iteration logging left off" "$(printf '%s' "$good" | sed "s/, 'enable_logging_iteration_details': True//")"
check_refused "the frozen instrument instead of the pilot's" "$(printf '%s' "$good" | sed "s/pilot_step_logger.PilotStepLoggingScheduler/step_logging_scheduler.StepLoggingScheduler/")"
check_refused "an unregistered non-default key" "$(printf '%s' "$good" | sed "s/}\$/, 'max_loras': 4}/")"
check_refused "no args line at all" "INFO started"

# The gateway: every arm binds, enforces and records; only admission differs; the static arm needs its rate.
for arm in R1 off static-cap prospective; do
  args=$(pp_gateway_args "$arm" 4321) || { bad "no gateway arguments for $arm"; continue; }
  for want in -bind-priority -enforce-benchmark-profile "-request-record-path=$PP_GATEWAY_RECORD"; do
    printf '%s\n' "$args" | grep -qx -- "$want" || bad "$arm's gateway lacks $want"
  done
done
[ "$(pp_gateway_args off | grep -c admission-mode=off)" = 1 ] && ok "off runs admission off" || bad "off's admission is not off"
pp_gateway_args prospective | grep -qx -- -admission-prospective-prefill-tokens=30000 && ok "prospective carries its frozen caps" || bad "prospective lacks its caps"
if pp_gateway_args static-cap "" >/dev/null 2>&1; then bad "the static arm ran without a rate"; else ok "the static arm refuses without a rate"; fi
[ "$(pp_request_id_flag B prospective 2)" = "--request-id-prefix=pp-B-prospective-2" ] && ok "request IDs name stage, arm and block" || bad "the request-ID prefix is not pp-<stage>-<arm>-<block>"
if pp_stage_arms A | grep -qx static-cap; then bad "stage A buys a static arm before its rate exists"; else ok "stage A has no static arm"; fi

echo
[ "$fails" = 0 ] && { echo "PASS"; exit 0; }
echo "$fails check(s) failed"; exit 1
