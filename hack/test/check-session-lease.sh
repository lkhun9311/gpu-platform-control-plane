#!/usr/bin/env bash
#
# Checks hack/lib/session-lease.sh with aws replaced by a shell function holding Parameter Store in a directory, without
# credentials or money.
#
#   bash hack/test/check-session-lease.sh
#
# A lease the reaper reads is what decides whether a cluster is deleted, so each case asserts both what the library
# concluded and what it left in the store.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck source=hack/lib/session-lease.sh
source hack/lib/session-lease.sh
LEASE_RENEW_WAIT=0

# The store: one file per parameter under $work/ssm. REAPER_STATE: what get-function answers (Active, or "missing").
# PUT_CORRUPT=1 makes put-parameter store something other than what it was given.
REAPER_STATE=Active
PUT_CORRUPT=0
GET_FAIL=0
DELETE_NOOP=0
HEARTBEAT=""
aws() {
  echo "$*" >>"$work/calls"
  local name="" value="" over=0 a
  local args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      --name) name="${args[$((i + 1))]}" ;;
      --value) value="${args[$((i + 1))]}" ;;
      --overwrite) over=1 ;;
    esac
  done
  local f="$work/ssm/${name//\//_}"
  case "$1 $2" in
    "lambda get-function")
      if [[ "$REAPER_STATE" == missing ]]; then echo "ResourceNotFoundException: Function not found" >&2; return 254; fi
      echo "$REAPER_STATE"
      ;;
    "ssm get-parameter")
      if [[ "$name" == "$REAPER_HEARTBEAT" ]]; then
        if [[ -n "$HEARTBEAT" ]]; then echo "$HEARTBEAT"; return 0; fi
        echo "An error occurred (ParameterNotFound)" >&2; return 254
      fi
      if ((GET_FAIL)); then echo "An error occurred (AccessDeniedException)" >&2; return 254; fi
      if [[ -f "$f" ]]; then cat "$f"; else echo "An error occurred (ParameterNotFound)" >&2; return 254; fi
      ;;
    "ssm put-parameter")
      if [[ -f "$f" && $over -eq 0 ]]; then echo "An error occurred (ParameterAlreadyExists)" >&2; return 254; fi
      mkdir -p "$work/ssm"
      if ((PUT_CORRUPT)); then printf '{"cluster": "x"}' >"$f"; else printf '%s' "$value" >"$f"; fi
      echo '{"Version": 1}'
      ;;
    "ssm delete-parameter")
      if ((DELETE_NOOP)); then echo '{}'; return 0; fi
      if [[ -f "$f" ]]; then rm -f "$f"; else echo "An error occurred (ParameterNotFound)" >&2; return 254; fi
      ;;
    *) echo "unexpected aws $*" >&2; return 99 ;;
  esac
}

reset() {
  rm -rf "$work/ssm" "$work/calls"
  REAPER_STATE=Active PUT_CORRUPT=0 GET_FAIL=0 DELETE_NOOP=0
  HEARTBEAT="$(date -u -d '-2 min' +%Y-%m-%dT%H:%M:%SZ)"
}
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$1" "$2"; }

# Mutation that turns it red: drop the reaper check.
reset
REAPER_STATE=missing
if lease_arm c1 ap-northeast-2 1800000000 s1 2>"$work/err"; then bad "armed with no reaper"; elif [[ -e "$work/ssm" ]]; then bad "refused, yet wrote a lease"; else ok "no reaper, no lease"; fi
reset
REAPER_STATE=Pending
if lease_arm c1 ap-northeast-2 1800000000 s1 2>"$work/err"; then bad "armed with a reaper that is not Active"; else ok "a reaper that is not Active is refused"; fi

# An Active function that has never completed a clean pass, or not recently, is not trusted.
# Mutation that turns it red: drop the heartbeat read, or its freshness bound.
reset
HEARTBEAT=""
if lease_arm c1 ap-northeast-2 1800000000 s1 2>"$work/err"; then bad "armed with no reaper heartbeat"; elif [[ -e "$work/ssm" ]]; then bad "refused, yet wrote a lease"; else ok "no clean reaper pass, no lease"; fi
reset
HEARTBEAT="$(date -u -d '-40 min' +%Y-%m-%dT%H:%M:%SZ)"
if lease_arm c1 ap-northeast-2 1800000000 s1 2>"$work/err"; then bad "armed with a 40-minute-old heartbeat"; else ok "a stale reaper heartbeat refuses the arm: $(cut -c1-90 "$work/err")"; fi

