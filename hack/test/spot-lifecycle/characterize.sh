#!/usr/bin/env bash
#
# Pins the observable behaviour of a single-instance GPU runner so a refactor can be shown to have
# changed nothing.
#
# WHY THIS EXISTS
#
# hack/m5b-scheduler-microtest.sh and the price-of-protection runner share about 150 lines of EC2
# lifecycle: results bucket, instance profile, AMI and subnet discovery, Spot launch with cross-zone
# retry, completion polling, teardown. That is being extracted into hack/lib/spot-run.sh. The obvious
# check -- diff the generated user-data before and after -- proves only that the remote workload is
# unchanged, and the remote workload is not the part being moved. Launch arguments, zone retry, stale
# completion markers and teardown are, and they are the parts that cost money when they break.
#
# So each scenario runs the real script with `aws` and `sleep` replaced by recording stubs, and
# compares the resulting call transcript against a golden file. A refactor that preserves behaviour
# produces no diff.
#
# WHAT IT CANNOT DO
#
# Everything past the AWS API boundary: cloud-init, IAM propagation delay, real Spot capacity, GPU
# readiness, whether the instance can actually reach S3. A green run here is a necessary condition for
# a safe refactor and not a substitute for one real launch.
set -uo pipefail

cd "$(dirname "$0")/../../.." || exit 1
ROOT=$(pwd)
HERE="hack/test/spot-lifecycle"

# The script under test. Overridable so the same driver can pin more than one runner.
TARGET="${TARGET:-hack/m5b-scheduler-microtest.sh}"
# One golden directory per runner, named after it. Two runners sharing a directory would collide on
# scenario names that mean different things, and a stale golden from the other runner would either fail
# for the wrong reason or, worse, pass.
SUITE=$(basename "$TARGET" .sh)
GOLDEN="$HERE/golden/$SUITE"
mkdir -p "$GOLDEN"

# Without the stubs this script runs the REAL aws against whatever credentials are loaded.
#
# It only prepends a directory to PATH, so a missing or non-executable stub is not an error, it is a
# silent change of subject: every scenario would launch real instances or fail with real API errors, and
# the transcript would be empty rather than wrong. The stubs also live under a path that .gitignore's
# "bin/" rule swallowed, so "the files are simply absent" is a state this has actually been in.
for stub in aws sleep; do
  [ -x "$(dirname "$0")/bin/$stub" ] || {
    printf 'FAIL: %s/bin/%s is missing or not executable; refusing to run against the real one\n' \
      "$(dirname "$0")" "$stub" >&2
    exit 2
  }
done

UPDATE=0
ONLY=""
for a in "$@"; do
  case "$a" in
    --update) UPDATE=1 ;;
    --only=*) ONLY="${a#--only=}" ;;
    *) printf 'usage: %s [--update] [--only=<scenario>]\n' "$0" >&2; exit 2 ;;
  esac
done

pass=0; fail=0
# Counted so that --only with a misspelled scenario name cannot report "0 passed, 0 failed" and exit 0,
# which is the same sentence a completely green run would print if there were no scenarios left.
selected=0

