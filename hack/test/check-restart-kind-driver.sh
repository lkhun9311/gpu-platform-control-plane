#!/usr/bin/env bash
#
# The kind restart rehearsal's driver, hack/restart-lifecycle-kind.sh, checked where it decides what is its own and
# whether it may report success, with no cluster.
#
#   bash hack/test/check-restart-kind-driver.sh
#
# Three parts:
#   1. a kind cluster list that cannot be read stops the driver before it creates or removes anything;
#   2. stopping a helper stops its whole process tree, its command substitutions' loops included;
#   3. check_outcomes.py passes the recorded rehearsal and fails each way a scenario can come out wrong.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=hack/lib/restart-kind-driver.sh
. hack/lib/restart-kind-driver.sh

# --- 1. the cluster lookup ----------------------------------------------------------------------------------------
mkdir -p "$work/bin"
# kind, docker, kubectl and make record their calls; kind answers `get clusters` from STUB_KIND and refuses to create.
cat >"$work/bin/stub" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"${STUB_CALLS:?}"
case "$(basename "$0") $*" in
  "kind get clusters")
    case "${STUB_KIND:-}" in
      fail) echo "ERROR: failed to list clusters: permission denied" >&2; exit 1 ;;
      none) echo "No kind clusters found." >&2 ;;
      *) printf '%s\n' $STUB_KIND ;;
    esac ;;
  "kind create"*) echo "stub kind refuses to create" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$work/bin/stub"
for t in kind docker kubectl make; do ln -s stub "$work/bin/$t"; done

lookup() { STUB_CALLS="$work/lookup.calls" STUB_KIND="$1" PATH="$work/bin:$PATH" rstk_cluster_listed rstlife; echo "rc=$?"; }
for c in "ckad m6clean rstlife:rc=0" "ckad m6clean platform:rc=1" "none:rc=1" "fail:rc=2"; do
  got="$(lookup "${c%%:*}" 2>&1 | tail -1)"
  if [[ "$got" == "${c#*:}" ]]; then ok "kind listing '${c%%:*}' reads ${c#*:}"; else bad "kind listing '${c%%:*}' reads $got, want ${c#*:}"; fi
done

# The driver itself, with the list unreadable: it must stop, and neither create nor remove a cluster or a node.
: >"$work/driver.calls"
out="$(STUB_CALLS="$work/driver.calls" STUB_KIND=fail RSTK_OUT="$work/evidence" PATH="$work/bin:$PATH" bash hack/restart-lifecycle-kind.sh 2>&1)"
rc=$?
touched="$(grep -cE '^kind (create|delete)|^docker (rm|kill|build)|^make ' "$work/driver.calls")"
if [[ "$rc" != 0 && "$touched" == 0 && "$(cat "$work/evidence/VOID" 2>&1)" == "could not tell whether a cluster rstlife exists"* ]]; then
  ok "an unreadable cluster list stops the driver before it builds, creates or removes anything"
else
  bad "with the cluster list unreadable the driver exited $rc after $touched build, create or remove call(s): $(tail -2 <<<"$out")"
fi

# --- 2. a helper's whole process tree -------------------------------------------------------------------------------
# A helper like hold_quota: its own loop waits in a command substitution, which loops itself and ticks a file.
helper() {
  local m
  m=$(while :; do echo tick >>"$work/ticks"; sleep 0.2; done)
  echo "$m"
}
: >"$work/ticks"
helper &
pid=$!
sleep 1
# Read before the kill, so a loop that survives can still be found and stopped once it has been measured.
tree="$(rstk_descendants "$pid")"
rstk_kill_tree "$pid"
sleep 0.5
before="$(wc -l <"$work/ticks")"
sleep 1.5
after="$(wc -l <"$work/ticks")"
# kill -0's status, not its output: a live process makes it print nothing, which a grep for its error read as gone
# (codex review of 8caf0d6e).
if [[ "$before" -gt 0 && "$before" == "$after" ]] && ! kill -0 "$pid" 2>>"$work/kill0.err"; then
  ok "stopping a helper stops its command substitution's loop ($before ticks, none after)"
else
  bad "a helper's loop went on after it was stopped: $before ticks, then $after"
fi
# A survivor would otherwise hold this script's output open after it ends.
for p in $tree; do kill -KILL "$p" 2>&1 | grep -v 'No such process'; done
# A helper whose shell takes a second to finish on TERM: rstk_kill_tree returns only once it has, so the cluster is not
# torn down under a helper still running (codex review of 8caf0d6e: the wait ran in a pipeline's subshell and waited
# for nothing).
helper2() {
  trap 'sleep 1; echo done >"$work/waited"; exit 0' TERM
  while :; do sleep 0.1; done
}
helper2 &
pid=$!
# A watchdog, so a helper that is never stopped cannot hang this check.
(
  sleep 8
  kill -KILL "$pid" 2>>"$work/watchdog.err"
) &
dog=$!
sleep 0.5
rstk_kill_tree "$pid"
if [[ -s "$work/waited" ]]; then ok "rstk_kill_tree waits for the helper to finish"; else bad "rstk_kill_tree returned before the helper finished"; fi
if kill -0 "$pid" 2>>"$work/kill0.err"; then bad "the helper still runs after rstk_kill_tree"; else ok "the helper is gone after rstk_kill_tree"; fi
rstk_kill_tree "$dog"
if grep -qE 'kill "\$p" 2>>' hack/restart-lifecycle-kind.sh || ! grep -q 'rstk_kill_tree "\$p"' hack/restart-lifecycle-kind.sh; then
  bad "the driver's cleanup stops its helpers some other way than rstk_kill_tree"
else
  ok "the driver's cleanup stops each helper with rstk_kill_tree"
fi

