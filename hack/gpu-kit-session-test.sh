#!/usr/bin/env bash
#
# Offline checks for hack/gpu-kit-session.sh, run before anything is bought.
# The EC2 lifecycle is hack/lib/spot-run.sh's, which other session tests cover; these checks cover the schedule, the cost cap, the refusals, the user-data and the termination path.
# Each guard is also run against a mutant of the session that breaks it, and the mutant must be caught, so a check that cannot fail does not pass silently.
#
#   bash hack/gpu-kit-session-test.sh
set -uo pipefail
# The checks pick their instance types themselves, so a caller's choice must not leak into them.
unset INSTANCE_TYPE
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/hack/gpu-kit-session.sh"
# Scratch space lives on disk, since /tmp is RAM-backed on the development machine.
SCRATCH="${SCRATCH:-$HOME/.cache/gpu-kit}"
mkdir -p "$SCRATCH"
WORK=$(mktemp -d -p "$SCRATCH")
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
# A mutant check whose mutant could not be made fails, rather than passing on an empty path.
mcheck() { if [ -n "$m" ]; then check "$@"; else echo "FAIL $1 (the mutant was not made)" >&2; failures=$((failures + 1)); fi; }

# mutant NAME SED: a copy of the session with SED applied, beside a copy of the library it sources, and its path.
mutant() {
  local d="$WORK/m-$1"
  mkdir -p "$d/hack/lib"
  cp "$ROOT/hack/lib/spot-run.sh" "$d/hack/lib/"
  sed "$2" "$S" >"$d/hack/gpu-kit-session.sh"
  cmp -s "$S" "$d/hack/gpu-kit-session.sh" && { echo "the mutant $1 changed nothing" >&2; return 1; }
  echo "$d/hack/gpu-kit-session.sh"
}

# A fake aws that records every call, so a refusal can be shown to come before any AWS call.
mkdir -p "$WORK/awsbin"
cat >"$WORK/awsbin/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >> "$AWS_CALLS"
case "$1 $2" in
  "ec2 terminate-instances") [ -z "${FAKE_TERMINATE_FAIL:-}" ] || { echo "An error occurred (UnauthorizedOperation)" >&2; exit 254; } ;;
  "ec2 describe-instances") case "$*" in *State.Name\'*|*"State.Name --output"*) echo "${FAKE_STATE:-terminated}" ;; *) printf '%s\tx\tx\tx\tx\n' "${FAKE_STATE:-terminated}" ;; esac ;;
  "sts get-caller-identity") echo 007635145730 ;;
esac
EOF
chmod +x "$WORK/awsbin/aws"
export AWS_CALLS="$WORK/aws-calls"
fake() { : >"$AWS_CALLS"; env -u SESSION_CONFIRM PATH="$WORK/awsbin:$PATH" SCRATCH="$SCRATCH" "$@"; }

check "the session parses" "bash -n '$S'"

# ---------------------------------------------------------------- schedule and cost
sched=$(bash "$S" --print-schedule 2>&1)
check "the default type's schedule and worst case ($sched)" \
  "[ '$sched' = 'instance_type=g5.xlarge harness_end_s=3600 evidence_s=3660 stop_s=3720 termination_s=4020 worst_case_usd=0.8579' ]"
sched2=$(INSTANCE_TYPE=g5.2xlarge bash "$S" --print-schedule 2>&1)
check "g5.2xlarge's schedule is the same and its worst case is \$0.9696 ($sched2)" \
  "[ '$sched2' = 'instance_type=g5.2xlarge harness_end_s=3600 evidence_s=3660 stop_s=3720 termination_s=4020 worst_case_usd=0.9696' ]"
check "the worst cases are 4,020 s at \$0.70 or \$0.80 plus \$0.0683 an hour, and the largest cap under \$1.00 is below \$0.8272" \
  "[ \"\$(python3 -c 'print(f\"{4020 / 3600 * (0.70 + 0.0683):.4f} {4020 / 3600 * (0.80 + 0.0683):.4f} {1 / (4020 / 3600) - 0.0683:.4f}\")')\" = '0.8579 0.9696 0.8272' ]"
check "the header states both worst cases, the largest cap and the stop" \
  "command grep -qF 'is \$0.7683/h all in, and \$0.8579.' '$S' && command grep -qF 'is \$0.8683/h all in, and \$0.9696.' '$S' && command grep -qF 'Any cap of \$0.8272/h or more' '$S' && command grep -qF 'The instance shuts itself down at 3,720 s' '$S'"
