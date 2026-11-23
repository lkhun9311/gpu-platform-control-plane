#!/bin/bash
exec > >(tee /var/log/gpukit.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop counts from the instance's own start, which LaunchTime precedes, so the precise one below fires first.
( sleep 3720; shutdown -h now ) &
BUCKET="gpukit-007635145730"
PREFIX="s1-cc97f149"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/gpukit.log log.txt; shutdown -h now' EXIT
R=/opt/kit/run
mkdir -p /opt/kit/in /opt/kit/bin /opt/kit/work "$R/results" || exit 1
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/inputs.tgz" /opt/kit/inputs.tgz || exit 1
[ "$(sha256sum /opt/kit/inputs.tgz | cut -d' ' -f1)" = "14a940d64f9b1c42e9c03188fd7e40fcdea76eda87d64c95c319dc0e89bc4036" ] || { echo "checksum mismatch for inputs.tgz"; exit 1; }
tar -xzf /opt/kit/inputs.tgz -C /opt/kit/in || exit 1
L=""
while [ $(( $(date +%s) - SR_START )) -lt 180 ]; do
  if aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/launch-time.txt" /tmp/launch-time.txt; then
    L=$(date -u -d "$(cat /tmp/launch-time.txt)" +%s || true)
    break
  fi
  sleep 5
done
NOW=$(date +%s)
if ! [[ "$L" =~ ^[0-9]+$ ]] || [ "$L" -gt "$NOW" ] || [ $(( NOW - L )) -gt 900 ]; then
  echo "LaunchTime was ${L:-not read} at $NOW"; exit 1
fi
( sleep $(( L + 3720 - $(date +%s) > 0 ? L + 3720 - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + 300 )); HE=$(( L + 3600 )); EV=$(( L + 3660 ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > "$R/preflight-nvidia-smi.csv" || exit 1
upload "$R/preflight-nvidia-smi.csv" preflight-nvidia-smi.csv
[ "$(tail -n +2 "$R/preflight-nvidia-smi.csv" | wc -l)" = 1 ] && ! tail -n +2 "$R/preflight-nvidia-smi.csv" | grep -qv A10G || { echo "PREFLIGHT FAILED: not 1 A10G"; exit 1; }
{ nvidia-smi; nvidia-smi -q; } > "$R/nvidia-smi.txt" 2>&1
df -BG / > "$R/df-before.txt"
free_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "${free_gb:-0}" -ge 60 ] || { echo "PREFLIGHT FAILED: ${free_gb:-?} GB free on /"; exit 1; }
cat > /tmp/python.sh <<'PY'
set -euo pipefail
# What the AMI has, recorded before anything is installed.
{ command -v python3.12 || echo "no python3.12 on PATH"; command -v python || echo "no python on PATH"; python3 --version || true; command -v huggingface-cli hf || true; } > /opt/kit/run/ami-python.txt 2>&1
cd /opt/kit
curl -fsSL -o uv.tgz "https://github.com/astral-sh/uv/releases/download/0.12.22/uv-x86_64-unknown-linux-gnu.tar.gz"
echo "b9980552309f09c15172b8be828555e375097f16deb459795ce7bfd200380f0b  uv.tgz" | sha256sum -c -
tar -xzf uv.tgz
export UV_PYTHON_INSTALL_DIR=/opt/kit/python
./uv-x86_64-unknown-linux-gnu/uv python install cpython-3.12.15-linux-x86_64-gnu
py=$(./uv-x86_64-unknown-linux-gnu/uv python find --no-project --managed-python cpython-3.12.15-linux-x86_64-gnu)
ln -sf "$py" /opt/kit/bin/python
ln -sf "$py" /opt/kit/bin/python3.12
# A kit may build its own venv with uv, so the pinned uv is on its PATH too.
ln -sf /opt/kit/uv-x86_64-unknown-linux-gnu/uv /opt/kit/bin/uv
{ echo "uv=$(./uv-x86_64-unknown-linux-gnu/uv --version)"; echo "python=$py"; /opt/kit/bin/python --version; } > /opt/kit/run/python-provenance.txt 2>&1
PY
bringup_left=$(( P1 - $(date +%s) ))
bringup_rc=124
if [ "$bringup_left" -gt 0 ]; then
  timeout --kill-after=15 "$bringup_left" bash /tmp/python.sh
  bringup_rc=$?
fi
echo "bring-up exited $bringup_rc"
{ echo "commit=06b8b59d1135ed789d9f187a5827b16c0cbb42f2"; echo "launch_time_epoch=$L"; echo "bringup_rc=$bringup_rc"; sha256sum /opt/kit/inputs.tgz; } > "$R/instance-provenance.txt"
if [ "$bringup_rc" = 0 ]; then
  # A Spot reclaim gives two minutes, so the records are copied out every cycle.
  # A cycle is the archive, an upload of up to 60 s and PARTIAL_SYNC_S of sleep, so a reclaim can lose up to one cycle's records.
  ( while :; do
      nice -n 19 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /opt/kit run >>/var/log/gpukit-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/gpukit-sync.log 2>&1
      sleep 60
    done ) &
  sync_pid=$!
  # Memory and the kernel's overcommit policy, since a load that maps one large checkpoint file depends on both.
  mem() { date -u +%Y-%m-%dT%H:%M:%SZ; free -m; swapon --show; echo "overcommit_memory=$(cat /proc/sys/vm/overcommit_memory) overcommit_ratio=$(cat /proc/sys/vm/overcommit_ratio)"; grep -E '^(MemTotal|MemAvailable|CommitLimit|Committed_AS):' /proc/meminfo; }
  mem > "$R/memory-before-kit.txt" 2>&1
  # run.sh cannot be touched, so the snapshot before its loads is taken when its status shows the last test step done.
  # The watcher polls every 2 s, and also samples memory every 30 s into memory.log.
  ( n=0; while :; do
      if [ ! -e "$R/memory-before-loads.txt" ] && grep -q '^test-files-fix ' "$R/results/status.txt" 2>/dev/null; then mem > "$R/memory-before-loads.txt" 2>&1; fi
      [ $(( n % 15 )) = 0 ] && { mem; echo; } >> "$R/memory.log" 2>&1
      n=$(( n + 1 )); sleep 2
    done ) &
  mem_pid=$!
  date -u +%Y-%m-%dT%H:%M:%SZ > "$R/kit-start.txt"
  cd /opt/kit/work
  # The kit runs unmodified; the timeout only stops one that overran its phase from eating the upload.
  env HOME=/root PATH="/opt/kit/bin:$PATH" UV_PYTHON_INSTALL_DIR=/opt/kit/python OUT="$R/results" \
    timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) bash /opt/kit/in/kit/run.sh > "$R/run-output.log" 2>&1
  kit_rc=$?
  date -u +%Y-%m-%dT%H:%M:%SZ > "$R/kit-end.txt"
  echo "kit_rc=$kit_rc" >> "$R/instance-provenance.txt"
  df -BG / > "$R/df-after.txt"
  kill "$sync_pid" "$mem_pid"
  cp /var/log/gpukit-sync.log "$R/sync.log"
  echo "run.sh exited $kit_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); the kit did not run" | tee "$R/VOID"
fi
cp /var/log/gpukit.log "$R/instance.log"
# The archive and its upload share the evidence phase, and each step gets only the time still left in it.
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
timeout "$left" tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /opt/kit run
tar_rc=$?
evidence=failed
# A failed upload is retried until the phase ends, since DONE ends the instance and its disk with it.
while [ "$tar_rc" -le 1 ]; do
  left=$(( EV - $(date +%s) )); [ "$left" -gt 0 ] || break
  timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz" && { evidence=uploaded; break; }
  sleep 5
done
echo "evidence_upload=$evidence tar_rc=$tar_rc"
upload /var/log/gpukit.log log.txt
echo "cc97f149 evidence=$evidence" > /tmp/DONE
upload /tmp/DONE DONE
