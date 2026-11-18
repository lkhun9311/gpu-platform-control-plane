#!/usr/bin/env bash
#
# Offline checks for hack/dra-nvidia-gpu-session.sh and the runner it ships, run before anything is bought.
#
# Nothing here reaches AWS, a cluster, a GPU or GitHub: aws, docker, kubectl, helm, make, kind, nvidia-smi and sleep are
# hack/dra-nvidia-gpu/fakes.py, first on PATH, and the upstream repository is a local stand-in at a commit of its own.
# The checks cover
#   - the schedule: the session's bounds are the runner's, and the stop and the worst case are their sum;
#   - the cost: constants that put the worst case over $5, or a cap above the all-in rate, are refused;
#   - the refusals a caller can trip, each before any AWS call;
#   - the session's laptop side against a fake AWS: the pinned AMI, the caps, the rendered user-data's backstop and
#     deadlines, the termination confirmed, the evidence downloaded and read, and the fallback to g5.xlarge;
#   - the runner's command sequence against a fake cluster: each phase runs the plan's commands in the plan's order,
#     the checkpoint is captured before and after every step, a failing S4 stops the run, and an experiment whose
#     precondition never held exits 4.
# What they do not cover: the fake instance never executes the user-data (it writes DONE and a summary at launch), and
# the fake cluster accepts any chart value and any feature gate, so neither proves the real bring-up or the real
# Kubernetes configuration works; the paid run's own phase records are what show that.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/hack/dra-nvidia-gpu-session.sh"
RD="$ROOT/hack/dra-nvidia-gpu"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }

for f in "$S" "$RD"/*.sh; do check "$(basename "$f") parses" "bash -n '$f'"; done
check "fakes.py compiles" "python3 -m py_compile '$RD/fakes.py'"

# ---------------------------------------------------------------- the schedule and the cost
val() { sed -n "s/^$1=\([0-9.]*\)\$/\1/p" "$2"; }
same=1
for v in CLUSTER_S BUILD_S S4_S S1_S S2_S S3_S; do
  a=$(val "$v" "$S"); b=$(val "$v" "$RD/runner.sh")
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "  $v=$a in the session, $b in the runner" >&2; same=0; }
done
check "every phase bound in the session is the runner's own" "[ $same = 1 ]"
check "the session and the runner pin the same upstream commit" \
  "[ -n \"\$(sed -n 's/^DRA_COMMIT=//p' '$S')\" ] && [ \"\$(sed -n 's/^DRA_COMMIT=//p' '$S')\" = \"\$(sed -n 's/^DRA_COMMIT=//p' '$RD/runner.sh')\" ]"
he=$(( $(val BOOT_S "$S") + $(val CLUSTER_S "$RD/runner.sh") + $(val BUILD_S "$RD/runner.sh") + $(val S4_S "$RD/runner.sh") +
  $(val S1_S "$RD/runner.sh") + $(val S2_S "$RD/runner.sh") + $(val S3_S "$RD/runner.sh") ))
ev=$(( he + $(val EVIDENCE_UPLOAD_S "$S") ))
term=$(( ev + 30 + 330 ))
worst=$(awk -v t="$term" -v r="$(val ALL_IN_RATE "$S")" 'BEGIN { printf "%.4f", t / 3600 * r }')
sched=$(env -u SESSION_CONFIRM bash "$S" --print-schedule 2>&1)
check "the schedule is the runner's bounds summed from LaunchTime ($sched)" \
  "[ '$sched' = 'harness_end_s=$he evidence_s=$ev stop_s=$(( ev + 60 )) termination_s=$term worst_usd=$worst' ]"
check "the schedule is the plan's: stop at 90 minutes, termination confirmed by 95, worst case \$1.9910" \
  "[ '$sched' = 'harness_end_s=5220 evidence_s=5340 stop_s=5400 termination_s=5700 worst_usd=1.9910' ]"
check "the all-in rate is the higher cap plus 100 GB gp3 and an IPv4" \
  "awk -v r='$(val ALL_IN_RATE "$S")' -v a='$(val MAX_PRICE_G6 "$S")' -v b='$(val MAX_PRICE_G5 "$S")' -v x='$(val EXTRAS_RATE "$S")' \
    'BEGIN { m = a > b ? a : b; exit !(r + 0 >= m + x - 1e-9 && x + 0 >= 100 * 0.0912 / 730 + 0.005 - 1e-9) }'"
# Each costly variant is the session with one constant moved, and must be refused by its own arithmetic.
costly() { mkdir -p "$WORK/costly/hack"; cp "$S" "$WORK/costly/hack/s.sh"; sed -i "$1" "$WORK/costly/hack/s.sh"
  # The refusal's status is not returned: under pipefail it would fail the grep that reads the reason.
  env -u SESSION_CONFIRM bash "$WORK/costly/hack/s.sh" --print-schedule 2>&1; return 0; }
check "a rate that puts the worst case over \$5 is refused" \
  "costly 's/^ALL_IN_RATE=.*/ALL_IN_RATE=3.20/' | grep -q 'is not under \\\$5.00'"
