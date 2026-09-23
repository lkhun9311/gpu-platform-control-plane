#!/usr/bin/env bash
# Bootstrap, measure and tear down the GitOps self-heal demonstration.
#
# See experiments/argocd-selfheal/README.md for why this uses its own Application instead of turning
# auto-sync back on for the seven platform Applications.
#
# Usage:
#   hack/argocd-selfheal.sh bootstrap     # create namespace, project and Application at the current commit
#   hack/argocd-selfheal.sh measure       # run both drift injections, REPS times each
#   hack/argocd-selfheal.sh teardown      # remove Application, project and namespace
#
# Environment:
#   CONTEXT   kube context                     (default kind-platform)
#   REPS      repetitions of each injection    (default 3)
#   EXDIR     where the evidence is written    (default ex/selfheal-<UTC timestamp>)
#   REVISION  commit SHA to pin the Application to (default: the current HEAD, which must be pushed)

set -euo pipefail

# Job control, so each backgrounded pipeline becomes its own process group and can be killed as one.
#
# Without it `kill $!` reaches only the last stage of the watch pipeline; see stop_watch for what that cost.
set -m

CONTEXT="${CONTEXT:-kind-platform}"
REPS="${REPS:-3}"
NS=gitops-selfheal
APP=gitops-selfheal-probe
PROJECT=selfheal-probe
DEPLOY=probe
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

k() { kubectl --context "$CONTEXT" "$@"; }

now() { date -u +%s.%N; }

# A timestamped line in the run log, so the narrative and the raw watches share one clock.
say() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$*" | tee -a "$EXDIR/run.log"; }

# Refuse before doing anything, rather than half-way through a measurement.
#
# The Application is pinned to a commit the repo-server fetches from GitHub. A SHA that exists only in the
# local checkout produces an Application stuck in Unknown, which reads like a self-heal failure and is not.
require_pushed_revision() {
  REVISION="${REVISION:-$(git -C "$ROOT" rev-parse HEAD)}"
  if ! git -C "$ROOT" cat-file -e "${REVISION}^{commit}" 2>/dev/null; then
    echo "REVISION $REVISION is not a commit in this repository" >&2
    exit 1
  fi
  # `git branch -r --contains` is empty when the commit was never pushed, which is the case that matters.
  if [[ -z "$(git -C "$ROOT" branch -r --contains "$REVISION" 2>/dev/null)" ]]; then
    echo "REVISION $REVISION is on no remote branch; the repo-server cannot fetch it. Push first." >&2
    exit 1
  fi
}

# Record the settings that govern recovery timing, at the moment of the run.
#
# The controller's own --help is the source here, not the documentation: they disagree about whether a
# fixed five-second self-heal timeout is in force, and the flags plus the (empty) ConfigMaps settle it.
record_settings() {
  say "recording controller settings"
  {
    echo "=== argocd-application-controller --help (self-heal and resync flags) ==="
    k -n argocd exec statefulset/argocd-application-controller -- \
      /usr/local/bin/argocd-application-controller --help 2>/dev/null |
      grep -E 'self-heal|app-resync' || echo "(could not read flags)"
    echo
    echo "=== argocd-cm data ==="
    k -n argocd get cm argocd-cm -o jsonpath='{.data}' 2>/dev/null
    echo
    echo "=== argocd-cmd-params-cm data ==="
    k -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data}' 2>/dev/null
    echo
    echo "=== controller image ==="
    k -n argocd get statefulset argocd-application-controller \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
    echo
  } >"$EXDIR/controller-settings.txt" 2>&1
}

# The state of the seven platform Applications, before and after.
#
# This experiment's whole safety argument is that it does not touch them. An argument is not evidence;
# a diff of these two files is.
record_platform_apps() {
  local when="$1"
  k -n argocd get applications.argoproj.io \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTOMATED:.spec.syncPolicy.automated' \
    >"$EXDIR/platform-apps-$when.txt" 2>&1 || true
}

