#!/usr/bin/env bash
#
# Checks the bring-up signal protocol and the bounded retry in hack/slurm-ec2/common.sh against a fake AWS CLI.
#
#   bash hack/test/check-slurm-ec2-signals.sh
#
# The first paid run lost its CONF_READY barrier on NFS; the signals now go over S3, and these are the ways that
# protocol could accept a signal it should refuse or wait past its deadline.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/s3"

# The fake CLI keeps objects under $work/s3 and answers as FAKE_AWS says: "" normally, "403" with an access refusal.
cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf 'AWS_MAX_ATTEMPTS=%s %s\n' "${AWS_MAX_ATTEMPTS:-}" "$*" >>"$S3/../calls.log"
# The sleep holds no output pipe, so a timeout that kills this script ends the caller's read too, as with the real CLI.
[ -z "${FAKE_AWS_DELAY:-}" ] || sleep "$FAKE_AWS_DELAY" </dev/null >/dev/null 2>&1
if [ "${FAKE_AWS:-}" = 403 ]; then
  echo "An error occurred (AccessDenied) when calling the GetObject operation: Access Denied" >&2
  exit 254
fi
args=()
while [ $# -gt 0 ]; do case "$1" in --cli-connect-timeout|--cli-read-timeout) shift 2 ;; *) args+=("$1"); shift ;; esac; done
set -- "${args[@]}"
key="" body=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in --key) j=$((i + 1)); key=${!j} ;; --body) j=$((i + 1)); body=${!j} ;; esac
done
f="$S3/$(printf '%s' "$key" | tr / _)"
case "$1 $2" in
  "s3api put-object") cp "$body" "$f" ;;
  "s3api get-object")
    [ -f "$f" ] || { echo "An error occurred (NoSuchKey) when calling the GetObject operation: The specified key does not exist." >&2; exit 254; }
    cp "$f" "${!#}" ;;
  *) echo "fake aws: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH" S3="$work/s3"

ROLE=gpu1 BUCKET=b PREFIX=run-1 T0=1000; : >"$work/stdout"
# shellcheck source=hack/slurm-ec2/common.sh
. hack/slurm-ec2/common.sh
DIAG=$work/diag CTRL=$work/ctrl
# A payload as head would write it, with one field replaced.
plant() {
  python3 -c 'import json,sys; d={"schema":1,"run":"run-1","t0":1000,"producer":"head","phase":"ready","token":"ab12"}; d.update(json.loads(sys.argv[1])); print(json.dumps(d))' "$1" \
    >"$S3/run-1_control_CONF_READY"
}
rc_of() { "$@" >>"$work/stdout"; echo $?; }

