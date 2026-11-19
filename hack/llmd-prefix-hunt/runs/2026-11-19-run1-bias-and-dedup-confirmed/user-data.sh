#!/bin/bash
exec > >(tee /var/log/hunt.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it, so the precise one below, armed once LaunchTime is read, always fires first.
( sleep 3840; shutdown -h now ) &
BUCKET="llmd-hunt-007635145730"
PREFIX="20261119T144026Z-76175127"
COMMIT="a528156237bd58a578e055ef54582c190e9c8006"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/hunt.log log.txt; shutdown -h now' EXIT
mkdir -p /src/hunt-run /opt/hunt || exit 1
# The input is fetched and checked against the hash this session computed, so the instance runs only what was built here.
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/inputs.tgz" /opt/hunt/inputs.tgz || exit 1
[ "$(sha256sum /opt/hunt/inputs.tgz | cut -d' ' -f1)" = "c0e374ec9a63b7e60668cf60ac3340dc57bb6b507c573e3268719aad9b2d42dd" ] || { echo "checksum mismatch for inputs.tgz"; exit 1; }
mkdir -p /opt/hunt/in && tar -xzf /opt/hunt/inputs.tgz -C /opt/hunt/in || exit 1
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
( sleep $(( L + 3840 - $(date +%s) > 0 ? L + 3840 - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + 240 )); HE=$(( L + 3720 )); EV=$(( L + 3780 ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -q A10G || { echo "PREFLIGHT FAILED: not one A10G"; exit 1; }
# The pinned image is CUDA 13.0 with vLLM's compatibility mode off (VLLM_ENABLE_CUDA_COMPATIBILITY=0 in its config), which needs a 580 or newer driver; an older one would only show after the 10 GB pull.
drv=$(tail -n +2 /tmp/nvidia-smi.csv | awk -F', ' '{print $4}' | cut -d. -f1)
[[ "$drv" =~ ^[0-9]+$ ]] && [ "$drv" -ge 580 ] || { echo "PREFLIGHT FAILED: driver ${drv:-unread} is older than 580"; exit 1; }
cat > /tmp/bringup.sh <<'BRINGUP'
export DEBIAN_FRONTEND=noninteractive
if ! command -v nvidia-ctk >/dev/null; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit || exit 1
fi
nvidia-ctk runtime configure --runtime=docker --set-as-default
sed -i 's/^#accept-nvidia-visible-devices-as-volume-mounts.*/accept-nvidia-visible-devices-as-volume-mounts = true/' \
  /etc/nvidia-container-runtime/config.toml || true
grep -q 'accept-nvidia-visible-devices-as-volume-mounts = true' /etc/nvidia-container-runtime/config.toml \
  || echo 'accept-nvidia-visible-devices-as-volume-mounts = true' >> /etc/nvidia-container-runtime/config.toml
systemctl restart docker
sleep 5
systemctl is-active --quiet docker || { echo "BRINGUP FAILED: docker is not running"; exit 1; }
docker info --format "{{json .Runtimes}}" | grep -q nvidia || { echo "BRINGUP FAILED: docker has no nvidia runtime"; exit 1; }
BRINGUP
bringup_left=$(( P1 - $(date +%s) ))
bringup_rc=124
if [ "$bringup_left" -gt 0 ]; then
  timeout --kill-after=15 "$bringup_left" bash /tmp/bringup.sh
  bringup_rc=$?
fi
echo "bring-up exited $bringup_rc"
{
  echo "commit=$COMMIT"
  echo "launch_time_epoch=$L"
  echo "bringup_rc=$bringup_rc"
  sha256sum /opt/hunt/inputs.tgz
} > /src/hunt-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/hunt-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/hunt-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/hunt-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  mkdir -p /src/hunt-run/sweep
  # A Spot reclaim gives two minutes, so the records leave the instance within PARTIAL_SYNC_S of being written.
  # One archive overwritten in place needs only the role's s3:PutObject; a sync would also need s3:ListBucket.
  # GNU tar exits 1 when a file grew while it was read, which the probe's running records do, so 1 still uploads.
  ( while :; do
      nice -n 19 ionice -c3 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /src/hunt-run sweep >>/var/log/hunt-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 nice -n 19 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/hunt-sync.log 2>&1
      sleep 30
    done ) &
  sync_pid=$!
  # The runner's own bounds sum to HE; this timeout only stops a runner that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) bash /opt/hunt/in/runner.sh /opt/hunt/in /src/hunt-run/sweep "$HE" \
    > /src/hunt-run/summary.txt 2>&1
  harness_rc=$?
  kill "$sync_pid" 2>>/var/log/hunt-sync.log
  cp /var/log/hunt-sync.log /src/hunt-run/sync.log
  cat /src/hunt-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/hunt-run/instance-provenance.txt
  echo "the runner exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/hunt-run/VOID
fi
cp /var/log/hunt.log /src/hunt-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src hunt-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/hunt.log log.txt
echo "76175127" > /tmp/DONE
upload /tmp/DONE DONE