# cost_refused SCRIPT: whether SCRIPT refuses even the schedule because its worst case is not under the cap.
cost_refused() { ! bash "$1" --print-schedule >"$WORK/cost.out" 2>&1 && command grep -qF 'SESSION REFUSED' "$WORK/cost.out"; }
check "the session as written is not refused on cost" "! cost_refused '$S'"
m=$(mutant cap 's/g5.xlarge) echo "0.70 0.7683 4"/g5.xlarge) echo "0.95 1.0183 4"/')
mcheck "mutant: a g5.xlarge cap of \$0.95/h puts the worst case over \$1.00 and is refused" "cost_refused '$m' && command grep -qF 'not under \$1.00' '$WORK/cost.out'"
m=$(mutant cap2 's/g5.2xlarge) echo "0.80 0.8683 8"/g5.2xlarge) echo "0.83 0.8983 8"/')
mcheck "mutant: a g5.2xlarge cap of \$0.83/h is refused even when the run buys g5.xlarge" "cost_refused '$m' && command grep -qF 'g5.2xlarge worst case' '$WORK/cost.out'"
m=$(mutant kit 's/^KIT_S=.*/KIT_S=4200/')
mcheck "mutant: a kit phase stretched to 4,200 s is refused" "cost_refused '$m' && command grep -qF 'not under \$1.00' '$WORK/cost.out'"
m=$(mutant quietcap 's/g5.xlarge) echo "0.70 0.7683 4"/g5.xlarge) echo "0.75 0.7683 4"/')
mcheck "mutant: a cap raised without its all-in rate is refused" "cost_refused '$m' && command grep -qF 'is not its Spot cap' '$WORK/cost.out'"

# ---------------------------------------------------------------- the instance type
# unlisted_refused SCRIPT: whether SCRIPT refuses a run on g5.4xlarge, which is not listed.
unlisted_refused() { ! INSTANCE_TYPE=g5.4xlarge bash "$1" --print-schedule >"$WORK/type.out" 2>&1 && command grep -qF 'SESSION REFUSED' "$WORK/type.out"; }
check "an unlisted instance type is refused before anything is checked or bought" \
  "unlisted_refused '$S' && command grep -qF \"INSTANCE_TYPE 'g5.4xlarge' is not one of the listed types\" '$WORK/type.out'"
m=$(mutant ratesonly 's/^    g5.2xlarge) echo "0.80 0.8683 8" ;;$/&\n    g5.4xlarge) echo "1.50 1.5683 16" ;;/')
mcheck "mutant: rates for an unlisted g5.4xlarge, whose \$1.75 worst case nothing checked, still do not let it run" "unlisted_refused '$m'"
m=$(mutant unlisted 's/^    g5.2xlarge) echo "0.80 0.8683 8" ;;$/&\n    g5.4xlarge) echo "1.50 1.5683 16" ;;/; /is not one of the listed types/d')
mcheck "mutant: without the listed-type guard an unlisted g5.4xlarge runs, and the check catches it" "! unlisted_refused '$m'"

# ---------------------------------------------------------------- refusals
fake bash "$S" kit-x >"$WORK/noconfirm" 2>&1; rc=$?
check "without SESSION_CONFIRM=yes nothing is checked or bought" \
  "[ $rc != 0 ] && command grep -qF 'SESSION_CONFIRM=yes is required' '$WORK/noconfirm' && [ ! -s '$AWS_CALLS' ]"
fake env MAX_SPOT_PRICE=2 bash "$S" --print-schedule >"$WORK/override" 2>&1; rc=$?
check "a caller who sets MAX_SPOT_PRICE is refused rather than ignored" "[ $rc != 0 ] && command grep -qF 'MAX_SPOT_PRICE is set' '$WORK/override'"
mkdir -p "$WORK/emptykit"
fake env SESSION_CONFIRM=yes bash "$S" "$WORK/emptykit" >"$WORK/norun" 2>&1; rc=$?
check "a kit without run.sh is refused before any AWS call" \
  "[ $rc != 0 ] && command grep -qF 'has no run.sh' '$WORK/norun' && [ ! -s '$AWS_CALLS' ]"
mkdir -p "$WORK/repo/kit" && git -C "$WORK/repo" init -q && echo 'echo hi' >"$WORK/repo/kit/run.sh" &&
  git -C "$WORK/repo" add kit && git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -qm init && echo junk >"$WORK/repo/kit/extra"
fake env SESSION_CONFIRM=yes OUT="$WORK/out-dirty" bash "$S" "$WORK/repo/kit" >"$WORK/dirtykit" 2>&1; rc=$?
check "a kit with an untracked file is refused, since it ships as a commit" \
  "[ $rc != 0 ] && command grep -qE 'kit has uncommitted or untracked files|working tree is dirty' '$WORK/dirtykit'"

