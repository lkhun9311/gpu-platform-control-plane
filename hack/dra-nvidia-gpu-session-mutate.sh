#!/usr/bin/env bash
#
# Mutation runs for hack/dra-nvidia-gpu-session-test.sh: each mutation breaks one guard of the session or of S5 in a copy
# of the files, and the offline test must fail on it.
# A mutation whose edit changed nothing is reported as not applied and counts as a failure of this script, so a stale
# pattern cannot pass as a killed mutant.
# The unmutated copy must pass first, or no mutant's failure means anything.
# Every mutant's copy is made before any test starts, so an edit to the tree during the run cannot reach a mutant.
# Mutants then run MUTATE_JOBS at a time (default 6), each in its own copy and its own fake state.
#
#   bash hack/dra-nvidia-gpu-session-mutate.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
D=hack/dra-nvidia-gpu
JOBS=${MUTATE_JOBS:-6}
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "MUTATE_JOBS is '$JOBS', not a positive integer" >&2; exit 2; }

# copy DIR: the files the session and its test read, without the run records, which the test does not read.
copy() {
  mkdir -p "$1/hack/lib" "$1/$D"
  cp "$ROOT/hack/dra-nvidia-gpu-session.sh" "$ROOT/hack/dra-nvidia-gpu-session-test.sh" "$1/hack/"
  cp "$ROOT/hack/lib/spot-run.sh" "$1/hack/lib/"
  find "$ROOT/$D" -maxdepth 1 -type f -exec cp {} "$1/$D/" \;
}

copy "$WORK/base"
n=0
# mutate NAME FILE SED makes one mutant's copy; a mutation that changed nothing is marked and never run.
mutate() {
  local name=$1 file=$2 expr=$3 m
  n=$((n + 1))
  m="$WORK/m$n"
  copy "$m"
  sed -i "$expr" "$m/$file"
  echo "$name" >"$m.name"
  if cmp -s "$WORK/base/$file" "$m/$file"; then
    echo "NOT APPLIED  $name ($file: $expr)" >"$m.verdict"
  fi
}

S5="$D/s5.sh"
# The two the plan names: objects still in the API counted as valid, and the force delete skipped.
mutate "objects still present while the plugin is down are counted as valid" "$S5" \
  's/^    \[ "\$pod_while_down" = gone \] && \[ "\$claim_while_down" = gone \] &&$/    true \&\&/'