rm -f "$S3"/*; expect_missing=$(rc_of sig_get CONF_READY head ready)
[ "$expect_missing" = 1 ] && ok "an absent signal is not ready yet (1)" || bad "an absent signal returned $expect_missing"
plant '{}'
[ "$(rc_of sig_get CONF_READY head ready)" = 0 ] && ok "this run's signal from head at its phase is accepted" || bad "a valid signal was refused"
for f in '{"run":"run-0"}' '{"t0":999}' '{"producer":"gpu2"}' '{"phase":"end"}' '{"schema":2}' '{"token":"ab'"'"'; touch x"}' '{"token":7}' '{"schema":true}' '{"t0":1000.0}'; do
  plant "$f"
  got=$(rc_of sig_get CONF_READY head ready)
  [ "$got" = 2 ] && ok "a signal with $f is refused as an error (2)" || bad "a signal with $f returned $got"
done
echo 'not json' >"$S3/run-1_control_CONF_READY"
[ "$(rc_of sig_get CONF_READY head ready)" = 2 ] && ok "an unreadable payload is an error" || bad "an unreadable payload was not an error"

# A refusal is not "not ready": 403 must surface as an error, and a valid file left from an earlier GET must not be read.
plant '{}'; sig_get CONF_READY head ready; cp "$CTRL/CONF_READY.download" "$work/leftover"
cp "$work/leftover" "$CTRL/CONF_READY.download"
got=$(FAKE_AWS=403 rc_of sig_get CONF_READY head ready)
[ "$got" = 2 ] && ok "a 403 is an error (2), and the valid file left from before is not accepted" || bad "a 403 with a leftover file returned $got"
rm -f "$S3"/*; cp "$work/leftover" "$CTRL/CONF_READY.download"
got=$(rc_of sig_get CONF_READY head ready)
[ "$got" = 1 ] && ok "a missing key with a valid file left from before is still not ready" || bad "a missing key with a leftover file returned $got"

: >"$work/calls.log"
sig_put CONF_ACK-gpu1 acked ab12
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d=={"schema":1,"run":"run-1","t0":1000,"producer":"gpu1","phase":"acked","token":"ab12"} else 1)' "$S3/run-1_control_CONF_ACK-gpu1" &&
  ok "sig_put writes schema, run, T0, producer, phase and token" || bad "sig_put wrote $(cat "$S3/run-1_control_CONF_ACK-gpu1")"
grep -q "^AWS_MAX_ATTEMPTS=1 .*--cli-connect-timeout 3 --cli-read-timeout 10 s3api put-object" "$work/calls.log" &&
  ok "every signal call runs with one attempt and connect and read timeouts" || bad "the signal call was: $(cat "$work/calls.log")"

start=$(date +%s); got=$(FAKE_AWS=403 rc_of sig_wait $((start + 60)) CONF_READY head ready); took=$(( $(date +%s) - start ))
[ "$got" = 2 ] && [ "$took" -lt 40 ] && ok "five refusals in a row end the wait as an error, in ${took} s, before its deadline" || bad "repeated refusals returned $got after ${took} s"

# A valid signal whose read ends after the deadline is not counted, and the read itself is cut to the time left.
plant '{}'; start=$(date +%s)
got=$(FAKE_AWS_DELAY=6 rc_of sig_wait $((start + 2)) CONF_READY head ready); took=$(( $(date +%s) - start ))
[ "$got" = 1 ] && [ "$took" -le 5 ] && ok "a signal read past the deadline is not counted, and the read stops at it (${took} s)" || bad "a slow read past the deadline returned $got after ${took} s"

# The same read with the cut disabled, so it succeeds after the deadline: sig_wait must still not count it.
got=$( (bound() { echo 20; }; FAKE_AWS_DELAY=3 rc_of sig_wait $(( $(date +%s) + 2 )) CONF_READY head ready) )
[ "$got" = 1 ] && ok "a signal that arrives after the deadline is not counted even when the read is not cut" || bad "an uncut late read returned $got"

# until_true: a success that lands after the deadline does not count, and nothing runs once the deadline has passed.
slow_ok() { sleep 3; return 0; }
got=$(rc_of until_true $(( $(date +%s) + 2 )) 1 slow_ok)
[ "$got" = 1 ] && ok "a function that succeeds after the deadline does not count" || bad "a late success returned $got"
start=$(date +%s); got=$(rc_of until_true $(( start + 2 )) 1 sleep 30); took=$(( $(date +%s) - start ))
[ "$got" = 1 ] && [ "$took" -le 5 ] && ok "a command is bounded by the time left (${took} s)" || bad "a hung command returned $got after ${took} s"
# Both a command and a function: timeout refuses a non-positive limit on its own, so only a function shows the check.
mark() { touch "$work/ran"; }
for c in "touch $work/ran" mark; do
  rm -f "$work/ran"
  # shellcheck disable=SC2086
  got=$(rc_of until_true $(( $(date +%s) - 1 )) 1 $c)
  [ "$got" = 1 ] && [ ! -e "$work/ran" ] && ok "nothing runs once the deadline has passed (${c%% *})" || bad "after the deadline (${c%% *}): $got, ran=$([ -e "$work/ran" ] && echo yes || echo no)"
done

# cluster.env: the session accepts the addresses and T0 only, the t3 rehearsal its clock and checks too, each once.
base=$'T0=1000\nHEAD_IP=172.31.0.10\nGPU1_IP=172.31.0.11\nGPU2_IP=172.31.0.12'
cen() { printf '%s\n' "$1" >"$work/cluster.env"; shift; ( export "$@"; cenv_check "$work/cluster.env" >/dev/null ); echo $?; }
[ "$(cen "$base" X=0)" = 0 ] && ok "the session's own cluster.env is accepted" || bad "the session's cluster.env was refused"
[ "$(cen "$base"$'\nB4_ADMIT_S=1' X=0)" = 1 ] && ok "the session refuses a clock or check setting in cluster.env" || bad "the session accepted B4_ADMIT_S"
[ "$(cen "$base"$'\nB4_ADMIT_S=600' SLURMEC2_NFS_PROBE=1)" = 0 ] && ok "the t3 rehearsal accepts its clock settings" || bad "the rehearsal refused B4_ADMIT_S"
for l in 'SLURMEC2_FAKE_GPU=1' 'TENANT=root' 'T0=1;touch' 'T0=$(id)' 'T0=2'; do
  [ "$(cen "$base"$'\n'"$l" SLURMEC2_NFS_PROBE=1)" = 1 ] && ok "cluster.env with '$l' is refused" || bad "cluster.env with '$l' was accepted"
done

# The mount the workers make; the options are what the registration names.
for o in vers=4.1 lookupcache=positive hard; do
  [[ ",$NFS_OPTS," == *",$o,"* ]] && ok "the worker mount sets $o" || bad "NFS_OPTS lacks $o: $NFS_OPTS"
done
grep -q 'mount -t nfs -o "$NFS_OPTS" head:"$SHARED" "$SHARED"' hack/slurm-ec2/instance.sh &&
  ok "the worker mounts /shared with NFS_OPTS" || bad "instance.sh does not mount /shared with NFS_OPTS"

[ "$fails" = 0 ] && echo "check-slurm-ec2-signals: all checks passed" || echo "check-slurm-ec2-signals: $fails failure(s)"
[ "$fails" = 0 ]
