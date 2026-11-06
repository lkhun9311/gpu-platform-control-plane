#!/usr/bin/env bash
# Runs the end of the restart rank's rendered command as PID 1 in a container, as the paid session's Pods run it, with
# a stand-in trainer in python's place, and checks what the shell does with TERM and with the trainer's exit.
#
#   bash hack/test/check-rank-command-pid1.sh [IMAGE]
#
# Docker, not the stubs check-restart-session.sh uses: a shell that is not PID 1 dies on TERM by default, so only a
# PID-1 shell shows whether a TERM it was not given a handler for is dropped, forwarded, or ends it early.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# The reader image the runner already pins, a busybox: the command's end needs only a shell, /proc and sleep.
IMAGE="${1:-$(sed -n 's/^RESTART_READER_IMAGE=//p' hack/lib/restart-session.sh)}"
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 777 "$work"

body="$(bash -c '. hack/lib/train-session.sh; . hack/lib/gpu-ttl.sh; . hack/lib/gpu-fault.sh; . hack/lib/restart-session.sh
  RESTART_IMAGE=x RESTART_CLAIM=c RESTART_MOUNT=/state restart_render_job rst-rank-kill-1 train-a gpu-train-a rst-rank-kill-1-0a1b2c3d rank-kill-1' |
  python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["spec"]["command"][2])')"
tail_from="$(grep -n '^python /tmp/train.py &$' <<<"$body" | cut -d: -f1)"
[[ -n "$tail_from" ]] || { echo "FAIL: the rendered command has no 'python /tmp/train.py &' line"; exit 1; }
tail_cmd="$(tail -n +"$tail_from" <<<"$body")"

# run NAME TRAINER: the command's end, with TRAINER in python's place, as PID 1 in a container named NAME.
run() {
  local cmd="${tail_cmd/python \/tmp\/train.py &/$2 &}"
  docker run -d --name "$1" -v "$work:/out" "$IMAGE" sh -c "$cmd" >/dev/null
}
status() { docker inspect -f '{{.State.ExitCode}}' "$1"; }

# A trainer that cleans up for a second after TERM and exits 7 is let finish, and its 7 is the container's.
name="rankcmd-graceful-$$"
run "$name" "sh -c 'trap \"sleep 1; echo cleaned >/out/marker; exit 7\" TERM; while :; do sleep 0.2; done'"
sleep 2
docker stop --time 10 "$name" >/dev/null
if [[ "$(status "$name")" == 7 && -s "$work/marker" ]]; then
  ok "TERM reaches the trainer, the shell waits for it, and the trainer's 7 is the container's"
else
  bad "the graceful trainer: container exit $(status "$name"), marker '$(cat "$work/marker" 2>&1)'"
fi
docker rm -f "$name" >/dev/null

# A trainer that kills itself for a fault still fails the container with 137.
name="rankcmd-selfkill-$$"
run "$name" "sh -c 'sleep 1; kill -KILL \$\$'"
docker wait "$name" >/dev/null
if [[ "$(status "$name")" == 137 ]]; then ok "a trainer's self-SIGKILL is the container's 137"; else bad "the self-killed trainer: container exit $(status "$name")"; fi
docker rm -f "$name" >/dev/null

# A trainer that finishes is the container's 0.
name="rankcmd-done-$$"
run "$name" "sh -c 'sleep 1; exit 0'"
docker wait "$name" >/dev/null
if [[ "$(status "$name")" == 0 ]]; then ok "a trainer that finishes is the container's 0"; else bad "the finishing trainer: container exit $(status "$name")"; fi
docker rm -f "$name" >/dev/null

if ((fails == 0)); then echo "check-rank-command-pid1: all checks passed"; else echo "check-rank-command-pid1: $fails check(s) failed"; exit 1; fi
