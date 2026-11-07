# shellcheck shell=bash
# Helpers shared by hack/slurm-ec2/instance.sh and hack/slurm-ec2/procedure.sh, on the instances.
# docs/superpowers/specs/2026-11-07-slurm-ec2-session-design.md is the registration they implement.
#
# Inputs from the user-data's environment: ROLE, BUCKET, PREFIX, and, once cluster.env is read, T0 and the addresses.
# Three switches, each set only by a rehearsal and each named where it changes behaviour:
#   SLURMEC2_FAKE_GPU=1     no GPU: a driverless /dev/nvidia0 and an nvidia-smi stand-in, and the trainer on the CPU
#                           (the local container rehearsal and the t3 real-NFS rehearsal);
#   SLURMEC2_SHARED_VOLUME=1 /shared is one volume every container mounts, no NFS (the local container rehearsal only);
#   SLURMEC2_NO_SHUTDOWN=1  the instance never shuts itself down (the local container rehearsal only).
# SLURMEC2_REHEARSAL=1, the older single switch, still sets all three, as the local rehearsal does.
if [ "${SLURMEC2_REHEARSAL:-0}" = 1 ]; then
  SLURMEC2_FAKE_GPU=1 SLURMEC2_SHARED_VOLUME=1 SLURMEC2_NO_SHUTDOWN=1
fi
SLURMEC2_FAKE_GPU=${SLURMEC2_FAKE_GPU:-0}
SLURMEC2_SHARED_VOLUME=${SLURMEC2_SHARED_VOLUME:-0}
SLURMEC2_NO_SHUTDOWN=${SLURMEC2_NO_SHUTDOWN:-0}
export SLURMEC2_FAKE_GPU SLURMEC2_SHARED_VOLUME SLURMEC2_NO_SHUTDOWN

# The exact packages the registration names; a different archive version fails the install, not the measurement.
SLURM_PKG_VERSION=23.11.4-1.2ubuntu5
MUNGE_PKG_VERSION=0.5.15-4ubuntu0.1
MARIADB_PKG_VERSION=1:10.11.14-0ubuntu0.24.04.1
TORCH_VERSION=2.5.1

# Offsets from T0, in seconds, as the registration's clock table gives them; cluster.env may set shorter ones for the
# t3 real-NFS rehearsal, and instance.sh checks whatever it sets.
BRINGUP_END_S=${BRINGUP_END_S:-1500}
CHECKS_END_S=${CHECKS_END_S:-5400}
EVIDENCE_S=${EVIDENCE_S:-5580}
# The NFS mount every worker makes. lookupcache=positive revalidates a cached absence on every lookup, which is how a
# path created later on head becomes visible at once; vers=4.1 is pinned so the negotiated version is the registered one.
NFS_OPTS=vers=4.1,proto=tcp,hard,timeo=600,retrans=2,lookupcache=positive
DIAG=/var/log/slurmec2/diag
CTRL=/var/lib/slurmec2/control

SHARED=/shared
EVID=$SHARED/evidence
TENANT=tenant
TENANT_UID=2001
# The packages create their service users with whatever ids are free, which differ between the Canonical and the
# Deep Learning images; Slurm needs the same SlurmUser everywhere, so the user is made first, with fixed ids.
SLURM_UID=1601
MUNGE_UID=1602

log() { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "${ROLE:-?}" "$*"; }

# phase NAME: one line per bring-up step into this host's diagnostics, in UTC and monotonic seconds.
phase() {
  mkdir -p "$DIAG"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$(cut -d' ' -f1 /proc/uptime)" "$*" >>"$DIAG/phases.log"
  log "phase $*"
}

# run_logged NAME CMD...: runs CMD, keeps its stdout and stderr in the diagnostics under NAME, and records its status.
run_logged() {
  local name=$1 rc
  shift
  mkdir -p "$DIAG/cmd"
  "$@" >"$DIAG/cmd/$name.out" 2>"$DIAG/cmd/$name.err"
  rc=$?
  echo "$rc" >"$DIAG/cmd/$name.rc"
  return "$rc"
}

# awsb ARGS...: one AWS CLI call, bounded as a whole and per connection, with no retries of its own; callers retry.
awsb() {
  timeout --kill-after=2 20 env AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard AWS_PAGER= \
    aws --cli-connect-timeout 3 --cli-read-timeout 10 "$@"
}

