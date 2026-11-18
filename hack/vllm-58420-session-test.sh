#!/usr/bin/env bash
# What vllm-58420-session.sh refuses before it spends anything, run offline.
#
# The session script runs from a throwaway clean repository holding a copy of it, with a fake `aws` and a fake `curl`
# first on PATH.
# Both record every call and fail, so no case here can reach AWS or the network whatever the script does, and a case
# that should have refused first but called one is caught by the record, not by a bill.
# The control case shows the refusals do not fire on a valid invocation: it must get past all of them and stop at
# the first AWS call, the read-only caller identity, which the fake refuses.
# The last checks hold the script's step bounds and pinned hashes to the harness's own constants, so the hard stop
# cannot drift from the work and the instance cannot be handed another build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/hack/vllm-58420-session.sh"
GO_SRC="$ROOT/internal/bench/srpf_sweep.go"
DIAG=hack/eks-serve/holdcap-study/diagnostic
failures=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
for tool in aws curl; do
  cat >"$WORK/bin/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >>"\$AWS_CALLS"
echo "fake $tool: no network call is allowed in this test" >&2
exit 1
EOF
  chmod +x "$WORK/bin/$tool"
done

# fixture makes a clean repository holding the session script and what it reads, and prints its path.
fixture() {
  local repo
  repo=$(mktemp -d "$WORK/repo.XXXXXX")
  mkdir -p "$repo/hack/lib" "$repo/$DIAG"
  cp "$SCRIPT" "$repo/hack/"
  cp "$ROOT/hack/lib/spot-run.sh" "$repo/hack/lib/"
  cp "$ROOT/hack/m5c-gpu-session.sh" "$repo/hack/"
  cp "$ROOT/$DIAG/SHA256SUMS" "$ROOT/$DIAG/trace-off-3.jsonl" "$ROOT/$DIAG/manifest-off-3.yaml" "$repo/$DIAG/"
  git -C "$repo" init -q || return 1
  git -C "$repo" add -A || return 1
  git -C "$repo" -c user.name=fixture -c user.email=fixture@invalid -c commit.gpgsign=false commit -q -m fixture || return 1
  echo "$repo"
}

# session runs the fixture's script with the fakes and env, printing its output; AWS_CALLS lists the calls it made.
session() {
  local repo="$1"
  shift
  : >"$WORK/aws-calls"
  env -u SESSION_CONFIRM -u VLLM58420_AMI_ID PATH="$WORK/bin:$PATH" AWS_CALLS="$WORK/aws-calls" "$@" \
    bash "$repo/hack/vllm-58420-session.sh" 2>&1
}

# refuses asserts the script exits non-zero with want in its output and never called aws or curl.
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
    echo "FAIL $name: refused only after calling out: $(paste -sd';' "$WORK/aws-calls")" >&2
    failures=$((failures + 1))
  else
    echo "ok   $name"
  fi
}

commit_all() {
  git -C "$1" -c user.name=fixture -c user.email=fixture@invalid -c commit.gpgsign=false commit -q -am "$2"
}

REPO=$(fixture) || { echo "FAIL could not build the fixture repository" >&2; exit 1; }
AMI=ami-0123456789abcdef0

refuses "no owner confirmation" "SESSION_CONFIRM=yes is required" "$REPO" VLLM58420_AMI_ID=$AMI
refuses "a confirmation other than yes" "SESSION_CONFIRM=yes is required" "$REPO" SESSION_CONFIRM=y VLLM58420_AMI_ID=$AMI
refuses "no AMI" "VLLM58420_AMI_ID is unset" "$REPO" SESSION_CONFIRM=yes
refuses "an AMI that is not an ID" "pins the AMI by ID" "$REPO" SESSION_CONFIRM=yes VLLM58420_AMI_ID=latest
for v in INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS VLLM_IMAGE ARM_ORDER SCHEDULING_POLICY VLLM_ENABLE_SRPF \
  VLLM_SRPF_STARVATION_THRESHOLD LONG_PREFILL_TOKEN_THRESHOLD SEED; do
  refuses "a caller's $v" "$v is set" "$REPO" SESSION_CONFIRM=yes VLLM58420_AMI_ID=$AMI "$v=1"
done

DIRTY=$(fixture) || exit 1
echo dirty >"$DIRTY/untracked.txt"
refuses "a dirty tree" "the working tree is dirty" "$DIRTY" SESSION_CONFIRM=yes VLLM58420_AMI_ID=$AMI

