#!/usr/bin/env bash
# What version-readiness-session.sh refuses before it spends anything, run offline.
#
# The session script runs from a throwaway clean repository holding a copy of it, with a fake `aws` first on PATH.
# The fake records every call and fails, so no case here can reach AWS whatever the script does, and a case that
# should have refused before AWS but called it is caught by the record, not by a bill.
# The control case shows the refusals do not fire on a valid invocation: it must get past all of them and stop at
# the first AWS call, the read-only caller identity, which the fake refuses.
# The last checks hold the script's step bounds to the harness's own constants, so the hard stop cannot drift from the work.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat >"$WORK/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$AWS_CALLS"
echo "fake aws: no AWS call is allowed in this test" >&2
exit 1
EOF
chmod +x "$WORK/bin/aws"

# fixture makes a clean repository holding the session script and what it sources, and prints its path.
fixture() {
  local repo
  repo=$(mktemp -d "$WORK/repo.XXXXXX")
  mkdir -p "$repo/hack/lib"
  cp "$ROOT/hack/version-readiness-session.sh" "$repo/hack/"
  cp "$ROOT/hack/lib/spot-run.sh" "$repo/hack/lib/"
  cp "$ROOT/hack/m5c-gpu-session.sh" "$repo/hack/"
  git -C "$repo" init -q || return 1
  git -C "$repo" add -A || return 1
  git -C "$repo" -c user.name=fixture -c user.email=fixture@invalid -c commit.gpgsign=false commit -q -m fixture || return 1
  echo "$repo"
}

# session runs the fixture's script with the fake aws and env, printing its output; AWS_CALLS lists the calls it made.
session() {
  local repo="$1"
  shift
  : >"$WORK/aws-calls"
  env -u SESSION_CONFIRM -u VERSION_READINESS_AMI_ID PATH="$WORK/bin:$PATH" AWS_CALLS="$WORK/aws-calls" "$@" \
    bash "$repo/hack/version-readiness-session.sh" 2>&1
}

