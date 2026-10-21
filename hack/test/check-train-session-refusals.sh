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
cd "$(dirname "$0")/../.." || exit 1

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
  "aws eks describe-cluster"*)
    if [[ -n "${STUB_CLUSTER_EXISTS:-}" ]]; then echo ACTIVE; exit 0; fi
    echo "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found" >&2
    exit 254 ;;
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
cp hack/lib/train-session.sh hack/lib/ddp-arms.sh hack/lib/gpu-ttl.sh "$repo/hack/lib/"
cp experiments/cpu-ddp/train.py "$repo/experiments/cpu-ddp/"
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
  # A watchdog is a detached process whose command names this case's directory; one left alive would fire at TTL.
  local stray
  stray="$(pgrep -f -- "$work/$name/" | paste -sd' ')"
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
session "an unknown training mode" "not a training mode" TRAIN=fsdp
# Every refusal passed: the next stop is the destroy-window check or the stub gh, both before the kill switch.
session "every training refusal passed" "does not exist"
grep -q -- "eks describe-cluster --region ap-northeast-2 --name gpu-platform" "$work/every training refusal passed.calls" &&
  ok "the cluster asked about is the one the session would build" ||
  bad "the cluster asked about was: $(grep describe-cluster "$work/every training refusal passed.calls")"

# --- the kill switch, armed under an absolute EXDIR --------------------------------------------------------------
# Without TRAIN nothing stops the session before its kill switch, so it arms one and then dies at the stub's terraform
# init. The watchdog must have reported its pid where the session reads it; the test then stops it.
name="an armed kill switch"
export STUB_CALLS="$work/$name.calls"
: >"$STUB_CALLS"
out="$(env -i HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" STUB_CALLS="$STUB_CALLS" SESSION_CONFIRM=yes AWS_PROFILE=stub \
  EGRESS_CIDR=192.0.2.1/32 EXDIR="$work/$name" TTL_MINUTES=300 timeout 60 bash "$repo/hack/eks-gitops-session.sh" 2>&1)"
pid="$(cat "$work/$name/ttl.pid" 2>/dev/null)"
stray="$(pgrep -f -- "$work/$name/" | paste -sd' ')"
if [[ -n "$pid" && " $stray " == *" $pid "* && "$out" == *"TTL kill switch armed: PID $pid"* ]]; then
  ok "$name: the watchdog reported pid $pid under an absolute EXDIR, and the session read it"
  grep -q '^terraform -chdir=infra/aws/cluster init' "$STUB_CALLS" && ok "$name: the cluster's init reached the stub, not a real terraform" ||
    bad "$name: the stub saw no init of the cluster root: $(grep '^terraform' "$STUB_CALLS" | head -3)"
else
  bad "$name: pid file '${pid:-absent}', processes '${stray:-none}', session said: $(grep -o 'TTL[^,]*\|never reported its pid[^;]*' <<<"$out" | head -1)"
fi
# shellcheck disable=SC2086
for p in $stray; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
sleep 1
[[ -z "$(pgrep -f -- "$work/$name/")" ]] && ok "$name: the test stopped its watchdog" || bad "$name: a watchdog survived the test: $(pgrep -af -- "$work/$name/")"

if [[ $fails -ne 0 ]]; then
  echo "check-train-session-refusals: $fails failure(s)"
  exit 1
fi
echo "check-train-session-refusals: all checks passed"