# A renewal of a GPU deadline that has passed waits out a reaper run; one that has not passed does not.
# Mutation that turns it red: never wait, or always wait.
reset
lease_arm c1 ap-northeast-2 1800000000 s1 2>/dev/null
lease_set_gpu c1 ap-northeast-2 "$(($(date +%s) + 600))" gpu 2>"$work/err"
grep -q waiting "$work/err" && bad "waited when the deadline replaced had not passed" || ok "a live GPU deadline is replaced without waiting"
lease_set_gpu c1 ap-northeast-2 "$(($(date +%s) - 5))" gpu 2>/dev/null
lease_set_gpu c1 ap-northeast-2 "$(($(date +%s) + 600))" gpu 2>"$work/err"
grep -q "waiting 0s" "$work/err" && ok "renewing a passed GPU deadline waits out a reaper run" || bad "renewing a passed deadline did not wait: $(cat "$work/err")"

# Mutation that turns it red: overwrite an existing lease.
reset
lease_arm c1 ap-northeast-2 1800000000 s1 2>"$work/err" || bad "the first arm failed: $(cat "$work/err")"
first="$(lease_get c1 ap-northeast-2)"
[[ "$(field "$first" deadline)" == 2027-01-15T08:00:00Z && "$(field "$first" cluster)" == c1 ]] &&
  ok "the lease holds the cluster and the deadline in UTC with its zone" || bad "the lease reads $first"
if lease_arm c1 ap-northeast-2 1900000000 s2 2>"$work/err"; then bad "a second session armed over a live lease"; else
  [[ "$(lease_get c1 ap-northeast-2)" == "$first" ]] && ok "a lease already there is refused and left as it was" || bad "a refused arm changed the lease"
  # Refused for this reason, before any write: put-parameter would refuse too, and that second refusal is not the check.
  grep -q 'already exists' "$work/err" && [[ "$(grep -c 'put-parameter' "$work/calls")" == 1 ]] &&
    ok "the refusal names the existing lease and writes nothing" || bad "the refusal said: $(cat "$work/err"); puts: $(grep -c put-parameter "$work/calls")"
fi

# A read that fails is not "no lease".
# Mutation that turns it red: read any get-parameter failure as not found.
reset
GET_FAIL=1
if lease_arm c1 ap-northeast-2 1800000000 s1 2>"$work/err"; then bad "armed though the lease could not be read"; elif grep -q put-parameter "$work/calls"; then
  bad "an unreadable store was read as no lease and a lease was written"
else ok "an unreadable lease store refuses the arm before writing"; fi

# Mutation that turns it red: skip the read-back comparison.
reset
PUT_CORRUPT=1
if lease_arm c1 ap-northeast-2 1800000000 s1 2>"$work/err"; then bad "armed though the stored lease differs from the written one"; else ok "a lease that reads back differently is a failure"; fi

# The GPU deadline is replaced at each phase and the groups accumulate.
# Mutation that turns it red: keep the first GPU deadline, or replace the group list.
reset
lease_arm c1 ap-northeast-2 1800000000 s1 2>/dev/null
lease_set_gpu c1 ap-northeast-2 1790000000 gpu 2>"$work/err" || bad "set_gpu failed: $(cat "$work/err")"
lease_set_gpu c1 ap-northeast-2 1795000000 gpu-single 2>"$work/err" || bad "set_gpu failed: $(cat "$work/err")"
lease_set_gpu c1 ap-northeast-2 1796000000 gpu 2>"$work/err" || bad "set_gpu failed: $(cat "$work/err")"
cur="$(lease_get c1 ap-northeast-2)"
if [[ "$(field "$cur" gpu_deadline)" == "$(lease_iso 1796000000)" && "$(field "$cur" gpu_nodegroups)" == "['gpu', 'gpu-single']" && "$(field "$cur" deadline)" == 2027-01-15T08:00:00Z ]]; then
  ok "the latest GPU deadline stands, the groups accumulate once each, the session deadline is untouched"
