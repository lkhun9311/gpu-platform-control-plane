# shellcheck shell=bash
# The user-data of the Slurm on EC2 session, rendered for one role.
#
# hack/slurm-ec2-session.sh uses it for the three instances it buys and hack/slurm-ec2-rehearsal.sh for the three
# containers it starts, so the rehearsal runs the same user-data, byte for byte apart from the run's identifiers.
# Like hack/lib/spot-run.sh it never calls `set`, never `cd`s and installs no traps.

# slurmec2_render_userdata ROLE FILE BUCKET PREFIX SOURCE_SHA STOP_S
#
# The user-data arms a shutdown at its own boot plus STOP_S before anything can fail, fetches the source archive the
# runner uploaded, checks it, and runs hack/slurm-ec2/instance.sh as ROLE. On exit it uploads its log and shuts the
# instance down, which terminates it (instance-initiated-shutdown-behavior=terminate); the rehearsal, which marks itself
# with SLURMEC2_REHEARSAL=1 in the environment it runs this with, does not shut its container down.
slurmec2_render_userdata() {
  local role="$1" file="$2" bucket="$3" prefix="$4" source_sha="$5" stop_s="$6"
  case "$role" in head|gpu1|gpu2) ;; *) printf 'slurmec2_render_userdata: role %s\n' "$role" >&2; return 1 ;; esac
  # Every value is written into the script unquoted, so each must be one shell word with no metacharacter.
  [[ "$stop_s" =~ ^[0-9]+$ ]] && [[ "$source_sha" =~ ^[0-9a-f]{64}$ ]] && [[ "$bucket" =~ ^[a-z0-9.-]+$ ]] &&
    [[ "$prefix" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'slurmec2_render_userdata: bad arguments\n' >&2
    return 1
  }
  cat >"$file" <<EOF
#!/bin/bash
exec > >(tee -a /var/log/slurmec2.log) 2>&1
export ROLE=$role BUCKET=$bucket PREFIX=$prefix STOP_S=$stop_s
export BOOT=\$(date +%s)
( sleep $stop_s; [ "\${SLURMEC2_REHEARSAL:-0}" = 1 ] || shutdown -h now ) &
trap 'aws s3 cp --only-show-errors /var/log/slurmec2.log "s3://\$BUCKET/\$PREFIX/log-\$ROLE.txt"; [ "\${SLURMEC2_REHEARSAL:-0}" = 1 ] || shutdown -h now' EXIT
# The Canonical AMI head runs on has no AWS CLI; the Deep Learning AMI the workers run on has one.
if ! command -v aws >/dev/null; then
  # snapd refuses installs until its first-boot seeding is done.
  snap wait system seed.loaded
  for i in 1 2 3; do snap install aws-cli --classic && break; sleep 10; done
  # cloud-init's PATH does not carry snap's bin directory, and every later aws call, instance.sh's included, needs it.
  export PATH=\$PATH:/snap/bin
fi
command -v aws >/dev/null || { echo "no aws cli"; exit 1; }
for i in \$(seq 1 30); do aws s3 cp --only-show-errors "s3://\$BUCKET/\$PREFIX/src/source.tgz" /tmp/source.tgz && break; sleep 5; done
[ "\$(sha256sum /tmp/source.tgz | cut -d' ' -f1)" = "$source_sha" ] || { echo "source checksum mismatch"; exit 1; }
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src || exit 1
bash /src/hack/slurm-ec2/instance.sh
echo "instance.sh exited \$?"
EOF
}
