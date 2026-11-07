#!/usr/bin/env bash
#
# The free rehearsal of the Slurm on EC2 session: the same user-data, rendered by hack/lib/slurm-ec2.sh, run in three
# local systemd containers named head, gpu1 and gpu2, against an S3 stub, then scored by the session's scorer.
#
#   bash hack/slurm-ec2-rehearsal.sh            # about 20 minutes; KEEP=1 keeps the containers
#
# What differs from EC2, and each is set only by SLURMEC2_REHEARSAL=1 in the instance side's environment:
# - no GPU: /dev/nvidia0 is a device node with no driver behind it and nvidia-smi a stand-in naming one A10G, so B1a
#   cannot hold and B1b is INVALID; the trainer runs on the CPU;
# - no NFS: /shared is one Docker volume the three containers mount, because this host has no nfsd module;
# - no shutdown, and S3 is a directory.
# Everything else, from the archive's Slurm packages to accounting, configless slurmd, cgroup v2 confinement, the
# health check, the drain and the requeue, runs as it would on the instances.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="${OUT:-hack/slurm-ec2-rehearsal-$(date -u +%Y%m%dT%H%M%SZ)}"
IMAGE=slurmec2-rehearsal:1
NET=slurmec2-rh
VOL=slurmec2-rh-shared
STOP_S=5700
PREFIX=rehearsal
# The rehearsal waits for DONE until T0 plus the evidence deadline and a margin.
WAIT_S=5640

say() { echo "== $(date -u +%H:%M:%S) $*" | tee -a "$OUT/rehearsal.log"; }
fail() { echo "REHEARSAL FAILED: $*" | tee -a "$OUT/rehearsal.log" >&2; exit 1; }

[ -z "$(git status --porcelain -- hack docs experiments)" ] || { echo "the tree under hack, docs or experiments is dirty; the rehearsal runs a commit"; exit 1; }
[ ! -e "$OUT" ] || { echo "$OUT exists"; exit 1; }
mkdir -p "$OUT/fakes3/$PREFIX/src"
FAKES3=$(cd "$OUT/fakes3" && pwd)
PIPCACHE=${SLURMEC2_PIP_CACHE:-$HOME/.cache/slurmec2-rehearsal-pip}
mkdir -p "$PIPCACHE"
say "rehearsal of $(git rev-parse HEAD) into $OUT"

for c in head gpu1 gpu2; do
  docker container inspect "$c" >/dev/null 2>>"$OUT/docker.err" && fail "a container named $c already exists; remove it first"
done

cleanup() {
  [ "${KEEP:-0}" = 1 ] && { say "KEEP=1: containers head gpu1 gpu2, network $NET and volume $VOL are left"; return; }
  docker rm -f head gpu1 gpu2 >>"$OUT/docker.log" 2>&1
  docker network rm "$NET" >>"$OUT/docker.log" 2>&1
  docker volume rm "$VOL" >>"$OUT/docker.log" 2>&1
}
trap cleanup EXIT

docker build -q -t "$IMAGE" hack/test/slurm-ec2 >>"$OUT/docker.log" 2>&1 || fail "image build; see $OUT/docker.log"
docker network create "$NET" >>"$OUT/docker.log" 2>&1 || fail "network $NET"
docker volume create "$VOL" >>"$OUT/docker.log" 2>&1 || fail "volume $VOL"
for c in head gpu1 gpu2; do
  extra=()
  [ "$c" = head ] && extra=(-v "$PIPCACHE:/root/.cache/pip")
  docker run -d --name "$c" --hostname "$c" --network "$NET" --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock -v "$VOL:/shared" -v "$FAKES3:/fakes3" "${extra[@]}" "$IMAGE" >>"$OUT/docker.log" 2>&1 ||
    fail "start $c"
done

git archive --format=tar.gz -o "$FAKES3/$PREFIX/src/source.tgz" HEAD || fail "git archive"
SOURCE_SHA=$(sha256sum "$FAKES3/$PREFIX/src/source.tgz" | cut -d' ' -f1)
dd if=/dev/urandom of="$FAKES3/$PREFIX/munge.key" bs=1024 count=1 status=none
# shellcheck source=hack/lib/slurm-ec2.sh
. hack/lib/slurm-ec2.sh
for c in head gpu1 gpu2; do
  slurmec2_render_userdata "$c" "$OUT/user-data-$c.sh" rehearsal-bucket "$PREFIX" "$SOURCE_SHA" "$STOP_S" || fail "render $c"
  docker cp "$OUT/user-data-$c.sh" "$c:/user-data.sh" >>"$OUT/docker.log" 2>&1 || fail "copy user-data to $c"
done
ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$1"; }
T0=$(date +%s)
printf 'T0=%s\nHEAD_IP=%s\nGPU1_IP=%s\nGPU2_IP=%s\n' "$T0" "$(ip head)" "$(ip gpu1)" "$(ip gpu2)" >"$FAKES3/$PREFIX/cluster.env"
cp "$FAKES3/$PREFIX/cluster.env" "$OUT/cluster.env"
for c in head gpu1 gpu2; do
  docker exec -d -e SLURMEC2_REHEARSAL=1 "$c" bash /user-data.sh || fail "start the user-data on $c"
done
say "user-data running on head, gpu1 and gpu2; T0=$T0"

deadline=$(( T0 + WAIT_S ))
while [ ! -s "$FAKES3/$PREFIX/DONE" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || fail "no DONE by T0 + $WAIT_S s"
  for c in gpu1 gpu2; do
    [ -s "$FAKES3/$PREFIX/stopped-$c" ] && say "$c stopped: $(cat "$FAKES3/$PREFIX/stopped-$c")"
  done
  sleep 15
done
say "DONE: $(cat "$FAKES3/$PREFIX/DONE")"
cp "$FAKES3/$PREFIX/DONE" "$OUT/DONE"
for k in log-head.txt log-gpu1.txt log-gpu2.txt; do cp "$FAKES3/$PREFIX/$k" "$OUT/" 2>>"$OUT/copy-errors.txt"; done
tar -xzf "$FAKES3/$PREFIX/evidence.tgz" -C "$OUT" || fail "the evidence archive did not unpack"
python3 hack/slurm-ec2/score.py "$OUT/evidence" "$OUT/verdict.json" | tee "$OUT/verdict.txt"
[ "${PIPESTATUS[0]}" = 0 ] || fail "the scorer failed"
rm -rf "$FAKES3"
python3 hack/slurm-ec2/check_rehearsal.py "$OUT/verdict.json" | tee "$OUT/rehearsal-check.txt"
exit "${PIPESTATUS[0]}"