# The lifecycle signals, over S3 under the run's prefix rather than over NFS: S3 reads after a write are strongly
# consistent, and a missing file on NFS can stay invisible to a client for longer than any deadline here.
# sig_put NAME PHASE [TOKEN]: writes {schema, run, t0, producer, phase, token} for NAME and PUTs it as control/NAME.
sig_put() {
  local name=$1 ph=$2 tok=${3:-} i
  mkdir -p "$CTRL" "$DIAG" || return 1
  python3 -c 'import json,sys; print(json.dumps({"schema": 1, "run": sys.argv[1], "t0": int(sys.argv[2]), "producer": sys.argv[3], "phase": sys.argv[4], "token": sys.argv[5]}, sort_keys=True))' \
    "$PREFIX" "${T0:-0}" "$ROLE" "$ph" "$tok" >"$CTRL/$name" || return 1
  for i in 1 2 3 4 5; do
    awsb s3api put-object --bucket "$BUCKET" --key "$PREFIX/control/$name" --body "$CTRL/$name" >>"$DIAG/s3.log" 2>&1 &&
      { phase "signal put $name $ph"; return 0; }
    sleep "$i"
  done
  phase "signal put $name FAILED"
  return 1
}

# sig_get NAME PRODUCER PHASE: 0 when control/NAME exists and is this run's, from PRODUCER, at PHASE; 1 when it does
# not exist yet; 2 on anything else (a refusal, a timeout, a payload for another run). A file left from an earlier
# attempt is never read: the download goes to a fresh name and is used only if the GET succeeded.
sig_get() {
  local name=$1 producer=$2 ph=$3 out err
  mkdir -p "$CTRL" "$DIAG"
  out="$CTRL/$name.download"
  rm -f "$out"
  if err=$(awsb s3api get-object --bucket "$BUCKET" --key "$PREFIX/control/$name" "$out" 2>&1 >/dev/null); then
    python3 - "$out" "$PREFIX" "${T0:-0}" "$producer" "$ph" <<'PY' && return 0
import json, sys
d = json.load(open(sys.argv[1]))
ok = d.get("schema") == 1 and d.get("run") == sys.argv[2] and d.get("t0") == int(sys.argv[3]) \
    and d.get("producer") == sys.argv[4] and d.get("phase") == sys.argv[5]
sys.exit(0 if ok else 1)
PY
    echo "$(date -u +%FT%TZ) $name: payload is not this run's or this phase's: $(head -c 300 "$out")" >>"$DIAG/s3.log"
    rm -f "$out"
    return 2
  fi
  echo "$(date -u +%FT%TZ) get $name: $err" >>"$DIAG/s3.log"
  case "$err" in *NoSuchKey*|*"(404)"*|*"Not Found"*) return 1 ;; esac
  return 2
}

# sig_wait END NAME PRODUCER PHASE: polls sig_get until it returns 0, END passes, or it returns 2 five times running;
# returns 0, 1 (deadline) or 2 (errors).
sig_wait() {
  local end=$1 name=$2 producer=$3 ph=$4 rc errs=0
  while [ "$(date +%s)" -lt "$end" ]; do
    sig_get "$name" "$producer" "$ph"
    rc=$?
    [ "$rc" = 0 ] && { phase "signal got $name $ph"; return 0; }
    if [ "$rc" = 2 ]; then errs=$((errs + 1)); [ "$errs" -lt 5 ] || return 2; else errs=0; fi
    sleep 5
  done
  return 1
}

# s3get KEY FILE and s3put FILE KEY move one object within the run's prefix; neither retries, the callers do.
s3get() { timeout --kill-after=2 120 aws s3 cp --only-show-errors --cli-connect-timeout 3 --cli-read-timeout 30 "s3://$BUCKET/$PREFIX/$1" "$2"; }
s3put() { timeout --kill-after=2 300 aws s3 cp --only-show-errors --cli-connect-timeout 3 --cli-read-timeout 30 "$1" "s3://$BUCKET/$PREFIX/$2"; }

# left END: seconds from now until the epoch END, never below 1: GNU timeout reads 0 as no limit at all.
left() { local l=$(( $1 - $(date +%s) )); [ "$l" -gt 1 ] && echo "$l" || echo 1; }

# until_true END INTERVAL CMD...: runs CMD until it succeeds or END passes, each attempt bounded by the time left, and
# returns 1 at the deadline. The deadline is read before and after each attempt, so a success after it does not count.
until_true() {
  local end=$1 interval=$2 l
  shift 2
  while :; do
    l=$(( end - $(date +%s) ))
    [ "$l" -gt 0 ] || return 1
    # A shell function cannot run under timeout; the functions given here bound their own calls (awsb).
    if declare -F "$1" >/dev/null; then "$@"; else timeout --kill-after=2 "$l" "$@"; fi && [ "$(date +%s)" -le "$end" ] && return 0
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep "$interval"
  done
}

# diag_ship TAG: archives this host's diagnostics and PUTs them as diag-ROLE-TAG.tgz, independent of Slurm and NFS.
diag_ship() {
  local tag=$1
  mkdir -p "$DIAG"
  tar -czf "/tmp/diag-$ROLE-$tag.tgz" -C /var/log slurmec2 2>>"$DIAG/ship.err" || return 1
  awsb s3api put-object --bucket "$BUCKET" --key "$PREFIX/diag-$ROLE-$tag.tgz" --body "/tmp/diag-$ROLE-$tag.tgz" >>"$DIAG/s3.log" 2>&1
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
