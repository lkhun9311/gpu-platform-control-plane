#!/bin/bash
# The on-instance part of hack/llmd-prefix-hunt-session.sh: two vLLM replicas of one small VLM on the A10G, then the probe.
#
#   runner.sh <dir with the fetched inputs> <out dir> <harness-end epoch>
#
# The replicas are containers on one docker network, each at its own address with the same ports, as two pods would be.
# The probe runs on the host, dials both replicas' KV-event sockets and HTTP ports, and writes its records under OUT/probe.
# A failure before the probe starts voids the run, so it stops there; a probe failure still collects the replicas' logs and metrics.
# The step bounds below are the session script's, which its offline test holds equal.
set -u
IN=$1
D=$2
HE=$3
# vllm/vllm-openai v0.34.0, pinned by its manifest-list digest, read from Docker Hub on 2026-11-19.
IMG="vllm/vllm-openai@sha256:20fdb089454afbb324efa4110a2c025ff7b27cc1a086e07aa580b18df8ad1ce1"
VLLM_VERSION=0.34.0
# The image's revision label, which is the v0.34.0 tag's commit and the source the hypotheses were read from.
VLLM_COMMIT=62d4bc3c7e33b1b6c906e233e6af2d3506c482ca
# Qwen2-VL-2B-Instruct, Apache-2.0, 4.43 GB of files, pinned by its Hugging Face commit.
MODEL=Qwen/Qwen2-VL-2B-Instruct
MODEL_REV=895c3a49bc3fa70a340399125c650a463535e71c
SERVED=qwen2vl
NET=llmd-hunt
NET_CIDR=172.30.0.0/24
ADDR_A=172.30.0.10
ADDR_B=172.30.0.11
# Each replica gets a fixed 3 GiB of KV cache, which also turns off v0.34's extensible KV cache, so the two replicas cannot race for the free memory.
KV_BYTES=3221225472
# A fixed KV cache leaves the utilization at its 0.92 default, and request_memory refuses a start with less free memory than that share of the GPU.
# So B would never start beside A; 0.45 each is what two replicas can both have.
GPU_UTIL=0.45
# The profile run sizes its dummy inputs from these limits: one image of the workload's size and no video, instead of the model's largest image and 999 videos.
MM_LIMITS='{"image":{"count":1,"width":336,"height":336},"video":0}'
PULL_S=1500
IMAGE_ID_S=60
START_A_S=600
START_B_S=300
PROBE_S=900
COLLECT_S=90
STOP_S=30
REPS=2
SEED=20261119

mkdir -p "$D"
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$D/steps.log"; }
left() { local l=$(( HE - $(date +%s) )); [ "$l" -gt "$1" ] && echo "$1" || echo $(( l > 1 ? l : 1 )); }

step "pull $IMG"
if ! timeout --kill-after=15 "$(left $PULL_S)" docker pull "$IMG" > "$D/pull.log" 2>&1; then
  step "PULL FAILED"; exit 2
fi
step "pulled"

step "image identity"
docker image inspect "$IMG" --format '{{json .RepoDigests}} {{index .Config.Labels "org.opencontainers.image.revision"}}' > "$D/image-identity.txt" 2>&1
grep -q "sha256:20fdb089454afbb324efa4110a2c025ff7b27cc1a086e07aa580b18df8ad1ce1" "$D/image-identity.txt" &&
  grep -q " $VLLM_COMMIT\$" "$D/image-identity.txt" || { step "IMAGE IDENTITY FAILED: $(cat "$D/image-identity.txt")"; exit 2; }
timeout --kill-after=15 "$(left $IMAGE_ID_S)" docker run --rm --entrypoint python3 "$IMG" -c 'import vllm; print(vllm.__version__)' \
  > "$D/vllm-version.txt" 2>&1
grep -qx "$VLLM_VERSION" "$D/vllm-version.txt" || { step "IMAGE IDENTITY FAILED: vllm $(tail -n 1 "$D/vllm-version.txt")"; exit 2; }
step "image identity ok"

docker network create --subnet "$NET_CIDR" "$NET" > "$D/network.txt" 2>&1 || { step "NETWORK FAILED: $(cat "$D/network.txt")"; exit 2; }
mkdir -p /opt/hf

