#!/bin/bash
# The llm-d-router #1598 pilot: four vLLM engines behind one EPP and Envoy on one g5.12xlarge, as the design's "Pilot" section lays out.
# hack/gpu-kit-session.sh runs this unmodified with OUT set, as root; pilot.py runs the cells and verdict.py judges them.
#
# A1's EPP is llm-d-router 733d0e4e; A2's is that commit with llm-d-router#4313's head d44cd676 merged, and the merged tree must
# hash to the value pinned below, so a moved PR or a different merge stops the run before any cell.
# Every step's exit code goes to $OUT/status.txt.
# The exit status is the verdict's: 0 the apparatus holds, 3 incomplete, 4 the apparatus failed, 1 a stop before the verdict.
#
# Settings (KIT_ENV through the session): STAGE (required: pilot, the first pilot's plan of 2026-11-21, pilot2, the
# knee-bracketing second pilot, or pilot3, the K-only third pilot), BUDGET_S (default 3150, at most 3250).
# Offline test only: KIT_OFFLINE_TEST=1 with KIT_TEST_BIN (a directory holding epp-a1, epp-a2 and envoy) skips the GPU and every
# download and runs the same pilot.py and verdict.py against fake engines.
set -uo pipefail
# The pins below are constants; a caller who sets one by name is refused rather than silently overridden.
for v in ROUTER_URL ROUTER_SHA PR_URL PR_SHA MERGED_TREE GO_TGZ GO_SHA256 ENVOY_URL ENVOY_SHA256 VLLM_WHEEL VLLM_WHEEL_URL \
  VLLM_SHA256 MODEL MODEL_REV ROOT; do
  [ -z "${!v+x}" ] || { echo "$v is set in the environment; the kit's pins are fixed" >&2; exit 1; }
done
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
ROUTER_URL=https://github.com/llm-d/llm-d-router
ROUTER_SHA=733d0e4ee18082d2e252fc887db7701c037b8034
PR_URL=https://github.com/DolevAdas/llm-d-router
PR_SHA=d44cd67633de14940df4868422559db75c4a2985
# git merge --no-ff of PR_SHA into ROUTER_SHA, done on 2026-11-21 with no conflict; the merged tree is the A2 source.
MERGED_TREE=f48fadc56abe657c6c30003fe9d14f64ff708f57
GO_TGZ=go1.27.4.linux-amd64.tar.gz
GO_SHA256=7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840
ENVOY_URL=https://github.com/envoyproxy/envoy/releases/download/v1.40.2/envoy-1.40.2-linux-x86_64
ENVOY_SHA256=1d64506e25c1844f146162ddb2ece7010fa4e784faddb40a079021491f1f03cc
VLLM_WHEEL=vllm-0.34.0-cp38-abi3-manylinux_2_28_x86_64.whl
VLLM_WHEEL_URL=https://files.pythonhosted.org/packages/0b/2c/55f3b76ceadbfc6d515f16b1c17e2e69136c8e54d47be2a94b9f7326f9bb/$VLLM_WHEEL
VLLM_SHA256=79ca4b3cd74aec08c4bf476bdf0cb15735b605ae5368526a2faae1e30f044ca2
MODEL=Qwen/Qwen2.5-3B-Instruct
MODEL_REV=aa8e72537993ba99e69dfaafa59ed015b17504d1
BUDGET_S=${BUDGET_S:-3150}
STAGE=${STAGE:-}
ROOT=/opt/llmd1598
START=$(date +%s)
mkdir -p "$OUT" || exit 1
# A rerun into the same OUT would leave an earlier run's cells for verdict.py to read, so only an empty OUT is used.
if [ -n "$(ls -A "$OUT")" ]; then echo "OUT=$OUT is not empty; each run writes a new directory" >&2; exit 1; fi
: > "$OUT/status.txt"

step() { # name, then the command; records the exit code and returns it
  local name=$1; shift
  "$@"; local rc=$?
  echo "$name exit=$rc t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
  return $rc
}
VERDICT_RC=1
finish() {
  if [ -f "$OUT/pilot.json" ]; then
    "$PY" -I "$HERE/verdict.py" "$OUT" > "$OUT/verdict-stdout.txt" 2>&1
    VERDICT_RC=$?
    echo "verdict exit=$VERDICT_RC t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
    cat "$OUT/verdict-stdout.txt"
  fi
  ( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS )
}
stop() { # the reason; the run ends here and says why
  echo "$*" | tee "$OUT/STOPPED" >&2
  echo "STOPPED $*" >> "$OUT/status.txt"
  finish
  exit 1
}
PY=python3