# --- 3. the scenarios' outcomes -------------------------------------------------------------------------------------
rec=hack/restart-lifecycle-kind-20261101T143009Z
fixture() {
  rm -rf "$work/out"
  mkdir -p "$work/out"
  cp -r "$rec"/run-a "$rec"/run-b "$rec"/run-c "$rec"/run-d "$rec"/quota-hold.txt "$rec"/stuck.txt "$rec"/clocks-broken.txt "$work/out/"
  # That rehearsal's run a terminate-wait-1 FAILED, before the rendezvous timeout; the fixture's is the recovery the
  # outcome check now requires, and "run a's terminate-wait-1 as first recorded" below is the real line.
  sed -i 's/^FAILED   terminate-wait-1: not recovered.*/ACCEPTED terminate-wait-1 {"class": "replacement", "from_step": 10}/' "$work/out/run-a/verdict.txt"
}
outcomes() { python3 hack/test/restart-kind/check_outcomes.py "$work/out" a b c d; }
fixture
if out="$(outcomes)"; then ok "the recorded rehearsal comes out as its scenarios require"; else bad "the recorded rehearsal: $(grep FAIL <<<"$out")"; fi
# defect NAME SETUP WANT: the fixture broken by SETUP must fail with WANT in its FAIL line.
defect() {
  fixture
  (cd "$work/out" && eval "$2")
  if out="$(outcomes)"; then
    bad "$1 passed the outcome check"
  elif grep '^FAIL' <<<"$out" | grep -qF -- "$3"; then
    ok "$1 fails: $(grep '^FAIL' <<<"$out" | grep -F -- "$3" | head -1)"
  else
    bad "$1 failed, but not for '$3': $(grep '^FAIL' <<<"$out" | head -2)"
  fi
}
defect "run a's terminate-wait-1 as first recorded" "cp '$PWD/$rec/run-a/verdict.txt' run-a/verdict.txt" "run-a/terminate-wait-1: FAILED"
defect "a terminate-wait that recovered on a spare" 'sed -i "s/\"class\": \"replacement\"/\"class\": \"spare\"/" run-b/verdict.txt' "run-b/terminate-wait-1: ACCEPTED"
defect "a case never submitted" 'rm run-b/rank-kill-2/case.json' "run-b/rank-kill-2: no case.json"
defect "a case with no directory" 'rm -r run-a/dcgm-1' "run-a/dcgm-1: no directory"
defect "a scorer that refused the run" 'sed -i "s/^exit=1$/exit=2/" run-a/verdict.txt' "run-a: the scorer exited 2"
defect "a scorer whose status was not read" 'sed -i "/^exit=/d" run-c/verdict.txt' "run-c: no scorer exit status"
defect "a censored case that ran to the end" 'sed -i "s/^FAILED   rank-kill-1: censored.*/ACCEPTED rank-kill-1 {}/" run-b/verdict.txt' "run-b/rank-kill-1: ACCEPTED"
defect "a VOID that was not before its fault" 'sed -i "s/VOID-before-fault/VOID-after/" run-d/verdict.txt' "run-d/rank-kill-1"
defect "a stop that was not the retirement's" 'sed -i "s/could not be retired/was skipped/" run-c/verdict.txt' "run-c/rank-kill-2"
defect "a quota never lowered" 'sed -i "/^lowered /d" quota-hold.txt' "run-b: quota-hold.txt"
defect "a finalizer never put on" 'rm stuck.txt' "run-c: no stuck.txt"
defect "clocks never broken" 'rm clocks-broken.txt' "run-d: no clocks-broken.txt"
defect "a failed injection" 'echo "2026-11-01T00:00:00Z hold_quota: the quota could not be lowered" >injection-failed.txt' "an injection failed"
fixture
if out="$(python3 hack/test/restart-kind/check_outcomes.py "$work/out")"; then bad "no run named passed"; else ok "no run named fails"; fi
# The driver exits on the outcome check as well as the lifecycle check.
if grep -q 'check_outcomes.py "\$OUT" \$RUNS' hack/restart-lifecycle-kind.sh && grep -q '\[ "\$CHECK_RC" = 0 \] && \[ "\$OUTCOMES_RC" = 0 \] || exit 1' hack/restart-lifecycle-kind.sh; then
  ok "the driver's exit status needs both the lifecycle and the outcome check"
else
  bad "the driver's exit status does not need the outcome check"
fi
# break_clocks and mend_clocks act on the exporters restart_exporters lists, those on nodes the group has now: an exporter
# left listed on a removed node cannot be exec'd into, and counting that as a failed injection failed a rehearsal whose
# every live clock was broken (codex review of 83b369ec).
for f in break_clocks mend_clocks; do
  body="$(sed -n "/^$f() {/,/^}/p" hack/restart-lifecycle-kind.sh)"
  if grep -q 'restart_exporters' <<<"$body" && ! grep -q 'component=dcgm-exporter' <<<"$body"; then
    ok "$f acts only on the exporters of the group's current nodes"
  else
    bad "$f lists exporters by label, the stale ones on removed nodes included"
  fi
done
# Each way an injection can fail is recorded: hold_quota's lowering and restoring, stick_pod's patch, and break_clocks'
# exec on a Pod and its having broken none.
for c in hold_quota:2 stick_pod:1 break_clocks:2; do
  f="${c%%:*}"
  n="$(sed -n "/^$f() {/,/^}/p" hack/restart-lifecycle-kind.sh | grep -c rstk_injection_failed)"
  if [[ "$n" == "${c#*:}" ]]; then ok "$f records each of its $n failed injections"; else bad "$f records $n failed injection(s), want ${c#*:}"; fi
done

if ((fails)); then
  echo "check-restart-kind-driver: $fails failure(s)"
  exit 1
fi
echo "check-restart-kind-driver: all checks passed"
