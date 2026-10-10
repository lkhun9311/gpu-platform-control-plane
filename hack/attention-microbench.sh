#!/usr/bin/env bash
#
# Times vLLM's own FlashAttention call on one A10G over a registered grid of mixed-step shapes.
# docs/superpowers/specs/2026-10-07-the-attention-kernel-measured-alone.md.
#
# Three development studies on the step-boundary archive narrowed the mixed-step misses to decoder waves whose
# cost depends on the prefill chunk beside them, and the archive cannot be used a fourth time. This measures the
# attention kernel alone, on fresh data, with the arguments the engine passed, so the mechanism is tested rather
# than fitted.
#
# It is m5b-scheduler-microtest.sh's lifecycle, unchanged: a Spot instance in a default public subnet, no
# inbound ports, everything from user-data, results to S3, a backstop inside the instance and a terminate here.
# No model is served and no weights are pulled: the kernel runs inside the pinned engine image on random
# tensors of Qwen2.5-3B's attention shape.
#
# DRY_RUN=1 stops before run-instances, with the user-data and the measurement written to OUT.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

REGION="${AWS_REGION:-ap-northeast-2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.xlarge}"
MAX_SPOT_PRICE="${MAX_SPOT_PRICE:-0.80}"
# 90 minutes of instance life is about three times the measurement, and the cheapest possible protection
# against a hung run: a Spot g5.xlarge left running for a day would cost more than every paid session so far.
BACKSTOP_SECONDS="${BACKSTOP_SECONDS:-3600}"
# The registered grid to time; 1 is the first session's, 2 adds the prefill's own context.
BENCH_GRID="${BENCH_GRID:-1}"
OUT="${OUT:-hack/attention-bench-$(date -u +%Y%m%d-%H%M%S)}"
# The role reads as well as writes, because grid 3's compositions (117 KB) do not fit in the 16 KB of user-data
# and are fetched from this run's prefix. A new name, because spot_ensure_profile leaves an existing role's policy
# as it found it, and the first two sessions' role could only write.
STACK="attention-microbench-rw"
# Every object this run writes lives under its own prefix, and the completion marker is one of them.
#
# The keys used to be fixed at the bucket root -- results.json, DONE -- against a bucket that keeps
# objects for 30 days. So the second run of this script found the FIRST run's DONE on its opening
# poll, downloaded the first run's results, printed them as its own readings and exited 0, having
# launched and paid for a GPU instance that it then terminated seconds later without waiting for it.
# A stale marker is indistinguishable from a fast one, and the recorded transcript for that case is
# hack/test/spot-lifecycle/golden/stale-done.txt.
#
# Derived from the run directory rather than generated, so the local evidence and the S3 objects carry
# the same name and either can be found from the other.

# LAUNCH_IDENTITY names ONE launch attempt, and it is the only thing allowed to decide what gets terminated.
#
# This runner had no per-run random value: RUN_ID is the output directory's basename, a timestamp to the second
# that OUT can override. A launch whose answer was lost has to be findable afterwards, and a selector two
# concurrent runs can share is one that can terminate somebody else's instance.
#
# Unlike the run id this MAY stop the session: a run that cannot name what it created must not create
# anything. No ${LAUNCH_IDENTITY:-} default, because an identity a caller can choose is not an identity.
LAUNCH_IDENTITY=$(openssl rand -hex 16 2>/dev/null \
  || head -c16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "${#LAUNCH_IDENTITY}" -eq 32 ] \
  || fail "no source of 128 random bits (openssl and /dev/urandom both refused), so a launch could not be named well enough to be recovered. Nothing was launched."
# The S3 prefix carries this launch's identity as well as the output directory's name.
# With the name alone, a reused OUT found an earlier run's DONE on the first poll, downloaded those results as
# this run's and terminated the new instance (found by review, reproduced with stubs).
RUN_ID="$(basename "$OUT")-${LAUNCH_IDENTITY:0:12}"

