#!/bin/bash
exec > >(tee /var/log/tp.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep 4500; shutdown -h now ) &
BUCKET="tpot-gpu-007635145730"
PREFIX="vllm-tpot-20261118T140948Z-40e430b9"
COMMIT="9114dea19e530dd6e2bdd16a94e4e356488b6732"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/tp.log log.txt; shutdown -h now' EXIT
mkdir -p /src/tp-run /opt/tp || exit 1
# The input is fetched and checked against the hash this session computed, so the instance runs only what was built here.
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/inputs.tgz" /opt/tp/inputs.tgz || exit 1
[ "$(sha256sum /opt/tp/inputs.tgz | cut -d' ' -f1)" = "193d99e4dda65a6b61e7f99f44c396649b92ad7c1ad18f1f2523304f7e14cbc6" ] || { echo "checksum mismatch for inputs.tgz"; exit 1; }
mkdir -p /opt/tp/in && tar -xzf /opt/tp/inputs.tgz -C /opt/tp/in || exit 1
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
( sleep $(( L + 4500 - $(date +%s) > 0 ? L + 4500 - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + 600 )); HE=$(( L + 4320 )); EV=$(( L + 4440 ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -q A10G || { echo "PREFLIGHT FAILED: not one A10G"; exit 1; }
# The pinned image is CUDA 13.2 with vLLM's compatibility mode off, which needs a 580 or newer driver; an older one would
# only show after the 11 GB pull.
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
  sha256sum /opt/tp/inputs.tgz
} > /src/tp-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/tp-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/tp-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/tp-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  # An authenticated pull gets ECR Public's higher limits; a failed login is recorded and the pull goes on anonymously.
  { aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws; } \
    > /src/tp-run/ecr-login.txt 2>&1 || echo "ECR Public login failed; the pull runs anonymously" >> /src/tp-run/ecr-login.txt
  mkdir -p /src/tp-run/sweep
  # A Spot reclaim gives two minutes, so the records leave the instance within PARTIAL_SYNC_S of being written.
  # One archive overwritten in place needs only the role's s3:PutObject; a sync would also need s3:ListBucket.
  # GNU tar exits 1 when a file grew while it was read, which a running pytest log does, so 1 still uploads.
  ( while :; do
      nice -n 19 ionice -c3 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /src/tp-run sweep >>/var/log/tp-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 nice -n 19 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/tp-sync.log 2>&1
      sleep 30
    done ) &
  sync_pid=$!
  # The runner's own bounds sum to HE; this timeout only stops a runner that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) bash /opt/tp/in/runner.sh /opt/tp/in /src/tp-run/sweep "$HE" \
    > /src/tp-run/summary.txt 2>&1
  harness_rc=$?
  kill "$sync_pid" 2>>/var/log/tp-sync.log
  cp /var/log/tp-sync.log /src/tp-run/sync.log
  cat /src/tp-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/tp-run/instance-provenance.txt
  echo "the runner exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/tp-run/VOID
fi
cp /var/log/tp.log /src/tp-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src tp-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/tp.log log.txt
echo "40e430b9" > /tmp/DONE
upload /tmp/DONE DONE
