#!/bin/bash
# The single-A10G capacity study (issue #673): one session is a warm-up, the pilot, one cycle and three restarts,
# under experiments/a10g-capacity/CONTRACT.md, whose values this kit reads from contract.json beside it.
# hack/gpu-kit-session.sh runs this unmodified with OUT set, as root, on one g5.xlarge.
#
# Every step's exit code goes to $OUT/status.txt, and the analysis writes report.txt and report.json.
# The exit status is 0 when the session ran to its report and no exclusion rule from X3 to X5 applies,
# 3 when the report names an exclusion, and 1 when the kit stopped before its report.
#
# Settings: none.
# The workload, the rates and the budget are the contract's, so any KIT_ variable other than the offline test's is refused.
#
# Offline test only: KIT_OFFLINE_TEST=1 with KIT_TEST_BIN (a directory holding capacityrun and benchharness) runs the
# same steps against the benchharness stub with the contract's time compressed by KIT_TEST_SCALE (default 0.1):
# durations and latency bounds times the scale, rates divided by it, so every stage plans the requests the GPU run plans.
# KIT_TEST_FAULTS may name drop-row, which deletes one cycle row before the report, to show the ledger check failing.
set -uo pipefail
# The pins are constants; a caller who sets one by name is refused rather than silently overridden.
for v in REPO_URL SRC_SHA GO_TGZ GO_SHA256 ENGINE_NAME ROOT; do
  [ -z "${!v+x}" ] || { echo "$v is set in the environment; the kit's pins are fixed" >&2; exit 1; }
done
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
REPO_URL=https://github.com/lkhun9311/gpu-platform-control-plane
# The commit whose cmd/capacityrun this kit builds; the kit's own commit comes later and cannot name itself.
SRC_SHA=3ca5f3cc00a977109d703bb36c1fa1dcf3f6b0f6
# go.mod's toolchain, checksum as go.dev publishes it.
GO_TGZ=go1.27.4.linux-amd64.tar.gz
GO_SHA256=7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840
ENGINE_NAME=a10g-vllm
ROOT=/opt/a10g
START=$(date +%s)
mkdir -p "$OUT" || exit 1
# A rerun into the same OUT would leave an earlier run's stages for the report to read, so only an empty OUT is used.
if [ -n "$(ls -A "$OUT")" ]; then echo "OUT=$OUT is not empty; each run writes a new directory" >&2; exit 1; fi
: > "$OUT/status.txt"
PY=python3

step() { # name, then the command; records the exit code and returns it
  local name=$1; shift
  "$@"; local rc=$?
  echo "$name exit=$rc t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
  return $rc
}
PIDS=()
REPORT_RC=1
finish() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  [ "${OFFLINE:-}" = 1 ] && [ -f "$OUT/engine.pid" ] && kill -9 "$(cat "$OUT/engine.pid")" 2>/dev/null
  wait 2>/dev/null
  if [ -d "$OUT/pilot" ] || [ -d "$OUT/warmup" ]; then
    [ -n "${FAULT_DROP_ROW:-}" ] && [ -f "$OUT/cycle/raw.jsonl" ] && sed -i '5d' "$OUT/cycle/raw.jsonl"
    "$PY" -I "$HERE/analysis.py" report "$C" "$OUT" > "$OUT/report-stdout.txt" 2>&1
    REPORT_RC=$?
    echo "report exit=$REPORT_RC t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
    cat "$OUT/report-stdout.txt"
  fi
  ( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS )
}
stop() { # the reason; the run ends here and says why
  echo "$*" | tee "$OUT/STOPPED" >&2
  echo "STOPPED $*" >> "$OUT/status.txt"
  engine_logs
  finish
  exit 1
}
engine_logs() { :; }

# ---------------------------------------------------------------- settings, refused before anything is downloaded
for v in $(compgen -v KIT_); do
  case "$v" in
    KIT_OFFLINE_TEST | KIT_TEST_BIN | KIT_TEST_SCALE | KIT_TEST_FAULTS | KIT_TEST_PORT | KIT_DRY_RUN) ;;
    *) echo "$v is set; the workload, rates and budget are the contract's" >&2; exit 1 ;;
  esac
done
C=$HERE/contract.json
OFFLINE=${KIT_OFFLINE_TEST:-}
if [ "$OFFLINE" = 1 ]; then
  SCALE=${KIT_TEST_SCALE:-0.1}
  [[ $SCALE =~ ^0\.[0-9]+$|^1$ ]] || { echo "KIT_TEST_SCALE=$SCALE is not in (0, 1]" >&2; exit 1; }
  "$PY" -I "$HERE/analysis.py" scale "$HERE/contract.json" "$SCALE" > "$OUT/contract.rehearsal.json" || exit 1
  C=$OUT/contract.rehearsal.json
  case " ${KIT_TEST_FAULTS:-} " in *" drop-row "*) FAULT_DROP_ROW=1 ;; esac