else
  bad "after three GPU phases the lease reads $cur"
fi
lease_update c1 ap-northeast-2 vpc_id vpc-0abc 2>/dev/null
[[ "$(field "$(lease_get c1 ap-northeast-2)" vpc_id)" == vpc-0abc ]] && ok "a recorded VPC is kept" || bad "the VPC was not recorded"

# Mutation that turns it red: report success without reading the lease back as gone.
reset
lease_arm c1 ap-northeast-2 1800000000 s1 2>/dev/null
if lease_disarm c1 ap-northeast-2 2>"$work/err" && ! lease_get c1 ap-northeast-2 >/dev/null 2>&1; then ok "disarm removes the lease"; else bad "disarm: $(cat "$work/err")"; fi
if lease_disarm c1 ap-northeast-2 2>"$work/err"; then ok "disarming a lease already gone is not a failure"; else bad "disarming nothing failed: $(cat "$work/err")"; fi
# A delete that answers success and leaves the lease is not a disarm.
reset
lease_arm c1 ap-northeast-2 1800000000 s1 2>/dev/null
DELETE_NOOP=1
if lease_disarm c1 ap-northeast-2 2>"$work/err"; then bad "disarm reported success while the lease is still there"; else ok "a lease still readable after its delete fails the disarm"; fi

# The runner arms the lease before its first apply and removes it only beside the verified disarm.
# Mutation that turns it red: move lease_arm after the cluster apply, or lease_disarm outside the verified branch.
arm_line=$(grep -n '^lease_arm "\$CLUSTER"' hack/eks-gitops-session.sh | cut -d: -f1)
apply_line=$(grep -n 'terraform -chdir="\$CLUSTER_DIR" apply' hack/eks-gitops-session.sh | head -1 | cut -d: -f1)
if [[ -n "$arm_line" && -n "$apply_line" ]] && ((arm_line < apply_line)); then ok "the lease is armed (line $arm_line) before the first cluster apply (line $apply_line)"; else
  bad "lease_arm at '${arm_line}', first cluster apply at '${apply_line}'"
fi
# Before the watchdog, so a refused lease leaves no watchdog armed; and after the checks that refuse an existing cluster.
# Mutation that turns it red: arm the lease after the watchdog, or before the existing-cluster refusal.
kill_line=$(grep -n 'killswitch_program "\$KILL_PIDFILE"' hack/eks-gitops-session.sh | head -1 | cut -d: -f1)
exists_line=$(grep -n 'already exists (\$existing)' hack/eks-gitops-session.sh | head -1 | cut -d: -f1)
if [[ -n "$kill_line" && -n "$exists_line" ]] && ((exists_line < arm_line && arm_line < kill_line)); then
  ok "the existing-cluster refusal (line $exists_line), then the lease (line $arm_line), then the watchdog (line $kill_line)"
else
  bad "existing-cluster refusal at '${exists_line}', lease at '${arm_line}', watchdog at '${kill_line}'"
fi
disarm_block="$(awk '/^if \[\[ -z "\$\{unasked\/\/ \/\}" && -z "\$\{billing_left\/\/ \/\}" \]\]; then$/{n++} n==2{print} /^fi$/{if(n==2) exit}' hack/eks-gitops-session.sh)"
if grep -q 'lease_disarm "\$CLUSTER"' <<<"$disarm_block" && [[ "$(grep -c 'lease_disarm "\$CLUSTER"' hack/eks-gitops-session.sh)" == 1 ]]; then
  ok "the lease is removed only inside the verified-teardown branch"
else
  bad "lease_disarm is not only in the verified-teardown branch"
fi
n_gpu=$(grep -c 'lease_set_gpu "\$CLUSTER"' hack/eks-gitops-session.sh)
n_ttl=$(grep -c 'if ! ttl_arm "\$CLUSTER"' hack/eks-gitops-session.sh)
((n_gpu == n_ttl && n_ttl > 0)) && ok "every GPU deadline ($n_ttl) is copied into the lease" || bad "$n_ttl GPU deadlines, $n_gpu lease copies"

if ((fails)); then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