say()  { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case "$BENCH_GRID" in 1|2|3) ;; *) fail "BENCH_GRID=$BENCH_GRID is not a registered grid" ;; esac
COMPOSITIONS="${COMPOSITIONS:-docs/superpowers/specs/data/2026-10-07-archive-attention-compositions.json}"
[ "$BENCH_GRID" != 3 ] || [ -s "$COMPOSITIONS" ] || fail "grid 3 needs the archive's compositions; $COMPOSITIONS is missing"

# The EC2 lifecycle is shared with the price-of-protection runner and lives in its own file.
#
# Defined BEFORE sourcing, because the library only supplies defaults for names the caller has not
# provided. Without this its diagnostics would go to stderr while this script's go to stdout, and the two
# would interleave differently in a captured log.
spot_say()  { say "$@"; }
spot_fail() { fail "$@"; }
# BASH_SOURCE, not $0: inside a sourced file $0 is still this script, so locating the library by $0 would
# work here and break the moment anything else sourced it.
# shellcheck source=hack/lib/spot-run.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/spot-run.sh"

ACCOUNT=$(spot_account) || fail "not authenticated"
BUCKET="${BUCKET:-$STACK-$ACCOUNT}"

# The engine image, read from the manifest rather than typed here, so the benchmark times the same kernel
# the archive ran. A different digest would time a different kernel.
ENGINE_IMAGE=$(grep -oP '^\s*(- )?image:\s*\Kvllm/vllm-openai@sha256:\S+' config/vllm/deployment.yaml | head -1)
[ -n "$ENGINE_IMAGE" ] || fail "no digest-pinned vLLM image in config/vllm/deployment.yaml"

# An OUT that already holds results is refused: a download that failed would otherwise leave the earlier
# results.json in place, and the check at the end would report it as this run's (found by review).
[ ! -e "$OUT/results.json" ] || fail "$OUT already holds results.json; choose a new OUT"
mkdir -p "$OUT"
say "engine $ENGINE_IMAGE"
say "output $OUT"

# ---------------------------------------------------------------- results path
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"

# ---------------------------------------------------------------- instance role
# This measurement only ever writes. A runner that also ships a binary to the instance needs GetObject, and
# passing the policy in is what lets the two differ without the library knowing about either.
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"

# ---------------------------------------------------------------- placement
AMI=$(spot_resolve_ami "$REGION" \
  /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id) \
  || fail "could not resolve a GPU AMI"

# A default subnet, because default subnets assign public IPs and therefore reach the internet through an
# internet gateway rather than a NAT gateway. That is the whole cost argument: inbound is free there.
#
# The zone has to be one that actually offers this instance type, which is not every zone in the region: the
# first attempt took Subnets[0], landed in ap-northeast-2b, and was refused because g5 is not offered there.
# AWS will say which zones do, so it is asked rather than assumed.
ZONES=$(spot_zones_offering "$REGION" "$INSTANCE_TYPE")
[ -n "$ZONES" ] || fail "$INSTANCE_TYPE is offered in no availability zone of $REGION"
say "$INSTANCE_TYPE is offered in: $ZONES"

SUBNET=""
for z in $ZONES; do
  if SUBNET=$(spot_subnet_in_zone "$REGION" "$z"); then
    say "using $SUBNET in $z"
    break
  fi
  SUBNET=""
done
[ -n "$SUBNET" ] || fail "no default public subnet in any zone offering $INSTANCE_TYPE; this test relies on one for free ingress"

say "ami $AMI in $SUBNET"

RUNSCRIPT=$(mktemp)
# Armed at the first mktemp so a refusal before `trap cleanup EXIT` cannot leave these files in tmpfs.
# `trap cleanup EXIT` replaces it later, and cleanup removes the same files.
# Bash runs an EXIT trap on INT, TERM and HUP as well, measured 2026-10-04, so this also covers a signal in the window.
trap 'rm -f "${RUNSCRIPT:-}" "${UD:-}" "${MEASURE:-}"' EXIT
cat > "$RUNSCRIPT" <<'USERDATA'
#!/bin/bash
exec > >(tee /var/log/attention-bench.log) 2>&1
set -x
( sleep BACKSTOP_SECONDS_PLACEHOLDER; shutdown -h now ) &

