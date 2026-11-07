#!/usr/bin/env bash
#
# Runs hack/eks-gitops-session.sh with TRAIN=ddp against stub tools, to show that each of its training refusals stops
# the session before anything is created: no Terraform call, no kill switch.
#
#   bash hack/test/check-train-session-refusals.sh
#
# The refusals sit ahead of the kill switch on purpose, so the script can be run up to them for free. A case that
# passes every training refusal is stopped by the stub gh a few lines later, before the kill switch, and is told
# from a refusal by the line train_require_new_cluster prints when it finds no cluster.
set -uo pipefail
self="$(readlink -f "$0")"
cd "$(dirname "$0")/../.." || exit 1
# The session bounds each paid phase by a cgroup it makes, so these run where it can: a delegated scope, entered here
# when not started in one.
# shellcheck source=hack/lib/phase-supervisor.sh
. hack/lib/phase-supervisor.sh
phase_supervisor_enter bash "$self" "$@" || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/stub" <<'EOF'
#!/usr/bin/env bash
tool=$(basename "$0")
printf '%s %s\n' "$tool" "$*" >>"${STUB_CALLS:?the stub was given nowhere to record its calls}" || exit 98
case "$tool $*" in
  "aws eks list-clusters"*)
    if [[ -n "${STUB_OTHER_CLUSTER:-}" ]]; then printf '%s\n' "$STUB_OTHER_CLUSTER"; else echo None; fi ;;
  "aws eks describe-cluster"*)
    if [[ -n "${STUB_CLUSTER_EXISTS:-}" ]]; then echo ACTIVE; exit 0; fi
    echo "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found" >&2
    exit 254 ;;
  "aws sts get-caller-identity"*) echo "${STUB_ACCOUNT:-111111111111}" ;;
  # The session lease (hack/lib/session-lease.sh): an Active reaper, and a store kept in one file beside the call log.
  "aws lambda get-function"*) echo Active ;;
  "aws ssm get-parameter --region"*"--name /gpu-platform/session-reaper/last-ok"*) date -u +%Y-%m-%dT%H:%M:%SZ ;;
  "aws ssm get-parameter"*)
    if [[ -f "$STUB_CALLS.lease" ]]; then cat "$STUB_CALLS.lease"; exit 0; fi
    echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2
    exit 254 ;;
  "aws ssm put-parameter"*)
    set -- "$@"
    while [[ $# -gt 0 && "$1" != --value ]]; do shift; done
    printf '%s' "$2" >"$STUB_CALLS.lease"
    echo '{"Version": 1}' ;;
  "gh "*) echo "stub gh refuses, so a case that passes every refusal stops here" >&2; exit 1 ;;
  "kubectl version"* | "helm version"* | "terraform version"* | "aws --version"*) echo "stub" ;;
  "terraform "*) echo "terraform reached" >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$work/bin/stub"
for t in aws terraform kubectl helm gh; do ln -s stub "$work/bin/$t"; done
sha="$(sha256sum experiments/cpu-ddp/train.py | cut -d' ' -f1)"

# The session runs from a copy holding only what it reads before Terraform, because it puts its own repository's bin/
# ahead of PATH: a checkout with bin/terraform would otherwise answer in the stub's place, and a case that reaches
# the cluster's init would run the real one.
repo="$work/repo"
mkdir -p "$repo/hack/lib" "$repo/experiments/cpu-ddp"
cp hack/eks-gitops-session.sh "$repo/hack/"
cp hack/lib/train-session.sh hack/lib/ddp-arms.sh hack/lib/gpu-ttl.sh hack/lib/phase-supervisor.sh hack/lib/session-teardown.sh hack/lib/session-lease.sh "$repo/hack/lib/"
cp experiments/cpu-ddp/train.py "$repo/experiments/cpu-ddp/"
mkdir -p "$repo/experiments/multi-gpu-throughput"
cp hack/lib/allreduce-arms.sh "$repo/hack/lib/"
cp experiments/multi-gpu-throughput/allreduce_bench.py experiments/multi-gpu-throughput/ddp_step_bench.py "$repo/experiments/multi-gpu-throughput/"
bench_sha="$(sha256sum experiments/multi-gpu-throughput/allreduce_bench.py | cut -d' ' -f1)"
step_sha="$(sha256sum experiments/multi-gpu-throughput/ddp_step_bench.py | cut -d' ' -f1)"
image="registry.example/nccl-tests@sha256:$(printf '%064d' 1)"
[[ ! -e "$repo/bin" ]] || bad "the session's copy has a bin/"