# ---------------------------------------------------------------- the user-data
# ud_ok SCRIPT: whether SCRIPT's user-data renders, parses, fits, and carries both stops and the pins.
ud_ok() {
  bash "$1" --print-user-data >"$WORK/ud.sh" 2>&1 || return 1
  bash -n "$WORK/ud.sh" && ! command grep -q _PLACEHOLDER "$WORK/ud.sh" && [ "$(wc -c <"$WORK/ud.sh")" -lt 16384 ] &&
    command grep -qxF '( sleep 3720; shutdown -h now ) &' "$WORK/ud.sh" &&
    command grep -qF '( sleep $(( L + 3720 - $(date +%s) > 0 ? L + 3720 - $(date +%s) : 1 )); shutdown -h now ) &' "$WORK/ud.sh" &&
    command grep -qF "trap 'upload /var/log/gpukit.log log.txt; shutdown -h now' EXIT" "$WORK/ud.sh" &&
    command grep -qF 'PREFLIGHT FAILED: not one A10G' "$WORK/ud.sh" &&
    command grep -qF 'echo "b9980552309f09c15172b8be828555e375097f16deb459795ce7bfd200380f0b  uv.tgz" | sha256sum -c -' "$WORK/ud.sh" &&
    command grep -qF 'uv python find --no-project --managed-python cpython-3.12.15-linux-x86_64-gnu' "$WORK/ud.sh" &&
    command grep -qF 'bash /opt/kit/in/kit/run.sh > "$R/run-output.log"' "$WORK/ud.sh" &&
    command grep -qxF 'ln -sf /opt/kit/uv-x86_64-unknown-linux-gnu/uv /opt/kit/bin/uv' "$WORK/ud.sh" &&
    command grep -qF 'env HOME=/root PATH="/opt/kit/bin:$PATH" UV_PYTHON_INSTALL_DIR=/opt/kit/python OUT="$R/results"' "$WORK/ud.sh" &&
    command grep -qF 'mem > "$R/memory-before-kit.txt"' "$WORK/ud.sh" &&
    command grep -qF "grep -q '^test-files-fix ' \"\$R/results/status.txt\" 2>/dev/null; then mem > \"\$R/memory-before-loads.txt\"" "$WORK/ud.sh"
}
check "the user-data renders, parses, fits 16 KB, stops itself at 3,720 s twice, and pins uv and Python" "ud_ok '$S'"
m=$(mutant nouv '/^ln -sf \/opt\/kit\/uv-x86_64-unknown-linux-gnu\/uv \/opt\/kit\/bin\/uv$/d')
mcheck "mutant: a user-data that leaves uv off the kit's PATH is caught" "! ud_ok '$m'"
m=$(mutant backstop '/^( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) &$/d')
mcheck "mutant: a user-data without its first backstop is caught" "! ud_ok '$m'"
m=$(mutant precise 's/^( sleep \$(( L + STOP_FROM_LAUNCH_S_PLACEHOLDER/( sleep $(( L + 99999/')
mcheck "mutant: a precise stop moved past the schedule is caught" "! ud_ok '$m'"
m=$(mutant exittrap "s/^trap 'upload \/var\/log\/gpukit.log log.txt; shutdown -h now' EXIT/trap 'upload \/var\/log\/gpukit.log log.txt' EXIT/")
mcheck "mutant: an exit trap that no longer shuts down is caught" "! ud_ok '$m'"
# ---------------------------------------------------------------- KIT_ENV
# kit_env_ud SCRIPT VALUE: the user-data SCRIPT renders with KIT_ENV=VALUE, or a failing status.
kit_env_ud() { env KIT_ENV="$2" bash "$1" --print-user-data >"$WORK/kitenv.sh" 2>&1; }
kit_env_line='env PHASES='"'"'3'"'"' SWEEP_FREE_GIB='"'"'16.2 16.4 16.6'"'"' HOME=/root PATH="/opt/kit/bin:$PATH"'
check "KIT_ENV reaches run.sh's environment as quoted pairs, and the user-data still parses" \
  "kit_env_ud '$S' 'PHASES=3;SWEEP_FREE_GIB=16.2 16.4 16.6' && bash -n '$WORK/kitenv.sh' && command grep -qF \"\$kit_env_line\" '$WORK/kitenv.sh'"
check "without KIT_ENV run.sh's environment line is unchanged" \
  "kit_env_ud '$S' '' && command grep -qF 'env HOME=/root PATH=\"/opt/kit/bin:\$PATH\"' '$WORK/kitenv.sh'"
