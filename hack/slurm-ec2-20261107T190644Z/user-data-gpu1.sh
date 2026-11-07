#!/bin/bash
exec > >(tee -a /var/log/slurmec2.log) 2>&1
export ROLE=gpu1 BUCKET=slurmec2-007635145730 PREFIX=slurm-ec2-20261107T190644Z-5c9cec57 STOP_S=5700
export BOOT=$(date +%s)
( sleep 6600; [ "${SLURMEC2_REHEARSAL:-0}${SLURMEC2_NO_SHUTDOWN:-0}" = 00 ] && shutdown -h now ) &
trap 'timeout 60 aws s3 cp --only-show-errors /var/log/slurmec2.log "s3://$BUCKET/$PREFIX/log-$ROLE.txt"; [ "${SLURMEC2_REHEARSAL:-0}${SLURMEC2_NO_SHUTDOWN:-0}" = 00 ] && shutdown -h now' EXIT
# The Canonical AMI head runs on has no AWS CLI; the Deep Learning AMI the workers run on has one.
if ! command -v aws >/dev/null; then
  # snapd refuses installs until its first-boot seeding is done.
  snap wait system seed.loaded
  for i in 1 2 3; do snap install aws-cli --classic && break; sleep 10; done
  # cloud-init's PATH does not carry snap's bin directory, and every later aws call, instance.sh's included, needs it.
  export PATH=$PATH:/snap/bin
fi
command -v aws >/dev/null || { echo "no aws cli"; exit 1; }
for i in $(seq 1 30); do aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz && break; sleep 5; done
[ "$(sha256sum /tmp/source.tgz | cut -d' ' -f1)" = "356219382f6c8b698b48f792085a37895b518748fbbb65dd0c6f38bae5895c8b" ] || { echo "source checksum mismatch"; exit 1; }
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src || exit 1
bash /src/hack/slurm-ec2/instance.sh
echo "instance.sh exited $?"