fi
# Every number below comes from the contract the run uses, read once.
eval "$("$PY" -I - "$C" <<'PY'
import json, math, sys, shlex
c = json.load(open(sys.argv[1]))
p, cy, rs, w, wk = c["pilot"], c["cycle"], c["restart"], c["warmup"], c["workload"]
up = lambda v: int(math.ceil(v))
vals = {
    "CONTRACT_ID": c["contract"], "IMAGE": wk["engine_image"], "PORT": wk["engine_port"],
    "BUDGET_S": up(c["session"]["budget_s"]),
    "WARMUP": f"warmup:{w['rate_rps']:g}:{w['duration_s']:g}", "WARMUP_SEED": w["seed"],
    "RUNGS": " ".join(f"{r:g}" for r in p["rungs_rps"]), "SEEDS": " ".join(str(s) for s in p["rung_seeds"]),
    "RUNG_S": f"{p['rung_s']:g}", "DRAIN_IDLE_S": f"{p['drain_idle_s']:g}", "DRAIN_GAUGE_S": f"{p['drain_gauge_timeout_s']:g}",
    "PILOT_BUDGET_S": up(p["budget_s"]),
    "RUNG_WORST_S": up(p["rung_s"] + wk["request_timeout_s"] + p["drain_idle_s"] + p["drain_gauge_timeout_s"]),
    "CYCLE_SEED": cy["seed"],
    "CYCLE_WORST_S": up(cy["baseline_s"] + cy["saturation_s"] + cy["overload_s"] + cy["recovery_s"] + wk["request_timeout_s"]),
    "RESTARTS": rs["count"], "RESTART_IDLE_S": f"{rs['idle_before_s']:g}",
    "RESTART_WORST_S": up(rs["idle_before_s"] + rs["bound_s"] + rs["probe_timeout_s"]),
    "GPU_QUERY": c["metrics"]["gpu_query"],
}
for k, v in vals.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
)" || exit 1
# Time kept after the restarts for the engine log, the report and the checksums.
RESERVE_S=60
[ "$OFFLINE" = 1 ] && RESERVE_S=$(awk -v s="$SCALE" 'BEGIN { printf "%d", 60 * s + 0.999 }')
{
  echo "contract=$CONTRACT_ID"; echo "contract_sha256=$(sha256sum "$C" | cut -d' ' -f1)"
  echo "image=$IMAGE"; echo "source=$REPO_URL@$SRC_SHA"; echo "go=$GO_TGZ sha256=$GO_SHA256"
  echo "budget_s=$BUDGET_S pilot_budget_s=$PILOT_BUDGET_S rung_worst_s=$RUNG_WORST_S cycle_worst_s=$CYCLE_WORST_S restart_worst_s=$RESTART_WORST_S"
  echo "warmup=$WARMUP rungs=$RUNGS restarts=$RESTARTS"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }
left() { echo $(( START + BUDGET_S - $(date +%s) )); }

# ---------------------------------------------------------------- the engine, its sender, and how each restarts
if [ "$OFFLINE" = 1 ]; then
  # The stub listens on its own port, so a rehearsal never meets an engine the host already runs on the contract's.
  PORT=${KIT_TEST_PORT:-18473}
fi
TARGET=http://127.0.0.1:$PORT
if [ "$OFFLINE" = 1 ]; then
  B=${KIT_TEST_BIN:?the offline test sets KIT_TEST_BIN}
  CR=$B/capacityrun
  # 64 running places like --max-num-seqs, and a service time of 128 frames that saturates near 100 req/s at scale 0.1,
  # the compressed image of 10 req/s, so the pilot finds an unstable rung inside its ladder.
  ITL_MS=$(awk -v s="$SCALE" 'BEGIN { printf "%d", 50 * s }')
  cat > "$OUT/stub-start.sh" <<EOF
#!/bin/bash
"$B/benchharness" stub-serve --port $PORT --metrics --tokens-from-request --stub-finish-reasons --stub-max-running 64 \\
  --ttft-ms 5 --itl-ms $ITL_MS >> "$OUT/engine.log" 2>&1 &
echo \$! > "$OUT/engine.pid"
EOF
  KILL_CMD="kill -9 \$(cat '$OUT/engine.pid')"
  START_CMD="sleep 0.5; bash '$OUT/stub-start.sh'"
  engine_first_start() { bash "$OUT/stub-start.sh"; }
  engine_logs() { :; }
  echo "offline_test=1 scale=$SCALE (benchharness stub, 64 running, itl ${ITL_MS} ms)" >> "$OUT/settings.txt"
