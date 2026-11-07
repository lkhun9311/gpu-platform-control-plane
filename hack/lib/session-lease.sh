# shellcheck shell=bash
# The session lease: the record the session reaper (infra/aws/bootstrap/reaper) acts on when the laptop that started a
# paid session cannot clean up after it (docs/superpowers/specs/2026-11-07-session-cloud-safety-design.md).
#
# One Parameter Store String per cluster, /gpu-platform/session-lease/<cluster>, holding JSON: the cluster, the session,
# the session deadline after which the reaper deletes the session's billing resources, and, once a GPU group is bought,
# the GPU deadline after which it holds the named groups at zero.
# Like hack/lib/gpu-ttl.sh it never calls `set` and installs no traps. Every function returns non-zero with a line on
# stderr when it cannot show that what it wrote is what AWS holds.

LEASE_PATH=/gpu-platform/session-lease/
REAPER_FUNCTION=gpu-platform-session-reaper

lease_name() { printf '%s%s' "$LEASE_PATH" "$1"; }

# lease_iso EPOCH: the time as UTC ISO 8601 with its zone, the only form the reaper reads.
lease_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# lease_get CLUSTER REGION: the lease's JSON on stdout; 1 when there is none, 2 when it cannot be read.
lease_get() {
  local out rc=0
  out="$(aws ssm get-parameter --region "$2" --name "$(lease_name "$1")" --query Parameter.Value --output text 2>&1)" || rc=$?
  if ((rc == 0)); then
    printf '%s' "$out"
    return 0
  fi
  if grep -q ParameterNotFound <<<"$out"; then
    return 1
  fi
  echo "lease: could not read $(lease_name "$1"): $out" >&2
  return 2
}

# lease_put CLUSTER REGION JSON [overwrite]: write it, then read it back and compare.
lease_put() {
  local cluster="$1" region="$2" body="$3" over="${4:-}" out got
  local args=(--region "$region" --name "$(lease_name "$cluster")" --type String --value "$body")
  [[ -n "$over" ]] && args+=(--overwrite)
  out="$(aws ssm put-parameter "${args[@]}" 2>&1)" || {
    echo "lease: could not write $(lease_name "$cluster"): $out" >&2
    return 1
  }
  got="$(lease_get "$cluster" "$region")" || {
    echo "lease: wrote $(lease_name "$cluster") and could not read it back" >&2
    return 1
  }
  if ! python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]) == json.loads(sys.argv[2]) else 1)' "$body" "$got"; then
    echo "lease: $(lease_name "$cluster") reads back as ${got:0:300}, not what was written" >&2
    return 1
  fi
}

# lease_arm CLUSTER REGION DEADLINE_EPOCH SESSION: create the lease, refusing when one is already there.
#
# A lease already there belongs to a session that is still running, or to one the reaper is still clearing; writing over
# it would move that session's deadline, so the new session stops instead. The reaper must exist, because a lease
# nothing reads protects nothing.
lease_arm() {
  local cluster="$1" region="$2" deadline="$3" session="$4" out body rc=0
  out="$(aws lambda get-function --region "$region" --function-name "$REAPER_FUNCTION" --query Configuration.State --output text 2>&1)" || {
    echo "lease: the session reaper $REAPER_FUNCTION is not readable ($out); apply infra/aws/bootstrap first" >&2
    return 1
  }
  [[ "$out" == Active ]] || {
    echo "lease: the session reaper $REAPER_FUNCTION is $out, not Active" >&2
    return 1
  }
  lease_get "$cluster" "$region" >/dev/null || rc=$?
  case "$rc" in
    0)
      echo "lease: $(lease_name "$cluster") already exists, from a session still running or one the reaper is clearing; read it, confirm its resources are gone, delete it by hand, then start again" >&2
      return 1
      ;;
    1) ;;
    *) return 1 ;;
  esac
  body="$(python3 -c 'import json,sys; print(json.dumps({"cluster": sys.argv[1], "session": sys.argv[2], "deadline": sys.argv[3]}, sort_keys=True))' \
    "$cluster" "$session" "$(lease_iso "$deadline")")"
  lease_put "$cluster" "$region" "$body"
}

# lease_update CLUSTER REGION KEY VALUE: set one string field.
lease_update() {
  local cluster="$1" region="$2" key="$3" value="$4" cur body
  cur="$(lease_get "$cluster" "$region")" || {
    echo "lease: no lease to update for $cluster" >&2
    return 1
  }
  body="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d[sys.argv[2]]=sys.argv[3]; print(json.dumps(d, sort_keys=True))' \
    "$cur" "$key" "$value")" || return 1
  lease_put "$cluster" "$region" "$body" overwrite
}

# lease_set_gpu CLUSTER REGION GPU_DEADLINE_EPOCH NODEGROUP: the GPU deadline, and the group added to those it covers.
#
# Set before the group is scaled up, and again at each later GPU phase: a deadline left from an earlier phase would have
# the reaper scale down a group the session just bought.
lease_set_gpu() {
  local cluster="$1" region="$2" deadline="$3" group="$4" cur body
  cur="$(lease_get "$cluster" "$region")" || {
    echo "lease: no lease to add the GPU deadline to for $cluster" >&2
    return 1
  }
  body="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
d["gpu_deadline"] = sys.argv[2]
groups = d.get("gpu_nodegroups", [])
if sys.argv[3] not in groups:
    groups.append(sys.argv[3])
d["gpu_nodegroups"] = groups
print(json.dumps(d, sort_keys=True))' "$cur" "$(lease_iso "$deadline")" "$group")" || return 1
  lease_put "$cluster" "$region" "$body" overwrite
}

# lease_disarm CLUSTER REGION: remove the lease, and show it is gone. Called only after a verified teardown.
lease_disarm() {
  local cluster="$1" region="$2" out rc=0
  out="$(aws ssm delete-parameter --region "$region" --name "$(lease_name "$cluster")" 2>&1)" || rc=$?
  if ((rc != 0)) && ! grep -q ParameterNotFound <<<"$out"; then
    echo "lease: could not delete $(lease_name "$cluster"): $out" >&2
    return 1
  fi
  rc=0
  lease_get "$cluster" "$region" >/dev/null || rc=$?
  if ((rc != 1)); then
    echo "lease: $(lease_name "$cluster") is still readable after its deletion" >&2
    return 1
  fi
}