check "a phase bound that puts the worst case over \$5 is refused" \
  "costly 's/^S2_S=.*/S2_S=9600/' | grep -q 'is not under \\\$5.00'"
check "a Spot cap raised above the all-in rate is refused" \
  "costly 's/^MAX_PRICE_G5=.*/MAX_PRICE_G5=1.50/' | grep -q 'is under a Spot cap'"
check "the unmoved constants are not refused" "! costly 's/^x//' | grep -q REFUSED"

# ---------------------------------------------------------------- the fakes and a stand-in upstream
BIN="$WORK/bin"
mkdir -p "$BIN"
for t in aws docker kubectl helm make kind nvidia-smi sleep; do ln -s "$RD/fakes.py" "$BIN/$t"; done
UPS="$WORK/upstream"
git init -q "$UPS"
while read -r p; do mkdir -p "$UPS/$(dirname "$p")"; : >"$UPS/$p"; done <<<"$(sed -n '/^UPSTREAM_PATHS="/,/"$/p' "$S" | sed 's/^UPSTREAM_PATHS="//; s/"$//')"
cat >"$UPS/hack/ci/gcp-nvkind/lib/setup-nvkind-node.sh" <<'EOF'
echo "setup-nvkind-node $NVKIND_CLUSTER_NAME $NVKIND_K8S_VERSION $NVKIND_CONFIG_PATH" >>"$FAKE_STATE/calls"
exit "${FAKE_SETUP_RC:-0}"
EOF
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: gpu-test-mps\n' >"$UPS/demo/specs/quickstart/v1/gpu-test-mps.yaml"
# The template's shape at the pinned commit: the gate in the cluster-wide list and in five component flags.
{ printf 'kind: Cluster\nfeatureGates:\n  DynamicResourceAllocation: true\nnodes:\n'
  for i in 1 2 3 4 5; do printf '        feature-gates: "DynamicResourceAllocation=true"\n'; done; } \
  >"$UPS/hack/ci/gcp-nvkind/lib/nvkind-config.yaml.tmpl"
git -C "$UPS" add -A && git -C "$UPS" -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -qm upstream
git -C "$UPS" config uploadpack.allowAnySHA1InWant true
UPC=$(git -C "$UPS" rev-parse HEAD)
pin() { sed -i -e "s|^DRA_REPO=.*|DRA_REPO=file://$UPS|" -e "s|^DRA_COMMIT=.*|DRA_COMMIT=$UPC|" "$@"; }

