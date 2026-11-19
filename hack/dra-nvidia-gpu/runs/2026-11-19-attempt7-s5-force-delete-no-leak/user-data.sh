#!/bin/bash
( sleep 4620; shutdown -h now ) >/dev/null 2>&1 &
# The line above is the first thing the instance runs, so no failure below can leave it running past the stop.
# It counts from the instance's own start; LaunchTime precedes that, so the precise backstop armed below fires first.
exec > >(tee /var/log/dra.log) 2>&1
set -x
SR_START=$(date +%s)
BUCKET="dra-gpu-007635145730"
PREFIX="dra-nvidia-gpu-20261119T141426Z-4816f6b9"
upload() { timeout 60 aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/dra.log log.txt; shutdown -h now' EXIT
mkdir -p /opt/dra/in /src/dra-run || exit 1
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/inputs.tgz" /opt/dra/inputs.tgz || exit 1
[ "$(sha256sum /opt/dra/inputs.tgz | cut -d' ' -f1)" = "439475ce6683b9b110b08a092a48f8289bae0d8f0f4e1f3a8a90c0e8ca70f15e" ] || { echo "checksum mismatch for inputs.tgz"; exit 1; }
tar -xzf /opt/dra/inputs.tgz -C /opt/dra/in || exit 1
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
( sleep $(( L + 4620 - $(date +%s) > 0 ? L + 4620 - $(date +%s) : 1 )); shutdown -h now ) >/dev/null 2>&1 &
BOOT_END=$(( L + 420 )); HE=$(( L + 4440 )); EV=$(( L + 4560 ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version,compute_mode --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -qE 'NVIDIA (L4|A10G),' ||
  { echo "PREFLIGHT FAILED: not one L4 or A10G"; exit 1; }
cp /tmp/nvidia-smi.csv /src/dra-run/nvidia-smi.csv
{ echo "launch_time_epoch=$L"; sha256sum /opt/dra/inputs.tgz; } > /src/dra-run/instance-provenance.txt
if [ "$(date +%s)" -lt "$BOOT_END" ]; then
  # The phases' bounds sum to HE; this timeout only stops a runner that overran them from eating the upload.
  UPLOAD_PREFIX="s3://$BUCKET/$PREFIX" timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) \
    bash /opt/dra/in/runner.sh /opt/dra/in /src/dra-run/run "$HE" > /src/dra-run/summary.txt 2>&1
  echo "harness_rc=$?" >> /src/dra-run/instance-provenance.txt
  cat /src/dra-run/summary.txt
else
  echo "the boot ran past its phase; nothing else runs" | tee /src/dra-run/VOID
fi
cp /var/log/dra.log /src/dra-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src dra-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/dra.log log.txt
echo "4816f6b9" > /tmp/DONE
upload /tmp/DONE DONE
