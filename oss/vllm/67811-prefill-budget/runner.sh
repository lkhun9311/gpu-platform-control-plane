#!/bin/bash
# The on-instance part of oss/vllm/67811-prefill-budget/vllm-67811-session.sh: pull, identity, model download, then one adaptive engine
# (run 2), running the PR's own benchmark once to warm up and once scored, with every controller call traced.
#
#   runner.sh <dir with the fetched inputs> <out dir> <harness-end epoch>
#
# Every step has its own bound, and the step bounds below are the session script's, which its offline test holds equal.
# A step that fails ends its engine, not the run; the summary says which steps of which engine ran.
set -u
IN=$1
D=$2
HE=$3
IMG="public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:c0c20a4cded4c7a33b479d0a78b74e19e3ff057a5023c1693ef7beaa4d0eac15"
MODEL=Qwen/Qwen2.5-3B-Instruct
REV=aa8e72537993ba99e69dfaafa59ed015b17504d1
SITE=/usr/local/lib/python3.12/dist-packages
PULL_S=1500
BASE_ID_S=300
MODEL_S=600
READY_S=450
ID_S=60
WARMUP_S=150
RUN_S=150
RUNS=1
METRICS_S=10
STOP_S=30
SEEDS="62574"
# path in the package, sha256 at the PR head, sha256 at the merge base ("-" for the new file)
OVERLAYS="vllm/config/scheduler.py 235f4f23be12c03ab3c4184e134797cca5947c864af295eefa62c4c2ff28e1bf 55df4cbe4465c711c7ce26bbe2c49a641331a6d73487d85538e0010c9c4c47f3
vllm/engine/arg_utils.py 1bcfc89c5a5d3a038e617c29cc4b5a09917d6d5f808f3577c5b89d3b7f9f6b5b 07cec047290935f5077c589ec157e3057a59f95036872562602801572e8ec55c
vllm/v1/core/sched/adaptive_prefill.py 34d0b0c696df729c3ea44dcbc00ef46686976bf020e6f0d7f4da2bbfc21ffda9 -
vllm/v1/core/sched/scheduler.py df43d03c1da9772e18b6e46405b8d21eb4e7e8807e4772f76fa68cb5b6fcb8d9 b67848721847aa8f45cddee43cabdbb2f35205eb3b441e16d79823d30f3be097
vllm/v1/outputs.py 1c3fb383d6931ae7ffd93bf67d1892e8e6c09e37794fab9630aa963dcbf18bbf e74337460e6c0b4b7ae0fc4538e5e30998ff70e724306461e1e5b9a7324c3a4f
vllm/v1/worker/gpu/async_utils.py 36eb2c44f33d983d1f53038f99f7700add3736cbe46eddeee5fcb9f86918eb7b a8efebea81cc75016cf52f8183bb4d691b31567108cec0f38de3ca842b061fa9
vllm/v1/worker/gpu/model_runner.py d0dd317bc16d0475f46897055c5ecc4b80a95e02ccb55c703674d4bb6b3a5f33 8e8c878427ca1bb38857d52c204768fffc11a078a88a74f3a2285e54603eef40"
# slot:arm, in the run order; each slot is a fresh engine
SLOTS="1:adaptive"

mkdir -p "$D"
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$D/steps.log"; }
left() { local l=$(( HE - $(date +%s) )); [ "$l" -gt "$1" ] && echo "$1" || echo $(( l > 1 ? l : 1 )); }
summary() { echo "$1" >> "$D/summary.tsv"; }
echo -e "slot\tarm\tready\tidentity\twarmup\tscored_ok\tscored_runs\tprobe_timed_steps" > "$D/summary.tsv"

step "pull $IMG"
if ! timeout --kill-after=15 "$(left $PULL_S)" docker pull "$IMG" > "$D/pull.log" 2>&1; then
  step "PULL FAILED"; exit 2
fi
step "pulled"