# ---------------------------------------------------------------- the session, offline
fixture() {
  local repo
  repo=$(mktemp -d "$WORK/repo.XXXXXX")
  mkdir -p "$repo/hack/lib" "$repo/hack/dra-nvidia-gpu"
  cp "$S" "$repo/hack/"
  cp "$ROOT/hack/lib/spot-run.sh" "$repo/hack/lib/"
  cp "$RD"/*.sh "$RD"/s4.mk "$repo/hack/dra-nvidia-gpu/"
  pin "$repo/hack/dra-nvidia-gpu-session.sh" "$repo/hack/dra-nvidia-gpu/runner.sh"
  git -C "$repo" init -q && git -C "$repo" add -A &&
    git -C "$repo" -c user.name=t -c user.email=t@invalid -c commit.gpgsign=false commit -qm fixture || return 1
  echo "$repo"
}
AMI=ami-035e3088f6b7821fb
# session NAME REPO ENV... runs the fixture's session against a fresh fake state and leaves its output in $WORK/NAME.
session() {
  local name=$1 repo=$2
  shift 2
  rm -rf "${WORK:?}/st-$name"; mkdir -p "$WORK/st-$name"
  env -u SESSION_CONFIRM -u DRA_GPU_AMI_ID PATH="$BIN:$PATH" FAKE_STATE="$WORK/st-$name" OUT="$WORK/out-$name" "$@" \
    timeout 300 bash "$repo/hack/dra-nvidia-gpu-session.sh" >"$WORK/$name.log" 2>&1
  echo $? >"$WORK/$name.rc"
}
REPO=$(fixture) || { echo "FAIL could not build the fixture repository" >&2; exit 1; }
# refused NAME WANT ENV...: the session exits non-zero with WANT in its output, and made no AWS call first.
refused() {
  local name=$1 want=$2
  shift 2
  session "$name" "$REPO" FAKE_AWS_FAIL=1 "$@"
  check "refused before any AWS call: $name" \
    "[ \"\$(cat '$WORK/$name.rc')\" != 0 ] && grep -qF -- '$want' '$WORK/$name.log' && ! grep -q '^aws ' '$WORK/st-$name/calls' 2>/dev/null"
}
refused no-confirm "SESSION_CONFIRM=yes is required" DRA_GPU_AMI_ID=$AMI
refused confirm-not-yes "SESSION_CONFIRM=yes is required" SESSION_CONFIRM=y DRA_GPU_AMI_ID=$AMI
refused no-ami "DRA_GPU_AMI_ID is unset" SESSION_CONFIRM=yes
refused ami-not-id "pins the AMI by ID" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=latest
for v in INSTANCE_TYPE MAX_SPOT_PRICE ALL_IN_RATE DRA_COMMIT TEST_FILTER_TAGS; do
  refused "caller-$v" "$v is set" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI "$v=1"
done
DIRTY=$(fixture) && echo dirty >"$DIRTY/untracked.txt"
session dirty "$DIRTY" FAKE_AWS_FAIL=1 SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI
check "refused before any AWS call: a dirty tree" "grep -q 'the working tree is dirty' '$WORK/dirty.log' && ! grep -q '^aws ' '$WORK/st-dirty/calls' 2>/dev/null"

session ok "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI
O="$WORK/out-ok" C="$WORK/st-ok/calls"
check "a valid session exits 0 and confirms the termination" \
  "[ \"\$(cat '$WORK/ok.rc')\" = 0 ] && grep -qx 'terminated i-0fake' '$O/termination.txt' && grep -qx 'termination=confirmed' '$O/outcome.txt'"
check "the launch is one g6.xlarge Spot at the \$0.99 cap, on the pinned AMI, 100 GB, terminating on shutdown" \
  "[ \"\$(grep -c '^aws ec2 run-instances' '$C')\" = 1 ] && grep '^aws ec2 run-instances' '$C' | grep -q -- '--image-id $AMI --instance-type g6.xlarge' &&
   grep '^aws ec2 run-instances' '$C' | grep -qF '\"MaxPrice\":\"0.99\"' && grep '^aws ec2 run-instances' '$C' | grep -qF '\"VolumeSize\":100' &&
   grep '^aws ec2 run-instances' '$C' | grep -q -- '--instance-initiated-shutdown-behavior terminate'"
check "the user-data's first command is the backstop at the stop, before its logging" \
  "[ \"\$(sed -n 2p '$WORK/st-ok/user-data.sh')\" = '( sleep 5400; shutdown -h now ) >/dev/null 2>&1 &' ] && bash -n '$WORK/st-ok/user-data.sh'"
check "the instance's deadlines count from the LaunchTime it reads from S3" \
  "grep -q 'L + 5400 - ' '$WORK/st-ok/user-data.sh' && grep -q 'HE=\$(( L + 5220 ))' '$WORK/st-ok/user-data.sh' && grep -q 'EV=\$(( L + 5340 ))' '$WORK/st-ok/user-data.sh'"
lt=$(cat "$O/launch-time.txt" 2>/dev/null)
want_tag=$(date -u -d "@$(( $(date -u -d "${lt:-1970-01-01}" +%s) + 5370 ))" +%Y-%m-%dT%H:%M:%SZ)
check "the sweeper's tag is moved to LaunchTime + 5,370 s, and LaunchTime is handed to the instance" \
  "[ -n '$lt' ] && grep -q 'create-tags .*Key=study-deadline,Value=$want_tag' '$C' && [ \"\$(cat '$WORK/st-ok/bucket/'*/launch-time.txt)\" = '$lt' ]"
