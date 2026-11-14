#!/usr/bin/env bash
#
# Checks the tenant boundary's committed artefacts without a cluster:
#   - the rendered bundles under config/tenants/ are what hack/tenant/render.sh renders today;
#   - the archived kind run scores PASS with hack/tenant-boundary/check.py;
#   - every check in that scorer fails when its own record is turned into the opposite outcome, once each, so no
#     check is decided by something other than its record.
#
#   bash hack/test/check-tenant-boundary.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

RUN=hack/tenant-boundary/2026-11-07-run1
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for t in train-a serve-a; do
  if hack/tenant/render.sh "$t" "$t" --stdout >"$work/$t.yaml" 2>"$work/$t.err" && cmp -s "$work/$t.yaml" "config/tenants/$t/bundle.yaml"; then
    ok "config/tenants/$t/bundle.yaml is the current render of the template"
  else
    bad "config/tenants/$t/bundle.yaml differs from hack/tenant/render.sh $t $t: $(cat "$work/$t.err")"
  fi
done
hack/tenant/render.sh 'Not_A_Label' x >"$work/refuse.out" 2>&1 && bad "the renderer accepted a tenant name that is not a DNS-1123 label" ||
  ok "the renderer refuses a tenant name that is not a DNS-1123 label"

# YAML reads an unquoted null, true or 0123 as something other than a string, and all three are DNS-1123 labels the
# renderer must accept (codex, review of the branch).
if hack/tenant/render.sh null 0123 --stdout | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
names = [d["metadata"]["name"] for d in docs if d["kind"] == "Namespace"] + [d["metadata"].get("namespace") for d in docs if d["kind"] != "Namespace"]
tenant = docs[0]["metadata"]["labels"]["platform.lkhun9311.github.io/tenant"]
sys.exit(0 if names and all(n == "0123" for n in names) and tenant == "null" else 1)'; then
  ok "names YAML would read as null or a number render as strings"
else
  bad "a tenant named null or a namespace named 0123 rendered as something other than a string"
fi

# Orphaned children outlive their parent's count, so each kind the controllers create must be counted itself.
for key in pods count/services count/deployments.apps count/replicasets.apps count/jobs.batch count/workloads.kueue.x-k8s.io limits.ephemeral-storage; do
  if grep -Fq "    $key: " config/tenant/bundle.yaml.tmpl; then ok "the baseline quota sets $key"; else bad "the baseline quota does not set $key"; fi
done

score() { python3 hack/tenant-boundary/check.py "$1" >"$1/score.out" 2>&1; }

if [ ! -s "$RUN/results.jsonl" ] || [ ! -s "$RUN/run.json" ]; then
  bad "$RUN holds no archived run"
  echo "check-tenant-boundary: $fails failure(s)"
  exit 1
fi
cp -r "$RUN" "$work/base"
if score "$work/base" && grep -qx 'tenant boundary: PASS' "$work/base/score.out"; then
  ok "the archived run scores PASS"
else
  bad "the archived run does not score PASS: $(tail -5 "$work/base/score.out")"
fi
if cmp -s "$work/base/verdict.json" "$RUN/verdict.json"; then ok "the archived verdict.json is what the scorer writes today"; else
  bad "the archived verdict.json differs from a fresh score of the same run"
fi

# mutate <name> <python expression over r, the record> <check id that must fail> [<id of the record to edit>]
mutate() {
  local name=$1 expr=$2 must=$3 target=${4:-$3}
  local d="$work/m-$name"
  cp -r "$RUN" "$d"
  rm -f "$d/verdict.json"
  python3 - "$d/results.jsonl" "$target" "$expr" <<'EOF' || { bad "$name: could not apply the mutation"; return; }
import json, sys
path, target, expr = sys.argv[1:]
rows = [json.loads(l) for l in open(path)]
hits = [r for r in rows if r["id"] == target]
assert len(hits) == 1, f"{target}: {len(hits)} records"
exec(expr, {"r": hits[0]})
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
EOF
  if score "$d"; then
    bad "$name: the run still scored PASS"
  elif grep -q "^FAIL $must: " "$d/score.out"; then
    ok "$name: $must fails"
  else
    bad "$name: the run failed, but not at $must: $(grep '^FAIL' "$d/score.out" | head -3)"
  fi
}

ALLOWED='r["exit"]=1; r["stderr"]="Error from server (Forbidden): denied"'
SUCCEEDED='r["exit"]=0; r["stderr"]=""'
python3 - >"$work/ids" <<'EOF'
import importlib.util
spec = importlib.util.spec_from_file_location("check", "hack/tenant-boundary/check.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for cid, (kind, arg, _) in m.CHECKS.items():
    print(cid, kind, arg or "-")
EOF
[ "$(wc -l <"$work/ids")" -ge 20 ] && ok "the scorer registers $(wc -l <"$work/ids") checks" || bad "the scorer registers only $(wc -l <"$work/ids") checks"
while read -r cid kind _; do
  case $kind in
    allowed) mutate "$cid-refused" "$ALLOWED" "$cid" ;;
    rbac-forbidden | policy-denied | pod-security) mutate "$cid-admitted" "$SUCCEEDED" "$cid" ;;
    blocked) mutate "$cid-reached" 'r["exit"]=0; r["stderr"]=""; r["stdout"]="engine\n"' "$cid" ;;
    reached) mutate "$cid-wrong-pod" 'r["stdout"]="someone-else\n"' "$cid" ;;
    resolved) mutate "$cid-unresolved" 'r["stdout"]="Server: 10.96.0.10\n"' "$cid" ;;
    *) bad "no mutation for the kind $kind of $cid" ;;
  esac
done <"$work/ids"

# A refusal in the wrong words, and a connection that failed for another reason, are not the boundary working.
mutate rbac-wrong-words 'r["stderr"]="error: resource mapping not found for kind LocalQueue"' create-localqueue
mutate policy-wrong-words 'r["stderr"]="Error from server (Forbidden): User \"user-train-a\" cannot patch resource"' tenant-fences
mutate psa-wrong-words 'r["stderr"]="Error from server (Forbidden): pods \"priv\" is forbidden: exceeded quota"' privileged-pod
mutate blocked-refused 'r["stderr"]="wget: can not connect to remote host: Connection refused"' tenant-to-other-engine
# A blocked connection means nothing if the client never worked.
mutate control-client 'r["exit"]=1; r["stderr"]="wget: download timed out"' tenant-to-other-engine rank-to-rank
mutate control-target 'r["exit"]=1; r["stderr"]="wget: download timed out"' trainer-to-own-engine gateway-to-own-engine

# The run's own record.
d="$work/absent"; cp -r "$RUN" "$d"; grep -v '"id": "dns"' "$RUN/results.jsonl" >"$d/results.jsonl"
score "$d"; grep -q '^FAIL dns: absent' "$d/score.out" && ok "a check the run did not record fails as absent" || bad "an absent check did not fail as absent"
d="$work/dirty"; cp -r "$RUN" "$d"
python3 -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r["dirty_paths"]=3; json.dump(r,open(p,"w"))' "$d/run.json"
score "$d"; grep -q '^FAIL the run was made with 3 uncommitted' "$d/score.out" && ok "a run of an uncommitted tree fails" || bad "a dirty run did not fail"
d="$work/twice"; cp -r "$RUN" "$d"; grep '"id": "dns"' "$RUN/results.jsonl" >>"$d/results.jsonl"
score "$d"; grep -q 'dns recorded twice' "$d/score.out" && ok "a check recorded twice fails" || bad "a duplicate record did not fail"

echo "check-tenant-boundary: $fails failure(s)"
[ "$fails" -eq 0 ]
