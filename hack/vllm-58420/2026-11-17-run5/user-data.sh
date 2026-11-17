#!/bin/bash
exec > >(tee /var/log/srpf.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep 11340; shutdown -h now ) &
BUCKET="srpf58420-gpu-007635145730"
PREFIX="vllm-58420-20261117T003012Z-10699ea5"
COMMIT="55d2d27fce0fa0d9dd37cdffef03c4ab6c2351dd"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/srpf.log log.txt; shutdown -h now' EXIT
mkdir -p /src/sr-run /opt/sr || exit 1
# Each input is fetched and checked against the hash this session computed, so the instance runs only what was built and fetched here.
fetch() {
  aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/$1" "/opt/sr/$1" || exit 1
  [ "$(sha256sum "/opt/sr/$1" | cut -d' ' -f1)" = "$2" ] || { echo "checksum mismatch for $1"; exit 1; }
}
fetch benchharness 2cd38cffba74609ce3bdb0aece2e63bfff123d505a57c20d024aeaaa0ff12022
fetch scheduler.py 19502766a57a37432cda1ac0a581979d22845cc0fe2d5f08be8647ca113d2fa9
fetch trace-off-3.jsonl 4360cb83f7c2259040c8ccda45b881a8b817a5087f968334630f26aa12d68167
fetch manifest-off-3.yaml 3a6ff64c2a45dcd0edc7b7e754f9431382bd0f4854bb5308c734560fe6ea67a0
chmod +x /opt/sr/benchharness
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
( sleep $(( L + 11340 - $(date +%s) > 0 ? L + 11340 - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + 600 )); HE=$(( L + 11160 )); EV=$(( L + 11280 ))
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
  sha256sum /opt/sr/benchharness /opt/sr/scheduler.py /opt/sr/trace-off-3.jsonl /opt/sr/manifest-off-3.yaml
} > /src/sr-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/sr-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/sr-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/sr-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  # An authenticated pull gets ECR Public's higher limits; a failed login is recorded and the pull goes on anonymously.
  { aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws; } \
    > /src/sr-run/ecr-login.txt 2>&1 || echo "ECR Public login failed; the pull runs anonymously" >> /src/sr-run/ecr-login.txt
  mkdir -p /src/sr-run/sweep
  # A Spot reclaim gives two minutes, so each arm's records leave the instance within PARTIAL_SYNC_S of being written.
  # One archive overwritten in place needs only the role's s3:PutObject; a sync would also need s3:ListBucket.
  # GNU tar exits 1 when a file grew while it was read, which the live replay rows always do, so 1 still uploads.
  # The copy runs at the lowest CPU and I/O priority, beside the replay client it shares the host with.
  # Each upload is bounded, so a stalled one cannot stop every later copy.
  ( while :; do
      nice -n 19 ionice -c3 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /src/sr-run sweep >>/var/log/srpf-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 nice -n 19 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/srpf-sync.log 2>&1
      sleep 30
    done ) &
  sync_pid=$!
  # The harness's own bounds sum to HE; this timeout only stops a harness that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) /opt/sr/benchharness srpf-sweep \
    -dir /src/sr-run/sweep -hf-cache /opt/sr/hf -compile-cache /opt/sr/compile -overlay /opt/sr/scheduler.py \
    -trace /opt/sr/trace-off-3.jsonl -archived-manifest /opt/sr/manifest-off-3.yaml > /src/sr-run/summary.txt 2>&1
  harness_rc=$?
  kill "$sync_pid" 2>>/var/log/srpf-sync.log
  cp /var/log/srpf-sync.log /src/sr-run/sync.log
  cat /src/sr-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/sr-run/instance-provenance.txt
  echo "the sweep exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/sr-run/VOID
fi
cp /var/log/srpf.log /src/sr-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
# A replay the harness's timeout orphaned can still be writing its rows, which makes tar exit 1 with a usable archive.
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src sr-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/srpf.log log.txt
echo "10699ea5" > /tmp/DONE
upload /tmp/DONE DONE
