# shellcheck shell=bash
# Helpers shared by hack/slurm-ec2/instance.sh and hack/slurm-ec2/procedure.sh, on the instances.
# docs/superpowers/specs/2026-11-07-slurm-ec2-session-design.md is the registration they implement.
#
# Inputs from the user-data's environment: ROLE, BUCKET, PREFIX, and, once cluster.env is read, T0 and the addresses.
# SLURMEC2_REHEARSAL=1 marks the local container rehearsal (hack/slurm-ec2-rehearsal.sh); every place it changes
# behaviour says so beside it.

# The exact packages the registration names; a different archive version fails the install, not the measurement.
SLURM_PKG_VERSION=23.11.4-1.2ubuntu5
MUNGE_PKG_VERSION=0.5.15-4ubuntu0.1
MARIADB_PKG_VERSION=1:10.11.14-0ubuntu0.24.04.1
TORCH_VERSION=2.5.1

# Offsets from T0, in seconds, as the registration's clock table gives them.
BRINGUP_END_S=1500
CHECKS_END_S=5400
EVIDENCE_S=5580

SHARED=/shared
EVID=$SHARED/evidence
TENANT=tenant
TENANT_UID=2001
# The packages create their service users with whatever ids are free, which differ between the Canonical and the
# Deep Learning images; Slurm needs the same SlurmUser everywhere, so the user is made first, with fixed ids.
SLURM_UID=1601
MUNGE_UID=1602

log() { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "${ROLE:-?}" "$*"; }

# s3get KEY FILE and s3put FILE KEY move one object within the run's prefix; neither retries, the callers do.
s3get() { aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/$1" "$2"; }
s3put() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2"; }

# left END: seconds from now until the epoch END, never below 1: GNU timeout reads 0 as no limit at all.
left() { local l=$(( $1 - $(date +%s) )); [ "$l" -gt 1 ] && echo "$l" || echo 1; }

# until_true END INTERVAL CMD...: runs CMD until it succeeds or END passes; returns CMD's last status.
until_true() {
  local end=$1 interval=$2
  shift 2
  while :; do
    "$@" && return 0
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep "$interval"
  done
}

# ship: archives /shared/evidence and uploads it under a key of its own, evidence-N.tgz, retrying; once S3 reports that
# object at the archive's exact size, it publishes evidence.latest, "n=N sha256=...", and returns 0.
# Called after every check. A key per upload means an upload whose verification fails never replaces the last verified
# archive, and evidence.latest, written only after verification, lets the runner recover the last one even when head
# dies before DONE.
ship() {
  local i size got n sha
  n=$(( $(cat /tmp/evidence.n 2>>/var/log/slurmec2-probe.log || echo 0) + 1 ))
  echo "$n" >/tmp/evidence.n
  tar -czf "/tmp/evidence-$n.tgz" -C "$SHARED" evidence || return 1
  size=$(stat -c %s "/tmp/evidence-$n.tgz")
  sha=$(sha256sum "/tmp/evidence-$n.tgz" | cut -d' ' -f1)
  for i in 1 2 3 4 5; do
    if s3put "/tmp/evidence-$n.tgz" "evidence-$n.tgz"; then
      got=$(aws s3api head-object --bucket "$BUCKET" --key "$PREFIX/evidence-$n.tgz" --query ContentLength --output text) &&
        [ "$got" = "$size" ] && {
          echo "n=$n sha256=$sha" >/tmp/evidence.latest
          s3put /tmp/evidence.latest evidence.latest || return 1
          echo "$sha" >/tmp/evidence.sha
          return 0
        }
    fi
    sleep $(( i * 2 ))
  done
  return 1
}