# session NAME WANT_LINE [VAR=VALUE...]: runs the session with TRAIN=ddp and the given environment, and checks that it
# exited non-zero, printed WANT_LINE, never called Terraform and never armed the kill switch.
session() {
  local name="$1" want="$2" out rc
  shift 2
  export STUB_CALLS="$work/$name.calls"
  : >"$STUB_CALLS"
  # HOME is empty, because the session puts ~/.local/bin ahead of PATH and a real aws there would answer instead.
  mkdir -p "$work/home"
  out="$(env -i HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" STUB_CALLS="$STUB_CALLS" SESSION_CONFIRM=yes AWS_PROFILE=stub EGRESS_CIDR=192.0.2.1/32 \
    EXDIR="$work/$name" TRAIN=ddp APPROVED_TRAIN_SHA256="$sha" TTL_MINUTES=300 "$@" \
    timeout 60 bash "$repo/hack/eks-gitops-session.sh" 2>&1)"
  rc=$?
  # A watchdog is a detached process whose command names its pid file under this run's directory; one left alive would
  # fire at TTL.
  # The case's name is not matched: the watchdog's command quotes it, a space becoming '\ ', and a name with spaces was
  # missed by the restart session's copy of this check.
  local stray
  stray="$(pgrep -f -- "KILL_PIDFILE=$work/" | paste -sd' ')"
  if [[ -n "$stray" ]]; then
    # shellcheck disable=SC2086
    for p in $stray; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
    bad "$name: left a watchdog running (pid $stray), stopped by the test"
    return
  fi
  if ((rc == 0)); then
    bad "$name: the session exited 0"
  elif [[ "$out" != *"$want"* ]]; then
    bad "$name: no '$want' in: $(tail -3 <<<"$out")"
  # Judged from the session's own log, not the stub's record: the session puts its repository's bin/ ahead of PATH,
  # and a real terraform found there would leave no line in the stub's.
  elif [[ ! -s "$work/$name/session.log" ]]; then
    bad "$name: the session wrote no log, so nothing shows where it stopped"
  elif grep -q 'terraform init\|TTL kill switch armed' "$work/$name/session.log"; then
    bad "$name: the session went past its refusals: $(grep 'terraform init\|TTL kill switch armed' "$work/$name/session.log" | head -1)"
  else
    ok "$name: $(grep -o "$want.*" <<<"$out" | head -1 | cut -c1-140)"
  fi
}

session "no approved hash" "needs APPROVED_TRAIN_SHA256" APPROVED_TRAIN_SHA256=
session "a short approved hash" "needs APPROVED_TRAIN_SHA256" APPROVED_TRAIN_SHA256=abc
session "a different train.py" "not the approved" APPROVED_TRAIN_SHA256="$(printf '%064d' 0)"
session "an unknown arm" "names warm-up, which is not an arm" TRAIN_ARMS="pass warm-up"
session "no arm" "names no arm" TRAIN_ARMS=" "
session "a deadline too short for the waits" "needs TTL_MINUTES of at least" TTL_MINUTES=120
session "with SERVE" "would buy GPUs in two groups" SERVE=yes
session "with STUDY" "would buy GPUs in two groups" STUDY=holdcap
session "with KEEP_UP" "refuses KEEP_UP=yes" KEEP_UP=yes
session "an existing cluster" "cluster gpu-platform already exists (ACTIVE)" STUB_CLUSTER_EXISTS=1
# Without TRAIN, SERVE or STUDY the nightly-destroy check, where the stub gh stops the cases above, is skipped, so these
# reach the account check that stands before the kill switch (gpt-6-astra's review of 116092ef, r5 finding 8).
session "another account" "paid sessions run only in gpu-lab (007635145730)" TRAIN= STUB_ACCOUNT=123456789012
session "keys in the environment" "AWS_ACCESS_KEY_ID is set in the environment" TRAIN= STUB_ACCOUNT=007635145730 AWS_ACCESS_KEY_ID=AKIASTUB
session "an unknown training mode" "not a training mode" TRAIN=fsdp
session "a zone letter for TRAIN_AZ" "TRAIN_AZ '2a' is not a zone name" TRAIN_AZ=2a
# A pin passes the refusals too, and says so; the line is how it is told from a session that never read TRAIN_AZ.
session "a pinned zone passes every refusal" "does not exist" TRAIN_AZ=ap-northeast-2a
grep -q "TRAIN_AZ: pinned to ap-northeast-2a" "$work/a pinned zone passes every refusal/session.log" &&
  ok "the pinned session logged its zone" ||
  bad "the pinned session did not log its zone: $(grep TRAIN_AZ "$work/a pinned zone passes every refusal/session.log")"