IMAGE="ENGINE_IMAGE_PLACEHOLDER"
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"

# Keys are relative to this run's prefix, so no call site can write to the bucket root by forgetting.
upload() { aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/attention-bench.log log.txt; shutdown -h now' EXIT

nvidia-smi --query-gpu=name,driver_version,memory.total,clocks.max.sm --format=csv > /tmp/gpu.csv 2>&1
upload /tmp/gpu.csv gpu.csv
docker pull "$IMAGE"
# Grid 3 times the archive's compositions, uploaded beside this run's results; a failed fetch is a failed run.
if [ "BENCH_GRID_PLACEHOLDER" = 3 ]; then
  aws s3 cp "s3://$BUCKET/$PREFIX/compositions.json" /usr/local/bin/bench/compositions.json || exit 1
fi

rc=0
docker run --rm --gpus all --entrypoint python3 -e BENCH_GRID=BENCH_GRID_PLACEHOLDER -v /usr/local/bin/bench:/b:ro "$IMAGE" /b/flash_attn_grid.py \
  > /tmp/results.json 2>/tmp/bench.err || rc=$?
upload /tmp/results.json results.json
upload /tmp/bench.err stderr.txt

# DONE only for results that exist and parse; a failed run still uploads its log and stderr above.
if [ "$rc" -eq 0 ] && [ -s /tmp/results.json ] \
   && python3 -c 'import json,sys; json.load(open("/tmp/results.json"))' 2>/dev/null; then
  touch /tmp/DONE && upload /tmp/DONE DONE
else
  echo "measurement did not produce usable results (exit $rc); DONE withheld"
fi
USERDATA

# The measurement itself, kept as its own file so the shell wrapper stays about lifecycle and this stays
# about the experiment.
MEASURE=$(mktemp)
cp hack/attention-bench/flash_attn_grid.py "$MEASURE" || fail "could not read hack/attention-bench/flash_attn_grid.py"

# Assembled here rather than templated inside the heredoc, so the measurement file stays valid Python that
# can be read and run on its own.
UD=$(mktemp)
{
  echo "#!/bin/bash"
  echo "mkdir -p /usr/local/bin/bench"
  echo "cat > /usr/local/bin/bench/flash_attn_grid.py <<'MEASUREEOF'"
  cat "$MEASURE"
  echo "MEASUREEOF"
  sed -e "s|BACKSTOP_SECONDS_PLACEHOLDER|$BACKSTOP_SECONDS|" \
      -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" \
      -e "s|BENCH_GRID_PLACEHOLDER|$BENCH_GRID|" \
      -e "s|ENGINE_IMAGE_PLACEHOLDER|$ENGINE_IMAGE|" \
      -e "s|BUCKET_PLACEHOLDER|$BUCKET|" "$RUNSCRIPT" | tail -n +2
} > "$UD"

# The FIRST thing checked about the payload, because it is the one `bash -n` cannot see.
#
# The stripping above begins with `tail -n +2`, which drops the heredoc's `#!/bin/bash`, and the line that
# re-emits it is one line in a block nobody reads twice. cloud-init executes user-data as a script ONLY when
# it begins with `#!`. A payload without one parses perfectly and does nothing: the instance boots, cloud-init
# declines to run it, and the machine bills until its backstop with no log at all, because the trap that
# uploads one lives inside the script that never ran.
#
# hack/m5c-gpu-session.sh was written from the shape of this file and dropped that line. Its first paid run
# on 2026-09-11 held a g5.2xlarge for 145 minutes, about $1.64, and produced nothing. This guard is here so
# the next omission costs a refusal instead.
head -1 "$UD" | grep -q '^#!' \
  || fail "the generated user-data does not begin with a shebang, so cloud-init would not execute it and the instance would boot, do nothing, and bill until its backstop. See $OUT/user-data.sh"
cp "$UD" "$OUT/user-data.sh"
cp "$MEASURE" "$OUT/flash_attn_grid.py"
bash -n "$UD" || fail "the generated user-data does not parse; see $OUT/user-data.sh"
if [ "${DRY_RUN:-0}" = 1 ]; then
  trap - EXIT; rm -f "${RUNSCRIPT:-}" "${UD:-}" "${MEASURE:-}"
  say "DRY_RUN: nothing launched; the user-data and the measurement are in $OUT"
  exit 0
fi
if [ "$BENCH_GRID" = 3 ]; then
  cp "$COMPOSITIONS" "$OUT/compositions.json"
  aws s3 cp "$COMPOSITIONS" "s3://$BUCKET/$RUN_ID/compositions.json" >/dev/null \
    || fail "could not upload the compositions grid 3 times; nothing was launched"
fi

say "launching $INSTANCE_TYPE spot (max \$$MAX_SPOT_PRICE/h)"
# Retried across zones, because "no capacity right now" is a normal Spot answer rather than a fault, and a
# single-zone attempt turns it into an aborted run.
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=attention-microbench}]"
# LAUNCH_UNCERTAIN holds the client token of a launch whose outcome this script does not know.
#
# Set BEFORE the AWS call and cleared only once the answer is in, because the window that matters is the call
# itself: a signal arriving while run-instances executes reaches cleanup with IID still empty. The subnet is
# remembered with it because cleanup cannot see the launch loop's $SUBNET, and spot_reconcile_token refuses a
# query it cannot scope to a zone.
LAUNCH_UNCERTAIN=""
LAUNCH_UNCERTAIN_SUBNET=""
# The trap is armed BEFORE the launch loop, not after it.
#
# It used to sit below `say "instance $IID"`, which left a window: run-instances had returned an id and
# nothing would terminate it yet. Under `set -euo pipefail` a failed write of the instance-id file, a
# SIGPIPE on stdout because this script was piped to something that had exited, or a Ctrl-C in that window
# all exit with a GPU instance running and no terminator. spot_terminate returns 0 on an empty id, so
# arming it early costs nothing and closes the window.
cleanup_ran=0
cleanup() {
  # Run once, whichever of EXIT, INT and TERM gets here first.
  #
  # The `exit 1` below re-enters this function through EXIT, so without the guard an interrupted session
  # called terminate-instances twice and polled for the state twice. The guard is set before the work,
  # because the second entry arrives while the first is still inside that polling.
  [ "$cleanup_ran" = "1" ] && return 0
  cleanup_ran=1
  # The mktemp files this runner made are removed here, on every path that reaches cleanup.
  #
  # RUNSCRIPT, UD and MEASURE were never deleted by anything: one invocation left two or three files in
  # /tmp, which is tmpfs here, so they are RAM rather than disk. Driving the four runners through the
  # golden suite a few times put 6167 of them there. ${VAR:-} because cleanup can run before they are set.
  #
  # These files are created before `trap cleanup EXIT` is armed, so a run that refuses before the launch --
  # an unset REPS, a dirty tree, credentials too short -- used to leave them: four full suites, 59 scenarios,
  # left 2. An EXIT trap armed at the first mktemp now removes them on that path, and this one replaces it.
  rm -f "${RUNSCRIPT:-}" "${UD:-}" "${MEASURE:-}" "${attempt_err:-}"
  # An unresolved launch is settled FIRST, because it is the instance nobody knows the id of.
  #
  # A signal during run-instances lands here with IID empty, and the terminate below would then report
  # `<none>` and exit 0 while an instance AWS accepted goes on billing.
  if [ -n "$LAUNCH_UNCERTAIN" ]; then
    spot_reconcile_token "$REGION" "$LAUNCH_UNCERTAIN" "$LAUNCH_UNCERTAIN_SUBNET" 6 || {
      printf 'TERMINATION UNCONFIRMED for the launch under token %s -- check the console before the next paid run\n' \
        "$LAUNCH_UNCERTAIN" >"${OUT:-.}/termination.txt" 2>/dev/null || true
      exit 1
    }
    LAUNCH_UNCERTAIN=""
  fi
  if spot_terminate "$REGION" "$IID"; then
    printf 'terminated %s\n' "${IID:-<none>}" >"${OUT:-.}/termination.txt" 2>/dev/null || true
  else
    printf 'TERMINATION UNCONFIRMED for %s -- check the console before the next paid run\n' \
      "${IID:-<none>}" >"${OUT:-.}/termination.txt" 2>/dev/null || true
    printf 'TERMINATION UNCONFIRMED for %s\n' "${IID:-<none>}" >&2
    # A record is not a gate. This runner launches a g5.xlarge like the other three and was the one left
    # out when they gained this: it terminated, ignored the answer, wrote nothing, and exited 0 whether or
    # not the instance was gone. A run whose instance may still be billing is a failed run.
    exit 1
  fi
}
IID=""
# A signal ends the run; it does not just clean up and fall through.
#
# `trap cleanup EXIT INT TERM` ran cleanup on a signal and then RESUMED the script, because a handler that
# returns hands control back to where the signal arrived -- so an interrupted session could go on to launch
# an instance the guard had already marked as cleaned.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  say "trying $z ($SUBNET)"
  # One token per (run, zone). EC2's idempotency is zonal because the subnet pins the zone, so retrying the
  # same zone under the same token returns the instance already created rather than making a second one.
  LAUNCH_TOKEN="attnbench-$LAUNCH_IDENTITY-$z"
  # Only a refusal that names a ZONE's shortage may move to another zone.
  #
  # A whitelist, not a denylist: an unrecognised error read as "definitive" sends the loop on to buy a second
  # instance while the first may already exist. Read as "ambiguous" it costs a retry and at worst a refused
  # session. LAUNCH_DEFINITIVE stops the OUTER loop as well, because `break` leaves only the inner one.
  LAUNCH_DEFINITIVE=""
  attempt=0
  # Outside $OUT on purpose: a file there holding only the last attempt's stderr is a second, thinner thing
  # that looks like evidence beside launch-errors.txt.
  attempt_err=$(mktemp)
  while :; do
    attempt=$((attempt + 1))
    : > "$attempt_err"
    # Set BEFORE the call. Everything after this line, including a signal, can be reconciled.
    LAUNCH_UNCERTAIN="$LAUNCH_TOKEN"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
    IID=$(spot_launch "$REGION" "$AMI" "$INSTANCE_TYPE" "$SUBNET" "$STACK" \
          "$MAX_SPOT_PRICE" 150 "$UD" "$TAGS" "$LAUNCH_TOKEN" 2>"$attempt_err") || IID=""
    cat "$attempt_err" >> "$OUT/launch-errors.txt"

    if [ -n "$IID" ] && [ "$IID" != "None" ]; then LAUNCH_UNCERTAIN=""; break; fi
    IID=""

    if grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$attempt_err" 2>/dev/null; then
      LAUNCH_UNCERTAIN=""            # AWS said it created nothing here; another zone is the right move
      break
    fi
    # IdempotentParameterMismatch is EVIDENCE AN INSTANCE EXISTS: AWS returns it only when this token was
    # already used by a request that SUCCEEDED, so reading it as a clean refusal walks away from a billing
    # instance.
    if grep -q 'IdempotentParameterMismatch' "$attempt_err" 2>/dev/null; then
      LAUNCH_UNCERTAIN=""
      spot_reconcile_token "$REGION" "$LAUNCH_TOKEN" "$SUBNET" 6 \
        || fail "a launch in $z was refused as a duplicate of an earlier request under the same token, so an instance exists, and AWS could not be asked which one. Nothing further is launched. See $OUT/launch-errors.txt"
      fail "a launch in $z was refused as a duplicate of an earlier request under the same token; whatever that earlier request created has been terminated. See $OUT/launch-errors.txt"
    fi
    if grep -qE 'UnauthorizedOperation|ValidationError|InvalidParameter|RequestLimitExceeded|InstanceLimitExceeded' \
         "$attempt_err" 2>/dev/null; then
      LAUNCH_UNCERTAIN=""            # AWS refused before creating anything
      LAUNCH_DEFINITIVE=1            # and no other zone would answer differently
      break
    fi

    # Ambiguous: the answer was lost, not given. Retry the SAME zone with the SAME token.
    if [ "$attempt" -lt "${LAUNCH_AMBIGUOUS_TRIES:-3}" ]; then
      say "the launch in $z gave no answer this script can classify; retrying the same zone with the same token"
      continue
    fi
    # Still unresolved. Do NOT move zones: an instance may exist under this token, and a second zone would
    # make two. The token is cleared BEFORE the outcome is judged, because `fail` re-enters cleanup through
    # the EXIT trap and cleanup would otherwise reconcile the same token a second time.
    LAUNCH_UNCERTAIN=""
    spot_reconcile_token "$REGION" "$LAUNCH_TOKEN" "$SUBNET" 6 \
      || fail "a launch in $z was neither confirmed nor refused, and AWS could not be asked what it created. Nothing further is launched, because a second zone would risk a second instance. See $OUT/launch-errors.txt"
    fail "a launch in $z gave no classifiable answer after $attempt attempts; anything it created has been terminated. Re-run when the API is answering. See $OUT/launch-errors.txt"
  done
  rm -f "$attempt_err"
  [ -n "$IID" ] && break
  [ -n "$LAUNCH_DEFINITIVE" ] && break