check "terminate is called after the wait, and the evidence is downloaded and unpacked" \
  "grep -q '^aws ec2 terminate-instances .*i-0fake' '$C' && [ -s '$O/dra-run/run/summary.tsv' ] && grep -qx 'evidence=returned' '$O/outcome.txt'"
check "the upstream files the phases use were checked at the pinned commit" "[ \"\$(wc -l <'$O/upstream-files.txt')\" = 10 ]"

session fallback "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_NO_CAPACITY=g6.xlarge
check "with no g6.xlarge capacity the fallback is g5.xlarge at its own \$1.24 cap" \
  "[ \"\$(cat '$WORK/fallback.rc')\" = 0 ] && grep '^aws ec2 run-instances' '$WORK/st-fallback/calls' | tail -1 | grep -q -- '--instance-type g5.xlarge' &&
   grep '^aws ec2 run-instances' '$WORK/st-fallback/calls' | tail -1 | grep -qF '\"MaxPrice\":\"1.24\"'"
session s4fail "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_PHASE_RCS="cluster=0 build=0 s4=1"
check "a session whose S4 failed exits 3" "[ \"\$(cat '$WORK/s4fail.rc')\" = 3 ] && grep -qx 's4=1' '$WORK/out-s4fail/outcome.txt'"
session s1invalid "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_PHASE_RCS="cluster=0 build=0 s4=0 s1=4 s2=0 s3=0"
check "a session whose S1 was not a valid experiment exits 2, not 0" "[ \"\$(cat '$WORK/s1invalid.rc')\" = 2 ]"
session stuck "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_STUCK=1 FAKE_LAUNCH_AGO=5690
check "a termination EC2 never reports done is reported unconfirmed and fails the session" \
  "[ \"\$(cat '$WORK/stuck.rc')\" = 1 ] && grep -q 'TERMINATION UNCONFIRMED for i-0fake' '$WORK/out-stuck/termination.txt'"