bootstrap() {
  require_pushed_revision
  record_settings
  record_platform_apps before

  say "creating namespace $NS"
  k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >>"$EXDIR/run.log" 2>&1

  say "applying AppProject $PROJECT"
  k apply -f "$ROOT/experiments/argocd-selfheal/bootstrap/project.yaml" >>"$EXDIR/run.log" 2>&1

  say "applying Application $APP pinned to $REVISION"
  sed "s|PINNED_REVISION|$REVISION|" "$ROOT/experiments/argocd-selfheal/bootstrap/application.yaml" |
    k apply -f - >>"$EXDIR/run.log" 2>&1

  # Assert the substitution landed. A sed that silently did nothing would leave the literal placeholder,
  # and the Application would fail in a way that looks like a repo-server problem.
  local pinned
  pinned="$(k -n argocd get application "$APP" -o jsonpath='{.spec.source.targetRevision}')"
  if [[ "$pinned" != "$REVISION" ]]; then
    echo "Application pinned to '$pinned', expected '$REVISION'" >&2
    exit 1
  fi
  say "pinned revision confirmed: $pinned"

  say "waiting for the first sync to reach Synced/Healthy"
  local deadline=$((SECONDS + 300))
  while ((SECONDS < deadline)); do
    local sync health
    sync="$(k -n argocd get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(k -n argocd get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      say "Application is Synced/Healthy"
      return 0
    fi
    sleep 3
  done
  echo "Application did not reach Synced/Healthy within 300s" >&2
  k -n argocd get application "$APP" -o yaml >"$EXDIR/application-stuck.yaml" 2>&1 || true
  exit 1
}

# Start a watch that timestamps every Deployment event on the client side.
#
# Started BEFORE the injection, because a watch opened afterwards cannot distinguish "the value was never
# wrong" from "the value was already repaired".
start_watch() {
  local tag="$1"
  k -n "$NS" get deployment \
    --field-selector "metadata.name=$DEPLOY" \
    --watch --output-watch-events \
    -o 'jsonpath={.type}{"\t"}{.object.metadata.uid}{"\t"}{.object.metadata.generation}{"\t"}{.object.spec.replicas}{"\n"}' 2>/dev/null |
    while IFS= read -r line; do
      printf '%s\t%s\n' "$(now)" "$line"
    done >"$EXDIR/watch-$tag.tsv" &
  WATCH_PID=$!
  # The watch needs to be established before the injection, or its first event is the injection itself.
  sleep 2
}

stop_watch() {
  if [[ -n "${WATCH_PID:-}" ]]; then
    # Kill the process GROUP, not the single PID `$!` reports.
    #
    # `$!` names the last stage of the pipeline -- the `while read` loop -- while `kubectl --watch` is its
    # sibling and outlives it. `wait` then blocks on a job that never ends. The first run of this script
    # stalled exactly there, after two repetitions, with the workload already repaired and nothing left to
    # do: a hang that looks identical to self-heal failing to fire.
    kill -- -"$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
  fi
}

# Wait until the named jsonpath reports the wanted value, and print the elapsed seconds.
#
# Polling, not watching, is used for the decision; the watch file is the independent record. A polling
# interval of 0.2s bounds the reported time to that resolution, which is stated in the write-up.
await_value() {
  local jsonpath="$1" want="$2" timeout="$3" t0="$4"
  local deadline
  deadline=$(python3 -c "print($t0 + $timeout)")
  while :; do
    local got
    got="$(k -n "$NS" get deployment "$DEPLOY" -o jsonpath="$jsonpath" 2>/dev/null || true)"
    if [[ "$got" == "$want" ]]; then
      python3 -c "print(f'{$(now) - $t0:.3f}')"
      return 0
    fi
    if (($(python3 -c "print(1 if $(now) > $deadline else 0)"))); then
      return 1
    fi
    sleep 0.2
  done
}

# The controller's own account of why it waited, kept beside each repetition.
#
# Recovery latency here is dominated by Argo's self-heal backoff rather than by detection: with
# --self-heal-timeout-seconds unset the controller refuses to retry the SAME revision until an exponential
# delay expires, and says so -- "Skipping auto-sync: already attempted sync to <sha> ... retrying in ...".
# Without this file the growing times read as a cluster getting slower, which is the wrong conclusion and
# the one a reader reaches on their own.
capture_controller_log() {
  local tag="$1"
  k -n argocd logs statefulset/argocd-application-controller --tail=300 2>/dev/null |
    grep "$APP" >"$EXDIR/controller-$tag.log" 2>&1 || true
}

inject_modify() {
  local rep="$1"
  say "modify rep $rep: setting spec.replicas 1 -> 3"
  start_watch "modify-$rep"
  local t0
  t0="$(now)"
  k -n "$NS" scale deployment "$DEPLOY" --replicas=3 >>"$EXDIR/run.log" 2>&1

  local elapsed
  if elapsed="$(await_value '{.spec.replicas}' 1 300 "$t0")"; then
    say "modify rep $rep: spec.replicas back to 1 after ${elapsed}s"
    echo -e "modify\t$rep\t$elapsed" >>"$EXDIR/results.tsv"
  else
    say "modify rep $rep: NOT repaired within 300s"
    echo -e "modify\t$rep\ttimeout" >>"$EXDIR/results.tsv"
  fi
  capture_controller_log "modify-$rep"
  stop_watch
  settle
}

