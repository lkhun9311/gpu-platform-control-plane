#!/bin/bash
exec > >(tee /var/log/ap.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep 4040; shutdown -h now ) &
BUCKET="ap67811-gpu-007635145730"
PREFIX="vllm-67811-20261118T031025Z-218aaea8"
COMMIT="672fac4800efab39159736b83fe2a84e82c8bfbc"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/ap.log log.txt; shutdown -h now' EXIT
mkdir -p /src/ap-run /opt/ap || exit 1
# Each input is fetched and checked against the hash this session computed, so the instance runs only what was built and fetched here.
fetch() {
  aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/$1" "/opt/ap/$1" || exit 1
  [ "$(sha256sum "/opt/ap/$1" | cut -d' ' -f1)" = "$2" ] || { echo "checksum mismatch for $1"; exit 1; }
}
fetch inputs.tgz 656e3583b63db09243a506345065ad1070d49e185f339ea42e5636bb8f040197
mkdir -p /opt/ap/in && tar -xzf /opt/ap/inputs.tgz -C /opt/ap/in || exit 1
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
( sleep $(( L + 4040 - $(date +%s) > 0 ? L + 4040 - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + 600 )); HE=$(( L + 3860 )); EV=$(( L + 3980 ))
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
  sha256sum /opt/ap/inputs.tgz
} > /src/ap-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/ap-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/ap-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/ap-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  # An authenticated pull gets ECR Public's higher limits; a failed login is recorded and the pull goes on anonymously.
  { aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws; } \
    > /src/ap-run/ecr-login.txt 2>&1 || echo "ECR Public login failed; the pull runs anonymously" >> /src/ap-run/ecr-login.txt
  mkdir -p /src/ap-run/sweep
  # A Spot reclaim gives two minutes, so each arm's records leave the instance within PARTIAL_SYNC_S of being written.
  # One archive overwritten in place needs only the role's s3:PutObject; a sync would also need s3:ListBucket.
  # GNU tar exits 1 when a file grew while it was read, which the live replay rows always do, so 1 still uploads.
  # The copy runs at the lowest CPU and I/O priority, beside the replay client it shares the host with.
  # Each upload is bounded, so a stalled one cannot stop every later copy.
  ( while :; do
      nice -n 19 ionice -c3 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /src/ap-run sweep >>/var/log/ap-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 nice -n 19 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/ap-sync.log 2>&1
      sleep 30
    done ) &
  sync_pid=$!
  # The runner's own bounds sum to HE; this timeout only stops a runner that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) bash /opt/ap/in/runner.sh /opt/ap/in /src/ap-run/sweep "$HE" \
    > /src/ap-run/summary.txt 2>&1
  harness_rc=$?
  kill "$sync_pid" 2>>/var/log/ap-sync.log
  cp /var/log/ap-sync.log /src/ap-run/sync.log
  cat /src/ap-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/ap-run/instance-provenance.txt
  echo "the runner exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/ap-run/VOID
fi
cp /var/log/ap.log /src/ap-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
# A benchmark the runner's timeout orphaned can still be writing, which makes tar exit 1 with a usable archive.
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src ap-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/ap.log log.txt
echo "218aaea8" > /tmp/DONE
upload /tmp/DONE DONE