done
# Also removed on the paths that leave this loop by exiting -- `fail` inside it, or a signal -- because /tmp
# here is tmpfs, so a leaked file is memory rather than disk. cleanup runs on all of them.
rm -f "${attempt_err:-}" 2>/dev/null || true
[ -n "$IID" ] || fail "no zone would launch $INSTANCE_TYPE; see $OUT/launch-errors.txt"
echo "$IID" > "$OUT/instance-id"
say "instance $IID"

# The trap stays here rather than in the library. Traps do not stack -- the last one for a signal replaces
# the earlier one -- so a library that armed its own would silently discard whatever the caller installed,
# and the thing being discarded is what stops an idle GPU instance from billing all night.

say "waiting for results (the engine has an image and weights to pull first)"
# The three endings are distinguished by exit status, because "the loop ended" has three causes and only
# one of them is a result. The library echoes the instance's terminal state on the second.
done_seen=0
ended_early=""
marker_rc=0
ended_early=$(spot_wait_for_marker "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" 120 30) || marker_rc=$?
case "$marker_rc" in
  0) say "results are up"; done_seen=1 ;;
  2) say "instance ended before writing DONE" ;;
esac

for k in results.json log.txt stderr.txt; do
  rm -f "$OUT/$k"
  aws s3 cp "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" >/dev/null 2>&1 || true
done

# Said before the results are read, and separately from them, because the two failures need different
# answers: an instance that died has a log worth reading, and a run that timed out is probably still
# alive and worth watching. Both used to arrive as the same "no results were written".
if [ "$done_seen" -eq 0 ]; then
  if [ -n "$ended_early" ]; then
    fail "the instance was $ended_early before it wrote its completion marker; $OUT/log.txt is whatever it managed to upload"
  fi
  fail "no completion marker after 120 polls; the run either is still going or hung, and $IID has been terminated"
fi

aws s3 cp "s3://$BUCKET/$RUN_ID/gpu.csv" "$OUT/gpu.csv" >/dev/null 2>&1 || true
if [ -s "$OUT/results.json" ]; then
  say "results: $OUT/results.json ($(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["rows"]), "shapes, FA", d["fa_version"], "on", d["device"])' "$OUT/results.json"))"
else
  fail "no results were written; $OUT/log.txt may say why"
fi