inject_delete() {
  local rep="$1"
  local before_uid
  before_uid="$(k -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.metadata.uid}')"
  say "delete rep $rep: deleting Deployment (uid $before_uid)"
  start_watch "delete-$rep"
  local t0
  t0="$(now)"
  k -n "$NS" delete deployment "$DEPLOY" --wait=false >>"$EXDIR/run.log" 2>&1

  # Recreation, not survival: the object must come back with a different UID.
  local deadline elapsed=""
  deadline=$(python3 -c "print($t0 + 300)")
  while :; do
    local uid
    uid="$(k -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    if [[ -n "$uid" && "$uid" != "$before_uid" ]]; then
      elapsed="$(python3 -c "print(f'{$(now) - $t0:.3f}')")"
      say "delete rep $rep: recreated after ${elapsed}s, uid $before_uid -> $uid"
      echo -e "delete\t$rep\t$elapsed" >>"$EXDIR/results.tsv"
      break
    fi
    if (($(python3 -c "print(1 if $(now) > $deadline else 0)"))); then
      say "delete rep $rep: NOT recreated within 300s"
      echo -e "delete\t$rep\ttimeout" >>"$EXDIR/results.tsv"
      break
    fi
    sleep 0.2
  done
  capture_controller_log "delete-$rep"
  stop_watch
  settle
}

# Return to Synced/Healthy before the next repetition.
#
# Self-heal delay is an exponential backoff from the previous operation's finishedAt, so a repetition
# started while the last one is still settling measures the backoff rather than the repair.
settle() {
  local deadline=$((SECONDS + 300))
  while ((SECONDS < deadline)); do
    local sync health ready
    sync="$(k -n argocd get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(k -n argocd get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    ready="$(k -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" && "$ready" == "1" ]]; then
      return 0
    fi
    sleep 3
  done
  say "WARNING: did not return to Synced/Healthy/ready=1 before the next repetition"
}

measure() {
  record_settings
  record_platform_apps before
  say "REPS=$REPS, evidence in $EXDIR"
  printf 'injection\trep\tseconds\n' >"$EXDIR/results.tsv"

  local i
  for ((i = 1; i <= REPS; i++)); do
    inject_modify "$i"
  done
  for ((i = 1; i <= REPS; i++)); do
    inject_delete "$i"
  done

  # The Application's own record of what it did, to pair with the client-side timings.
  k -n argocd get application "$APP" -o json >"$EXDIR/application-final.json" 2>&1 || true
  record_platform_apps after

  say "results:"
  cat "$EXDIR/results.tsv" | tee -a "$EXDIR/run.log"

  # The safety claim, checked rather than asserted.
  if diff -q "$EXDIR/platform-apps-before.txt" "$EXDIR/platform-apps-after.txt" >/dev/null 2>&1; then
    say "the seven platform Applications are unchanged"
  else
    say "WARNING: the platform Applications changed during this run; see platform-apps-*.txt"
  fi
}

teardown() {
  say "deleting Application $APP (its finalizer removes the workload)"
  k -n argocd delete application "$APP" --ignore-not-found >>"$EXDIR/run.log" 2>&1
  say "deleting AppProject $PROJECT"
  k -n argocd delete appproject "$PROJECT" --ignore-not-found >>"$EXDIR/run.log" 2>&1
  say "deleting namespace $NS"
  k delete namespace "$NS" --ignore-not-found >>"$EXDIR/run.log" 2>&1
  say "teardown complete"
}

# True when another instance of this script is already running.
running_elsewhere() {
  local pid argv0 argv1
  for pid in /proc/[0-9]*; do
    pid="${pid##*/}"
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    [[ -r "/proc/$pid/cmdline" ]] || continue
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || continue
    argv0="${argv[0]:-}"
    argv1="${argv[1]:-}"
    [[ "$argv0" == *bash && "$argv1" == *argocd-selfheal.sh ]] && return 0
  done
  return 1
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    bootstrap | measure | teardown) ;;
    *)
      echo "usage: $0 {bootstrap|measure|teardown}" >&2
      exit 1
      ;;
  esac

  # Refuse a second concurrent runner.
  #
  # Two instances writing one results.tsv produced a duplicated row that read as a measurement rather than as
  # bookkeeping damage, and the instance that caused it was an earlier run left alive by the stop_watch hang.
  # A corrupted evidence file is worse than a missing one: nothing downstream can tell the two apart.
  #
  # The test reads argv[1] out of /proc rather than using `pgrep -f`, whose pattern matches the command line
  # of whatever shell is holding the pattern -- including this one.
  if [[ "$cmd" == "measure" ]] && running_elsewhere; then
    echo "another argocd-selfheal.sh is already running; refusing to share an evidence directory" >&2
    exit 1
  fi

  EXDIR="${EXDIR:-ex/selfheal-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$EXDIR"

  trap stop_watch EXIT

  "$cmd"
}

main "$@"