# ---------------------------------------------------------------- settings, refused before anything is downloaded
[[ $BUDGET_S =~ ^[0-9]+$ ]] && [ "$BUDGET_S" -le 3250 ] || stop "BUDGET_S=$BUDGET_S: whole seconds, at most 3250, inside the session's 3,300 s"
# No default stage: a launch that forgot it would otherwise buy a session that repeats the first pilot.
case "$STAGE" in
  pilot) PLAN_TEXT="calibration, isolated TTFT, A3 ramps A B W942, logging v2/v5 on A and K, A2 and A3 on A, B pressure (pilot.py run())" ;;
  pilot2) PLAN_TEXT="A1 and A3 ramps on A and B and A1 on W942 at -v=2 from 64/s, K, K-equal and K-stagger under A1 primed (pilot.py run_pilot2())" ;;
  pilot3) PLAN_TEXT="K only at -v=2: primed K under A1, A2 and A3, K-equal and K-stagger under A1, upstream-body visibility bound (pilot.py run_pilot3())" ;;
  *) stop "STAGE='$STAGE': set STAGE=pilot, STAGE=pilot2 or STAGE=pilot3" ;;
esac
# The arms, the model, the engine flags and the plan are the design's, so a setting that would move one is refused rather than ignored.
for v in KIT_ROUTER_SHA KIT_PR_SHA KIT_MODEL KIT_VLLM KIT_ARMS KIT_PLAN KIT_RATES KIT_SEEDS KIT_PEAK; do
  [ -z "${!v:-}" ] || stop "$v is set; the arms, model, engines and plan are fixed by the design"
done
{
  echo "router=$ROUTER_URL@$ROUTER_SHA"; echo "pr4313=$PR_URL@$PR_SHA merged_tree=$MERGED_TREE"
  echo "go=$GO_TGZ sha256=$GO_SHA256"; echo "envoy=$ENVOY_URL sha256=$ENVOY_SHA256"
  echo "vllm=$VLLM_WHEEL sha256=$VLLM_SHA256"; echo "model=$MODEL@$MODEL_REV"
  echo "arms=A1 guide optimized-baseline on 733d0e4e; A2 the same config on 733d0e4e+#4313; A3 max-score-picker alone (round-robin)"
  echo "engines=4 x vllm serve, one per GPU, --max-num-seqs 16, prefix caching, block 16; AK 4096 tokens/4096 blocks, B 2048/400, W 8192/default"
  echo "stage=$STAGE"
  echo "plan=$PLAN_TEXT"
  echo "budget_s=$BUDGET_S"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }

if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  echo "offline_test=1 (fake engines; EPP and Envoy from KIT_TEST_BIN)" >> "$OUT/settings.txt"
  B=${KIT_TEST_BIN:?the offline test sets KIT_TEST_BIN}
  step pilot "$PY" -I "$HERE/pilot.py" --out "$OUT" --mode offline --stage "$STAGE" --budget-s "${KIT_TEST_BUDGET_S:-900}" \
    --epp-a1 "$B/epp-a1" --epp-a2 "$B/epp-a2" --envoy "$B/envoy" --fake-engine "${KIT_TEST_FAKE:?}" \
    --time-scale "${KIT_TEST_SCALE:-0.2}" --fake-itl-ms "${KIT_TEST_ITL_MS:-4}" $(for f in ${KIT_TEST_FAULTS:-}; do printf -- '--fault %s ' "$f"; done) > "$OUT/pilot-stdout.txt" 2>&1
  finish
  exit $VERDICT_RC
fi

# ---------------------------------------------------------------- the GPUs
step gpu bash -c "nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > '$OUT/gpu.txt' 2>&1" || stop "nvidia-smi failed"
ngpu=$(tail -n +2 "$OUT/gpu.txt" | grep -c A10G)
[ "$ngpu" -eq 4 ] || stop "$ngpu A10G(s); the pilot runs one engine on each of four"
command -v git > /dev/null || stop "git is not installed"
command -v uv > /dev/null || stop "uv is not on PATH; the session provides it"
command -v taskset > /dev/null || stop "taskset is not installed"
mkdir -p "$ROOT" || stop "cannot create $ROOT"