# replica NAME ADDR: starts one replica; the flags are the session's whole serving configuration.
# The block size is left to vLLM's default, which is what the hypotheses are about, and the events record what it was.
replica() {
  docker run -d --name "hunt-$1" --gpus all --ipc host --network "$NET" --ip "$2" \
    -v /opt/hf:/root/.cache/huggingface -e HF_HUB_DISABLE_TELEMETRY=1 "$IMG" \
    --model "$MODEL" --revision "$MODEL_REV" --served-model-name "$SERVED" \
    --kv-cache-memory-bytes "$KV_BYTES" --gpu-memory-utilization "$GPU_UTIL" --max-model-len 4096 --enforce-eager \
    --enable-prompt-tokens-details --limit-mm-per-prompt "$MM_LIMITS" \
    --kv-events-config '{"enable_kv_cache_events":true,"publisher":"zmq","endpoint":"tcp://*:5557","topic":"kv@'"$SERVED"'"}' \
    --port 8000 > "$D/replica-$1.id" 2>&1
}
# ready NAME ADDR BOUND: waits for /health, and gives up early if the container exited.
ready() {
  local end=$(( $(date +%s) + $(left "$3") ))
  while [ "$(date +%s)" -lt "$end" ]; do
    curl -fsS -m 5 "http://$2:8000/health" > /dev/null 2>&1 && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "hunt-$1" 2>/dev/null)" = true ] || return 1
    sleep 5
  done
  return 1
}
collect_logs() {
  for n in a b; do docker logs "hunt-$n" > "$D/replica-$n.log" 2>&1; done
}
# metrics WHEN: both replicas' Prometheus text, which holds vLLM's own prefix-cache hit and query counters.
metrics() {
  curl -fsS -m 10 "http://$ADDR_A:8000/metrics" > "$D/metrics-a-$1.txt" 2>&1
  curl -fsS -m 10 "http://$ADDR_B:8000/metrics" > "$D/metrics-b-$1.txt" 2>&1
}
stop_all() {
  collect_logs
  timeout $(( STOP_S / 3 )) docker rm -f hunt-a hunt-b > /dev/null 2>&1
}

# A starts alone, so it downloads the model once and both replicas' memory profiles do not overlap.
step "replica a: start"
replica a "$ADDR_A" || { step "REPLICA A FAILED to start: $(cat "$D/replica-a.id")"; stop_all; exit 2; }
ready a "$ADDR_A" "$START_A_S" || { step "REPLICA A NOT READY"; stop_all; exit 2; }
step "replica a: ready"
step "replica b: start"
replica b "$ADDR_B" || { step "REPLICA B FAILED to start: $(cat "$D/replica-b.id")"; stop_all; exit 2; }
ready b "$ADDR_B" "$START_B_S" || { step "REPLICA B NOT READY"; stop_all; exit 2; }
step "replica b: ready"
nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv > "$D/gpu-after-start.csv" 2>&1

# The flood must evict every earlier prefix from A, so it is sized from the KV capacity A logged, one and a half times over.
kv_tokens=$(docker logs hunt-a 2>&1 | grep -o 'KV cache size: [0-9,]* tokens' | head -n 1 | grep -o '[0-9,]*' | tr -d ,)
if ! [[ "$kv_tokens" =~ ^[0-9]+$ ]] || [ "$kv_tokens" -le 0 ]; then
  step "KV CAPACITY UNREAD from replica a's log"; stop_all; exit 2
fi
flood=$(( (kv_tokens * 3 / 2 + 1023) / 1024 ))
[ "$flood" -ge 6 ] || flood=6
[ "$flood" -le 400 ] || { step "KV CAPACITY $kv_tokens tokens needs $flood flood prompts, over the 400 the probe's bound allows"; stop_all; exit 2; }
echo "kv_cache_tokens=$kv_tokens flood_prompts=$flood" > "$D/flood.txt"
step "kv capacity $kv_tokens tokens; flood $flood prompts per repetition"
metrics before

step "probe: start"
timeout --kill-after=15 "$(left $PROBE_S)" "$IN/probe" -pods "a=$ADDR_A,b=$ADDR_B" -model "$SERVED" \
  -render-url "http://$ADDR_A:8000" -out "$D/probe" -seed "$SEED" -reps "$REPS" -flood "$flood" \
  > "$D/probe.log" 2>&1
probe_rc=$?
step "probe: exited $probe_rc"

metrics after
if [ -s "$D/probe/requests.jsonl" ]; then
  timeout "$(left $COLLECT_S)" python3 "$IN/verdict.py" "$D/probe" > "$D/verdict-on-instance.txt" 2>&1
fi
stop_all
# "all items done" is what the session reads as a whole record, so a probe that failed or was cut by its bound does not write it.
if [ "$probe_rc" != 0 ]; then
  step "PROBE FAILED, exit $probe_rc; the records are partial"
  exit 3
fi
step "all items done, probe exited 0"