# The installed package must be the merge base's before anything is mounted over it.
step "base identity"
base_args=()
while read -r p head base; do [ "$base" = - ] || base_args+=("$SITE/$p"); done <<<"$OVERLAYS"
timeout --kill-after=15 "$(left $BASE_ID_S)" docker run --rm --entrypoint sha256sum "$IMG" "${base_args[@]}" > "$D/base-sha256.txt" 2>&1
bad=0
while read -r p head base; do
  [ "$base" = - ] && { timeout 60 docker run --rm --entrypoint test "$IMG" ! -e "$SITE/$p" || { step "BASE IDENTITY: $p exists in the image"; bad=1; }; continue; }
  grep -q "^$base  $SITE/$p\$" "$D/base-sha256.txt" || { step "BASE IDENTITY: $p is not the merge base's"; bad=1; }
done <<<"$OVERLAYS"
[ "$bad" = 0 ] || { step "BASE IDENTITY FAILED"; exit 2; }
step "base identity ok"

step "model download"
mkdir -p /opt/ap/hf
if ! timeout --kill-after=15 "$(left $MODEL_S)" docker run --rm -v /opt/ap/hf:/root/.cache/huggingface --entrypoint python3 "$IMG" \
  -c "from huggingface_hub import snapshot_download; print(snapshot_download('$MODEL', revision='$REV'))" > "$D/model-download.log" 2>&1; then
  step "MODEL DOWNLOAD FAILED"; exit 2
fi
step "model downloaded"

mounts=()
while read -r p head base; do mounts+=(-v "$IN/ovl/$p:$SITE/$p:ro"); done <<<"$OVERLAYS"

for sa in $SLOTS; do
  slot=${sa%%:*}; arm=${sa#*:}
  name="ap-$slot-$arm"
  flags=(--long-prefill-token-threshold 1024)
  case $arm in
    adaptive) flags+=(--adaptive-prefill) ;;
    t512) flags=(--long-prefill-token-threshold 512) ;;
  esac
  ready=no; identity=no; warmup=no; ok=0
  step "engine $name: start"
  mkdir -p "/opt/ap/compile/$arm"
  docker run -d --name "$name" --gpus all --shm-size 1g -p 127.0.0.1:8000:8000 \
    -v /opt/ap/hf:/root/.cache/huggingface -v "/opt/ap/compile/$arm:/root/.cache/vllm" "${mounts[@]}" \
    -v "$IN/bench:/bench:ro" -v "$IN/probe:/probe:ro" -v "$D:/out" \
    -e PYTHONPATH=/probe -e AP_PROBE_DIR=/out -e AP_SLOT="$slot-$arm" \
    --entrypoint env "$IMG" -u VLLM_GPU_SYNC_CHECK \
    vllm serve "$MODEL" --revision "$REV" --tokenizer-revision "$REV" --dtype half --max-model-len 32768 \
    --max-num-batched-tokens 8192 --max-num-seqs 64 --enable-chunked-prefill --no-enable-prefix-caching \
    --gpu-memory-utilization 0.90 --port 8000 "${flags[@]}" > "$D/$name.container-id" 2>&1
  t0=$(date +%s); limit=$(left $READY_S)
  while [ $(( $(date +%s) - t0 )) -lt "$limit" ]; do
    curl -fsS -m 2 http://127.0.0.1:8000/health >/dev/null 2>&1 && { ready=yes; break; }
    [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] || break
    sleep 2
  done
  echo "$(( $(date +%s) - t0 ))" > "$D/$name.ready-seconds"
  step "engine $name: ready=$ready after $(cat "$D/$name.ready-seconds") s"
  if [ "$ready" = yes ]; then
    # The files the engine imports, hashed inside the container at the paths Python resolves them to.
    timeout "$(left $ID_S)" docker exec "$name" python3 -c '
import hashlib, importlib.util, sys
for mod in sys.argv[1:]:
    path = importlib.util.find_spec(mod).origin
    print(hashlib.sha256(open(path, "rb").read()).hexdigest(), path, sep="  ")