mutate "the force delete is skipped" "$S5" 's/^    step "r\$r-force-delete" force_delete "\$ns" "\$claim" && forced=yes$/    forced=yes/'
# The rest of S5's guards.
mutate "the pod is deleted normally, not forced" "$S5" 's|kubectl delete -n "\$1" pod/pod --force --grace-period=0 --wait=false|kubectl delete -n "$1" pod/pod --wait=false|'
mutate "a claim still present is counted as valid" "$S5" 's/^    \[ "\$pod_while_down" = gone \] && \[ "\$claim_while_down" = gone \] &&$/    [ "$pod_while_down" = gone ] \&\&/'
mutate "a held claim's finalizers are never removed" "$S5" 's/^  timeout "\$(left 30)" kubectl patch -n "\$1" "resourceclaim\/\$2" .*/  :/'
mutate "a presence read that fails is taken as gone" "$S5" 's/2>>"\$D\/presence.err") || { echo unread; return; }/2>>"$D\/presence.err") || { echo gone; return; }/'
mutate "validity ignores PrepareCompleted" "$S5" 's/^  \[ "\$after_prepare" = PrepareCompleted \] && \[ "\$down" = yes \]/  [ "$down" = yes ]/'
mutate "the watch is a tenth of two retry periods" "$S5" 's/^WATCH_S=150$/WATCH_S=15/'
mutate "the cleanup-interval watch is shortened" "$S5" 's/^CLEANUP_WATCH_S=630$/CLEANUP_WATCH_S=300/'
mutate "a finding does not end the repetitions" "$S5" 's/^    break$/    :/'
mutate "the issue's second pod is not run after a finding" "$S5" 's/^    step "r\$r-pod-b" pod_b "\$ns"$/    POD_B=-/'
mutate "the exit-4 rule is dropped" "$S5" 's/^\[ "\$valid_reps" = "\$started" \] || exit 4$/exit 0/'
mutate "the claim name is not read from the pod's status" "$S5" 's/{.status.resourceClaimStatuses\[?(@.name=="gpu")\].resourceClaimName}/{.spec.resourceClaims[0].name}/'
mutate "the claim delete fails on a claim the collector removed" "$S5" 's/ --force --grace-period=0 --wait=false --ignore-not-found$/ --force --grace-period=0 --wait=false/'
mutate "the plugin's registration is not required" "$S5" 's/^  poll 90 5 registered$/  true/'
mutate "a failed plugin listing reads as the plugin down" "$D/lib.sh" 's/^no_plugin_pod() { local o; o=\$(kubectl get pods -n "\$NS" -l "\$PLUGIN_SEL" -o name) && \[ -z "\$o" \]; }$/no_plugin_pod() { [ -z "$(kubectl get pods -n "$NS" -l "$PLUGIN_SEL" -o name)" ]; }/'
# The runner and the session.
mutate "the runner leaves S5 out" "$D/runner.sh" 's/^SCENARIOS="s1 s5"$/SCENARIOS="s1"/'
mutate "S5 runs before S1" "$D/runner.sh" 's/^SCENARIOS="s1 s5"$/SCENARIOS="s5 s1"/'
mutate "S4 may run after another scenario" "$D/runner.sh" 's/^case " \$SCENARIOS " in \*" s4 "\*).*/:/'
mutate "the build pulls no images" "$D/build.sh" 's|^for img in docker.io/library/ubuntu:22.04 registry.k8s.io/pause:3.10; do$|for img in; do|'
mutate "the session ignores a scenario's exit 4" "hack/dra-nvidia-gpu-session.sh" 's/^  \[ "\$(phase_rc "\$ph")" = 0 \] || exit 2$/  true/'
mutate "the session ships S1 alone" "hack/dra-nvidia-gpu-session.sh" 's/^PHASES="cluster build s1 s5"$/PHASES="cluster build s1"/'
mutate "the cost cap is back at \$5" "hack/dra-nvidia-gpu-session.sh" 's/^COST_CAP_USD=2.00$/COST_CAP_USD=5.00/'
mutate "the session's S5 bound is not the runner's" "hack/dra-nvidia-gpu-session.sh" 's/^S5_S=1500$/S5_S=1200/'
mutate "a dirty tree is not refused" "hack/dra-nvidia-gpu-session.sh" 's/^\[ -z "\$(git status --porcelain)" \] || fail/true || fail/'
mutate "the sweeper is not checked" "hack/dra-nvidia-gpu-session.sh" 's/^\[ "\$sw_state" = Active \] || fail .*/:/'

# The base runs once every copy exists, and must pass, or no mutant's failure means anything.
if ! bash "$WORK/base/hack/dra-nvidia-gpu-session-test.sh" >"$WORK/base.log" 2>&1; then
  echo "the unmutated copy fails its own test; see $WORK/base.log" >&2
  grep '^FAIL' "$WORK/base.log" >&2
  exit 2
fi
echo "base  the unmutated copy passes ($(grep -c '^ok' "$WORK/base.log") checks)"

# run_one I runs mutant I's test and writes its verdict: killed only when the test exits non-zero with a FAIL line.
run_one() {
  local m="$WORK/m$1" name rc fails
  name=$(cat "$m.name")
  bash "$m/hack/dra-nvidia-gpu-session-test.sh" >"$m.log" 2>&1
  rc=$?
  fails=$(grep -c '^FAIL' "$m.log")
  if [ "$rc" != 0 ] && [ "$fails" -gt 0 ]; then
    echo "killed ($fails FAIL)  $name: $(grep -m1 '^FAIL' "$m.log" | cut -c6-160)" >"$m.verdict"
  else
    echo "SURVIVED  $name (rc=$rc, $fails FAIL)" >"$m.verdict"
  fi
}
for i in $(seq 1 "$n"); do
  [ -e "$WORK/m$i.verdict" ] && continue
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
  run_one "$i" &
done
wait

survived=0
for i in $(seq 1 "$n"); do
  v=$(cat "$WORK/m$i.verdict")
  echo "$v"
  case $v in killed*) ;; *) survived=$((survived + 1)) ;; esac
done
echo "$((n - survived)) of $n mutants killed"
[ "$survived" = 0 ]