# Each scenario is a name followed by the stub environment that defines it.
#
# The names say what condition is being pinned, not what the script is expected to do -- the golden
# file is what says that, and it was recorded from the script rather than written by hand.
run_scenario() {
  local name="$1"; shift
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  selected=$((selected + 1))

  local work; work=$(mktemp -d)
  local out="$work/run"
  mkdir -p "$out"

  export STUB_STATE="$work/state"
  export STUB_TRANSCRIPT="$work/transcript.txt"
  export STUB_OUT="$out"
  : > "$STUB_TRANSCRIPT"

  # The stubs shadow the real binaries by sitting first on PATH.
  local rc=0
  (
    export PATH="$ROOT/$HERE/bin:$PATH"
    export OUT="$out"
    export AWS_REGION=ap-northeast-2
    export BUCKET=stub-bucket
    "$@" >"$work/stdout.txt" 2>"$work/stderr.txt"
  ) || rc=$?

  # The shipped binary's checksum changes with every Go edit, so it is normalized out of the user-data
  # golden and the property it exists for is asserted directly: the checksum the instance will verify must
  # be the checksum of the binary that was actually uploaded. Goldening the digit string instead would make
  # any change to cmd/benchharness break this suite for no behavioural reason, and a golden that breaks for
  # no reason is one that gets regenerated without being read.
  if [ -f "$out/user-data.sh" ] && [ -f "$out/benchharness" ]; then
    local embedded built
    embedded=$(grep -oE 'HARNESS_SHA="[0-9a-f]{64}"' "$out/user-data.sh" | head -1 | cut -d'"' -f2)
    built=$(sha256sum "$out/benchharness" | cut -d' ' -f1)
    if [ -n "$embedded" ] && [ "$embedded" = "$built" ]; then
      printf 'harness checksum: user-data matches the uploaded binary\n' >> "$STUB_TRANSCRIPT"
    else
      printf 'harness checksum: MISMATCH (user-data %s, binary %s)\n' "${embedded:-none}" "$built" >> "$STUB_TRANSCRIPT"
    fi
    sed -i 's/HARNESS_SHA="[0-9a-f]\{64\}"/HARNESS_SHA="<SHA>"/' "$out/user-data.sh"
  fi

  # What the script SAID is part of the golden, not only what it called and what it returned.
  #
  # Without this, replacing the results check `[ -s ]` with `[ -f ]` -- accepting an empty results file
  # as a result -- produced no diff at all: the run still exited non-zero, because the reading printer
  # then died on the empty file instead. Same exit status, completely different meaning, and the run
  # would have printed a table from nothing on any input that merely parsed. An exit code is a very
  # coarse description of what a script did.
  #
  # Volatile substrings are replaced so two runs of one scenario agree.
  sed -e "s#$out#<OUT>#g" \
      -e "s#${TMPDIR:-/tmp}/tmp\.[A-Za-z0-9]*#<TMP>#g" \
      -e "s#/tmp/tmp\.[A-Za-z0-9]*#<TMP>#g" \
      "$work/stdout.txt" "$work/stderr.txt" > "$work/messages.txt"

  # The transcript alone would hide a script that recorded every AWS call correctly and then exited
  # non-zero, or one that stopped writing its run directory. Both are behaviour.
  {
    # Repeating poll cycles are folded to one copy plus a count, so a 120-poll timeout is readable in
    # a diff without losing the count itself.
    python3 "$ROOT/$HERE/collapse.py" < "$STUB_TRANSCRIPT"
    printf -- '--- exit %s\n' "$rc"
    printf -- '--- messages\n'
    cat "$work/messages.txt"
    printf -- '--- files\n'
    ( cd "$out" && find . -type f | LC_ALL=C sort )
  } > "$work/actual.txt"

  local golden="$GOLDEN/$name.txt"
  if [ "$UPDATE" = "1" ]; then
    cp "$work/actual.txt" "$golden"
    printf 'RECORDED %s\n' "$name"
  elif [ ! -f "$golden" ]; then
    printf 'FAIL     %s (no golden; run with --update to record)\n' "$name"
    fail=$((fail + 1))
  elif diff -u "$golden" "$work/actual.txt" > "$work/diff.txt"; then
    printf 'ok       %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL     %s\n' "$name"
    sed -n '1,60p' "$work/diff.txt"
    fail=$((fail + 1))
  fi

  # The generated user-data is goldened separately, because it is the one artifact whose exact bytes
  # reach the instance, and because the transcript deliberately reduces it to a placeholder path.
  #
  # One file for every scenario, not one per scenario: the remote workload does not depend on which
  # zone answered or whether the bucket already existed, so eight copies would only mean eight places
  # for a real change to hide in a diff nobody reads.
  if [ -f "$out/user-data.sh" ]; then
    local udg="$GOLDEN/user-data.sh"
    if [ "$UPDATE" = "1" ]; then
      cp "$out/user-data.sh" "$udg"
    elif [ ! -f "$udg" ]; then
      # Absent is not "nothing to compare". Deleting the golden used to turn this check off without
      # saying so, which is the difference between a check that passed and a check that did not run.
      printf 'FAIL     %s (no user-data golden; run with --update to record)\n' "$name"
      fail=$((fail + 1))
    elif ! diff -u "$udg" "$out/user-data.sh" > "$work/ud.diff"; then
      printf 'FAIL     %s (user-data changed)\n' "$name"
      sed -n '1,40p' "$work/ud.diff"
      fail=$((fail + 1))
    fi
  fi

  rm -rf "$work"
}

# --- the scenarios ---------------------------------------------------------------------------------
#
# One set per runner. Selected by suite rather than run unconditionally, because the scenarios encode what
# a particular runner does: pointing TARGET at something else and running the microtest's scenarios against
# it would compare a runner to another runner's expectations and call the difference a regression.