# A trace edited and committed is a clean tree, so only its listed checksum stops it from being replayed.
EDITED=$(fixture) || exit 1
sed -i '1s/"offsetMs":265/"offsetMs":266/' "$EDITED/$DIAG/trace-off-3.jsonl"
commit_all "$EDITED" edited
refuses "a trace that is not the frozen one" "does not match its SHA256SUMS" "$EDITED" SESSION_CONFIRM=yes VLLM58420_AMI_ID=$AMI

# A list that lost the manifest's line still verifies the trace's, so both lines must be required.
UNLISTED=$(fixture) || exit 1
sed -i '/  manifest-off-3.yaml$/d' "$UNLISTED/$DIAG/SHA256SUMS"
commit_all "$UNLISTED" unlisted
refuses "a manifest its SHA256SUMS does not list" "does not match its SHA256SUMS" "$UNLISTED" SESSION_CONFIRM=yes VLLM58420_AMI_ID=$AMI

# A rate that puts the worst case over the cap must be refused by the script's own arithmetic.
COSTLY=$(fixture) || exit 1
sed -i 's/^ALL_IN_RATE=.*/ALL_IN_RATE=1.40/' "$COSTLY/hack/vllm-58420-session.sh"
commit_all "$COSTLY" costly
refuses "a worst case over \$3" "is not under \$3.00" "$COSTLY" SESSION_CONFIRM=yes VLLM58420_AMI_ID=$AMI

# Seven arms at run 8's 500 s ready bound end at 13,800 s, $3.18 at the all-in rate, so the cut bound is what fits them.
# Mutation that turns this red: drop the worst-case check, or compute it from a fixed six arms.
OLDREADY=$(fixture) || exit 1
sed -i 's/^READY_BOUND_S=.*/READY_BOUND_S=500/' "$OLDREADY/hack/vllm-58420-session.sh"
commit_all "$OLDREADY" oldready
refuses "seven arms at run 8's ready bound" "the worst case, 13800 s at \$0.8292/h, is not under \$3.00" "$OLDREADY" SESSION_CONFIRM=yes VLLM58420_AMI_ID=$AMI
MOREARMS=$(fixture) || exit 1
sed -i 's/^ARMS=.*/ARMS=8/' "$MOREARMS/hack/vllm-58420-session.sh"
commit_all "$MOREARMS" morearms
refuses "an eighth arm" "is not under \$3.00" "$MOREARMS" SESSION_CONFIRM=yes VLLM58420_AMI_ID=$AMI

# The control: a valid invocation passes every refusal and stops at the first AWS call, which is the caller identity.
out=$(session "$REPO" SESSION_CONFIRM=yes VLLM58420_AMI_ID=$AMI)
calls=$(cat "$WORK/aws-calls")
if [[ "$out" != *"could not read the caller's account"* || "$calls" != "aws sts get-caller-identity --query Account --output text" ]]; then
  echo "FAIL a valid invocation did not reach the caller-identity check, or called more than it" >&2
  echo "  calls: $calls" >&2
  echo "  got: ${out:0:300}" >&2
  failures=$((failures + 1))
else
  echo "ok   a valid invocation passes every refusal and stops at the first AWS call"
fi

# The step bounds the stop is summed from must be the harness's own: seconds in the script, time.Second in Go.
script_value() { sed -n "s/^$1=\([0-9]*\)\$/\1/p" "$SCRIPT"; }
go_value() { sed -n "s/^[[:space:]]*$1 = \([0-9]*\) \* time.Second\$/\1/p" "$GO_SRC"; }
for pair in PULL_BOUND_S:SRPFSweepPullBound IMAGE_IDENTITY_S:SRPFSweepImageIdentityBound MODEL_BOUND_S:SRPFSweepModelBound \
  READY_BOUND_S:SRPFSweepReadyBound ARM_IDENTITY_S:SRPFSweepArmIdentityBound CAPTURE_BOUND_S:SRPFSweepCaptureBound \
  WARMUP_S:SRPFSweepWarmupBound IDLE_S:SRPFSweepIdleBound METRICS_S:SRPFSweepMetricsBound REPLAY_S:SRPFSweepReplayBound \
  STOP_BOUND_S:SRPFSweepStopBound; do
  s=$(script_value "${pair%%:*}") g=$(go_value "${pair##*:}")
  if [[ -z "$s" || "$s" != "$g" ]]; then
    echo "FAIL ${pair%%:*} is '$s' s in the script but ${pair##*:} is '$g' s in the harness" >&2
    failures=$((failures + 1))
  else
    echo "ok   ${pair%%:*} = ${pair##*:} = $s s"
  fi
