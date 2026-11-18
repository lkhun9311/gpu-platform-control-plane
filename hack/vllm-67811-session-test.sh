#!/usr/bin/env bash
#
# Offline checks for hack/vllm-67811-session.sh and the runner it ships, run before anything is bought.
# The EC2 lifecycle is hack/vllm-58420-session.sh's, which hack/vllm-58420-session-test.sh covers; these checks cover
# what is new here: the runner's bounds against the session's stop, the probe, and the runner's whole path, driven
# against fake docker, curl and nvidia-smi so a defect in a later step shows here rather than on a paid card.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/hack/vllm-67811-session.sh"
R="$ROOT/hack/vllm-67811/runner.sh"
P="$ROOT/hack/vllm-67811/probe/sitecustomize.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

check "the session, the runner and the probe parse" "bash -n '$S' && bash -n '$R' && python3 -m py_compile '$P'"

# The stop is summed from the runner's bounds, so each must be the same number in both files.
same=1
for pair in PULL_BOUND_S:PULL_S BASE_ID_S:BASE_ID_S MODEL_BOUND_S:MODEL_S READY_S:READY_S ID_S:ID_S METRICS_S:METRICS_S \
  WARMUP_S:WARMUP_S RUN_S:RUN_S RUNS:RUNS STOP_S:STOP_S; do
  a=$(grep -m1 "^${pair%%:*}=" "$S" | cut -d= -f2); b=$(grep -m1 "^${pair#*:}=" "$R" | cut -d= -f2)
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "  ${pair%%:*}=$a in the session, ${pair#*:}=$b in the runner" >&2; same=0; }
done
check "every step bound in the session is the runner's own" "[ $same = 1 ]"
slots=$(grep -m1 '^SLOTS=' "$R" | tr -cd ':' | wc -c)
check "the session's engine count is the runner's slot count ($slots)" "[ \"$(grep -m1 '^ENGINES=' "$S" | cut -d= -f2)\" = $slots ]"
sched=$(bash "$S" --print-schedule 2>&1)
check "the schedule is the bounds' sum ($sched)" "[ '$sched' = 'harness_end_s=12960 evidence_s=13080 stop_s=13140 termination_s=13440' ]"
check "the runner pins seven overlays" "[ \"\$(sed -n '/^OVERLAYS=\"/,/\"\$/p' '$R' | grep -c ' [0-9a-f]\\{64\\} ')\" = 7 ]"
cp "$S" "$WORK/costly.sh"; sed -i 's/^ALL_IN_RATE=.*/ALL_IN_RATE=0.90/' "$WORK/costly.sh"
check "a rate that puts the worst case over \$3 is refused" "! bash '$WORK/costly.sh' --print-schedule >/dev/null 2>&1"

# The probe must wrap the controller once its module is imported, and record what complete() is given.
mkdir -p "$WORK/pkg/vllm/v1/core/sched" "$WORK/probe-out"
for d in vllm vllm/v1 vllm/v1/core vllm/v1/core/sched; do : > "$WORK/pkg/$d/__init__.py"; done
cat > "$WORK/pkg/vllm/v1/core/sched/adaptive_prefill.py" <<'EOF'
class AdaptivePrefillController:
    def __init__(self):
        self.token_ms, self.decode_ms, self.scale = 0.02, 1.0, 1.0
    def complete(self, step_id, device_ms):
        if device_ms:
            self.token_ms = device_ms / 1000
        return step_id
EOF
AP_PROBE_DIR="$WORK/probe-out" AP_SLOT=t PYTHONPATH="$ROOT/hack/vllm-67811/probe:$WORK/pkg" python3 -c '
from vllm.v1.core.sched.adaptive_prefill import AdaptivePrefillController as C
c = C()
assert c.complete(7, 12.5) == 7
c.complete(8, None)'
check "the probe records each complete() call with what it was fed" \
  "[ \"\$(cat '$WORK'/probe-out/probe-t-*.jsonl | wc -l)\" = 2 ] && grep -q '\"device_ms\": 12.5' '$WORK'/probe-out/probe-t-*.jsonl"

