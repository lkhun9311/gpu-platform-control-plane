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
rev="$PP_MODEL_REVISION"

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
if out=$(pp_process_args_refusal "$good"); then ok "the registered engine passes"; else bad "the registered engine was refused: $out"; fi
check_refused() {
  local name="$1" line="$2" cap="${3:-0}" out
  # A refusal must say why: a validator that crashed also exits non-zero, with nothing on stdout.
  if out=$(pp_process_args_refusal "$line" "$cap"); then bad "$name passed"
  elif [ -z "$out" ]; then bad "$name was refused without a reason, which is what a crash looks like"
  else ok "$name refuses: $out"; fi
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
# The revision and model are the registration's, whatever the caller passes (pilot review 11, finding 3).
check_refused "an unregistered revision" "$(printf '%s' "$good" | sed "s/$rev/$(printf 'd%.0s' $(seq 1 40))/g")"
check_refused "a different model" "$(printf '%s' "$good" | sed "s#Qwen/Qwen2.5-3B-Instruct#Qwen/Qwen2.5-7B-Instruct#g")"
check_refused "the model keys absent" "$(printf '%s' "$good" | sed "s#'model_tag': 'Qwen/Qwen2.5-3B-Instruct', 'model': 'Qwen/Qwen2.5-3B-Instruct', ##")"
stub_line=$(printf '%s' "$good" | sed "s#'model_tag': 'Qwen/Qwen2.5-3B-Instruct', 'model': 'Qwen/Qwen2.5-3B-Instruct'#'model_tag': 'stub', 'model': 'stub'#")
if ENGINE_PIN_WAIVED=1 pp_process_args_refusal "$stub_line" >/dev/null; then ok "a rehearsal with the pin waived excuses the stub's model name"; else bad "a waived rehearsal's stub was refused"; fi
check_refused "the stub's model name without the waiver" "$stub_line"

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

# The admission diagnostic's stage D: its arms, the engine's prefill cap only where the arm runs it, and the
# gateway's serial-prefill hold on hold and hold-cap (design page, "v25").
[ "$(pp_stage_arms D | tr '\n' ' ')" = "R1 off hold cap hold-cap " ] && ok "stage D's arms are R1, off, hold, cap and hold-cap" \
  || bad "stage D's arms: $(pp_stage_arms D | tr '\n' ' ')"
pp_gateway_args hold | grep -qx -- -admission-mode=serial-prefill && pp_gateway_args hold-cap | grep -qx -- "-admission-serial-prefill-max-hold=25s" \
  && pp_gateway_args cap | grep -qx -- -admission-mode=off \
  && ok "hold and hold-cap run serial-prefill with a 25 s hold; cap runs admission off" || bad "the diagnostic's gateway arguments"
if pp_render_manifest config/vllm/deployment.yaml "$work/cap.yaml" "$rev" 384 >/dev/null \
   && grep -qx -- "[[:space:]]*- --long-prefill-token-threshold=384" "$work/cap.yaml" \
   && pp_render_manifest config/vllm/deployment.yaml "$work/nocap.yaml" "$rev" 0 >/dev/null \
   && ! grep -q long-prefill "$work/nocap.yaml"; then
  ok "the engine carries the 384 prefill cap only when the arm runs it"
else
  bad "the rendered prefill cap"
fi
capline=$(printf '%s' "$good" | sed "s/}\$/, 'long_prefill_token_threshold': 384}/")
if out=$(pp_process_args_refusal "$capline" 384); then ok "a cap arm's engine with the cap passes"; else bad "a cap arm's engine was refused: $out"; fi
check_refused "a cap arm's engine without the cap" "$good" 384
check_refused "the cap on an arm that does not run it" "$capline"
# Stage D's cells are named by their stage like the pilot's; the first rehearsal of stage D stopped at its first cell
# because only A and B were accepted here.
[ "$(pp_request_id_flag D hold-cap 2)" = "--request-id-prefix=pp-D-hold-cap-2" ] && ok "stage D's request IDs name its stage, arm and block" \
  || bad "stage D's request-ID prefix"
[ "$(pp_arm_prefill_cap hold)" = 0 ] && [ "$(pp_arm_prefill_cap hold-cap)" = 384 ] && ok "only cap and hold-cap run the prefill cap" || bad "pp_arm_prefill_cap"

# The capture, against stubbed kubectl, curl and docker on PATH: the cluster calls answer at once, except the
# gateway record's node read, which sleeps past the bound.
# A complete step log showing a request at the wrong priority must still stop the pilot (exit 3), because that is
# an apparatus fault; the read running out of time is not allowed to demote it to ineligibility (review of ffe3047).
capture_with() {
  local prio_premium="$1" bin="$work/bin" rc
  mkdir -p "$bin"
  OUT="$work/out-$prio_premium"; mkdir -p "$OUT"
  printf '%s\n' '{"requestId":"pp-A-off-1-0","tenant":"premium-1"}' > "$OUT/raw-off-1.jsonl"
  printf '%s\n' \
    "{\"ev\":\"add\",\"id\":\"chatcmpl-pp-A-off-1-0\",\"priority\":$prio_premium,\"prompt\":68,\"seq\":1}" \
    '{"ev":"terminal","seq_written":1,"seq_produced":1,"buffered":0}' > "$work/step-$prio_premium.jsonl"
  cat > "$bin/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *port-forward*) exec sleep 30 ;;
  *"-- cat"*) cat "$work/step-$prio_premium.jsonl" ;;
  *" logs "*) echo "INFO engine log" ;;
  *jsonpath*) echo "x" ;;