# Every refusal passed: the next stop is the destroy-window check or the stub gh, both before the kill switch.
session "every training refusal passed" "does not exist"
grep -q -- "eks describe-cluster --region ap-northeast-2 --name gpu-platform" "$work/every training refusal passed.calls" &&
  ok "the cluster asked about is the one the session would build" ||
  bad "the cluster asked about was: $(grep describe-cluster "$work/every training refusal passed.calls")"

# --- TRAIN=allreduce, experiment C -------------------------------------------------------------------------------
ar=(TRAIN=allreduce APPROVED_BENCH_SHA256="$bench_sha" APPROVED_STEP_SHA256="$step_sha" NCCLTESTS_IMAGE="$image" TTL_MINUTES=320)
session "C: no bench hash" "needs APPROVED_BENCH_SHA256" "${ar[@]}" APPROVED_BENCH_SHA256=
session "C: a different step bench" "ddp_step_bench.py is $step_sha, not the approved" "${ar[@]}" APPROVED_STEP_SHA256="$(printf '%064d' 0)"
session "C: no nccl-tests image" "needs NCCLTESTS_IMAGE" "${ar[@]}" NCCLTESTS_IMAGE=
session "C: an image by tag" "needs NCCLTESTS_IMAGE" "${ar[@]}" NCCLTESTS_IMAGE=registry.example/nccl-tests:2.13.11
session "C: a deadline too short for thirty jobs" "TRAIN=allreduce needs TTL_MINUTES of at least 310" "${ar[@]}" TTL_MINUTES=300
session "C: with SERVE" "TRAIN=allreduce with SERVE or STUDY" "${ar[@]}" SERVE=yes
session "C: with KEEP_UP" "refuses KEEP_UP=yes" "${ar[@]}" KEEP_UP=yes
session "C: every refusal passed" "does not exist" "${ar[@]}"
grep -q 'TRAIN=allreduce: 1 x g5.12xlarge of 4 GPUs, price ceiling \$6.98, GPU budget 13800s' "$work/C: every refusal passed/session.log" &&
  ok "C: one g5.12xlarge of four GPUs, ceiling \$6.98, 13,800 s of GPU budget" ||
  bad "C: the mode's settings: $(grep 'TRAIN=allreduce:' "$work/C: every refusal passed/session.log")"
session "C: an operator's ceiling" "does not exist" "${ar[@]}" TRAIN_MAX_PRICE=7.20
grep -q 'price ceiling \$7.20' "$work/C: an operator's ceiling/session.log" && ok "C: an operator's ceiling is kept" ||
  bad "C: the operator's ceiling was replaced: $(grep 'TRAIN=allreduce:' "$work/C: an operator's ceiling/session.log")"
# --- STUDY=prefixroute, which buys the same group with the same gates -------------------------------------------
# TRAIN is emptied in each case, so these are the routing study's refusals and not the training mode's.
session "prefixroute: a deadline too short for twelve cells" "STUDY=prefixroute needs TTL_MINUTES of at least" \
  TRAIN= STUDY=prefixroute TTL_MINUTES=300
session "prefixroute: one minute short of the first start and twelve cells" "STUDY=prefixroute needs TTL_MINUTES of at least 440" \
  TRAIN= STUDY=prefixroute TTL_MINUTES=439
session "prefixroute: with SERVE" "STUDY=prefixroute with SERVE or TRAIN would buy GPUs in two groups" \
  TRAIN= STUDY=prefixroute SERVE=yes TTL_MINUTES=440
session "prefixroute: with KEEP_UP" "refuses KEEP_UP=yes" TRAIN= STUDY=prefixroute KEEP_UP=yes TTL_MINUTES=440
session "prefixroute: an existing cluster" "cluster gpu-platform already exists (ACTIVE)" \
  TRAIN= STUDY=prefixroute STUB_CLUSTER_EXISTS=1 TTL_MINUTES=440
session "prefixroute: every refusal passed" "does not exist" TRAIN= STUDY=prefixroute TTL_MINUTES=440
# Any cluster in the Region refuses the session before its lease or watchdog: they all share one terraform state.
# Mutation that turns it red: check only a cluster of this session's name.
session "another cluster in the Region" "an EKS cluster already exists in ap-northeast-2 (gpu-other)" \
  STUB_ACCOUNT=007635145730 STUB_OTHER_CLUSTER=gpu-other TRAIN= TTL_MINUTES=300

