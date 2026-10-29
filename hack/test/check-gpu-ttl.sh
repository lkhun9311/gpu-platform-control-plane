#!/usr/bin/env bash
#
# Checks hack/lib/gpu-ttl.sh's deadline reads by calling them with aws replaced by a shell function, without
# credentials or money.
#
#   bash hack/test/check-gpu-ttl.sh
#
# Each case says what each Scheduler call answers and asserts both what the library concluded and what it asked:
# a failed read must refuse or report "cannot tell", never stand in for "no deadline" or a later one (codex audit,
# 2026-10-28).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck source=hack/lib/gpu-ttl.sh
source hack/lib/gpu-ttl.sh
export TTL_ROLE_ARN=arn:aws:iam::000000000000:role/stub

# LIST, LIST_RC: list-schedules' output and status. GET_<name>, GET_RC_<name>: get-schedule's per schedule.
# DELETE_RC: delete-schedule's status. Every call is appended to $work/calls.
# A failing call prints its answer on stderr, as the CLI does, so a reader that drops stderr sees nothing.
answer() {
  if [ "$2" -eq 0 ]; then printf '%s' "$1"; else printf '%s\n' "$1" >&2; fi
  return "$2"
}
aws() {
  echo "$*" >>"$work/calls"
  case "$1 $2" in
    "scheduler list-schedules") answer "${LIST:-}" "${LIST_RC:-0}"; return ;;
    "scheduler get-schedule")
      local n="$4" v rc
      v="GET_${n//-/_}"
      rc="GET_RC_${n//-/_}"
      answer "${!v:-}" "${!rc:-0}"
      return
      ;;
    "scheduler delete-schedule") return "${DELETE_RC:-0}" ;;
    "scheduler create-schedule") return 0 ;;
  esac
  return 0
}

reset() {
  : >"$work/calls"
  unset LIST LIST_RC DELETE_RC TTL_REPLACE
  TTL_SCHEDULE_NAME=""
}
called() { grep -q -- "$1" "$work/calls"; }

# A failed listing is not an empty one. Mutation that turns it red: read the listing with 2>/dev/null and no status.
reset
LIST="AccessDeniedException: not authorized" LIST_RC=254
if ttl_arm c g 60 2>"$work/err"; then
  bad "a deadline was armed although the existing ones could not be listed"
elif called create-schedule; then
  bad "the refusal still created a schedule"
elif ! grep -q "AccessDeniedException" "$work/err"; then
  bad "the refusal does not say why: $(cat "$work/err")"
else
  ok "an unreadable listing refuses to arm, and says why"
fi

# A failed delete under TTL_REPLACE=1 leaves the earlier deadline to fire first. Mutation that turns it red: ignore
# the delete's status.
reset
LIST="gpu-ttl-c-g-20261028000000" DELETE_RC=254 TTL_REPLACE=1
export TTL_REPLACE
if ttl_arm c g 60 2>"$work/err"; then
  bad "a deadline was armed beside an earlier one that could not be deleted"
elif called create-schedule; then
  bad "the refusal still created a schedule"
else
  ok "a failed replace-delete refuses to arm"
fi

# The control: nothing listed, so the deadline is armed and read back.
reset
LIST="" GET_gpu_ttl_c_g_stub="at(2026-10-29T10:00:00)"
if ttl_arm c g 60 2>"$work/err" && called create-schedule && [ -n "$TTL_SCHEDULE_NAME" ]; then
  ok "with nothing listed, the deadline is armed"
else
  bad "the control did not arm: $(cat "$work/err")"
fi

# One schedule unreadable: the earliest is unknown, so nothing is printed. Mutation that turns it red: skip the
# unreadable schedule, which prints the later deadline.
reset
LIST="gpu-ttl-c-g-a gpu-ttl-c-g-b"
GET_gpu_ttl_c_g_a="ThrottlingException" GET_RC_gpu_ttl_c_g_a=254
GET_gpu_ttl_c_g_b="at($(date -u -d '+300 minutes' '+%Y-%m-%dT%H:%M:%S'))"
if out=$(ttl_remaining_minutes c g 2>"$work/err"); then
  bad "an unreadable schedule was skipped and $out minutes reported"
elif [ -n "$out" ]; then
  bad "a failure still printed '$out'"
else
  ok "an unreadable schedule makes the remaining time unknown"
fi

# One schedule not an at() time: also unknown.
reset
LIST="gpu-ttl-c-g-a gpu-ttl-c-g-b"
GET_gpu_ttl_c_g_a="rate(5 minutes)" GET_RC_gpu_ttl_c_g_a=0
if out=$(ttl_remaining_minutes c g 2>"$work/err"); then
  bad "a schedule that is not at() was skipped and $out minutes reported"
else
  ok "a schedule that is not an at() time makes the remaining time unknown"
fi

# The control: both readable, and the earlier one is reported.
reset
LIST="gpu-ttl-c-g-a gpu-ttl-c-g-b"
GET_gpu_ttl_c_g_a="at($(date -u -d '+61 minutes' '+%Y-%m-%dT%H:%M:%S'))" GET_RC_gpu_ttl_c_g_a=0
GET_gpu_ttl_c_g_b="at($(date -u -d '+300 minutes' '+%Y-%m-%dT%H:%M:%S'))"
if out=$(ttl_remaining_minutes c g 2>"$work/err") && [ "$out" -ge 59 ] && [ "$out" -le 61 ]; then
  ok "with both readable, the earlier deadline is reported ($out min)"
else
  bad "the control reported '${out:-}' instead of about 60: $(cat "$work/err")"
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all gpu-ttl checks passed"