esac
EOF
  printf '#!/usr/bin/env bash\n[[ "$*" == *http_code* ]] && printf 200\nexit 0\n' > "$bin/curl"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$bin/docker"
  chmod +x "$bin"/*
  ( PATH="$bin:$PATH" KCTX=x NS_A=ns MODEL=m PP_CAPTURE_BOUND_S=4
    say() { :; }
    pp_capture off 1 "$(date +%s)" >/dev/null ) && rc=0 || rc=$?
  echo "$rc"
}
rc=$(capture_with 1)
[ "$rc" = 3 ] && ok "a witnessed wrong priority stops the pilot even when a later read outruns the bound" \
  || bad "a witnessed wrong priority under an expired bound returned $rc, not 3"
rc=$(capture_with 0)
[ "$rc" = 1 ] && grep -q "did not finish within" "$work/out-0/ineligible-off-1.txt" 2>/dev/null \
  && ok "a correct priority under an expired bound is ineligible, for the bound" \
  || bad "a correct priority under an expired bound returned $rc: $(cat "$work/out-0/ineligible-off-1.txt" 2>/dev/null)"

# The sidecar, against stubbed kubectl and docker and a hook that records what it was handed: on its interval it
# uploads the live rows and a fresh gateway record and logs each upload, and a Spot notice triggers one at once.
sidecar_run() {
  local name="$1" interval="$2" notice="$3" wait_s="$4" bin="$work/sbin"
  mkdir -p "$bin"
  OUT="$work/side-$name"; mkdir -p "$OUT"
  printf '{"requestId":"x"}\n' > "$OUT/live-raw-off-1.jsonl"
  printf '#!/usr/bin/env bash\necho x\n' > "$bin/kubectl"
  printf '#!/usr/bin/env bash\necho "{\\"ev\\":\\"arrive\\"}"\n' > "$bin/docker"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$(basename "$1")" "$(cat "$2")" >> "%s/hook.log"\n' "$OUT" > "$bin/hook"
  chmod +x "$bin"/*
  [ "$notice" = 1 ] && : > "$OUT/notice"
  ( PATH="$bin:$PATH" KCTX=x NS_A=ns CELL_SIDECAR_HOOK="$bin/hook" PP_SIDECAR_INTERVAL_S="$interval" \
      PP_SPOT_NOTICE_FILE="$OUT/notice"
    pp_sidecar_start off 1; sleep "$wait_s"; pp_sidecar_stop; sleep 1 )
}
sidecar_run interval 1 0 3.5
n=$(grep -c $'\tinterval\t' "$work/side-interval/sidecar-uploads.tsv" 2>/dev/null)
[ "${n:-0}" -ge 2 ] && grep -q '^live-raw-off-1.jsonl|{"ev":"arrive"}$' "$work/side-interval/hook.log" \
  && ok "the sidecar uploads the live rows and a fresh gateway record on its interval, and logs each upload ($n)" \
  || bad "the sidecar's interval uploads: $(cat "$work/side-interval/sidecar-uploads.tsv" "$work/side-interval/hook.log" 2>&1)"
sidecar_run notice 100 1 2.5
[ "$(grep -c $'\tspot-notice\t' "$work/side-notice/sidecar-uploads.tsv" 2>/dev/null)" = 1 ] \
  && ! grep -q $'\tinterval\t' "$work/side-notice/sidecar-uploads.tsv" \
  && ok "a Spot notice triggers one upload at once, long before the interval" \
  || bad "the sidecar's notice upload: $(cat "$work/side-notice/sidecar-uploads.tsv" 2>&1)"
# Stopped while an upload is in flight, the sidecar still records it (review of a0602d0).
( OUT="$work/side-inflight"; WORK="$work"; mkdir -p "$OUT"; bin="$work/sbin"
  printf '#!/usr/bin/env bash\nsleep 2\n' > "$bin/slowhook"; chmod +x "$bin/slowhook"
  PATH="$bin:$PATH" KCTX=x NS_A=ns CELL_SIDECAR_HOOK="$bin/slowhook" PP_SIDECAR_INTERVAL_S=1
  pp_sidecar_start off 1; sleep 1.6; pp_sidecar_stop; sleep 3.5 )
[ "$(grep -c $'\tinterval\t' "$work/side-inflight/sidecar-uploads.tsv" 2>/dev/null)" = 1 ] \
  && ok "an upload in flight when the sidecar is stopped still leaves its row, and no further upload starts" \
  || bad "the in-flight upload: $(cat "$work/side-inflight/sidecar-uploads.tsv" 2>&1)"
( OUT="$work/side-none"; mkdir -p "$OUT"; unset CELL_SIDECAR_HOOK; pp_sidecar_start off 1; [ -z "$PP_SIDECAR_PID" ] ) \
  && ok "without a hook the sidecar starts nothing" || bad "the sidecar started without a hook"

# The engine sampler, against a stubbed kubectl and a curl that serves vLLM's gauges: one line per gauge per sample,
# and nothing else from the page.
( OUT="$work/sampler"; WORK="$work"; mkdir -p "$OUT"; bin="$work/smbin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$bin/kubectl"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "vllm:num_requests_running{engine=\\"0\\"} 5.0" "vllm:num_requests_waiting{engine=\\"0\\"} 2.0" "vllm:kv_cache_usage_perc{engine=\\"0\\"} 0.25" "vllm:num_preemptions_total{engine=\\"0\\"} 0.0" "vllm:other 9"\n' > "$bin/curl"
  chmod +x "$bin"/*
  PATH="$bin:$PATH" KCTX=x NS_A=ns PP_SAMPLE_INTERVAL_S=0.5
  pp_sampler_start off 1; sleep 1.8; pp_sampler_stop; sleep 1 )
f="$work/sampler/engine-samples-off-1.tsv"
n_run=$(awk -F'\t' '$2 == "vllm:num_requests_running" && $3 == "5.0"' "$f" 2>/dev/null | wc -l)
[ "$n_run" -ge 2 ] && ! grep -q "vllm:other" "$f" && awk -F'\t' 'NR > 1 && NF != 3 {bad=1} END {exit bad}' "$f" \
  && ok "the engine sampler writes each gauge per sample ($n_run samples) and nothing else" \
  || bad "the engine samples: $(cat "$f" 2>&1 | head -6)"
# Milliseconds, thirteen digits: this machine's date prints nine digits for %3N, which once made every sleep zero.
awk -F'\t' 'NR > 1 && length($1) != 13 {bad=1} END {exit bad}' "$f" && [ "$n_run" -le 5 ] \
  && ok "the samples are stamped in milliseconds and kept to their interval ($n_run in 1.8 s at 0.5 s)" \
  || bad "the sample stamps or cadence: $n_run samples, first stamps $(awk -F'\t' 'NR > 1 {print $1}' "$f" | head -2 | tr '\n' ' ')"
# A read that fails leaves a row saying so, so a gap in the series is visible.
( OUT="$work/sampler-fail"; WORK="$work"; mkdir -p "$OUT"; bin="$work/smbin2"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$bin/kubectl"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$bin/curl"
  chmod +x "$bin"/*
  PATH="$bin:$PATH" KCTX=x NS_A=ns PP_SAMPLE_INTERVAL_S=0.5
  pp_sampler_start off 1; sleep 1.2; pp_sampler_stop; sleep 1 )
grep -q $'\tscrape-failed\t' "$work/sampler-fail/engine-samples-off-1.tsv" \
  && ok "a failed engine read leaves a scrape-failed row" || bad "no scrape-failed row: $(cat "$work/sampler-fail/engine-samples-off-1.tsv")"

echo
[ "$fails" = 0 ] && { echo "PASS"; exit 0; }
echo "$fails check(s) failed"; exit 1