# --- the kill switch, armed under an absolute EXDIR --------------------------------------------------------------
# Without TRAIN nothing stops the session before its kill switch, so it arms one and then dies at the stub's terraform
# init. The watchdog must have reported its pid where the session reads it; the test then stops it.
name="an armed kill switch"
export STUB_CALLS="$work/$name.calls"
: >"$STUB_CALLS"
out="$(env -i HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" STUB_CALLS="$STUB_CALLS" SESSION_CONFIRM=yes AWS_PROFILE=stub STUB_ACCOUNT=007635145730 \
  EGRESS_CIDR=192.0.2.1/32 EXDIR="$work/$name" TTL_MINUTES=300 timeout 60 bash "$repo/hack/eks-gitops-session.sh" 2>&1)"
pid="$(cat "$work/$name/ttl.pid" 2>/dev/null)"
# Found by the pid it wrote, never by its paths: the program quotes them with %q, so a path with a space is not on its
# command line as written, and a search by path found nothing and left the watchdog running past the test.
stray=""
[[ "$pid" =~ ^[0-9]+$ ]] && ps -o pid= -p "$pid" | grep -q . && stray="$pid"
if [[ -n "$pid" && "$stray" == "$pid" && "$out" == *"TTL kill switch armed: PID $pid"* ]]; then
  ok "$name: the watchdog reported pid $pid under an absolute EXDIR, and the session read it"
  grep -q '^terraform -chdir=infra/aws/cluster init' "$STUB_CALLS" && ok "$name: the cluster's init reached the stub, not a real terraform" ||
    bad "$name: the stub saw no init of the cluster root: $(grep '^terraform' "$STUB_CALLS" | head -3)"
  # The lease is written before the first terraform call, and holds this cluster.
  lease_at=$(grep -n '^aws ssm put-parameter' "$STUB_CALLS" | head -1 | cut -d: -f1)
  init_at=$(grep -n '^terraform -chdir=infra/aws/cluster init' "$STUB_CALLS" | head -1 | cut -d: -f1)
  if [[ -n "$lease_at" && -n "$init_at" ]] && ((lease_at < init_at)) && grep -q '"cluster": "gpu-platform"' "$STUB_CALLS.lease"; then
    ok "$name: the session lease was written before the cluster's init"
  else
    bad "$name: lease written at call '${lease_at}', init at '${init_at}', lease: $(cat "$STUB_CALLS.lease" 2>&1)"
  fi
else
  bad "$name: pid file '${pid:-absent}', processes '${stray:-none}', session said: $(grep -o 'TTL[^,]*\|never reported its pid[^;]*' <<<"$out" | head -1)"
fi
# The watchdog leads its own session (setsid), so its process group is its pid and holds its sleep too.
[[ -n "$stray" ]] && kill -- "-$stray"
sleep 1
# A zombie is not a survivor: it has exited and only waits to be reaped (codex review of a7d10208).
if [[ -n "$stray" ]] && ps -o stat= -g "$stray" | grep -qv '^Z'; then
  bad "$name: a watchdog survived the test: $(ps -o pid=,args= -g "$stray" | head -2)"
else
  ok "$name: the test stopped its watchdog"
fi

# The TTL role read from the bootstrap root's state: its failure is one line in the session log and its error goes to
# terraform.log, where all three paid restart runs printed terraform's whole error block into the session log, and a
# second copy of the read sent it to /dev/null; an ARN that was read is returned as it is.
for row in "fails|1|" "reads|0|arn:aws:iam::007635145730:role/gpu-platform-ttl-scaledown"; do
  IFS='|' read -r what rc arn <<<"$row"
  d="$work/ttl-role-$what"
  mkdir -p "$d/bin"
  if [[ $rc == 1 ]]; then
    printf '#!/bin/sh\necho "Error: Backend initialization required, please run \\"terraform init\\"" >&2\nexit 1\n' >"$d/bin/terraform"
  else
    printf '#!/bin/sh\nprintf %%s %s\n' "$arn" >"$d/bin/terraform"
  fi
  chmod +x "$d/bin/terraform"
  got="$(PATH="$d/bin:/usr/bin:/bin" bash -c 'EXDIR="$1"; log() { printf "%s\n" "$*" | tee -a "$EXDIR/session.log"; }
