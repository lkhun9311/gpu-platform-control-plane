#!/bin/bash
exec > >(tee /var/log/verready.log) 2>&1
set -x
VR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep 9930; shutdown -h now ) &
BUCKET="verready-gpu-007635145730"
PREFIX="version-readiness-20261116T110818Z-e78b920f"
HARNESS_SHA="2768b744f27b51e88fcbeb23a5bda983334f24272cb9d1ac14d78e070822668e"
COMMIT="197e7362872f27923adddf97ccd7652ccc99e34a"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/verready.log log.txt; shutdown -h now' EXIT
mkdir -p /src/vr-run /opt/vr || exit 1
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/benchharness" /opt/vr/benchharness || exit 1
[ "$(sha256sum /opt/vr/benchharness | cut -d' ' -f1)" = "$HARNESS_SHA" ] || { echo "harness checksum mismatch"; exit 1; }
chmod +x /opt/vr/benchharness
L=""
while [ $(( $(date +%s) - VR_START )) -lt 180 ]; do
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
( sleep $(( L + 9930 - $(date +%s) > 0 ? L + 9930 - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + 600 )); HE=$(( L + 9750 )); EV=$(( L + 9870 ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -q A10G || { echo "PREFLIGHT FAILED: not one A10G"; exit 1; }
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
  echo "harness_sha256=$HARNESS_SHA"
} > /src/vr-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/vr-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/vr-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/vr-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  mkdir -p /src/vr-run/readiness
  # A Spot reclaim gives two minutes and the 2026-11-16 run 3 lost everything, so each start's record leaves the
  # instance within PARTIAL_SYNC_S of being written, not only in the final archive.
  # One archive overwritten in place needs only the role's s3:PutObject; a sync would also need s3:ListBucket.
  ( while :; do
      tar -czf /tmp/partial.tgz -C /src/vr-run readiness >>/var/log/verready-sync.log 2>&1 &&
        aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/verready-sync.log 2>&1
      sleep 30
    done ) &
  sync_pid=$!
  # The harness's own bounds sum to HE; this timeout only stops a harness that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) /opt/vr/benchharness version-readiness \
    -dir /src/vr-run/readiness -hf-cache /opt/vr/hf -compile-cache /opt/vr/compile > /src/vr-run/summary.txt
  harness_rc=$?
  kill "$sync_pid" 2>>/var/log/verready-sync.log
  cp /var/log/verready-sync.log /src/vr-run/sync.log
  cat /src/vr-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/vr-run/instance-provenance.txt
  echo "the readiness harness exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/vr-run/VOID
fi
cp /var/log/verready.log /src/vr-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar -czf /tmp/evidence.tgz -C /src vr-run && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/verready.log log.txt
echo "e78b920f" > /tmp/DONE
upload /tmp/DONE DONE