scenarios_microtest() {
# Nothing exists yet: the bucket and the instance profile are both created on the way through.
STUB_BUCKET_EXISTS=0 STUB_PROFILE_EXISTS=0 STUB_DONE_AFTER=2 \
  STUB_PRESENT_KEYS="results.json log.txt stderr.txt" \
  run_scenario fresh bash "$TARGET"

# The steady state after the first run: both already exist, so neither is touched.
STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=2 \
  STUB_PRESENT_KEYS="results.json log.txt stderr.txt" \
  run_scenario existing bash "$TARGET"

# Spot has no capacity in the first zone. "No capacity right now" is a normal answer, not a fault, and
# the run has to continue into the next zone rather than abort.
STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=2 \
  STUB_LAUNCH_FAIL_ZONES="ap-northeast-2a" STUB_PRESENT_KEYS="results.json log.txt stderr.txt" \
  run_scenario zone-retry bash "$TARGET"

# No zone will take it. This must fail loudly and must not leave an instance behind.
STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 \
  STUB_LAUNCH_FAIL_ZONES="ap-northeast-2a ap-northeast-2c" \
  run_scenario all-zones-fail bash "$TARGET"

# One of the zones offers the instance type but has no default public subnet, so it is skipped.
STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=2 \
  STUB_NO_SUBNET_ZONES="ap-northeast-2a" STUB_PRESENT_KEYS="results.json log.txt stderr.txt" \
  run_scenario no-subnet-in-zone bash "$TARGET"

# The instance dies before it writes its completion marker -- a reclaimed Spot node.
# Only the log made it up, via the remote trap. There are no results to download, and a harness that
# invented some would report a dead instance as a completed run.
STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=-1 STUB_TERMINATED_AFTER=2 \
  STUB_PRESENT_KEYS="log.txt" \
  run_scenario instance-died bash "$TARGET"

# The marker arrives but the results file is empty. The run produced nothing and must say so.
STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=2 STUB_RESULTS_EMPTY=1 \
  STUB_PRESENT_KEYS="results.json log.txt stderr.txt" \
  run_scenario empty-results bash "$TARGET"

# The marker never arrives and the instance stays up: the poll loop runs to exhaustion.
#
# Added because none of the other scenarios reaches the end of the loop, so its length was untested --
# replacing 120 attempts with 2 left every transcript identical while killing a real run that was still
# pulling fifteen gigabytes of weights.
STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=-1 \
  STUB_PRESENT_KEYS="log.txt" \
  run_scenario poll-exhausted bash "$TARGET"

# THE ONE THAT MATTERS: the completion marker is already in the bucket from a PREVIOUS run.
#
# The results bucket keeps objects for 30 days and the keys are fixed at the root, so a second run of
# this script finds the first run's DONE on its first poll. Whatever this scenario records is what the
# script does today; it is pinned here so that fixing it is a visible, deliberate diff.
STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_PRESENT_AT_START=1 \
  run_scenario stale-done bash "$TARGET"
}

scenarios_price_of_protection() {
  # The pilot's four arms, everything present, results returned.
  STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=2 \
    STUB_PRESENT_KEYS="evidence.tgz run.json log.txt stderr.txt" \
    run_scenario pilot bash "$TARGET"

  # First run in a fresh account: bucket and profile are created, and the profile must carry GetObject
  # because this runner's instance downloads the binary it was sent.
  STUB_BUCKET_EXISTS=0 STUB_PROFILE_EXISTS=0 STUB_DONE_AFTER=2 \
    STUB_PRESENT_KEYS="evidence.tgz run.json log.txt stderr.txt" \
    run_scenario fresh bash "$TARGET"

  # Spot has no capacity in the first zone.
  STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=2 \
    STUB_LAUNCH_FAIL_ZONES="ap-northeast-2a" \
    STUB_PRESENT_KEYS="evidence.tgz run.json log.txt stderr.txt" \
    run_scenario zone-retry bash "$TARGET"

  # The instance dies before finishing. Only the log made it up, so there is no archive to unpack and the
  # run must refuse rather than report on an empty directory.
  STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=-1 STUB_TERMINATED_AFTER=2 \
    STUB_PRESENT_KEYS="log.txt" \
    run_scenario instance-died bash "$TARGET"

  # The marker never arrives and the instance stays up: the poll runs to exhaustion.
  STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=-1 \
    STUB_PRESENT_KEYS="log.txt" \
    run_scenario poll-exhausted bash "$TARGET"

  # The marker arrives but the archive is empty: the instance said it finished and sent nothing usable.
  STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_AFTER=2 STUB_EMPTY_ARCHIVE=1 \
    STUB_PRESENT_KEYS="evidence.tgz run.json log.txt stderr.txt" \
    run_scenario empty-archive bash "$TARGET"

  # A previous run's marker sits at the bucket root. This runner scopes its keys, so it must not see it.
  STUB_BUCKET_EXISTS=1 STUB_PROFILE_EXISTS=1 STUB_DONE_PRESENT_AT_START=1 \
    STUB_PRESENT_KEYS="log.txt" \
    run_scenario stale-done bash "$TARGET"
}

case "$SUITE" in
  m5b-scheduler-microtest)  scenarios_microtest ;;
  m5b-price-of-protection)  scenarios_price_of_protection ;;
  *) printf 'FAIL: no scenarios defined for %s\n' "$SUITE" >&2; exit 2 ;;
esac

if [ "$selected" -eq 0 ]; then
  printf 'FAIL: --only=%s matched no scenario\n' "$ONLY" >&2
  exit 2
fi

printf '\n%s: %d passed, %d failed\n' "$SUITE" "$pass" "$fail"
[ "$fail" -eq 0 ]