done
arms=$(sed -n 's/^const srpfSweepArmCount = \([0-9]*\)$/\1/p' "$GO_SRC")
if [[ -z "$arms" || "$(script_value ARMS)" != "$arms" ]]; then
  echo "FAIL the script runs $(script_value ARMS) arms and the harness $arms" >&2
  failures=$((failures + 1))
else
  echo "ok   ARMS = srpfSweepArmCount = $arms"
fi

# The schedule the script runs by must be the sum of the harness's bounds, recomputed here from the Go source.
g() { go_value "$1"; }
arm_s=$(( $(g SRPFSweepReadyBound) + $(g SRPFSweepArmIdentityBound) + $(g SRPFSweepCaptureBound) + $(g SRPFSweepWarmupBound) +
  2 * $(g SRPFSweepIdleBound) + 2 * $(g SRPFSweepMetricsBound) + $(g SRPFSweepReplayBound) + $(g SRPFSweepStopBound) ))
want_end=$(( $(script_value BRINGUP_S) + $(g SRPFSweepPullBound) + $(g SRPFSweepImageIdentityBound) + $(g SRPFSweepModelBound) + arms * arm_s ))
schedule=$(env -u SESSION_CONFIRM PATH="$WORK/bin:$PATH" AWS_CALLS="$WORK/aws-calls" bash "$SCRIPT" --print-schedule 2>&1)
if [[ "$schedule" != "harness_end_s=$want_end "* ]]; then
  echo "FAIL the script schedules '$schedule', but the harness's bounds end at $want_end s" >&2
  failures=$((failures + 1))
else
  echo "ok   the schedule ($schedule) ends the harness at the sum of its bounds"
fi

# The instance must be handed the build and the trace the harness checks for, or every arm would be refused on the card.
go_string() { sed -n "s/^[[:space:]]*$1[[:space:]]*= \"\([0-9a-f]*\)\"\$/\1/p" "$GO_SRC"; }
sums_trace=$(awk '$2 == "trace-off-3.jsonl" {print $1}' "$ROOT/$DIAG/SHA256SUMS")
if [[ "$(sed -n 's/^SCHED_SHA256=\([0-9a-f]*\)$/\1/p' "$SCRIPT")" != "$(go_string SRPFSweepPRSchedulerSHA256)" ||
  -z "$(go_string SRPFSweepPRSchedulerSHA256)" ]]; then
  echo "FAIL the script's SCHED_SHA256 is not the harness's SRPFSweepPRSchedulerSHA256" >&2
  failures=$((failures + 1))
elif [[ "$(sed -n 's/^PR_COMMIT=\([0-9a-f]*\)$/\1/p' "$SCRIPT")" != "$(go_string SRPFSweepPRCommit)" ]]; then
  echo "FAIL the script's PR_COMMIT is not the harness's SRPFSweepPRCommit" >&2
  failures=$((failures + 1))
elif [[ -z "$sums_trace" || "$sums_trace" != "$(go_string SRPFSweepTraceChecksum)" ]]; then
  echo "FAIL the committed trace-off-3.jsonl ($sums_trace) is not the harness's SRPFSweepTraceChecksum" >&2
  failures=$((failures + 1))
else
  echo "ok   the scheduler hash, the PR commit and the trace checksum are the harness's"
fi

# A Spot reclaim can come at any time, so the records must leave the instance while the harness runs, and the caller
# must collect them when the final archive never arrives.
# The instance role has no s3:ListBucket, so the copy must be a plain put of one object, never aws s3 sync.
# The live replay rows grow while tar reads them, and GNU tar then exits 1, which must still upload.
if grep -q 'aws s3 sync' "$SCRIPT" ||
  ! grep -qxF '  ( while :; do' "$SCRIPT" ||
  ! grep -qF 'tar --warning=no-file-changed -czf /tmp/partial.tgz -C /src/sr-run sweep' "$SCRIPT" ||
  ! grep -qF '[ $? -le 1 ] && timeout 60 nice -n 19 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz"' "$SCRIPT" ||
  ! grep -qxF '[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"' "$SCRIPT" ||
  ! grep -qF 'sleep PARTIAL_SYNC_S_PLACEHOLDER' "$SCRIPT" ||
  ! grep -qF 's|PARTIAL_SYNC_S_PLACEHOLDER|$PARTIAL_SYNC_S|' "$SCRIPT" ||
  ! grep -qF 'aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/partial.tgz" "$OUT/partial.tgz"' "$SCRIPT" ||
  ! grep -qx 'PARTIAL_SYNC_S=30' "$SCRIPT"; then
  echo "FAIL the sweep's records are not copied off the instance during the run, or not collected after a reclaim" >&2
  failures=$((failures + 1))