# refuses asserts the script exits non-zero with want in its output and never called aws.
refuses() {
  local name="$1" want="$2" repo="$3"
  shift 3
  local out status
  out=$(session "$repo" "$@")
  status=$?
  if [[ $status -eq 0 ]]; then
    echo "FAIL $name: exited 0; it must refuse" >&2
    failures=$((failures + 1))
  elif [[ "$out" != *"$want"* ]]; then
    echo "FAIL $name: refused, but not for this reason" >&2
    echo "  wanted to find: $want" >&2
    echo "  got: ${out:0:300}" >&2
    failures=$((failures + 1))
  elif [[ -s "$WORK/aws-calls" ]]; then
    echo "FAIL $name: refused only after calling aws: $(paste -sd';' "$WORK/aws-calls")" >&2
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

REPO=$(fixture) || { echo "FAIL could not build the fixture repository" >&2; exit 1; }
AMI=ami-0123456789abcdef0

refuses "no owner confirmation" "SESSION_CONFIRM=yes is required" "$REPO" VERSION_READINESS_AMI_ID=$AMI
refuses "a confirmation other than yes" "SESSION_CONFIRM=yes is required" "$REPO" SESSION_CONFIRM=y VERSION_READINESS_AMI_ID=$AMI
refuses "no AMI" "VERSION_READINESS_AMI_ID is unset" "$REPO" SESSION_CONFIRM=yes
refuses "an AMI that is not an ID" "pins the AMI by ID" "$REPO" SESSION_CONFIRM=yes VERSION_READINESS_AMI_ID=latest
for v in INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS READINESS_SECONDS WARM_STARTS; do
  refuses "a caller's $v" "$v is set" "$REPO" SESSION_CONFIRM=yes VERSION_READINESS_AMI_ID=$AMI "$v=1"
done

DIRTY=$(fixture) || exit 1
echo dirty >"$DIRTY/untracked.txt"
refuses "a dirty tree" "the working tree is dirty" "$DIRTY" SESSION_CONFIRM=yes VERSION_READINESS_AMI_ID=$AMI

# A rate that puts the worst case over the cap must be refused by the script's own arithmetic.
COSTLY=$(fixture) || exit 1
sed -i 's/^ALL_IN_RATE=.*/ALL_IN_RATE=1.40/' "$COSTLY/hack/version-readiness-session.sh"
git -C "$COSTLY" -c user.name=fixture -c user.email=fixture@invalid -c commit.gpgsign=false commit -q -am costly
refuses "a worst case over \$3" "is not under \$3.00" "$COSTLY" SESSION_CONFIRM=yes VERSION_READINESS_AMI_ID=$AMI

# The control: a valid invocation passes every refusal and stops at the first AWS call, which is the caller identity.
out=$(session "$REPO" SESSION_CONFIRM=yes VERSION_READINESS_AMI_ID=$AMI)
calls=$(cat "$WORK/aws-calls")
if [[ "$out" != *"could not read the caller's account"* || "$calls" != "sts get-caller-identity --query Account --output text" ]]; then
  echo "FAIL a valid invocation did not reach the caller-identity check, or called more of AWS" >&2
  echo "  calls: $calls" >&2
  echo "  got: ${out:0:300}" >&2
  failures=$((failures + 1))
else
  echo "ok   a valid invocation passes every refusal and stops at the first AWS call"
fi

# The step bounds the stop is summed from must be the harness's own: seconds in the script, time.Second in Go.
script_value() { sed -n "s/^$1=\([0-9]*\)\$/\1/p" "$ROOT/hack/version-readiness-session.sh"; }
go_value() { sed -n "s/^[[:space:]]*$1 = \([0-9]*\) \* time.Second\$/\1/p" "$ROOT/internal/bench/version_readiness.go"; }
for pair in PULL_BOUND_S:ReadinessPullBound MODEL_BOUND_S:ReadinessModelBound CAPTURE_BOUND_S:ReadinessCaptureBound \
  STOP_BOUND_S:ReadinessStopBound; do
  s=$(script_value "${pair%%:*}") g=$(go_value "${pair##*:}")
  if [[ -z "$s" || "$s" != "$g" ]]; then
    echo "FAIL ${pair%%:*} is '$s' s in the script but ${pair##*:} is '$g' s in the harness" >&2
    failures=$((failures + 1))
  else
    echo "ok   ${pair%%:*} = ${pair##*:} = $s s"
  fi
done
# Read inside versionAsyncDesign only: the rehearsal design registers a shorter bound of its own.
readiness=$(sed -n '/^func versionAsyncDesign()/,/^}/ s/^[[:space:]]*ReadinessSeconds:[[:space:]]*\([0-9]*\),$/\1/p' "$ROOT/internal/bench/version_study.go")
warm=$(sed -n 's/^[[:space:]]*ReadinessWarmStarts = \([0-9]*\)$/\1/p' "$ROOT/internal/bench/version_readiness.go")
if [[ "$(script_value READINESS_BOUND_S)" != "$readiness" || -z "$warm" || "$(script_value STARTS)" != "$(( 3 * (1 + warm) ))" ]]; then
  echo "FAIL the script's readiness bound $(script_value READINESS_BOUND_S) or $(script_value STARTS) starts differ from the design's $readiness s and 3 x (1 + $warm)" >&2
  failures=$((failures + 1))
else
  echo "ok   READINESS_BOUND_S = the registered $readiness s, STARTS = 3 x (1 + $warm)"
fi

# The schedule the script runs by must be the sum of the harness's bounds, recomputed here from the Go source.
g() { go_value "$1"; }
want_end=$(( $(script_value BRINGUP_S) + 2 * $(g ReadinessPullBound) + $(g ReadinessModelBound) +
  3 * (1 + warm) * (readiness + $(g ReadinessCaptureBound) + $(g ReadinessStopBound)) ))
schedule=$(env -u SESSION_CONFIRM PATH="$WORK/bin:$PATH" AWS_CALLS="$WORK/aws-calls" bash "$ROOT/hack/version-readiness-session.sh" --print-schedule 2>&1)
if [[ "$schedule" != "harness_end_s=$want_end "* ]]; then
  echo "FAIL the script schedules '$schedule', but the harness's bounds end at $want_end s" >&2
  failures=$((failures + 1))
else
  echo "ok   the schedule ($schedule) ends the harness at the sum of its bounds"
fi

if [[ $failures -ne 0 ]]; then
  echo "$failures check(s) did not behave as registered" >&2
  exit 1
fi
echo "every refusal fires before AWS, none fires on a valid invocation, and the stop is summed from the harness's bounds"