# ---------------------------------------------------------------- the runner, against a fake cluster
# The copy differs from the shipped files only in the upstream it fetches, where it checks out, and the two waits that
# are wall-clock time by design (S1's watch and S2's settle), shortened so the run takes seconds.
IN="$WORK/in"
mkdir -p "$IN" && cp "$RD"/*.sh "$RD"/s4.mk "$IN/"
pin "$IN/runner.sh"
sed -i "s|^SRC=.*|SRC=$WORK/src|" "$IN/runner.sh"
sed -i 's/^WATCH_S=150$/WATCH_S=2/' "$IN/s1.sh"
sed -i 's/^SETTLE_S=60$/SETTLE_S=1/' "$IN/s2.sh"
sed -i 's/poll 120 3 in_state "\$uid" PrepareStarted/poll 4 3 in_state "$uid" PrepareStarted/' "$IN/s2.sh"
check "the shortened waits are the shipped 150 s, 60 s and 120 s" \
  "grep -qx 'WATCH_S=150' '$RD/s1.sh' && grep -qx 'SETTLE_S=60' '$RD/s2.sh' && grep -qx 'WATCH_S=2' '$IN/s1.sh' && grep -qx 'SETTLE_S=1' '$IN/s2.sh' &&
   grep -q 'poll 120 3 in_state \"\$uid\" PrepareStarted' '$RD/s2.sh' && grep -q 'poll 4 3 in_state \"\$uid\" PrepareStarted' '$IN/s2.sh'"
runner() {
  local name=$1
  shift
  rm -rf "${WORK:?}/rst-$name" "$WORK/rout-$name" "$WORK/src"; mkdir -p "$WORK/rst-$name" "$WORK/tmp"
  env PATH="$BIN:$PATH" FAKE_STATE="$WORK/rst-$name" HOME="$WORK/home" TMPDIR="$WORK/tmp" UPLOAD_PREFIX=s3://b/run "$@" \
    timeout 600 bash "$IN/runner.sh" "$IN" "$WORK/rout-$name" $(( $(date +%s) + 100000 )) >"$WORK/rout-$name.log" 2>&1
  echo $? >"$WORK/rout-$name.rc"
}
runner good
R="$WORK/rout-good" RC="$WORK/rst-good/calls"
check "the runner completes every phase" \
  "[ \"\$(cat '$WORK/rout-good.rc')\" = 0 ] && grep -q 'all scenarios done' '$R/steps.log' && [ \"\$(awk -F'\t' 'NR>1 && \$2==0' '$R/summary.tsv' | wc -l)\" = 6 ]"
check "the cluster is upstream's setup-nvkind-node.sh at the pinned commit, Kubernetes v1.34.3" \
  "grep -q 'setup-nvkind-node dra-session v1.34.3 $R/cluster/nvkind-config.yaml.tmpl' '$RC' && [ \"\$(git -C '$WORK/src' rev-parse HEAD)\" = '$UPC' ]"
check "the cluster's template is upstream's with DRAConsumableCapacity on all four components and cluster-wide" \
  "[ \"\$(grep -c 'feature-gates: \"DynamicResourceAllocation=true,DRAConsumableCapacity=true\"' '$R/cluster/nvkind-config.yaml.tmpl')\" = 5 ] &&
   grep -qx '  DRAConsumableCapacity: true' '$R/cluster/nvkind-config.yaml.tmpl'"
check "S4 pre-pulls the bats files' image into the GPU node before bats runs" \
  "p=\$(grep -n '^docker exec dra-session-worker crictl pull docker.io/library/ubuntu:24.04' '$RC' | cut -d: -f1) &&
   b=\$(grep -n 'tests-session-s4' '$RC' | cut -d: -f1) && [ -n \"\$p\" ] && [ \"\$p\" -lt \"\$b\" ]"
check "the driver is built from the checkout and loaded into the cluster" \
  "grep -q '^make -f deployments/container/Makefile build DOCKER_BUILD_OPTIONS=--load CI=true' '$RC' && grep -q '^kind load docker-image registry.k8s.io/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.6.0-dev --name dra-session' '$RC'"
s4call=$(grep 'tests-session-s4' "$RC")
check "S4 is upstream's bats Makefile with the session's target, on the kind network, single-GPU filters, no compute domains" \
  "[[ '$s4call' == 'make -f tests/bats/Makefile -f $IN/s4.mk tests-session-s4 '* ]] && [[ '$s4call' == *'DOCKER_NETWORK=kind'* ]] &&
   [[ '$s4call' == *'TEST_FILTER_TAGS=!version-specific,!multi-gpu'* ]] && [[ '$s4call' == *'DISABLE_COMPUTE_DOMAINS=true'* ]] &&
   [[ '$s4call' == *'TEST_CHART_LOCAL=true'* ]] && [[ '$s4call' == *'CI=true'* ]]"
check "S4's target runs exactly the plan's three bats files" \
  "[ \"\$(grep -o 'tests/bats/test_[a-z_]*\.bats' '$RD/s4.mk' | paste -sd' ')\" = 'tests/bats/test_gpu_basic.bats tests/bats/test_gpu_robustness.bats tests/bats/test_gpu_sharing.bats' ]"
# Against upstream's real Makefile, when a checkout is at hand: make -n shows the target expands to a bats run of the three.
UPSTREAM_CLONE="${DRA_UPSTREAM_CLONE:-$HOME/workspace/oss/dra-driver-nvidia-gpu}"
if [ -f "$UPSTREAM_CLONE/tests/bats/Makefile" ]; then
  check "with upstream's own Makefile the target expands to bats over the three files" \
    "(cd '$UPSTREAM_CLONE' && CI=true USER=root KUBECONFIG=/k make -n -f tests/bats/Makefile -f '$RD/s4.mk' tests-session-s4 GIT_COMMIT_SHORT=e775fdb6 TMPDIR=/tmp 2>&1) |
     grep -q 'bats .* tests/bats/test_gpu_basic.bats tests/bats/test_gpu_robustness.bats tests/bats/test_gpu_sharing.bats \"\$'"
else
  echo "skip the make -n expansion: no upstream checkout at $UPSTREAM_CLONE"
fi

# S1, the #1278 path, three times: plugin down, then pod and claim deleted, then plugin back, then the watch.
order_ok=1
for r in 1 2 3; do
  ln_of() { grep -n -- "$1" "$RC" | head -1 | cut -d: -f1; }
  down=$(ln_of "kubectl patch ds -n dra-driver-nvidia-gpu dra-driver-nvidia-gpu-kubelet-plugin --type merge -p {\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"dra-gpu-session/plugin-down\":\"true\"}}}}}")
  dp=$(ln_of "kubectl delete -n s1-r$r pod/pod --wait=false")
  dc=$(ln_of "kubectl delete -n s1-r$r resourceclaim/gpu --wait=false")
  up=$(grep -n -- 'patch ds .*--type json -p \[{"op":"remove","path":"/spec/template/spec/nodeSelector"}\]' "$RC" | sed -n "${r}p" | cut -d: -f1)
  downr=$(grep -n -- 'patch ds .*--type merge' "$RC" | sed -n "${r}p" | cut -d: -f1)
  [ -n "$down" ] && [ -n "$dp" ] && [ -n "$dc" ] && [ -n "$up" ] && [ "$downr" -lt "$dp" ] && [ "$dp" -lt "$dc" ] && [ "$dc" -lt "$up" ] ||
    { echo "  S1 rep $r: down=$downr pod=$dp claim=$dc up=$up" >&2; order_ok=0; }
done
check "S1 takes the plugin down, then deletes the pod, then the claim, then brings the plugin back, in each of three reps" "[ $order_ok = 1 ]"
check "S1's claim is a ResourceClaim of its own, so deleting it is a step and not garbage collection" \
  "grep -q 'resourceClaimName: gpu' '$R/s1/r1.yaml' && grep -q '^kind: ResourceClaim\$' '$R/s1/r1.yaml'"
check "S1 records three valid reps, each read from the checkpoint: PrepareCompleted, then gone once the plugin is back" \
  "[ \"\$(awk -F'\t' 'NR>1 && \$2==\"yes\" && \$4==\"PrepareCompleted\" && \$5==\"gone\" && \$6==\"gone\" && \$8==\"absent\"' '$R/s1/result.tsv' | wc -l)\" = 3 ]"
check "S1 saves the plugin's log of every rep before the pod is replaced" \
  "[ -s '$R/s1/r1.plugin-before-down.log' ] && [ -s '$R/s3/../s1/r3.plugin-after-watch.log' ]"
check "S1 installs its chart after removing the bats suite's release" \
  "grep -q '^helm uninstall -n dra-driver-nvidia-gpu dra-driver-nvidia-gpu-batssuite' '$RC' && grep -q '^helm upgrade -i dra-gpu-session .*--set resources.computeDomains.enabled=false --set logVerbosity=6' '$RC'"
snaps_ok=1
for s in r1-prepare r1-plugin-down r1-delete r1-plugin-up r1-watch; do
  b=$(ls "$R"/s1/snap/*-"$s".before.checkpoint.json 2>/dev/null | head -1); a=$(ls "$R"/s1/snap/*-"$s".after.checkpoint.json 2>/dev/null | head -1)
  [ -s "$b" ] && [ -s "$a" ] && jq -e .v2 "$b" >/dev/null && [ "$(basename "$b" | cut -d- -f1)" -lt "$(basename "$a" | cut -d- -f1)" ] ||
    { echo "  S1 $s: before '$b' after '$a'" >&2; snaps_ok=0; }
done
check "S1 captures the checkpoint JSON before and after every step" "[ $snaps_ok = 1 ]"
check "S1 keeps both sides' logs" "[ -s '$R/s1/kubelet.log' ] && [ -s '$R/s1/plugin.log' ] && [ -s '$R/s1/resources.yaml' ]"
runner leak FAKE_S1_LEAK=1 FAKE_PHASE=x
check "S1 reports an entry that survives the watch as still PrepareCompleted, and that is a valid result" \
  "[ \"\$(awk -F'\t' 'NR>1 && \$2==\"yes\" && \$8==\"PrepareCompleted\"' '$WORK/rout-leak/s1/result.tsv' | wc -l)\" = 3 ] &&
   awk -F'\t' '\$1==\"s1\" && \$2==0' '$WORK/rout-leak/summary.tsv' | grep -q ."
runner notprepared FAKE_S1_NOT_PREPARED=1
check "S1 whose claim never reached PrepareCompleted is invalid: it exits 4, and S2 and S3 still run" \
  "awk -F'\t' '\$1==\"s1\" && \$2==4' '$WORK/rout-notprepared/summary.tsv' | grep -q . && [ \"\$(awk -F'\t' 'NR>1 && \$2==\"no\"' '$WORK/rout-notprepared/s1/result.tsv' | wc -l)\" = 3 ] &&
   awk -F'\t' '\$1==\"s3\" && \$2==0' '$WORK/rout-notprepared/summary.tsv' | grep -q ."

# S2, #1639's trigger: the quota, then the MPS claim, then SIGKILL only once the checkpoint says PrepareStarted.
s2_ok=1
for r in 1 2 3; do
  q=$(grep -n -- '^kubectl -n dra-driver-nvidia-gpu create quota s2-block-new-pods --hard=pods=1' "$RC" | sed -n "${r}p" | cut -d: -f1)
  ap=$(grep -n -- "^kubectl apply -f $WORK/src/demo/specs/quickstart/v1/gpu-test-mps.yaml" "$RC" | sed -n "${r}p" | cut -d: -f1)
  k=$(grep -n -- '^docker exec dra-session-worker kill -KILL 4242' "$RC" | sed -n "${r}p" | cut -d: -f1)
  rel=$(grep -n -- '^kubectl delete ns gpu-test-mps --wait=true' "$RC" | sed -n "${r}p" | cut -d: -f1)
  [ -n "$q" ] && [ -n "$ap" ] && [ -n "$k" ] && [ -n "$rel" ] && [ "$q" -lt "$ap" ] && [ "$ap" -lt "$k" ] && [ "$k" -lt "$rel" ] ||
    { echo "  S2 rep $r: quota=$q apply=$ap kill=$k release=$rel" >&2; s2_ok=0; }
done
check "S2 blocks new pods, applies #1639's MPS spec, SIGKILLs the plugin, then releases, in each of three reps" "[ $s2_ok = 1 ]"
check "S2's kill comes after a checkpoint read showed PrepareStarted" \
  "jq -e '.v2.preparedClaims[\"uid-mps\"].checkpointState == \"PrepareStarted\"' \"\$(ls '$R'/s2/snap/*-r1-sigkill.before.checkpoint.json)\" >/dev/null"
check "S2 records the four survivors after the restart and after the release, three valid times" \
  "[ \"\$(awk -F'\t' 'NR>1 && \$2==\"yes\" && \$4==\"yes\" && \$5==\"yes\" && \$6==\"yes\" && \$7==\"PrepareStarted\" && \$8==0 && \$9==0 && \$10==\"Default\" && \$15==\"Default\"' '$R/s2/result.tsv' | wc -l)\" = 3 ] &&
   head -1 '$R/s2/result.tsv' | grep -q 'deploy_settled.node_mount_settled.host_mount_settled.compute_mode_settled'"
check "S2 keeps the killed plugin's log and the restarted one's" "[ -s '$R/s2/r1.plugin-before-kill.log' ] && [ -s '$R/s2/r3.plugin-settled.log' ]"
runner mpsnever FAKE_MPS_NEVER=1
check "S2 whose claim never reached PrepareStarted kills nothing and is invalid: it exits 4" \
  "awk -F'\t' '\$1==\"s2\" && \$2==4' '$WORK/rout-mpsnever/summary.tsv' | grep -q . && ! grep -q 'kill -KILL' '$WORK/rst-mpsnever/calls'"
check "S2 enables MPS and resets the GPU to Default after each rep" \
  "grep -q '^helm upgrade -i dra-gpu-session .*--set featureGates.MPSSupport=true' '$RC' && [ \"\$(grep -c '^nvidia-smi -c DEFAULT' '$RC')\" = 3 ]"

# S3, #1572: memory mode, two claims of 4Gi.
s3y=$(grep -l 'namespace: s3-shares' "$WORK"/rst-good/applied-*.yaml | paste -sd' ')
check "S3 installs ConsumableShares in memory mode" \
  "grep -q '^helm upgrade -i dra-gpu-session .*--set featureGates.ConsumableShares=true --set consumableShares=memory' '$RC'"
check "S3 applies two ResourceClaims of memory 4Gi each and a pod for each" \
  "[ \"\$(cat $s3y | grep -c '^kind: ResourceClaim\$')\" = 2 ] && [ \"\$(cat $s3y | grep -c '            memory: 4Gi')\" = 2 ] && [ \"\$(cat $s3y | grep -c 'resourceClaimName: mem-')\" = 2 ]"
check "S3 submits the second claim only after the first pod is ready" \
  "w=\$(grep -n '^kubectl wait -n s3-shares --for=condition=Ready pod/pod-0' '$RC' | cut -d: -f1) &&
   a=\$(grep -n '^kubectl apply -f $R/s3/claim-1.yaml' '$RC' | cut -d: -f1) && [ -n \"\$w\" ] && [ -n \"\$a\" ] && [ \"\$w\" -lt \"\$a\" ]"
check "S3 is valid on a slice that carries memory's requestPolicy" "awk -F'\t' 'NR==2 && \$1==\"yes\" && \$2==\"yes\"' '$R/s3/result.tsv' | grep -q ."
runner nopolicy FAKE_NO_POLICY=1
check "S3 on a slice without requestPolicy (the Kubernetes gate off) is invalid: it exits 4" \
  "awk -F'\t' '\$1==\"s3\" && \$2==4' '$WORK/rout-nopolicy/summary.tsv' | grep -q ."
runner pending FAKE_S3_POD1_PENDING=1
check "S3 records a second pod that never schedules, with the scheduler's reason" \
  "awk -F'\t' 'NR==2 && \$1==\"yes\" && \$3==\"yes\" && \$4==\"no\" && \$7 ~ /cannot allocate all claims/' '$WORK/rout-pending/s3/result.tsv' | grep -q ."
check "each phase's evidence leaves the instance as the phase ends" \
  "[ \"\$(grep -c '^aws s3 cp --only-show-errors $WORK/tmp/phase-[a-z0-9]*.tgz s3://b/run/phase-' '$RC')\" = 6 ]"

# The stop: a failing S4 ends the run before S1, S2 and S3, and so do a failed cluster and build.
runner s4fail FAKE_S4_RC=1
F="$WORK/rst-s4fail/calls"
check "a failing S4 stops the run: exit 3, and no S1, S2 or S3 command ran" \
  "[ \"\$(cat '$WORK/rout-s4fail.rc')\" = 3 ] && grep -q 'S4 FAILED' '$WORK/rout-s4fail/steps.log' &&
   ! grep -qE '^helm (upgrade|uninstall)|^kubectl (apply|patch|create)' '$F' && [ ! -d '$WORK/rout-s4fail/s1' ] && [ ! -d '$WORK/rout-s4fail/s2' ] && [ ! -d '$WORK/rout-s4fail/s3' ]"
runner clusterfail FAKE_SETUP_RC=1
check "a failed cluster stops the run before the build" \
  "[ \"\$(cat '$WORK/rout-clusterfail.rc')\" = 2 ] && ! grep -q '^make ' '$WORK/rst-clusterfail/calls'"
runner twoworkers FAKE_WORKERS=$'w1\nw2'
check "a cluster with other than one worker node is refused before the build" \
  "[ \"\$(cat '$WORK/rout-twoworkers.rc')\" = 2 ] && ! grep -q '^make ' '$WORK/rst-twoworkers/calls'"

if [[ $failures -ne 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