else
  echo "ok   each arm's records leave the instance every 30 s as one archive and a reclaimed run's partial evidence is collected"
fi

# The DONE wait must outlast the stop; a fixed attempt count once ended it before the work could.
wait_call=$(grep -n 'spot_wait_for_marker_until "\$REGION"' "$SCRIPT")
if ! grep -qx 'WAIT_ATTEMPTS=$(( STOP_FROM_LAUNCH_S / WAIT_INTERVAL_S + 2 ))' "$SCRIPT" ||
  ! grep -qF '"$RUN_ID/DONE" "$IID" $(( L + STOP_FROM_LAUNCH_S )) "$WAIT_INTERVAL_S" "$WAIT_ATTEMPTS"' <<<"$wait_call"; then
  echo "FAIL the DONE wait's attempts are not derived from the stop: $wait_call" >&2
  failures=$((failures + 1))
else
  echo "ok   the DONE wait polls until the stop, not for a fixed count"
fi

# The spliced bring-up does not stop on a failed command, so its last lines must judge the outcome.
bringup_tail=$(awk '/echo "cat > \/tmp\/bringup.sh/{on=1} on{print} /echo "BRINGUP"/{exit}' "$SCRIPT")
if ! grep -q 'systemctl is-active --quiet docker || { .*exit 1; }' <<<"$bringup_tail" ||
  ! grep -q 'grep -q nvidia || { .*exit 1; }' <<<"$bringup_tail"; then
  echo "FAIL the bring-up script does not end by refusing a stopped docker or one without the nvidia runtime" >&2
  failures=$((failures + 1))
else
  echo "ok   the bring-up exits non-zero unless docker runs with the nvidia runtime"
fi