eval "$(awk "/^ttl_role_from_state\\(\\)/,/^}/" "$2")"
ttl_role_from_state' _ "$d" "$repo/hack/eks-gitops-session.sh" 2>"$d/stderr")"
  if [[ "$got" == "$arn" ]] && if [[ $rc == 1 ]]; then
    [[ "$(grep -c . "$d/session.log")" == 1 ]] && grep -q 'reads the TTL role from IAM' "$d/session.log" &&
      ! grep -q 'Backend initialization' "$d/session.log" && grep -q 'Backend initialization' "$d/terraform.log"
  else
    [[ ! -e "$d/session.log" ]]
  fi; then
    ok "the TTL role's read from state that $what returns '${arn:-nothing}'$([[ $rc == 1 ]] && echo ', and its error is in terraform.log, not the session log')"
  else
    bad "the TTL role's read from state that $what: got '$got', session.log: $(head -c 200 "$d/session.log" 2>&1)"
  fi
done

# A reused EXDIR holds the last session's ttl.pid, and the session read that pid before its new watchdog wrote its own,
# so it would have disarmed the dead one and left the live one to destroy the cluster at its TTL (gpt-6-astra's defect
# review of #505).
name="a reused EXDIR"
export STUB_CALLS="$work/$name.calls"
: >"$STUB_CALLS"
# Read-only, so the new watchdog cannot overwrite it first and hide the read: the race decided whether the test saw
# the defect, and a mutation removing the fix passed it.
mkdir -p "$work/$name" && echo 999999999 >"$work/$name/ttl.pid" && chmod 444 "$work/$name/ttl.pid"
out="$(env -i HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" STUB_CALLS="$STUB_CALLS" SESSION_CONFIRM=yes AWS_PROFILE=stub STUB_ACCOUNT=007635145730 \
  EGRESS_CIDR=192.0.2.1/32 EXDIR="$work/$name" TTL_MINUTES=300 timeout 60 bash "$repo/hack/eks-gitops-session.sh" 2>&1)"
pid="$(cat "$work/$name/ttl.pid" 2>/dev/null)"
stray=""
[[ "$pid" =~ ^[0-9]+$ && "$pid" != 999999999 ]] && ps -o pid= -p "$pid" | grep -q . && stray="$pid"
if [[ -n "$stray" && "$out" == *"TTL kill switch armed: PID $pid,"* && "$out" != *"PID 999999999"* ]]; then
  ok "$name: the session read its own watchdog's pid $pid, not the stale one left in the directory"
else
  bad "$name: pid file '${pid:-absent}', session said: $(grep -o 'TTL kill switch armed: PID [0-9]*\|never reported its pid' <<<"$out" | head -1)"
fi
# Found by its pid file's directory too: when the defect is back the pid file is the stale one, the watchdog's own pid is
# nowhere, and a mutation run left it alive; the pattern skips the space the program quotes in the name.
for p in $(printf "%s\n" $stray $(pgrep -f -- "KILL_PIDFILE=$work/a[^/]*reused") | sort -u); do kill -- "-$p"; done
sleep 1
left="$(pgrep -f -- "KILL_PIDFILE=$work/a[^/]*reused" | paste -sd' ')"
if [[ -n "$left" ]] || { [[ -n "$stray" ]] && ps -o stat= -g "$stray" | grep -qv '^Z'; }; then
  bad "$name: a watchdog survived the test: ${left:-$(ps -o pid=,args= -g "$stray" | head -2)}"
else
  ok "$name: the test stopped its watchdog"
fi

# Every call the session makes to the node gates passes the GPUs per node they require.
# The refusals above stop before any node is bought, so none of them reaches these calls: STUDY=prefixroute kept a
# four-argument train_qualify_nodes after #406 made the fifth required, and only a review found it (codex, c9ddbb42).
calls="$(python3 - hack/eks-gitops-session.sh <<'PY'
import re, shlex, sys
for n, line in enumerate(open(sys.argv[1]), 1):
    m = re.search(r'\$\((train_qualify_nodes|train_qualification_held) (.*?)\)"? *\|\|', line)
    if m:
        args = shlex.split(re.sub(r'\$\(\((.*?)\)\)', 'ARITH', m.group(2)))
        print(n, m.group(1), len(args))
PY
)"
short="$(awk '$3 < 5' <<<"$calls")"
[[ -n "$calls" && -z "$short" ]] && ok "every node-gate call passes its required count ($(wc -l <<<"$calls") calls)" ||
  bad "node-gate calls missing the required count: ${short:-no calls found}"

if [[ $fails -ne 0 ]]; then
  echo "check-train-session-refusals: $fails failure(s)"
  exit 1
fi
echo "check-train-session-refusals: all checks passed"
