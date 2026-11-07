# shellcheck shell=bash
# The parts of hack/restart-lifecycle-kind.sh that decide whether a cluster is its own, whether its helpers are gone,
# and whether the rehearsal may report success, as functions, so hack/test/check-restart-kind-driver.sh can break each.
#
# Like hack/lib/restart-session.sh it never calls `set`, never `cd`s and installs no traps: those belong to the caller.

# rstk_cluster_listed NAME: 0 when kind lists NAME, 1 when it lists clusters and not NAME, 2 when the list cannot be read.
#
# A failed lookup is not "no cluster": read that way, the driver went on to create one, took ownership, and its cleanup
# would then remove a cluster of that name it had not made (codex review against origin/dev).
rstk_cluster_listed() {
  local listed
  listed="$(kind get clusters 2>&1)" || {
    echo "could not list the kind clusters: ${listed:0:200}" >&2
    return 2
  }
  # kind says this on stderr, merged above, when there are none; it is an answer, not a cluster's name.
  listed="$(grep -v '^No kind clusters found\.$' <<<"$listed")"
  if grep -qx -- "$1" <<<"$listed"; then return 0; fi
  return 1
}

# rstk_descendants PID: every process below PID, deepest last, one per line.
rstk_descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    rstk_descendants "$child"
  done
}

# rstk_running PID: 0 while PID is a process that has not exited; a zombie has, though kill -0 still succeeds on it.
rstk_running() {
  local st
  st="$(ps -o stat= -p "$1")" || return 1
  [[ -n "$st" && "$st" != Z* ]]
}

# rstk_kill_tree PID: PID and every process below it stopped, and PID waited for, which must be this shell's child.
#
# Killing only the helper's own shell left the command substitution it was waiting in, a loop of its own, polling
# kubectl after the cluster was gone (codex review against origin/dev).
# The tree is read before anything is killed, because a killed parent's children are reparented away from it.
# TERM gets RSTK_TERM_GRACE seconds (default 10), then PID and its tree are killed outright: a helper that ignored TERM,
# or that waited on a child that did, once held the wait below, and the cleanup with it, forever (gpt-6-astra review of
# 116092ef).
rstk_kill_tree() {
  local pid="$1" tree p n=0
  tree="$(rstk_descendants "$pid")"
  kill -TERM "$pid" 2>&1 | grep -v 'No such process'
  for p in $tree; do
    kill -TERM "$p" 2>&1 | grep -v 'No such process'
  done
  while rstk_running "$pid" && ((n < ${RSTK_TERM_GRACE:-10} * 10)); do
    sleep 0.1
    n=$((n + 1))
  done
  # Anything that ignored TERM is killed outright, so no helper survives its cleanup.
  for p in "$pid" $tree; do
    if rstk_running "$p"; then kill -KILL "$p" 2>&1 | grep -v 'No such process'; fi
  done
  # In this shell, never in a pipeline: a pipeline's side runs in a subshell, where the helper is no child and the wait
  # returns at once (codex review of 8caf0d6e); a PID this shell did not start is reported on stderr and not waited for.
  wait "$pid"
  return 0
}

# rstk_injection_failed OUT WHAT: a scenario's fault injection failed, recorded so the rehearsal cannot report success.
rstk_injection_failed() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $2" >>"$1/injection-failed.txt"
}