# The instance runs only the inputs this session hashed: each is fetched and checked before the harness starts.
fetches=$(grep -c '^fetch [A-Z_]*PLACEHOLDER [A-Z_]*PLACEHOLDER$\|^fetch [a-z.]* [A-Z_0-9]*_PLACEHOLDER$' "$SCRIPT")
fetch_body=$(awk '/^fetch\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$SCRIPT")
if [[ "$fetches" != 4 ]] ||
  ! grep -qxF '  [ "$(sha256sum "/opt/sr/$1" | cut -d'"' '"' -f1)" = "$2" ] || { echo "checksum mismatch for $1"; exit 1; }' <<<"$fetch_body"; then
  echo "FAIL the user-data fetches $fetches of its four inputs, or its fetch does not compare each with this session's hash" >&2
  failures=$((failures + 1))
else
  echo "ok   the harness, the scheduler, the trace and the manifest are each checked on the instance"
fi

# A clean tree names the harness's source only if the build cannot be pointed at other files.
if ! grep -qF 'GOFLAGS= GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/benchharness" ./cmd/benchharness' "$SCRIPT"; then
  echo "FAIL the harness build inherits GOFLAGS or GOWORK, which can compile sources the commit does not hold" >&2
  failures=$((failures + 1))
else
  echo "ok   the harness build ignores the caller's GOFLAGS and GOWORK"
fi

# The default output directory is created before the purchase, so a refused attempt must not leave the tree dirty.
if ! git -C "$ROOT" check-ignore -q "hack/vllm-58420-$(date -u +%Y%m%dT%H%M%SZ)/session.log" ||
  ! grep -qF 'OUT="${OUT:-hack/vllm-58420-$(date -u +%Y%m%dT%H%M%SZ)}"' "$SCRIPT"; then
  echo "FAIL the session's default output directory is not ignored, so a refused attempt blocks the next on a dirty tree" >&2
  failures=$((failures + 1))
else
  echo "ok   the session's default output directory is ignored"
fi

# Run 3 on 2026-11-16 ran past the pull bound pulling anonymously, so the instance logs in to ECR Public before the
# sweep, and the role's policy, which spot_ensure_profile never updates on an existing role, is written every time.
s="$ROOT/hack/vllm-58420-session.sh"
if ! grep -qF 'aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws' "$s" ||
  ! grep -qF 'ecr-public:GetAuthorizationToken' "$s" || ! grep -qF 'sts:GetServiceBearerToken' "$s" ||
  ! grep -qF 'aws iam put-role-policy --role-name "$STACK" --policy-name write-results --policy-document "$ROLE_POLICY"' "$s"; then
  echo "FAIL the instance does not log in to ECR Public with a role allowed to, written on every run" >&2
  failures=$((failures + 1))
else
  echo "ok   the instance logs in to ECR Public before the pull, and the role's policy is rewritten each run"
fi

# Run 5 on 2026-11-17 was still extracting layers when the pull bound cut it, so the volume is provisioned past gp3's
# free baseline, and that cost is in the all-in rate the $3 check reads.
s="$ROOT/hack/vllm-58420-session.sh"
if ! grep -qF '"$UD" "$TAGS" "$token" "" "" "$EBS_THROUGHPUT_MIBPS" "$EBS_IOPS"' "$s" ||
  ! grep -qx 'EBS_THROUGHPUT_MIBPS=500' "$s" || ! grep -qx 'EBS_IOPS=6000' "$s" || ! grep -qx 'ALL_IN_RATE=0.8292' "$s" ||
  ! grep -qF ',\"Throughput\":$ebs_throughput' "$ROOT/hack/lib/spot-run.sh"; then
  echo "FAIL the launch does not provision the volume's throughput and IOPS, or the all-in rate does not count them" >&2
  failures=$((failures + 1))
else
  echo "ok   the launch provisions 500 MiB/s and 6,000 IOPS, and the all-in rate counts them"
fi

# Run 6 returned its evidence with all six arms refused and exited 0, so the session reads the measured count itself.
d=$(mktemp -d); mkdir -p "$d/sweep"
printf '{"arms":[{"outcome":"measured"},{"outcome":"failed"}]}' >"$d/sweep/summary.json"
got=$(python3 -c 'import json, sys
arms = json.load(open(sys.argv[1]))["arms"]
print("%d of %d" % (sum(a.get("outcome") == "measured" for a in arms), len(arms)))' "$d/sweep/summary.json")
s="$ROOT/hack/vllm-58420-session.sh"
if [ "$got" != "1 of 2" ] || ! grep -qF 'echo "measured=$MEASURED"' "$s" || ! grep -qF '[ "$MEASURED" = "$ARMS of $ARMS" ] || exit 2' "$s" ||
  ! grep -qF 'print("%d of %d" % (sum(a.get("outcome") == "measured" for a in arms), len(arms)))' "$s"; then
  echo "FAIL the session does not report and exit on the number of measured arms (counted $got)" >&2
  failures=$((failures + 1))
else
  echo "ok   the session reports how many arms were measured and exits 2 unless all of them were"
fi
rm -rf "$d"

# Run 7 was reclaimed in ap-northeast-2a, so that zone is tried last but still tried.
order=$(ZONES="ap-northeast-2a ap-northeast-2c ap-northeast-2d"; RECLAIMED_ZONES="ap-northeast-2a"
  ZONES=$(for z in $ZONES; do case " $RECLAIMED_ZONES " in *" $z "*) ;; *) echo "$z" ;; esac; done
    for z in $ZONES; do case " $RECLAIMED_ZONES " in *" $z "*) echo "$z" ;; esac; done)
  paste -sd' ' <<<"$ZONES")
if [ "$order" != "ap-northeast-2c ap-northeast-2d ap-northeast-2a" ] || ! grep -qx 'RECLAIMED_ZONES="ap-northeast-2a"' "$ROOT/hack/vllm-58420-session.sh" ||
  [ "$(grep -cF 'for z in $ZONES; do case " $RECLAIMED_ZONES " in *" $z "*)' "$ROOT/hack/vllm-58420-session.sh")" != 2 ]; then
  echo "FAIL a reclaimed zone is not tried last (got $order)" >&2
  failures=$((failures + 1))
else
  echo "ok   a zone that reclaimed this study is tried after the others"
fi

# The schedule and the cost are pinned to their values, so a change to either is a change this test is edited for.
schedule=$(env -u SESSION_CONFIRM PATH="$WORK/bin:$PATH" AWS_CALLS="$WORK/aws-calls" bash "$SCRIPT" --print-schedule 2>&1)
if [[ "$schedule" != "harness_end_s=11920 evidence_s=12040 stop_s=12100 termination_s=12400" ]] ||
  [[ "$(python3 -c 'print("%.4f" % (12400 / 3600 * 0.8292))')" != 2.8561 ]] || ! grep -qx 'ALL_IN_RATE=0.8292' "$SCRIPT"; then
  echo "FAIL the schedule is '$schedule', not the 12,400 s worst case (\$2.8561) the session was sized for" >&2
  failures=$((failures + 1))
