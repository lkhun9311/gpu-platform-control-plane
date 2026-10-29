#!/usr/bin/env bash
#
# Checks hack/eks-gitops-session.sh's sweep of the network interfaces the VPC CNI leaves detached, and the destroy
# block that calls it, with aws, terraform and the session's logging replaced by shell functions.
#
#   bash hack/test/check-cni-eni-sweep.sh
#
# Both are extracted from the session script at run time rather than copied, so this checks the code that ships.
# Four-GPU run 3's destroy failed on one such interface (2026-10-29); the sweep must delete only detached aws-K8S
# interfaces in the one project VPC, and the destroy must be retried once, and only after the sweep deleted one.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
SRC=hack/eks-gitops-session.sh

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sweep_src=$(sed -n '/^sweep_leaked_cni_enis() {/,/^}/p' "$SRC")
block_src=$(sed -n '/^if ! destroy_cluster; then/,/^}/p' "$SRC")
[ -n "$sweep_src" ] || { echo "FAIL: sweep_leaked_cni_enis() not found in $SRC"; exit 1; }
[ -n "$block_src" ] || { echo "FAIL: the destroy block that calls it was not found in $SRC"; exit 1; }
REGION=ap-northeast-2

# VPCS, VPCS_RC, ENIS, ENIS_RC, DELETE_RC answer the three calls; every call is appended to $work/calls.
answer() {
  if [ "$2" -eq 0 ]; then printf '%s' "$1"; else printf '%s\n' "$1" >&2; fi
  return "$2"
}
aws() {
  echo "$*" >>"$work/calls"
  case "$2" in
    describe-vpcs) answer "${VPCS-vpc-1}" "${VPCS_RC:-0}" ;;
    describe-network-interfaces) answer "${ENIS-}" "${ENIS_RC:-0}" ;;
    delete-network-interface) answer "denied" "${DELETE_RC:-0}" ;;
  esac
}
log() { echo "$*" >>"$work/log"; }
eval "$sweep_src"

reset() {
  : >"$work/calls"
  : >"$work/log"
  unset VPCS VPCS_RC ENIS ENIS_RC DELETE_RC
}
deleted() { grep -c "delete-network-interface" "$work/calls"; }

# A detached CNI interface is deleted, and only through a listing narrowed to it.
reset
ENIS="eni-1"
if sweep_leaked_cni_enis && [ "$(deleted)" = 1 ] && grep -q -- "--network-interface-id eni-1" "$work/calls"; then
  ok "a detached aws-K8S interface in the project VPC is deleted"
else
  bad "the leaked interface was not deleted: $(cat "$work/calls")"
fi
for want in "Name=vpc-id,Values=vpc-1" "Name=status,Values=available" "Name=description,Values=aws-K8S-\*"; do
  grep -q -- "describe-network-interfaces.*$want" "$work/calls" || bad "the interface listing is not narrowed by $want"
done

reset
ENIS=""
if sweep_leaked_cni_enis || [ "$(deleted)" != 0 ]; then bad "with nothing detached, the sweep reported a change"; else ok "nothing detached: no retry is asked for"; fi

reset
VPCS="AccessDenied" VPCS_RC=254
if sweep_leaked_cni_enis || [ "$(deleted)" != 0 ]; then bad "an unreadable VPC listing still swept"; else ok "an unreadable VPC listing deletes nothing"; fi

reset
VPCS="vpc-1	vpc-2" ENIS="eni-1"
if sweep_leaked_cni_enis || [ "$(deleted)" != 0 ]; then bad "two project VPCs and the sweep still deleted"; else ok "two project VPCs: nothing is deleted"; fi

reset
ENIS="AccessDenied" ENIS_RC=254
if sweep_leaked_cni_enis || [ "$(deleted)" != 0 ]; then bad "an unreadable interface listing still swept"; else ok "an unreadable interface listing deletes nothing"; fi

reset
ENIS="eni-1" DELETE_RC=254
if sweep_leaked_cni_enis; then bad "a refused delete reported success"; elif grep -q "denied" "$work/log"; then ok "a refused delete fails the sweep and says why"; else bad "the refused delete was not logged"; fi

# The destroy block: DESTROYS lists each destroy_cluster call's status in order; SWEEP_RC is the sweep's.
run_block() {
  (
    n=0
    destroy_cluster() {
      n=$((n + 1))
      echo destroy >>"$work/calls"
      return "$(echo "$DESTROYS" | cut -d' ' -f"$n")"
    }
    sweep_leaked_cni_enis() { echo sweep >>"$work/calls"; return "$SWEEP_RC"; }
    bad() { echo "$*" >>"$work/log"; }
    kill() { return 0; }
    KILL_PID=1 KILL_LOG=/dev/null
    eval "$block_src"
    exit 0
  )
}
count() { grep -c "^$1$" "$work/calls"; }
block_case() {
  local want_rc="$1" want_destroys="$2" want_sweeps="$3" what="$4"
  reset
  run_block
  local rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$(count destroy)" = "$want_destroys" ] && [ "$(count sweep)" = "$want_sweeps" ]; then
    ok "$what"
  else
    bad "$what: exit $rc, $(count destroy) destroy(s), $(count sweep) sweep(s)"
  fi
}
DESTROYS="0" SWEEP_RC=0 block_case 0 1 0 "a destroy that succeeds is not swept or retried"
DESTROYS="1 0" SWEEP_RC=0 block_case 0 2 1 "a failed destroy is swept and retried, and the retry's success ends it"
DESTROYS="1 0" SWEEP_RC=1 block_case 1 1 1 "a sweep that deleted nothing is not followed by a retry, and the session fails"
DESTROYS="1 1" SWEEP_RC=0 block_case 1 2 1 "a retry that fails again fails the session"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all CNI interface sweep checks passed"