# The runner's whole path, against fakes that answer as the image and the engine would.
mkfakes() {
  local bin="$WORK/bin" st="$WORK/state"
  rm -rf "$bin" "$st"; mkdir -p "$bin" "$st"
  cat > "$bin/docker" <<'EOF'
#!/bin/bash
st="$FAKE_STATE"; echo "docker $*" >> "$st/calls"
site=/usr/local/lib/python3.12/dist-packages
case "$1" in
  pull) exit 0 ;;
  run)
    if [ "$2" = -d ]; then
      name=$4; printf '%s\n' "$@" > "$st/$name.args"; echo id-$name; exit 0
    fi
    if printf '%s\n' "$@" | grep -qx sha256sum; then
      for p in "$@"; do case $p in "$site"/*)
        rel=${p#"$site"/}; h=$(grep "^$rel " "$FAKE_OVERLAYS" | awk '{print $3}')
        [ "$rel" = "${FAKE_BAD_BASE:-}" ] && h=0000
        echo "$h  $p" ;;
      esac; done
      exit 0
    fi
    printf '%s\n' "$@" | grep -qx test && exit 0
    printf '%s\n' "$@" | grep -q snapshot_download && { echo /root/.cache/huggingface/x; exit 0; }
    exit 1 ;;
  inspect)
    if [ "$2" = -f ]; then [ -f "$st/$4.args" ] && echo true || echo false; exit 0; fi
    [ -f "$st/$2.args" ] ;;
  exec)
    name=$2; shift 2
    if printf '%s\n' "$@" | grep -qx /bench/serve.py; then
      out=$(printf '%s\n' "$@" | grep -A1 -x -- --output | tail -1)
      echo '{"ok": true}' > "$FAKE_OUT/$(basename "$out")"; exit 0
    fi
    for m in "$@"; do case $m in vllm.*)
      rel="$(echo "$m" | tr . /).py"
      h=$(grep "^$rel " "$FAKE_OVERLAYS" | awk '{print $2}')
      [ "$rel" = "${FAKE_WRONG_HEAD:-}" ] && h=1111
      echo "$h $site/$rel" | sed 's/ /  /' ;;
    esac; done ;;
  logs)
    a="$st/$2.args"; [ -f "$a" ] || exit 0
    t=$(grep -A1 -x -- --long-prefill-token-threshold "$a" | tail -1)
    ad=""; grep -qx -- --adaptive-prefill "$a" && [ "${FAKE_DROP_FLAG:-}" != "$2" ] && ad=", 'adaptive_prefill': True"
    echo "INFO non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'enable_prefix_caching': False, 'long_prefill_token_threshold': $t$ad}" ;;
  rm) rm -f "$st/$3.args" ;;
esac
EOF
  printf '#!/bin/bash\ncase "$*" in *health*) exit 0 ;; *metrics*) echo "vllm:num_preemptions_total 0" ;; esac\n' > "$bin/curl"
  printf '#!/bin/bash\nexec sleep 300\n' > "$bin/nvidia-smi"
  chmod +x "$bin"/*
  sed -n '/^OVERLAYS="/,/"$/p' "$R" | sed 's/^OVERLAYS="//; s/"$//' > "$WORK/overlays"
}
runfake() {
  mkfakes; local out="$WORK/out-$1"; rm -rf "$out"; mkdir -p "$out"
  env FAKE_STATE="$WORK/state" FAKE_OUT="$out" FAKE_OVERLAYS="$WORK/overlays" PATH="$WORK/bin:$PATH" "${@:2}" \
    timeout 120 bash "$R" "$WORK/in" "$out" $(( $(date +%s) + 100000 )) > "$out/runner.out" 2>&1
  echo $? > "$out/rc"
}
mkdir -p "$WORK/in"
runfake good env
check "the runner completes all six engines, each with identity and five scored runs" \
  "grep -q 'all engines done' '$WORK/out-good/steps.log' && [ \"\$(awk -F'\t' 'NR>1 && \$3==\"yes\" && \$4==\"yes\" && \$5==\"yes\" && \$6==5' '$WORK/out-good/summary.tsv' | wc -l)\" = 6 ]"
check "the arms run in the order base, adaptive, t512, t512, adaptive, base" \
  "[ \"\$(awk -F'\t' 'NR>1{printf \"%s \", \$2}' '$WORK/out-good/summary.tsv')\" = 'base adaptive t512 t512 adaptive base ' ]"
check "only the adaptive engines get --adaptive-prefill, and only t512 gets threshold 512" \
  "grep -q -- '--adaptive-prefill' '$WORK/state/calls' && [ \"\$(grep -c 'run -d .*--adaptive-prefill' '$WORK/state/calls')\" = 2 ] && [ \"\$(grep -c 'run -d .*--long-prefill-token-threshold 512' '$WORK/state/calls')\" = 2 ]"
check "every engine runs with prefix caching off, the probe on its path, and the seven overlays mounted read-only" \
  "[ \"\$(grep -c 'run -d .*--no-enable-prefix-caching.*' '$WORK/state/calls')\" = 6 ] && [ \"\$(grep 'run -d' '$WORK/state/calls' | grep -c 'PYTHONPATH=/probe')\" = 6 ] && [ \"\$(grep -m1 'run -d' '$WORK/state/calls' | grep -o 'dist-packages/vllm/[^ ]*:ro' | wc -l)\" = 7 ]"
check "every scored run uses the shared seeds" "[ \"\$(grep -c 'serve.py.*--seed 6257[4-8]' '$WORK/state/calls')\" = 30 ]"

runfake badbase env FAKE_BAD_BASE=vllm/v1/outputs.py
check "an image whose package is not the merge base's is refused before any engine starts" \
  "grep -q 'BASE IDENTITY FAILED' '$WORK/out-badbase/steps.log' && ! grep -q 'run -d' '$WORK/state/calls'"
runfake wronghead env FAKE_WRONG_HEAD=vllm/v1/core/sched/scheduler.py
check "an engine importing a file that is not the PR head's is not measured" \
  "[ \"\$(awk -F'\t' 'NR>1 && \$4==\"no\"' '$WORK/out-wronghead/summary.tsv' | wc -l)\" = 6 ] && ! grep -q 'serve.py' '$WORK/state/calls'"
runfake dropflag env FAKE_DROP_FLAG=ap-2-adaptive
check "an adaptive engine whose args do not show the flag is not measured" \
  "awk -F'\t' 'NR>1 && \$1==2 && \$4==\"no\"' '$WORK/out-dropflag/summary.tsv' | grep -q . && awk -F'\t' 'NR>1 && \$1==5 && \$4==\"yes\"' '$WORK/out-dropflag/summary.tsv' | grep -q ."

if [[ $failures -ne 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