' vllm.config.scheduler vllm.engine.arg_utils vllm.v1.core.sched.adaptive_prefill vllm.v1.core.sched.scheduler \
      vllm.v1.outputs vllm.v1.worker.gpu.async_utils vllm.v1.worker.gpu.model_runner > "$D/$name.identity.txt" 2>&1
    docker logs "$name" 2>&1 | grep -m1 "non-default args" > "$D/$name.args.txt"
    identity=yes
    while read -r p head base; do
      grep -q "^$head  $SITE/$p\$" "$D/$name.identity.txt" || { step "IDENTITY: $p is not the PR head's"; identity=no; }
    done <<<"$OVERLAYS"
    case $arm in
      adaptive) grep -q "'adaptive_prefill': True" "$D/$name.args.txt" || { step "IDENTITY: adaptive flag missing"; identity=no; } ;;
      *) ! grep -q "adaptive_prefill" "$D/$name.args.txt" || { step "IDENTITY: adaptive flag present"; identity=no; } ;;
    esac
    case $arm in
      t512) grep -q "'long_prefill_token_threshold': 512" "$D/$name.args.txt" || { step "IDENTITY: threshold not 512"; identity=no; } ;;
      *) grep -q "'long_prefill_token_threshold': 1024" "$D/$name.args.txt" || { step "IDENTITY: threshold not 1024"; identity=no; } ;;
    esac
    grep -q "'enable_prefix_caching': False" "$D/$name.args.txt" || { step "IDENTITY: prefix caching not off"; identity=no; }
    step "engine $name: identity=$identity"
  fi
  if [ "$identity" = yes ]; then
    timeout "$(left $METRICS_S)" curl -fsS http://127.0.0.1:8000/metrics > "$D/$name.metrics-before.prom" 2>&1
    ( nvidia-smi --query-gpu=timestamp,clocks.sm,clocks.mem,temperature.gpu,power.draw,utilization.gpu,memory.used \
        --format=csv -lms 1000 > "$D/$name.gpu.csv" 2>&1 & echo $! > /tmp/ap-smi.pid
      while :; do echo "$(date +%s) $(cat /proc/loadavg)" >> "$D/$name.loadavg"; sleep 1; done & echo $! > /tmp/ap-load.pid )
    # A host-side timeout kills only the docker client, so the bound is enforced inside the container too, and
    # serve.py's per-request timeout sits under it. Any failed invocation ends the engine, so an orphaned workload
    # can never overlap a later scored run.
    bench() { local b; b=$(left "$1"); timeout --kill-after=10 $(( b + 15 )) docker exec "$name" \
      timeout --kill-after=5 "$b" python3 /bench/serve.py --model "$MODEL" --timeout $(( b - 20 )) "${@:2}"; }
    # The warm-up is the same mixed workload under a seed no scored run uses, and it is never scored.
    bench "$WARMUP_S" --label "$slot-$arm-warmup" --output "/out/$name.warmup.json" --seed 1 > "$D/$name.warmup.log" 2>&1 && warmup=yes
    i=0
    if [ "$warmup" = yes ]; then
      for seed in $SEEDS; do
        bench "$RUN_S" --label "$slot-$arm-r$i" --output "/out/$name.r$i.json" --seed "$seed" > "$D/$name.r$i.log" 2>&1 || break
        ok=$(( ok + 1 )); i=$(( i + 1 ))
      done
    fi
    kill "$(cat /tmp/ap-smi.pid)" "$(cat /tmp/ap-load.pid)" 2>/dev/null
    timeout "$(left $METRICS_S)" curl -fsS http://127.0.0.1:8000/metrics > "$D/$name.metrics-after.prom" 2>&1
  fi
  probe=n/a
  if [ "$arm" = adaptive ]; then
    probe=$(python3 -c '
import glob, json, math, sys
n = 0
for f in glob.glob(sys.argv[1]):
    for line in open(f):
        v = json.loads(line).get("device_ms")
        n += isinstance(v, (int, float)) and math.isfinite(v) and v > 0
print(n)' "$D/probe-$slot-$arm-*.jsonl" 2>/dev/null || echo 0)
  fi
  docker logs "$name" > "$D/$name.engine.log" 2>&1
  timeout "$(left $STOP_S)" docker rm -f "$name" > /dev/null 2>&1
  docker inspect "$name" > /dev/null 2>&1 && { step "engine $name was not removed; stopping the run"; summary "$slot	$arm	$ready	$identity	$warmup	$ok	$RUNS	${probe:-n/a}"; exit 2; }
  summary "$slot	$arm	$ready	$identity	$warmup	$ok	$RUNS	${probe:-n/a}"
  step "engine $name: done, $ok of $RUNS scored runs"
done
step "all engines done"