# ---------------------------------------------------------------- three independent downloads in parallel
build_router() {
  local src=$ROOT/router
  rm -rf "$src" "$ROOT/go" && mkdir -p "$src" || return 1
  curl -fsSL -o "$ROOT/$GO_TGZ" "https://go.dev/dl/$GO_TGZ" &&
    [ "$(sha256sum "$ROOT/$GO_TGZ" | cut -d' ' -f1)" = "$GO_SHA256" ] &&
    tar -xzf "$ROOT/$GO_TGZ" -C "$ROOT" || { echo "go download or checksum failed"; return 1; }
  export PATH=$ROOT/go/bin:$PATH GOTOOLCHAIN=local GOPATH=$ROOT/gopath GOCACHE=$ROOT/gocache CGO_ENABLED=0
  git -C "$src" init -q &&
    git -C "$src" fetch -q --filter=blob:none "$ROUTER_URL" "$ROUTER_SHA" &&
    git -C "$src" fetch -q --filter=blob:none "$PR_URL" "$PR_SHA" &&
    git -C "$src" checkout -q "$ROUTER_SHA" || { echo "router fetch failed"; return 1; }
  ( cd "$src" && go build -trimpath -o "$ROOT/epp-a1" ./cmd/epp ) || { echo "A1 build failed"; return 1; }
  git -C "$src" -c user.name=kit -c user.email=kit@localhost merge --no-ff --no-edit -q "$PR_SHA" || { echo "merge of #4313 failed"; return 1; }
  local tree; tree=$(git -C "$src" rev-parse 'HEAD^{tree}')
  [ "$tree" = "$MERGED_TREE" ] || { echo "merged tree $tree is not the pinned $MERGED_TREE"; return 1; }
  ( cd "$src" && go build -trimpath -o "$ROOT/epp-a2" ./cmd/epp ) || { echo "A2 build failed"; return 1; }
  go version
}
get_envoy() {
  curl -fsSL -o "$ROOT/envoy" "$ENVOY_URL" && [ "$(sha256sum "$ROOT/envoy" | cut -d' ' -f1)" = "$ENVOY_SHA256" ] && chmod +x "$ROOT/envoy"
}
get_vllm() {
  rm -rf "$ROOT/venv" && uv venv -q "$ROOT/venv" --python 3.12 &&
    curl -fsSL -o "$ROOT/$VLLM_WHEEL" "$VLLM_WHEEL_URL" &&
    [ "$(sha256sum "$ROOT/$VLLM_WHEEL" | cut -d' ' -f1)" = "$VLLM_SHA256" ] &&
    VIRTUAL_ENV=$ROOT/venv uv pip install -q "$ROOT/$VLLM_WHEEL" &&
    VIRTUAL_ENV=$ROOT/venv uv pip freeze > "$OUT/venv-freeze.txt"
}
build_router > "$OUT/build-router.log" 2>&1 & P_ROUTER=$!
get_envoy > "$OUT/get-envoy.log" 2>&1 & P_ENVOY=$!
get_vllm > "$OUT/get-vllm.log" 2>&1 & P_VLLM=$!
wait $P_ENVOY; echo "envoy exit=$? t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
wait $P_VLLM; rc_v=$?; echo "vllm exit=$rc_v t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
[ "$rc_v" = 0 ] || stop "vLLM install failed; see get-vllm.log"
PY=$ROOT/venv/bin/python
step model "$PY" -I -c "
from huggingface_hub import snapshot_download
p = snapshot_download('$MODEL', revision='$MODEL_REV', local_dir='$ROOT/model')
print(p)" > "$OUT/model.log" 2>&1 || stop "model download failed; see model.log"
( cd "$ROOT/model" && find . -type f -not -path './.cache/*' | LC_ALL=C sort | xargs -d '\n' sha256sum ) > "$OUT/model-sha256.txt"
wait $P_ROUTER; rc_r=$?; echo "router exit=$rc_r t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
[ "$rc_r" = 0 ] || stop "router build failed; see build-router.log"
[ -x "$ROOT/envoy" ] || stop "envoy download or checksum failed; see get-envoy.log"
sha256sum "$ROOT/epp-a1" "$ROOT/epp-a2" "$ROOT/envoy" > "$OUT/binaries-sha256.txt"
echo "setup_s=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"

# ---------------------------------------------------------------- the pilot
left=$(( BUDGET_S - ($(date +%s) - START) - 60 ))
[ "$left" -gt 600 ] || stop "only $left s left after setup"
# The pilot's own process (sender, sampler) runs on cores the engines, the EPP and Envoy do not use.
step pilot taskset -c 36-47 "$PY" -I "$HERE/pilot.py" --out "$OUT" --mode gpu --stage "$STAGE" --budget-s "$left" \
  --epp-a1 "$ROOT/epp-a1" --epp-a2 "$ROOT/epp-a2" --envoy "$ROOT/envoy" --venv "$ROOT/venv" --model-dir "$ROOT/model" \
  > "$OUT/pilot-stdout.txt" 2>&1
finish
exit $VERDICT_RC
