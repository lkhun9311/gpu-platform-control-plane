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
CHECKS_END_S=4200
EVIDENCE_S=4380

SHARED=/shared
EVID=$SHARED/evidence
TENANT=tenant
TENANT_UID=2001

log() { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "${ROLE:-?}" "$*"; }

# s3get KEY FILE and s3put FILE KEY move one object within the run's prefix; neither retries, the callers do.
s3get() { aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/$1" "$2"; }
s3put() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2"; }

# left END: seconds from now until the epoch END, never below 0.
left() { local l=$(( $1 - $(date +%s) )); [ "$l" -gt 0 ] && echo "$l" || echo 0; }

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

# ship: archives /shared/evidence and uploads it as evidence.tgz, retrying, and returns 0 only when S3 reports the
# uploaded object at the archive's exact size. Called after every check, so a later failure loses at most one check.
ship() {
  local i size got
  tar -czf /tmp/evidence.tgz.new -C "$SHARED" evidence || return 1
  mv /tmp/evidence.tgz.new /tmp/evidence.tgz
  size=$(stat -c %s /tmp/evidence.tgz)
  for i in 1 2 3 4 5; do
    if s3put /tmp/evidence.tgz evidence.tgz; then
      got=$(aws s3api head-object --bucket "$BUCKET" --key "$PREFIX/evidence.tgz" --query ContentLength --output text) &&
        [ "$got" = "$size" ] && return 0
    fi
    sleep $(( i * 2 ))
  done
  return 1
}
