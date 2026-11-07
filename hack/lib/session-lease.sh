# shellcheck shell=bash
# The session lease: the record the session reaper (infra/aws/bootstrap/reaper) acts on when the laptop that started a
# paid session cannot clean up after it (docs/superpowers/specs/2026-11-07-session-cloud-safety-design.md).
#
# One Parameter Store String per session, /gpu-platform/session-lease/<session>, holding JSON: the cluster, the session,
# the session deadline after which the reaper deletes the session's billing resources, and, once a GPU group is bought,
# the GPU deadline after which it holds the named groups at zero.
# The name is the session's, never the cluster's, and only one lease may exist at a time: every session builds into the
# one cluster/terraform.tfstate, so the lease is also the account's lock on it, held from before anything is created until
# the teardown is verified or the reaper has removed everything (round 4 of the adversarial review). A name per session
# means a delayed removal of an old lease can never remove a newer one, which Parameter Store, with no conditional
# delete, could not otherwise promise.
# Like hack/lib/gpu-ttl.sh it never calls `set` and installs no traps. Every function returns non-zero with a line on
# stderr when it cannot show that what it wrote is what AWS holds.

LEASE_PATH=/gpu-platform/session-lease/
REAPER_FUNCTION=gpu-platform-session-reaper
REAPER_HEARTBEAT=/gpu-platform/session-reaper/last-ok
# How recent the reaper's last clean pass must be: two of its five-minute runs and a margin.
REAPER_FRESH_SECONDS=${REAPER_FRESH_SECONDS:-900}
# How long to wait after renewing an expired GPU deadline before the group may be bought again: longer than one reaper
# run (timeout 120 s), so a run that read the expired copy has finished before anything is scaled up.
LEASE_RENEW_WAIT=${LEASE_RENEW_WAIT:-130}

lease_name() { printf '%s%s' "$LEASE_PATH" "$1"; }

# lease_key TEXT: a session's lease key, the characters a parameter name allows, and short enough to stay one.
lease_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-120; }

# lease_list REGION: the names of every lease, one per line; 2 when they cannot be listed.
lease_list() {
  local out
  out="$(aws ssm get-parameters-by-path --region "$1" --path "${LEASE_PATH%/}" --query 'Parameters[].Name' --output text 2>&1)" || {
    echo "lease: could not list the leases under $LEASE_PATH: $out" >&2
    return 2
  }
  tr -s ' \t' '\n' <<<"$out" | sed '/^$/d; /^None$/d'
}

# lease_iso EPOCH: the time as UTC ISO 8601 with its zone, the only form the reaper reads.
lease_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# lease_get KEY REGION: the lease's JSON on stdout; 1 when there is none, 2 when it cannot be read.
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

# lease_put KEY REGION JSON [overwrite]: write it, then read it back and compare.
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

# lease_arm KEY REGION DEADLINE_EPOCH CLUSTER: create this session's lease, refusing when any lease is already there.
#
# A lease already there, of any session, belongs to a session that is still running or to one the reaper is still
# clearing, and both share this session's terraform state; the new session stops instead. The reaper must exist and have
# completed a recent clean pass, because a lease nothing reads protects nothing.
lease_arm() {
  local key="$1" region="$2" deadline="$3" cluster="$4" out body rc=0 others
  out="$(aws lambda get-function --region "$region" --function-name "$REAPER_FUNCTION" --query Configuration.State --output text 2>&1)" || {
    echo "lease: the session reaper $REAPER_FUNCTION is not readable ($out); apply infra/aws/bootstrap first" >&2
    return 1
  }
  [[ "$out" == Active ]] || {
    echo "lease: the session reaper $REAPER_FUNCTION is $out, not Active" >&2
    return 1
  }
  # Active says the function exists, not that its role can read the leases; only a recent clean pass shows that.
  local beat at now
  beat="$(aws ssm get-parameter --region "$region" --name "$REAPER_HEARTBEAT" --query Parameter.Value --output text 2>&1)" || {
    echo "lease: the session reaper has recorded no clean pass ($beat); it has not run, or cannot read the leases" >&2
    return 1
  }
  at="$(date -u -d "$beat" +%s 2>&1)" || {
    echo "lease: the reaper's heartbeat '${beat:0:80}' is not a time" >&2
    return 1
  }
  now="$(date -u +%s)"
  if ((now - at > REAPER_FRESH_SECONDS)); then
    echo "lease: the session reaper's last clean pass was $(((now - at) / 60)) min ago ($beat), more than $((REAPER_FRESH_SECONDS / 60)); read its log before starting" >&2
    return 1
  fi
  others="$(lease_list "$region")" || return 1
  if [[ -n "$others" ]]; then
    echo "lease: a lease already exists ($(paste -sd' ' <<<"$others")), from a session still running or one the reaper is clearing; read it, confirm its resources are gone, delete it by hand, then start again" >&2
    return 1
  fi
  lease_get "$key" "$region" >/dev/null || rc=$?
  ((rc == 1)) || {
    ((rc == 0)) && echo "lease: $(lease_name "$key") already exists" >&2
    return 1
  }
  body="$(python3 -c 'import json,sys; print(json.dumps({"cluster": sys.argv[1], "session": sys.argv[2], "deadline": sys.argv[3]}, sort_keys=True))' \
    "$cluster" "$key" "$(lease_iso "$deadline")")"
  lease_put "$key" "$region" "$body"
}

# lease_update KEY REGION FIELD VALUE: set one string field.
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

# lease_set_gpu KEY REGION GPU_DEADLINE_EPOCH NODEGROUP: the GPU deadline, and the group added to those it covers.
#
# Set before the group is scaled up, and again at each later GPU phase: a deadline left from an earlier phase would have
# the reaper scale down a group the session just bought.
# When the deadline it replaces has already passed, a reaper run may be acting on that old copy at this moment; the
# reaper reads the lease again before each scale-down, and this waits out a run's timeout so none that read the old copy
# is still going when the group is bought.
lease_set_gpu() {
  local cluster="$1" region="$2" deadline="$3" group="$4" cur body old
  cur="$(lease_get "$cluster" "$region")" || {
    echo "lease: no lease to add the GPU deadline to for $cluster" >&2
    return 1
  }
  old="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("gpu_deadline", ""))' "$cur")" || return 1
  body="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
d["gpu_deadline"] = sys.argv[2]
groups = d.get("gpu_nodegroups", [])
if sys.argv[3] not in groups:
    groups.append(sys.argv[3])
d["gpu_nodegroups"] = groups
print(json.dumps(d, sort_keys=True))' "$cur" "$(lease_iso "$deadline")" "$group")" || return 1
  lease_put "$cluster" "$region" "$body" overwrite || return 1
  if [[ -n "$old" ]] && (($(date -u -d "$old" +%s) <= $(date -u +%s))); then
    echo "lease: the GPU deadline renewed had passed ($old); waiting ${LEASE_RENEW_WAIT}s for any reaper run on it to end" >&2
    sleep "$LEASE_RENEW_WAIT"
  fi
}

# lease_disarm KEY REGION: remove the lease, and show it is gone. Called only after a verified teardown.
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