else
  CR=$ROOT/capacityrun
  step gpu bash -c "nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > '$OUT/gpu.txt' 2>&1" || stop "nvidia-smi failed"
  ngpu=$(tail -n +2 "$OUT/gpu.txt" | grep -c A10G)
  [ "$ngpu" -eq 1 ] || stop "$ngpu A10G(s); the contract measures one"
  for t in docker git curl sha256sum; do command -v "$t" > /dev/null || stop "$t is not installed"; done
  mkdir -p "$ROOT/hf" || stop "cannot create $ROOT"
  docker info --format '{{json .Runtimes}}' > "$OUT/docker-runtimes.txt" 2>&1
  # The image pull is the long pole, so it starts first and the sender is built beside it.
  pull() {
    local t0; t0=$(date +%s)
    timeout 1200 docker pull "$IMAGE" && echo "pull_s=$(( $(date +%s) - t0 ))"
  }
  build() {
    export PATH=$ROOT/go/bin:$PATH GOTOOLCHAIN=local GOPATH=$ROOT/gopath GOCACHE=$ROOT/gocache CGO_ENABLED=0 GOFLAGS=-mod=readonly
    curl -fsSL -o "$ROOT/$GO_TGZ" "https://go.dev/dl/$GO_TGZ" &&
      [ "$(sha256sum "$ROOT/$GO_TGZ" | cut -d' ' -f1)" = "$GO_SHA256" ] &&
      tar -xzf "$ROOT/$GO_TGZ" -C "$ROOT" || { echo "go download or checksum failed"; return 1; }
    rm -rf "$ROOT/src" && mkdir -p "$ROOT/src" &&
      git -C "$ROOT/src" init -q && git -C "$ROOT/src" fetch -q --depth 1 "$REPO_URL" "$SRC_SHA" &&
      git -C "$ROOT/src" checkout -q FETCH_HEAD &&
      [ "$(git -C "$ROOT/src" rev-parse HEAD)" = "$SRC_SHA" ] || { echo "source fetch failed"; return 1; }
    ( cd "$ROOT/src" && go build -trimpath -o "$CR" ./cmd/capacityrun ) || { echo "build failed"; return 1; }
    go version && sha256sum "$CR"
  }
  pull > "$OUT/pull.log" 2>&1 & P_PULL=$!
  build > "$OUT/build.log" 2>&1 & P_BUILD=$!
  wait $P_BUILD; echo "build exit=$? t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
  [ -x "$CR" ] || stop "the sender build failed; see build.log"
  wait $P_PULL; rc=$?; echo "pull exit=$rc t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
  [ "$rc" = 0 ] || stop "the image pull failed; see pull.log"
  docker image inspect --format '{{json .RepoDigests}}' "$IMAGE" > "$OUT/image-digests.txt" 2>&1
  mapfile -t ENGINE_ARGS < <("$CR" engine-args --contract "$C")
  [ "${#ENGINE_ARGS[@]}" -gt 5 ] || stop "capacityrun refused the contract; see the line above"
  printf '%s\n' "${ENGINE_ARGS[@]}" > "$OUT/engine-args.txt"
  # The container is restarted, not recreated, so its compile cache survives a restart (CONTRACT.md section 7).
  engine_first_start() {
    docker run --detach --name "$ENGINE_NAME" --gpus all --shm-size 1g --publish "127.0.0.1:$PORT:$PORT" \
      --volume "$ROOT/hf:/root/.cache/huggingface" "$IMAGE" "${ENGINE_ARGS[@]}"
  }
  KILL_CMD="docker kill --signal=SIGKILL $ENGINE_NAME"
  START_CMD="docker start $ENGINE_NAME"
  engine_logs() {
    docker logs --timestamps "$ENGINE_NAME" > "$OUT/engine.log" 2>&1
    docker inspect "$ENGINE_NAME" > "$OUT/engine-inspect.json" 2>&1
  }
fi
"$CR" engine-args --contract "$C" > /dev/null || stop "capacityrun refused the contract"

# ---------------------------------------------------------------- first start, then the samplers
t0=$(date +%s)
step engine-start engine_first_start > "$OUT/engine-start.log" 2>&1 || stop "the engine did not start; see engine-start.log"
ready=0
while [ $(( $(date +%s) - t0 )) -lt 1200 ]; do
  if curl -fsS -o /dev/null --max-time 2 "$TARGET/health"; then ready=1; break; fi
  sleep 2
