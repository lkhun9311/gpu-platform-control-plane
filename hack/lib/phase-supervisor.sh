# shellcheck shell=bash
# The bound on a paid phase: everything the phase starts runs in a cgroup of its own, killed whole at its deadline.
#
# Every earlier bound was a wrapper around one call (timeout -k, kubectl's request timeout, restart_by), and each call
# or descendant no wrapper reached was a way past it.
# A credential helper that ignored TERM outlived timeout, kept the caller's pipe open, and held a 1 s deadline for 6 s
# (sixth attack of the retarget registration); the same attack found calls no wrapper covered at all.
# A cgroup holds every descendant, one that called setsid included, and one write to cgroup.kill ends them all.
# docs/superpowers/specs/2026-11-05-paid-phase-supervisor-design.md registers this.
#
# It needs the session to own its cgroup: run it under `systemd-run --user --scope -p Delegate=yes`.
# phase_supervisor_ready says whether it does, by tripping the mechanism rather than reading permissions.

# How often a phase is checked against its deadline, so a phase outlives it by at most this; the first checks come
# sooner, so a phase that ends at once costs its caller milliseconds and not a whole interval.
PHASE_POLL=0.5
PHASE_POLL_FIRST=(0.01 0.02 0.05 0.1 0.2)

# phase_now: PHASE_NOW set to whole seconds of CLOCK_BOOTTIME, read from /proc/uptime without a fork.
# The supervisor decides on this clock and not on SECONDS, which follows the wall clock: a backward step of the
# collector's clock delayed SECONDS' deadline by the step (gpt-6-astra's GO review of 7e9ac2a5), and clock faults on the
# collector are in the registration's threat model.
phase_now() {
  local _rest
  read -r PHASE_NOW _rest </proc/uptime
  PHASE_NOW="${PHASE_NOW%.*}"
}
# Both clocks read once when this file is sourced, before any deadline is computed; paid_phase converts a deadline its
# caller gave in SECONDS through this pair as well as from its own start (paid_phase says why).
phase_now
PHASE_T0_MONO="$PHASE_NOW"
PHASE_T0_SEC="$SECONDS"
# The prefix of this session's phase cgroups, so phase_kill_all ends this session's phases and no other's: two sessions
# can share one writable cgroup (bare review of f29d698d).
PHASE_SESSION="${PHASE_SESSION:-$$}"