# kit_env_refused SCRIPT VALUE TEXT: whether SCRIPT refuses KIT_ENV=VALUE with TEXT in its message.
kit_env_refused() { ! kit_env_ud "$1" "$2" && command grep -qF "$3" "$WORK/kitenv.sh"; }
check "a KIT_ENV that sets OUT is refused" "kit_env_refused '$S' 'OUT=/tmp' 'one the session or the shell relies on'"
check "a KIT_ENV that sets LD_PRELOAD is refused" "kit_env_refused '$S' 'LD_PRELOAD=x' 'one the session or the shell relies on'"
check "a KIT_ENV value with a shell character is refused" "kit_env_refused '$S' 'A=\$(id)' 'characters outside'"
check "a KIT_ENV value with a quote is refused" "kit_env_refused '$S' \"A=x'y\" 'characters outside'"
check "a KIT_ENV entry without = is refused" "kit_env_refused '$S' 'PHASES' 'is not NAME=value'"
check "a lower-case KIT_ENV name is refused" "kit_env_refused '$S' 'phases=3' 'not an upper-case variable name'"
m=$(mutant kitenvreserved 's/^      HOME | PATH | OUT | UV_\* | PYTHON\* | LD_\* | BASH_\* | ENV | IFS | SHELL | AWS_\* | KIT_ENV)$/      NEVER_MATCHES_ANYTHING)/')
mcheck "mutant: without the reserved-name guard, a KIT_ENV that sets OUT is caught" "! kit_env_refused '$m' 'OUT=/tmp' 'one the session or the shell relies on'"
m=$(mutant kitenvvalue 's/^    \[\[ \$value =~ .*$/    true/')
mcheck "mutant: without the value guard, a shell character is caught" "! kit_env_refused '$m' 'A=\$(id)' 'characters outside'"
m=$(mutant kitenvrender 's/-e "s|KIT_ENV_PLACEHOLDER|\$KIT_ENV_WORDS|"/-e "s|KIT_ENV_PLACEHOLDER||"/')
mcheck "mutant: a render that drops KIT_ENV is caught" "! { kit_env_ud '$m' 'PHASES=3;SWEEP_FREE_GIB=16.2 16.4 16.6' && command grep -qF \"\$kit_env_line\" '$WORK/kitenv.sh'; }"
check "the session records KIT_ENV in session-provenance.txt" "command grep -qF 'echo \"kit_env=\${KIT_ENV:-}\"' '$S'"

check "the launch asks EC2 to terminate, not stop, on the instance's own shutdown" \
  "command grep -qF -- '--instance-initiated-shutdown-behavior terminate' '$ROOT/hack/lib/spot-run.sh'"

# ---------------------------------------------------------------- the termination path
mkdir -p "$WORK/end"
# ends SCRIPT STATE [TERMINATE_FAIL]: the exit status and record of SCRIPT's --end-instance against a fake EC2 answering STATE.
ends() {
  fake env OUT="$WORK/end" FAKE_STATE="$2" FAKE_TERMINATE_FAIL="${3:-}" SPOT_TERMINATE_WAIT=0 SPOT_TERMINATE_TRIES=2 \
    bash "$1" --end-instance i-0fake >"$WORK/end.out" 2>&1
}
# unconfirmed_fails SCRIPT: whether an instance still running is reported unconfirmed with a failing status.
unconfirmed_fails() {
  ends "$1" running; local rc=$?
  [ $rc != 0 ] && command grep -qF 'TERMINATION UNCONFIRMED for i-0fake' "$WORK/end/termination.txt" && command grep -qx 'termination=unconfirmed' "$WORK/end.out"
}
ends "$S" terminated; rc=$?
check "an instance EC2 reports terminated is confirmed, and the call was made" \
  "[ $rc = 0 ] && command grep -q '^terminated i-0fake, confirmed at ' '$WORK/end/termination.txt' && command grep -q '^aws ec2 terminate-instances .*i-0fake' '$AWS_CALLS'"
check "an instance still running after the terminate call is unconfirmed, and the status fails" "unconfirmed_fails '$S'"
ends "$S" running 1; rc=$?
check "a refused terminate call on a running instance fails" "[ $rc != 0 ] && command grep -qF 'TERMINATION UNCONFIRMED' '$WORK/end/termination.txt'"
m=$(mutant optimist 's/^    TERMINATION=unconfirmed$/    TERMINATION=confirmed/')
mcheck "mutant: an end path that calls every termination confirmed is caught" "! unconfirmed_fails '$m'"
m=$(mutant lenient 's/^  \[ "\$TERMINATION" = confirmed \] || exit 1$/  true/')
mcheck "mutant: an --end-instance that ignores an unconfirmed termination is caught" "! unconfirmed_fails '$m'"
check "the session ends on a failing status unless the termination was confirmed" \
  "command grep -qxF '[ \"\$TERMINATION\" = confirmed ] || exit 1' '$S'"

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed" >&2; exit 1; fi