else
  echo "ok   the worst case is 12,400 s at \$0.8292/h, \$2.8561"
fi

# The arms are the built harness's, printed from each arm's own docker run arguments.
# fcfs and priority carry no SRPF variable; each SRPF arm carries VLLM_ENABLE_SRPF=1 and its own threshold.
# Mutation that turns this red: give priority the SRPF variables, set every SRPF arm's threshold to 5, or reorder the arms.
BH="$WORK/benchharness"
if ! (cd "$ROOT" && GOFLAGS= GOWORK=off go build -o "$BH" ./cmd/benchharness) >"$WORK/build.log" 2>&1; then
  echo "FAIL the harness did not build: $(tail -5 "$WORK/build.log")" >&2
  failures=$((failures + 1))
else
  arms_got=$("$BH" srpf-sweep -print-arms 2>&1)
  arms_want="1 priority policy=priority no-srpf-env
2 srpf-s10 policy=fcfs VLLM_ENABLE_SRPF=1 VLLM_SRPF_STARVATION_THRESHOLD=10
3 srpf-s2 policy=fcfs VLLM_ENABLE_SRPF=1 VLLM_SRPF_STARVATION_THRESHOLD=2
4 srpf-s5 policy=fcfs VLLM_ENABLE_SRPF=1 VLLM_SRPF_STARVATION_THRESHOLD=5
5 fcfs policy=fcfs no-srpf-env
6 srpf-s3 policy=fcfs VLLM_ENABLE_SRPF=1 VLLM_SRPF_STARVATION_THRESHOLD=3
7 srpf-s8 policy=fcfs VLLM_ENABLE_SRPF=1 VLLM_SRPF_STARVATION_THRESHOLD=8"
  if [[ "$arms_got" != "$arms_want" ]]; then
    echo "FAIL the harness runs these arms:" >&2
    echo "$arms_got" >&2
    failures=$((failures + 1))
  elif [[ "$(grep -c . <<<"$arms_got")" != "$(script_value ARMS)" ]]; then
    echo "FAIL the harness prints $(grep -c . <<<"$arms_got") arms and the script is sized for $(script_value ARMS)" >&2
    failures=$((failures + 1))
  else
    echo "ok   the arms are fcfs, priority and SRPF at 2, 3, 5, 8 and 10, each with its own variables, in the frozen order"
  fi
fi
# The session records the printed arms before anything is bought, and refuses a count it was not sized for.
if ! grep -qF '"$OUT/benchharness" srpf-sweep -print-arms >"$OUT/arms.txt"' "$SCRIPT" ||
  ! grep -qF '[ "$(grep -c . "$OUT/arms.txt")" = "$ARMS" ] || fail' "$SCRIPT" ||
  ! grep -qF 'echo "arms_sha256=' "$SCRIPT"; then
  echo "FAIL the session does not record the harness's arms or check their count against its schedule" >&2
  failures=$((failures + 1))
else
  echo "ok   the session records the harness's arms in its provenance and refuses a count it was not sized for"
fi

# The pins are the 2026-11-18 head's, not run 8's.
if ! grep -qx 'PR_COMMIT=b8b0d3610dee138db57ba465897f4b7af74abbd5' "$SCRIPT" ||
  ! grep -qx 'SCHED_SHA256=2b39435388f0d716cb5a3f02b532f4225d1688153b483a67643af8c26389972a' "$SCRIPT" ||
  ! grep -qF 'SRPFSweepImage = "public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:bfb59377bd23ee1ac0a31ae8aa4836baaf7d840e6c1004906afbec1ffbf35467"' "$GO_SRC" ||
  ! grep -qF 'SRPFSweepBaseCommit = "5039f736e612ae637099eba3fa645031d416ef53"' "$GO_SRC"; then
  echo "FAIL the PR head, its scheduler hash, the image digest or the merge base is not the one this sweep was prepared for" >&2
  failures=$((failures + 1))
else
  echo "ok   the PR head b8b0d36, its scheduler 2b394353, merge base 5039f736 and image bfb59377 are pinned"
fi

if [[ $failures -ne 0 ]]; then
  echo "$failures check(s) did not behave as registered" >&2
  exit 1
fi
echo "every refusal fires before AWS, none fires on a valid invocation, and the stop and build are the harness's"