# phase_cgroup: the directory of this process's cgroup on the unified hierarchy.
phase_cgroup() {
  local line
  line="$(</proc/self/cgroup)"
  [[ "$line" == 0::/* ]] || {
    echo "this process is not on a unified (v2) cgroup hierarchy: ${line:0:120}"
    return 1
  }
  printf '/sys/fs/cgroup%s\n' "${line#0::}"
}

# phase_alive PID: PID runs; a zombie does not, though kill -0 succeeds on one not yet reaped.
phase_alive() {
  local stat
  stat="$(ps -o stat= -p "$1")" && [[ -n "$stat" && "$stat" != Z* ]]
}

# phase_empty CG: kill what CG still holds and wait up to 5 s for it to empty, then remove it.
phase_empty() {
  local cg="$1" i
  [[ -d "$cg" ]] || return 0
  grep -q '^populated 0$' "$cg/cgroup.events" || echo 1 >"$cg/cgroup.kill"
  for ((i = 0; i < 50; i++)); do
    grep -q '^populated 0$' "$cg/cgroup.events" && break
    sleep 0.1
  done
  rmdir "$cg" || {
    echo "the phase cgroup $cg could not be emptied: $(tr '\n' ' ' <"$cg/cgroup.procs")"
    return 1
  }
}

# phase_supervisor_ready: the session can bound a phase, shown by killing a sleeper in a cgroup it made.
phase_supervisor_ready() {
  local parent cg sleeper out
  parent="$(phase_cgroup)" || {
    echo "$parent"
    return 1
  }
  cg="$parent/phase-ready-$BASHPID"
  out="$(mkdir "$cg" 2>&1)" || {
    echo "cannot make a cgroup under $parent (${out:0:120}); run the session under systemd-run --user --scope -p Delegate=yes"
    return 1
  }
  if [[ ! -e "$cg/cgroup.kill" ]]; then
    rmdir "$cg"
    echo "$cg has no cgroup.kill, which needs Linux 5.14 or later"
    return 1
  fi
  (echo "$BASHPID" >"$cg/cgroup.procs" && exec sleep 300) </dev/null >/dev/null 2>&1 &
  sleeper=$!
  sleep 0.2
  if ! grep -qx "$sleeper" "$cg/cgroup.procs"; then
    kill "$sleeper"
    wait "$sleeper"
    rmdir "$cg"
    echo "a process could not be moved into $cg; run the session under systemd-run --user --scope -p Delegate=yes"
    return 1
  fi
  out="$(phase_empty "$cg")" || {
    echo "$out"
    return 1
  }
  wait "$sleeper"
  echo "a sleeper in $cg was killed with its cgroup and the cgroup removed"
}

# phase_supervisor_enter COMMAND ARGS...: returns when this process owns its cgroup; otherwise replaces it with COMMAND
# ARGS under a delegated scope, once, or fails saying why.
# The user manager is asked first; a host without one (a CI runner) is asked through sudo, with PATH carried over,
# because sudo's secure_path would otherwise drop the stubs a test puts first.
phase_supervisor_enter() {
  local why
  why="$(phase_supervisor_ready)" && return 0
  if [[ -n "${PHASE_SUPERVISOR_ENTERED:-}" ]]; then
    echo "under a delegated scope and still unable to bound a phase: $why"
    return 1
  fi
  export PHASE_SUPERVISOR_ENTERED=1
  if systemd-run --user --scope -q -p Delegate=yes true; then
    exec systemd-run --user --scope -q -p Delegate=yes -- "$@"
  fi
  exec sudo -n --preserve-env systemd-run --scope -q -p Delegate=yes --uid="$(id -u)" --gid="$(id -g)" -- \
    env "PATH=$PATH" "$@"
}

# paid_phase NAME DEADLINE FN ARGS...: FN ARGS in a cgroup of its own, killed whole at DEADLINE (in SECONDS), and
# whatever it left behind killed when it returns.
# DEADLINE is converted to the monotonic clock twice, and the earlier of the two is kept: from this call (what is left,
# DEADLINE - SECONDS), which a wall-clock step between the deadline's computation and this call shifts, and from the
# pair read when this file was sourced, which only a step before the computation shifts. A step moves one of them later
# only by moving the other earlier, unless the clock steps forward before the computation and back after it.
# FN's stdout and stderr go to files, replayed to the caller's after the cgroup is empty, so nothing it started can hold
# the caller's command substitution open.
# Returns FN's status; 124, saying so on stdout, when the deadline ended it or had passed before it; and 125 when it
# could not be started in its cgroup.
# FN runs in a subshell: what it sets is lost, so a phase reports through its output and its files only.
paid_phase() {
  local name="$1" dl="$2" parent cg out err pid rc killed="" mdl t0dl
  shift 2
  phase_now
  mdl=$((PHASE_NOW + dl - SECONDS))
  t0dl=$((PHASE_T0_MONO + dl - PHASE_T0_SEC))
  ((t0dl >= mdl)) || mdl="$t0dl"
  if ((PHASE_NOW >= mdl)); then
    echo "$name: its deadline had passed, so it was not started"
    return 124
  fi
  parent="$(phase_cgroup)" || {
    echo "$name: $parent"
    return 125
  }
  cg="$parent/phase-$PHASE_SESSION-$name-$BASHPID-$RANDOM"
  rc="$(mkdir "$cg" 2>&1)" || {
    echo "$name: could not make its cgroup: ${rc:0:200}"
    return 125
  }
  out="$(mktemp)" && err="$(mktemp)" || {
    rmdir "$cg"
    echo "$name: could not make its output files"
    return 125
  }
  (
    echo "$BASHPID" >"$cg/cgroup.procs" || {
      echo "$name: it could not enter its cgroup $cg" >&2
      exit 125
    }
    "$@"
  ) </dev/null >"$out" 2>"$err" &
  pid=$!
  local n=0
  while phase_alive "$pid"; do
    phase_now
    if ((PHASE_NOW >= mdl)); then
      echo 1 >"$cg/cgroup.kill"
      # The subshell too, by its pid: one not yet in its cgroup is not reached by cgroup.kill, and would enter the
      # emptied cgroup and run FN unwatched (bare review of f29d698d). What it started before this lands is in the
      # cgroup, which phase_empty kills again below.
      if phase_alive "$pid"; then kill -KILL "$pid"; fi
      killed=1
      break
    fi
    sleep "${PHASE_POLL_FIRST[n]:-$PHASE_POLL}"
    n=$((n + 1))
  done
  # Read so that errexit, which the launcher sets, cannot end the caller on the phase's own failure.
  wait "$pid" && rc=0 || rc=$?
  phase_empty "$cg" >>"$err" || :
  cat "$out"
  cat "$err" >&2
  rm -f "$out" "$err"
  if [[ -n "$killed" ]]; then
    echo "$name: it passed its deadline and was killed with everything it started"
    return 124
  fi
  return "$rc"
}

# phase_kill_all: every phase of this session this process's cgroup still holds, killed and removed, for an exit that
# left one running.
phase_kill_all() {
  local parent cg
  parent="$(phase_cgroup)" || return 0
  for cg in "$parent"/phase-"$PHASE_SESSION"-*/; do
    [[ -d "$cg" ]] || continue
    phase_empty "${cg%/}"
  done
}
