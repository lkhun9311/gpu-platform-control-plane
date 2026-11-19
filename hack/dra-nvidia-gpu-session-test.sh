#!/usr/bin/env bash
#
# Offline checks for hack/dra-nvidia-gpu-session.sh and the runner it ships, run before anything is bought.
#
# Nothing here reaches AWS, a cluster, a GPU or GitHub: aws, docker, kubectl, helm, make, kind, nvidia-smi and sleep are
# hack/dra-nvidia-gpu/fakes.py, first on PATH, and the upstream repository is a local stand-in at a commit of its own.
# The checks cover
#   - the schedule: the session's bounds are the runner's, and the stop and the worst case are their sum;
#   - the cost: constants that put the worst case over $2, or a cap above the all-in rate, are refused;
#   - the refusals a caller can trip, each before any AWS call;
#   - the session's laptop side against a fake AWS: the pinned AMI, the caps, the rendered user-data's backstop and
#     deadlines, the termination confirmed, the evidence downloaded and read, and the fallback to g5.xlarge;
#   - the runner's command sequence against a fake cluster: each phase runs the plan's commands in the plan's order,
#     the checkpoint is captured before and after every step, a failing S4 stops the run, and an experiment whose
#     precondition never held exits 4;
#   - the shipped scenario list (S1, then S5) on its own, and S5's guards: both objects force-deleted and read gone
#     while the plugin is down, or the repetition is invalid.
# The S2, S3 and S4 checks run the runner with every scenario listed, since the shipped list leaves them out.
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
for v in CLUSTER_S BUILD_S S1_S S5_S; do
  a=$(val "$v" "$S"); b=$(val "$v" "$RD/runner.sh")
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "  $v=$a in the session, $b in the runner" >&2; same=0; }
done
check "every phase bound in the session is the runner's own" "[ $same = 1 ]"
check "the session ships the cluster, the build and exactly the runner's scenarios, in order" \
  "[ \"\$(sed -n 's/^PHASES=\"\(.*\)\"\$/\1/p' '$S')\" = \"cluster build \$(sed -n 's/^SCENARIOS=\"\(.*\)\"\$/\1/p' '$RD/runner.sh')\" ] &&
   [ \"\$(sed -n 's/^SCENARIOS=\"\(.*\)\"\$/\1/p' '$RD/runner.sh')\" = 's1 s5' ]"
check "the session and the runner pin the same upstream commit" \
  "[ -n \"\$(sed -n 's/^DRA_COMMIT=//p' '$S')\" ] && [ \"\$(sed -n 's/^DRA_COMMIT=//p' '$S')\" = \"\$(sed -n 's/^DRA_COMMIT=//p' '$RD/runner.sh')\" ]"
he=$(( $(val BOOT_S "$S") + $(val CLUSTER_S "$RD/runner.sh") + $(val BUILD_S "$RD/runner.sh") + $(val S1_S "$RD/runner.sh") +
  $(val S5_S "$RD/runner.sh") ))
ev=$(( he + $(val EVIDENCE_UPLOAD_S "$S") ))
term=$(( ev + 30 + 330 ))
worst=$(awk -v t="$term" -v r="$(val ALL_IN_RATE "$S")" 'BEGIN { printf "%.4f", t / 3600 * r }')
sched=$(env -u SESSION_CONFIRM bash "$S" --print-schedule 2>&1)
check "the schedule is the runner's bounds summed from LaunchTime ($sched)" \
  "[ '$sched' = 'harness_end_s=$he evidence_s=$ev stop_s=$(( ev + 60 )) termination_s=$term worst_usd=$worst' ]"
check "the schedule: stop at 77 minutes, termination confirmed by 82, worst case \$1.7186, under \$2" \
  "[ '$sched' = 'harness_end_s=4440 evidence_s=4560 stop_s=4620 termination_s=4920 worst_usd=1.7186' ]"
check "the all-in rate is the higher cap plus 100 GB gp3 and an IPv4" \
  "awk -v r='$(val ALL_IN_RATE "$S")' -v a='$(val MAX_PRICE_G6 "$S")' -v b='$(val MAX_PRICE_G5 "$S")' -v x='$(val EXTRAS_RATE "$S")' \
    'BEGIN { m = a > b ? a : b; exit !(r + 0 >= m + x - 1e-9 && x + 0 >= 100 * 0.0912 / 730 + 0.005 - 1e-9) }'"
# Each costly variant is the session with one constant moved, and must be refused by its own arithmetic.
costly() { mkdir -p "$WORK/costly/hack"; cp "$S" "$WORK/costly/hack/s.sh"; sed -i "$1" "$WORK/costly/hack/s.sh"
  # The refusal's status is not returned: under pipefail it would fail the grep that reads the reason.
  env -u SESSION_CONFIRM bash "$WORK/costly/hack/s.sh" --print-schedule 2>&1; return 0; }
check "a rate that puts the worst case over \$2 is refused" \
  "costly 's/^ALL_IN_RATE=.*/ALL_IN_RATE=1.50/' | grep -q 'is not under \\\$2.00'"
check "a phase bound that puts the worst case over \$2 is refused" \
  "costly 's/^S5_S=.*/S5_S=2500/' | grep -q 'is not under \\\$2.00'"
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

session nosweeper "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_SWEEPER_STATE=Inactive
check "a termination sweeper that is not Active refuses the session before any launch" \
  "[ \"\$(cat '$WORK/nosweeper.rc')\" != 0 ] && grep -q 'the termination sweeper is Inactive, not Active' '$WORK/nosweeper.log' &&
   ! grep -q '^aws ec2 run-instances' '$WORK/st-nosweeper/calls'"
session ok "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI
O="$WORK/out-ok" C="$WORK/st-ok/calls"
check "a valid session exits 0 and confirms the termination" \
  "[ \"\$(cat '$WORK/ok.rc')\" = 0 ] && grep -qx 'terminated i-0fake' '$O/termination.txt' && grep -qx 'termination=confirmed' '$O/outcome.txt'"
check "the launch is one g5.xlarge Spot at the \$1.24 cap (the SCP allows no g6), on the pinned AMI, 100 GB, terminating on shutdown" \
  "[ \"\$(grep -c '^aws ec2 run-instances' '$C')\" = 1 ] && grep '^aws ec2 run-instances' '$C' | grep -q -- '--image-id $AMI --instance-type g5.xlarge' &&
   ! grep -q 'g6.xlarge' '$C' && grep '^aws ec2 run-instances' '$C' | grep -qF '\"MaxPrice\":\"1.24\"' && grep '^aws ec2 run-instances' '$C' | grep -qF '\"VolumeSize\":100' &&
   grep '^aws ec2 run-instances' '$C' | grep -q -- '--instance-initiated-shutdown-behavior terminate'"
check "the user-data's first command is the backstop at the stop, before its logging" \
  "[ \"\$(sed -n 2p '$WORK/st-ok/user-data.sh')\" = '( sleep 4620; shutdown -h now ) >/dev/null 2>&1 &' ] && bash -n '$WORK/st-ok/user-data.sh'"
check "the instance's deadlines count from the LaunchTime it reads from S3" \
  "grep -q 'L + 4620 - ' '$WORK/st-ok/user-data.sh' && grep -q 'HE=\$(( L + 4440 ))' '$WORK/st-ok/user-data.sh' && grep -q 'EV=\$(( L + 4560 ))' '$WORK/st-ok/user-data.sh'"
lt=$(cat "$O/launch-time.txt" 2>/dev/null)
want_tag=$(date -u -d "@$(( $(date -u -d "${lt:-1970-01-01}" +%s) + 4590 ))" +%Y-%m-%dT%H:%M:%SZ)
check "the sweeper's tag is moved to LaunchTime + 4,590 s, and LaunchTime is handed to the instance" \
  "[ -n '$lt' ] && grep -q 'create-tags .*Key=study-deadline,Value=$want_tag' '$C' && [ \"\$(cat '$WORK/st-ok/bucket/'*/launch-time.txt)\" = '$lt' ]"
check "terminate is called after the wait, and the evidence is downloaded and unpacked" \
  "grep -q '^aws ec2 terminate-instances .*i-0fake' '$C' && [ -s '$O/dra-run/run/summary.tsv' ] && grep -qx 'evidence=returned' '$O/outcome.txt'"
check "the upstream files the phases use were checked at the pinned commit" "[ \"\$(wc -l <'$O/upstream-files.txt')\" = 10 ]"

session s5invalid "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_PHASE_RCS="cluster=0 build=0 s1=0 s5=4"
check "a session whose S5 was not a valid experiment exits 2, not 0" \
  "[ \"\$(cat '$WORK/s5invalid.rc')\" = 2 ] && grep -qx 's5=4' '$WORK/out-s5invalid/outcome.txt'"
session s1invalid "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_PHASE_RCS="cluster=0 build=0 s1=4 s5=0"
check "a session whose S1 was not a valid experiment exits 2, not 0" "[ \"\$(cat '$WORK/s1invalid.rc')\" = 2 ]"
session s5missing "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_PHASE_RCS="cluster=0 build=0 s1=0"
check "a session with no status for S5 exits 2, not 0" "[ \"\$(cat '$WORK/s5missing.rc')\" = 2 ]"
check "a session without S4 among its phases does not ask for S4's status" \
  "[ \"\$(cat '$WORK/ok.rc')\" = 0 ] && ! grep -q '^s4=' '$WORK/out-ok/outcome.txt'"
session stuck "$REPO" SESSION_CONFIRM=yes DRA_GPU_AMI_ID=$AMI FAKE_STUCK=1 FAKE_LAUNCH_AGO=4910
check "a termination EC2 never reports done is reported unconfirmed and fails the session" \
  "[ \"\$(cat '$WORK/stuck.rc')\" = 1 ] && grep -q 'TERMINATION UNCONFIRMED for i-0fake' '$WORK/out-stuck/termination.txt'"

# ---------------------------------------------------------------- the runner, against a fake cluster
# The copy differs from the shipped files only in the upstream it fetches, where it checks out, and the two waits that
# are wall-clock time by design (S1's watch and S2's settle), shortened so the run takes seconds.
# IN runs the shipped scenario list; INALL lists every scenario, S4 first, so S2, S3 and S4 are still checked.
IN="$WORK/in"
mkdir -p "$IN" && cp "$RD"/*.sh "$RD"/s4.mk "$IN/"
pin "$IN/runner.sh"
sed -i "s|^SRC=.*|SRC=$WORK/src|" "$IN/runner.sh"
sed -i 's/^WATCH_S=150$/WATCH_S=2/' "$IN/s1.sh"
sed -i -e 's/^WATCH_S=150$/WATCH_S=2/' -e 's/^CLEANUP_WATCH_S=630$/CLEANUP_WATCH_S=4/' -e 's/poll 30 3 gone/poll 1 3 gone/g' \
  -e 's/poll 90 3 no_plugin_pod/poll 2 3 no_plugin_pod/' "$IN/s5.sh"
sed -i 's/^SETTLE_S=60$/SETTLE_S=1/' "$IN/s2.sh"
sed -i 's/poll 120 3 in_state "\$uid" PrepareStarted/poll 4 3 in_state "$uid" PrepareStarted/' "$IN/s2.sh"
sed -i -e 's/poll 60 3 gone pod\/pod/poll 2 3 gone pod\/pod/' -e 's/poll 15 3 gone resourceclaim/poll 1 3 gone resourceclaim/' \
  -e 's/poll 90 3 no_plugin_pod/poll 2 3 no_plugin_pod/' "$IN/s1.sh"
sed -i -e 's/poll 30 3 found_plugin_ds/poll 2 3 found_plugin_ds/' -e 's/poll 90 3 foreign_plugin_gone/poll 2 3 foreign_plugin_gone/' "$IN/lib.sh"
check "the shortened waits are the shipped 150 s, 60 s, 120 s, 30 s, 90 s and S1's 90 s" \
  "grep -qx 'WATCH_S=150' '$RD/s1.sh' && grep -qx 'SETTLE_S=60' '$RD/s2.sh' && grep -qx 'WATCH_S=2' '$IN/s1.sh' && grep -qx 'SETTLE_S=1' '$IN/s2.sh' &&
   grep -q 'poll 120 3 in_state \"\$uid\" PrepareStarted' '$RD/s2.sh' && grep -q 'poll 4 3 in_state \"\$uid\" PrepareStarted' '$IN/s2.sh' &&
   grep -q 'poll 30 3 found_plugin_ds' '$RD/lib.sh' && grep -q 'poll 2 3 found_plugin_ds' '$IN/lib.sh' &&
   grep -q 'poll 90 3 foreign_plugin_gone' '$RD/lib.sh' && grep -q 'poll 2 3 foreign_plugin_gone' '$IN/lib.sh' &&
   grep -q 'poll 90 3 no_plugin_pod' '$RD/s1.sh' && grep -q 'poll 2 3 no_plugin_pod' '$IN/s1.sh'"
check "S5's shortened waits are the shipped 150 s, 630 s, 30 s and 90 s" \
  "grep -qx 'WATCH_S=150' '$RD/s5.sh' && grep -qx 'CLEANUP_WATCH_S=630' '$RD/s5.sh' && [ \"\$(grep -c 'poll 30 3 gone' '$RD/s5.sh')\" = 3 ] &&
   grep -q 'poll 90 3 no_plugin_pod' '$RD/s5.sh' && grep -q 'poll 2 3 no_plugin_pod' '$IN/s5.sh' &&
   grep -qx 'WATCH_S=2' '$IN/s5.sh' && grep -qx 'CLEANUP_WATCH_S=4' '$IN/s5.sh' && [ \"\$(grep -c 'poll 1 3 gone' '$IN/s5.sh')\" = 3 ]"
INALL="$WORK/inall"
mkdir -p "$INALL" && cp "$IN"/* "$INALL/"
sed -i 's/^SCENARIOS=.*/SCENARIOS="s4 s1 s2 s3 s5"/' "$INALL/runner.sh"
# runner NAME ENV... runs the runner in RIN (INALL unless set) against a fresh fake cluster.
runner() {
  local name=$1 rin=${RIN:-$INALL}
  shift
  rm -rf "${WORK:?}/rst-$name" "$WORK/rout-$name" "$WORK/src"; mkdir -p "$WORK/rst-$name" "$WORK/tmp"
  env PATH="$BIN:$PATH" FAKE_STATE="$WORK/rst-$name" HOME="$WORK/home" TMPDIR="$WORK/tmp" UPLOAD_PREFIX=s3://b/run "$@" \
    timeout 600 bash "$rin/runner.sh" "$rin" "$WORK/rout-$name" $(( $(date +%s) + 100000 )) >"$WORK/rout-$name.log" 2>&1
  echo $? >"$WORK/rout-$name.rc"
}
runner good
R="$WORK/rout-good" RC="$WORK/rst-good/calls"
check "the runner completes every phase" \
  "[ \"\$(cat '$WORK/rout-good.rc')\" = 0 ] && grep -q 'all scenarios done' '$R/steps.log' && [ \"\$(awk -F'\t' 'NR>1 && \$2==0' '$R/summary.tsv' | wc -l)\" = 7 ]"
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
  "[[ '$s4call' == 'make -f tests/bats/Makefile -f $INALL/s4.mk tests-session-s4 '* ]] && [[ '$s4call' == *'DOCKER_NETWORK=kind'* ]] &&
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
runner getfail FAKE_GET_FAIL=1
check "S1 records a presence query the API could not answer as unread, not as gone" \
  "[ \"\$(awk -F'\t' 'NR>1 && \$5==\"unread\" && \$6==\"unread\"' '$WORK/rout-getfail/s1/result.tsv' | wc -l)\" = 3 ]"
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
runner nsstuck FAKE_NS_DELETE_FAIL=1
check "S2 whose release did not complete is invalid: it exits 4, and its readings are not marked released" \
  "awk -F'\t' '\$1==\"s2\" && \$2==4' '$WORK/rout-nsstuck/summary.tsv' | grep -q . &&
   [ \"\$(awk -F'\t' 'NR>1 && \$2==\"no\" && \$6==\"no\"' '$WORK/rout-nsstuck/s2/result.tsv' | wc -l)\" = 3 ]"
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
runner pod0pending FAKE_S3_POD0_PENDING=1
check "S3 whose first pod never became ready submits no second claim and is invalid: it exits 4" \
  "awk -F'\t' '\$1==\"s3\" && \$2==4' '$WORK/rout-pod0pending/summary.tsv' | grep -q . && ! grep -q 'claim-1.yaml' '$WORK/rst-pod0pending/calls'"
runner nopolicy FAKE_NO_POLICY=1
check "S3 on a slice without requestPolicy (the Kubernetes gate off) is invalid: it exits 4" \
  "awk -F'\t' '\$1==\"s3\" && \$2==4' '$WORK/rout-nopolicy/summary.tsv' | grep -q ."
runner pending FAKE_S3_POD1_PENDING=1
check "S3 records a second pod that never schedules, with the scheduler's reason" \
  "awk -F'\t' 'NR==2 && \$1==\"yes\" && \$3==\"yes\" && \$4==\"no\" && \$7 ~ /cannot allocate all claims/' '$WORK/rout-pending/s3/result.tsv' | grep -q ."
# The kubelet-plugin DaemonSet, as attempt 4 met it: installed, but without the component label on its own metadata.
check "S1 waits for the bats release's plugin pods to go before installing its own release" \
  "u=\$(grep -n '^helm uninstall -n dra-driver-nvidia-gpu dra-driver-nvidia-gpu-batssuite' '$RC' | cut -d: -f1) &&
   w=\$(grep -n '^kubectl get pods -n dra-driver-nvidia-gpu -l dra-driver-nvidia-gpu-component=kubelet-plugin,app.kubernetes.io/instance!=dra-gpu-session -o name' '$RC' | head -1 | cut -d: -f1) &&
   i=\$(grep -n '^helm upgrade -i dra-gpu-session' '$RC' | head -1 | cut -d: -f1) && [ \"\$u\" -lt \"\$w\" ] && [ \"\$w\" -lt \"\$i\" ]"
check "S2 reads the plugin pod of this release, and S1's plugin-down test counts the plugin pod of any release" \
  "grep -q '^kubectl get pods -n dra-driver-nvidia-gpu -l dra-driver-nvidia-gpu-component=kubelet-plugin,app.kubernetes.io/instance=dra-gpu-session --field-selector=status.phase=Running' '$RC' &&
   grep -q '^kubectl get pods -n dra-driver-nvidia-gpu -l dra-driver-nvidia-gpu-component=kubelet-plugin -o name' '$RC'"
runner linger FAKE_OLD_PODS_LINGER=1
check "a plugin pod of another release that outlives its uninstall stops every install before its helm upgrade" \
  "[ \"\$(awk -F'\t' '\$1 ~ /^s[123]\$/ && \$2==2' '$WORK/rout-linger/summary.tsv' | wc -l)\" = 3 ] && ! grep -q '^helm upgrade' '$WORK/rst-linger/calls' &&
   grep -q 'plugin pod of another release was still present' '$WORK/rout-linger/s3/steps.log' && [ -f '$WORK/rout-linger/s1/install-failure/helm-list.txt' ] && [ -s '$WORK/rout-linger/s1/install-failure/ds-pods.txt' ]"
runner nods FAKE_NO_DS=1
NC="$WORK/rst-nods/calls"
nods_ok=1
for s in s1 s2 s3 s5; do
  f="$WORK/rout-nods/$s/install-failure"
  awk -F'\t' -v s=$s '$1==s && $2==2' "$WORK/rout-nods/summary.tsv" | grep -q . &&
    grep -qx 'KUBECONFIG=.*/.kube/config' "$f/context.txt" && [ -s "$f/helm-list.txt" ] && [ -s "$f/helm-status.txt" ] &&
    [ -f "$f/helm-manifest.yaml" ] && [ -s "$f/ds-pods.txt" ] && [ -s "$f/ns.txt" ] && [ -f "$f/ds.yaml" ] ||
    { echo "  $s: $(ls "$f" 2>&1 | paste -sd' ')" >&2; nods_ok=0; }
done
check "an install whose DaemonSet never appears fails S1, S2, S3 and S5 with the cluster's state written beside each" "[ $nods_ok = 1 ]"
check "that state is the releases, what helm applied, the DaemonSets and pods with labels, the namespaces, and the context" \
  "[ \"\$(grep -c '^helm list -A -a' '$NC')\" = 4 ] && [ \"\$(grep -c '^helm status -n dra-driver-nvidia-gpu dra-gpu-session' '$NC')\" = 4 ] &&
   [ \"\$(grep -c '^helm get manifest -n dra-driver-nvidia-gpu dra-gpu-session' '$NC')\" = 4 ] &&
   [ \"\$(grep -c '^kubectl get ds,pods -A --show-labels' '$NC')\" = 4 ] && [ \"\$(grep -c '^kubectl get ns\$' '$NC')\" = 4 ] &&
   [ \"\$(grep -c '^kubectl config current-context' '$NC')\" = 4 ]"
check "the state keeps each command's stderr" "grep -q 'fake helm status note on stderr' '$WORK/rout-nods/s1/install-failure/helm-status.txt'"
check "the DaemonSet is looked up repeatedly before the install is given up, not once" \
  "[ \"\$(grep -c '^kubectl get ds -n dra-driver-nvidia-gpu -l app.kubernetes.io/instance=dra-gpu-session -o json' '$NC')\" -ge 6 ]"
check "the lookup's own error reaches the phase's log" "grep -q '0 kubelet-plugin DaemonSets in the release' '$WORK/rout-nods/s1/out.log'"
runner listfail FAKE_HELM_LIST_FAIL=1
check "a helm list that fails stops the install instead of reading as no release" \
  "awk -F'\t' '\$1==\"s1\" && \$2==2' '$WORK/rout-listfail/summary.tsv' | grep -q . && ! grep -q '^helm upgrade' '$WORK/rst-listfail/calls' &&
   grep -q 'helm list failed' '$WORK/rout-listfail/s1/steps.log' && grep -q 'cluster unreachable' '$WORK/rout-listfail/s1/out.log'"
# Against the real chart, when a checkout and helm are at hand: the lookup finds the DaemonSet the chart renders, and the
# component-label query attempt 4 used does not.
if [ -d "$UPSTREAM_CLONE/deployments/helm/dra-driver-nvidia-gpu" ] && command -v helm >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  helm template dra-gpu-session "$UPSTREAM_CLONE/deployments/helm/dra-driver-nvidia-gpu" -n dra-driver-nvidia-gpu \
    --set nvidiaDriverRoot=/ --set gpuResourcesEnabledOverride=true --set resources.computeDomains.enabled=false \
    --kube-version 1.34.3 --api-versions resource.k8s.io/v1 >"$WORK/chart.yaml" 2>"$WORK/chart.err" || cat "$WORK/chart.err" >&2
  python3 -I -c 'import json, sys, yaml
items = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "DaemonSet"]
json.dump({"items": items}, open(sys.argv[2], "w"))' "$WORK/chart.yaml" "$WORK/chart-ds.json"
  mkdir -p "$WORK/rst-chart"
  chart_ds() { env PATH="$BIN:$PATH" FAKE_STATE="$WORK/rst-chart" FAKE_DS_JSON="$WORK/chart-ds.json" bash -c ". '$RD/lib.sh'; $1" 2>&1; }
  check "with the real chart the lookup finds its one kubelet-plugin DaemonSet" \
    "[ \"\$(chart_ds plugin_ds)\" = dra-driver-nvidia-gpu-kubelet-plugin ]"
  # The query's failure is the expected outcome, so its output is read from a variable rather than a pipe pipefail would fail.
  old_query=$(chart_ds 'kubectl get ds -n $NS -l $PLUGIN_SEL -o jsonpath={.items[0].metadata.name}')
  check "with the real chart the component-label query attempt 4 used finds nothing" \
    "grep -q 'index out of bounds' <<<'$old_query' && ! grep -q kubelet-plugin <<<'$old_query'"
else
  echo "skip the real-chart lookup: no upstream checkout, helm or PyYAML"
fi
check "each phase's evidence leaves the instance as the phase ends" \
  "[ \"\$(grep -c '^aws s3 cp --only-show-errors $WORK/tmp/phase-[a-z0-9]*.tgz s3://b/run/phase-' '$RC')\" = 7 ]"

# ---------------------------------------------------------------- the shipped list: S1, then S5
RIN="$IN" runner shipped
P="$WORK/rout-shipped" PC="$WORK/rst-shipped/calls"
check "the shipped runner runs the cluster, the build, S1 and S5, in that order, and nothing of S2, S3 or S4" \
  "[ \"\$(cat '$WORK/rout-shipped.rc')\" = 0 ] && [ \"\$(awk -F'\t' 'NR>1 {print \$1\":\"\$2}' '$P/summary.tsv' | paste -sd' ')\" = 'cluster:0 build:0 s1:0 s5:0' ] &&
   ! grep -qE 'tests-session-s4|kill -KILL|create quota|s3-shares' '$PC' && [ ! -d '$P/s2' ] && [ ! -d '$P/s3' ] && [ ! -d '$P/s4' ]"
check "without S4, the build pulls S1's ubuntu:22.04 and S5's pause:3.10 into the GPU node before S1 applies anything" \
  "a=\$(grep -n '^docker exec dra-session-worker crictl pull docker.io/library/ubuntu:22.04' '$PC' | cut -d: -f1) &&
   b=\$(grep -n '^docker exec dra-session-worker crictl pull registry.k8s.io/pause:3.10' '$PC' | cut -d: -f1) &&
   f=\$(grep -n '^kubectl apply -f $P/s1/r1.yaml' '$PC' | cut -d: -f1) && [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \"\$a\" -lt \"\$f\" ] && [ \"\$b\" -lt \"\$f\" ]"
check "S5's manifest is the issue's: a ResourceClaimTemplate for one full GPU, and a pause:3.10 pod that names it" \
  "grep -qx 'kind: ResourceClaimTemplate' '$P/s5/r1.yaml' && ! grep -qx 'kind: ResourceClaim' '$P/s5/r1.yaml' &&
   grep -qx '    resourceClaimTemplateName: gpu-claim' '$P/s5/r1.yaml' && grep -qx '    image: registry.k8s.io/pause:3.10' '$P/s5/r1.yaml' &&
   grep -qx '          allocationMode: ExactCount' '$P/s5/r1.yaml' && grep -qx '          count: 1' '$P/s5/r1.yaml' &&
   grep -qx '        request: gpu' '$P/s5/r1.yaml' && grep -qx '  restartPolicy: Never' '$P/s5/r1.yaml'"
s5_order=1
for r in 1 2 3; do
  lof() { grep -n -- "$1" "$PC" | head -1 | cut -d: -f1; }
  st=$(lof "^kubectl get -n s5-r$r pod/pod -o jsonpath={.status.resourceClaimStatuses\[?(@.name==\"gpu\")\].resourceClaimName}")
  # S5's down patch is the same command line as S1's: the S1 reps' three, then one per S5 rep.
  dn=$(grep -n -- 'patch ds .*--type merge' "$PC" | sed -n "$(( r + 3 ))p" | cut -d: -f1)
  fp=$(lof "^kubectl delete -n s5-r$r pod/pod --force --grace-period=0 --wait=false")
  fc=$(lof "^kubectl delete -n s5-r$r resourceclaim/pod-gpu-x7k2q --force --grace-period=0 --wait=false")
  fz=$(lof "^kubectl patch -n s5-r$r resourceclaim/pod-gpu-x7k2q --type merge -p {\"metadata\":{\"finalizers\":null}}")
  rp=$(grep -n -- "^kubectl get -n s5-r$r pod/pod --ignore-not-found -o name" "$PC" | tail -1 | cut -d: -f1)
  rc_=$(grep -n -- "^kubectl get -n s5-r$r resourceclaim/pod-gpu-x7k2q --ignore-not-found -o name" "$PC" | tail -1 | cut -d: -f1)
  up=$(grep -n -- 'patch ds .*--type json' "$PC" | sed -n "$(( r + 3 ))p" | cut -d: -f1)
  [ -n "$st" ] && [ -n "$dn" ] && [ -n "$fp" ] && [ -n "$fc" ] && [ -n "$fz" ] && [ -n "$rp" ] && [ -n "$rc_" ] && [ -n "$up" ] &&
    [ "$st" -lt "$dn" ] && [ "$dn" -lt "$fp" ] && [ "$fp" -lt "$fc" ] && [ "$fc" -lt "$fz" ] && [ "$fz" -lt "$rp" ] && [ "$fz" -lt "$rc_" ] &&
    [ "$rp" -lt "$up" ] && [ "$rc_" -lt "$up" ] ||
    { echo "  S5 rep $r: status=$st down=$dn pod=$fp claim=$fc finalizers=$fz read=$rp/$rc_ up=$up" >&2; s5_order=0; }
done
check "S5 reads the claim from the pod's status, takes the plugin down, force-deletes the pod and then the claim, clears a held claim's finalizers, and reads both gone before the plugin returns, in each of three reps" "[ $s5_order = 1 ]"
check "S5 takes the plugin down with exactly S1's patch, six times in all" \
  "[ \"\$(grep -c -- '^kubectl patch ds -n dra-driver-nvidia-gpu dra-driver-nvidia-gpu-kubelet-plugin --type merge -p {\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"dra-gpu-session/plugin-down\":\"true\"}}}}}\$' '$PC')\" = 6 ]"
check "S5 records three valid reps: PrepareCompleted, forced, finalizers removed, both gone while down, absent after the watch, one plugin Unprepare called" \
  "[ \"\$(awk -F'\t' 'NR>1 && \$2==\"yes\" && \$3==\"pod-gpu-x7k2q\" && \$6==\"PrepareCompleted\" && \$7==\"yes\" && \$8==\"yes\" && \$9==\"gone\" && \$10==\"gone\" && \$12==\"absent\" && \$14==\"no\" && \$15>=1 && \$17==1 && \$18==\"-\"' '$P/s5/result.tsv' | wc -l)\" = 3 ] &&
   grep -qx 'valid_reps=3 started=3 reps=3 finding=no' '$P/s5/verdict.txt'"
s5_snaps=1
for s in r1-prepare r1-plugin-down r1-force-delete r1-until-gone r1-plugin-up r1-watch; do
  b=$(ls "$P"/s5/snap/*-"$s".before.checkpoint.json 2>/dev/null | head -1); a=$(ls "$P"/s5/snap/*-"$s".after.checkpoint.json 2>/dev/null | head -1)
  [ -s "$b" ] && [ -s "$a" ] && jq -e .v2 "$b" >/dev/null || { echo "  S5 $s: before '$b' after '$a'" >&2; s5_snaps=0; }
done
check "S5 captures the checkpoint before and after every step" "[ $s5_snaps = 1 ]"
check "S5 keeps the per-step timeline, kubelet's DRA state, the pod's resourceClaimStatuses and both sides' logs" \
  "[ \"\$(awk '{print \$2}' '$P/s5/r1.timeline' | grep -vx watch | paste -sd' ')\" = 'prepared plugin-down deleted plugin-up watched' ] &&
   [ -s '$P/s5/r1.kubelet-dra-state.deleted.json' ] && [ -f '$P/s5/r1.resource-claim-statuses.json' ] &&
   [ -s '$P/s5/r1.kubelet.log' ] && [ -s '$P/s5/r1.plugin.log' ] && [ -s '$P/s5/plugin.log' ]"
RIN="$IN" runner s5stays FAKE_S5_STAYS=1
check "S5 whose force-deleted pod is still in the API is invalid in every rep, whatever the checkpoint shows, and exits 4" \
  "awk -F'\t' '\$1==\"s5\" && \$2==4' '$WORK/rout-s5stays/summary.tsv' | grep -q . &&
   [ \"\$(awk -F'\t' 'NR>1 && \$2==\"no\" && \$9==\"present\"' '$WORK/rout-s5stays/s5/result.tsv' | wc -l)\" = 3 ]"
RIN="$IN" runner s5leak FAKE_S5_LEAK=1
L5="$WORK/rout-s5leak/s5"
check "S5 reports an entry that survives as a finding: valid, still PrepareCompleted after the cleanup-interval watch, no plugin Unprepare called" \
  "awk -F'\t' '\$1==\"s5\" && \$2==0' '$WORK/rout-s5leak/summary.tsv' | grep -q . &&
   awk -F'\t' 'NR==2 && \$2==\"yes\" && \$12==\"PrepareCompleted\" && \$14==\"yes\" && \$17==0' '$L5/result.tsv' | grep -q . &&
   grep -qx 'valid_reps=1 started=1 reps=3 finding=yes' '$L5/verdict.txt'"
check "after a finding S5 runs the issue's second pod, records the uid it is refused for, and starts no further rep" \
  "awk -F'\t' 'NR==2 && \$18==\"not-ready\" && \$19==1' '$L5/result.tsv' | grep -q . && grep -q 'already allocated to different claim uid-s5-r1' '$L5/r1.pod-b-events.txt' &&
   ! grep -q 's5-r2' '$WORK/rst-s5leak/calls'"
RIN="$IN" runner s5gc FAKE_S5_CLAIM_GC=1
check "S5's claim delete after the collector's is sent anyway, and accepts not-found" \
  "grep -q '^kubectl delete -n s5-r1 resourceclaim/pod-gpu-x7k2q --force --grace-period=0 --wait=false --ignore-not-found\$' '$WORK/rst-s5gc/calls'"
check "S5 whose claim the garbage collector removes with its pod is still valid, and removes no finalizer" \
  "[ \"\$(awk -F'\t' 'NR>1 && \$2==\"yes\" && \$8==\"no\"' '$WORK/rout-s5gc/s5/result.tsv' | wc -l)\" = 3 ] && ! grep -q 'finalizers' '$WORK/rst-s5gc/calls'"
RIN="$IN" runner s5claimstays FAKE_S5_CLAIM_STAYS=1
check "S5 whose pod is gone but whose claim is still in the API is invalid in every rep, and exits 4" \
  "awk -F'\t' '\$1==\"s5\" && \$2==4' '$WORK/rout-s5claimstays/summary.tsv' | grep -q . &&
   [ \"\$(awk -F'\t' 'NR>1 && \$2==\"no\" && \$9==\"gone\" && \$10==\"present\"' '$WORK/rout-s5claimstays/s5/result.tsv' | wc -l)\" = 3 ]"
RIN="$IN" runner s5unreg FAKE_S5_UNREGISTERED=1
check "S5 whose returned plugin never logs its registration is invalid, and exits 4" \
  "awk -F'\t' '\$1==\"s5\" && \$2==4' '$WORK/rout-s5unreg/summary.tsv' | grep -q . &&
   [ \"\$(awk -F'\t' 'NR>1 && \$2==\"no\" && \$9==\"gone\" && \$10==\"gone\"' '$WORK/rout-s5unreg/s5/result.tsv' | wc -l)\" = 3 ]"
RIN="$IN" runner s5listfail FAKE_PLUGIN_LIST_FAIL=1
check "S5 whose plugin-pod listing fails does not take the plugin for down: it deletes nothing and exits 4" \
  "awk -F'\t' '\$1==\"s5\" && \$2==4' '$WORK/rout-s5listfail/summary.tsv' | grep -q . && ! grep -q -- '--force' '$WORK/rst-s5listfail/calls' &&
   grep -q 'Unable to connect' '$WORK/rout-s5listfail/s5/out.log'"
RIN="$IN" runner s5getfail FAKE_GET_FAIL=1
check "S5 whose presence reads fail records them unread, not gone, and exits 4" \
  "awk -F'\t' '\$1==\"s5\" && \$2==4' '$WORK/rout-s5getfail/summary.tsv' | grep -q . &&
   [ \"\$(awk -F'\t' 'NR>1 && \$2==\"no\" && \$9==\"unread\" && \$10==\"unread\"' '$WORK/rout-s5getfail/s5/result.tsv' | wc -l)\" = 3 ] &&
   grep -q 'Unable to connect' '$WORK/rout-s5getfail/s5/presence.err'"
RIN="$IN" runner s5nostatus FAKE_S5_NO_STATUS=1
check "S5 whose pod lists no generated claim in its status deletes nothing, keeps the plugin up, and exits 4" \
  "awk -F'\t' '\$1==\"s5\" && \$2==4' '$WORK/rout-s5nostatus/summary.tsv' | grep -q . && ! grep -q -- '--force' '$WORK/rst-s5nostatus/calls' &&
   [ \"\$(grep -c 'patch ds .*--type merge' '$WORK/rst-s5nostatus/calls')\" = 3 ]"
RIN="$IN" runner s5notprepared FAKE_S5_NOT_PREPARED=1
check "S5 whose claim never reached PrepareCompleted is invalid and exits 4" \
  "awk -F'\t' '\$1==\"s5\" && \$2==4' '$WORK/rout-s5notprepared/summary.tsv' | grep -q . &&
   [ \"\$(awk -F'\t' 'NR>1 && \$2==\"no\" && \$6==\"absent\"' '$WORK/rout-s5notprepared/s5/result.tsv' | wc -l)\" = 3 ]"
INS4="$WORK/ins4" && mkdir -p "$INS4" && cp "$IN"/* "$INS4/" && sed -i 's/^SCENARIOS=.*/SCENARIOS="s1 s4"/' "$INS4/runner.sh"
RIN="$INS4" runner s4late
check "a scenario list with S4 after another scenario is refused before any scenario runs" \
  "[ \"\$(cat '$WORK/rout-s4late.rc')\" = 2 ] && grep -q 'S4 must run first' '$WORK/rout-s4late/steps.log' && [ ! -d '$WORK/rout-s4late/s1' ]"

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