done
[ "$ready" = 1 ] || stop "the engine was not healthy within 1200 s"
echo "first_ready_s=$(( $(date +%s) - t0 ))" | tee -a "$OUT/status.txt"
"$PY" -I "$HERE/sampler.py" "$C" "$TARGET/metrics" "$OUT/engine-samples.jsonl" & PIDS+=($!)
if [ "$OFFLINE" != 1 ]; then
  nvidia-smi --query-gpu="$GPU_QUERY" --format=csv -lms 1000 > "$OUT/gpu-samples.csv" 2>&1 & PIDS+=($!)
fi

# ---------------------------------------------------------------- warm-up and pilot
step warmup "$CR" stage --contract "$C" --segments "$WARMUP" --seed "$WARMUP_SEED" --target "$TARGET" \
  --out "$OUT/warmup" --request-id-prefix warmup > "$OUT/warmup.log" 2>&1 || stop "the warm-up did not record; see warmup.log"
mkdir -p "$OUT/pilot"
# The pilot leaves time for the cycle, the restarts and the report, whichever ends first: its own budget or that.
pilot_end=$(( $(date +%s) + PILOT_BUDGET_S ))
room=$(( START + BUDGET_S - CYCLE_WORST_S - RESTARTS * RESTART_WORST_S - RESERVE_S ))
[ "$room" -lt "$pilot_end" ] && pilot_end=$room
read -r -a rungs <<< "$RUNGS"
read -r -a seeds <<< "$SEEDS"
for k in "${!rungs[@]}"; do
  n=$(printf '%02d' $(( k + 1 )))
  if [ $(( $(date +%s) + RUNG_WORST_S )) -gt "$pilot_end" ]; then
    echo "pilot budget: rung $n not started" | tee -a "$OUT/status.txt"; break
  fi
  step "rung-$n" "$CR" stage --contract "$C" --segments "rung:${rungs[$k]}:$RUNG_S" --seed "${seeds[$k]}" --target "$TARGET" \
    --out "$OUT/pilot/rung-$n" --request-id-prefix "rung-$n" > "$OUT/pilot/rung-$n.log" 2>&1 || stop "rung $n did not record"
  sleep "$DRAIN_IDLE_S"
  step "drain-$n" "$PY" -I "$HERE/sampler.py" --drained "$C" "$TARGET/metrics" "$DRAIN_GAUGE_S" || stop "the engine did not drain after rung $n"
  "$PY" -I "$HERE/analysis.py" rung "$C" "$OUT/pilot/rung-$n" > "$OUT/pilot/rung-$n.verdict.json"
  rc=$?
  echo "rung-$n verdict=$rc rate=${rungs[$k]}" | tee -a "$OUT/status.txt"
  [ "$rc" = 0 ] && continue
  [ "$rc" = 10 ] && break
  stop "rung $n could not be judged; see pilot/rung-$n.verdict.json"
done
step plan "$PY" -I "$HERE/analysis.py" plan "$C" "$OUT/pilot" > "$OUT/pilot/plan-stdout.txt" 2>&1 || stop "no cycle plan; see pilot/plan-stdout.txt"

# ---------------------------------------------------------------- the cycle
segs=$("$PY" -I -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["segments"] if p["run"] else "")' "$OUT/pilot/cycle-plan.json")
if [ -z "$segs" ]; then
  echo "cycle not run: $("$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["reason"])' "$OUT/pilot/cycle-plan.json")" | tee -a "$OUT/status.txt"
elif [ "$(left)" -lt $(( CYCLE_WORST_S + RESERVE_S )) ]; then
  echo "cycle not run: $(left) s left of the budget" | tee -a "$OUT/status.txt"
else
  step cycle "$CR" stage --contract "$C" --segments "$segs" --seed "$CYCLE_SEED" --target "$TARGET" \
    --out "$OUT/cycle" --request-id-prefix cycle > "$OUT/cycle.log" 2>&1
fi

# ---------------------------------------------------------------- the restarts
for i in $(seq 1 "$RESTARTS"); do
  if [ "$(left)" -lt $(( RESTART_WORST_S + RESERVE_S )) ]; then
    echo "restart $i not run: $(left) s left of the budget" | tee -a "$OUT/status.txt"; break
  fi
  sleep "$RESTART_IDLE_S"
  step "restart-$i" "$CR" restart --contract "$C" --target "$TARGET" --kill-cmd "$KILL_CMD" --start-cmd "$START_CMD" \
    --index "$i" --out "$OUT/restart-$i.json" > "$OUT/restart-$i.log" 2>&1 || break
done

engine_logs
finish
[ "$REPORT_RC" = 0 ] && exit 0
[ "$REPORT_RC" = 3 ] && exit 3
exit 1
