#!/usr/bin/env bash
#
# Checks hack/lib/ddp-arms.sh without a cluster: that what it writes for the analyzer is written as the registered
# kind harness writes it, and that the job it renders carries train.py and the backend into the container intact.
#
#   bash hack/test/check-ddp-arms-lib.sh
#
# The rendered command is executed, not inspected: a stub `python` stands in for the interpreter and reports the
# backend it was given and the hash of the script it was asked to run.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck source=hack/lib/ddp-arms.sh
source hack/lib/ddp-arms.sh
HARNESS=hack/multi-pod-ddp.sh
LIB=hack/lib/ddp-arms.sh

# --- the records the analyzer reads are written alike --------------------------------------------------------------
# Every Python program each file runs: the heredoc bodies, and the one passed by -c that picks the Pods to stream.
programs() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for body in re.findall(r"<<'PY'\n(.*?)\nPY\n", text, re.S):
    print("HEREDOC", repr(body))
for body in re.findall(r"python3 -c '(import json,sys\n.*?)' \"\$dir/\.pods\.json\"", text, re.S):
    print("INLINE", repr(body))
PY
}
want="$(programs "$HARNESS")"
got="$(programs "$LIB")"
if [[ "$(wc -l <<<"$want")" != 3 ]]; then
  bad "found $(wc -l <<<"$want") record-writing programs in $HARNESS, want 3: the extraction no longer matches it"
elif [[ "$want" == "$got" ]]; then
  ok "the three record-writing programs are the harness's exactly"
else
  bad "the record-writing programs differ from $HARNESS: $(diff <(echo "$want") <(echo "$got") | head -5)"
fi

# --- the arms' environments are the harness's -----------------------------------------------------------------------
for arm in pass no-sync bad-address one-rank-fails; do
  harness_env="$(sed -n "s/^ *$arm) extra=\"\(.*\)\" ;;\$/\1/p" "$HARNESS")"
  lib_env="$(ddp_arm_env "$arm")"
  # grep -c prints 0 and exits 1 when nothing matches, so its status is not read here, only the count.
  found="$(grep -c "^ *$arm) extra=" "$HARNESS")"
  if [[ "$found" != 1 ]]; then
    bad "$arm: not found once in $HARNESS"
  elif [[ "$harness_env" == "$lib_env" ]]; then
    ok "$arm: environment '$lib_env' as the harness sets it"
  else
    bad "$arm: '$lib_env', the harness sets '$harness_env'"
  fi
done
ddp_arm_env some-other-arm >/dev/null && bad "an unknown arm has an environment" || ok "an unknown arm is refused"
ddp_arm_body x some-other-arm >/dev/null && bad "an unknown arm has a body" || ok "an unknown arm has no body"

# --- the rendered job runs the script it carries ---------------------------------------------------------------------
mkdir -p "$work/bin"
cat >"$work/bin/python" <<'EOF'
#!/usr/bin/env bash
echo "backend=${DDP_BACKEND:-unset} master=${MASTER_ADDR:-unset} run=${DDP_RUN_ID:-unset} script=$(sha256sum "$1" | cut -d' ' -f1)"
EOF
chmod +x "$work/bin/python"
DDP_NS=train-a DDP_QUEUE=gpu-train-a DDP_IMAGE=registry.example/torch@sha256:0000 DDP_SCRIPT="$work/train.py"
DDP_PRELUDE="$(ddp_prelude_for experiments/cpu-ddp/train.py "$DDP_SCRIPT" nccl)"
want_sha="$(sha256sum experiments/cpu-ddp/train.py | cut -d' ' -f1)"
ddp_render_job ddp-bad-address-1 "$(ddp_arm_body ddp-bad-address-1 bad-address)" >"$work/job.json"
spec="$(python3 -c '
import json, sys
j = json.load(open(sys.argv[1]))
s = j["spec"]
print(j["metadata"]["namespace"], s["queue"], s["image"], s["gpuCount"], s["distributed"]["worldSize"], s["command"][:2])
' "$work/job.json")"
if [[ "$spec" == "train-a gpu-train-a registry.example/torch@sha256:0000 1 2 ['sh', '-c']" ]]; then
  ok "the job: $spec"
else
  bad "the job's fields: $spec"
fi
body="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["spec"]["command"][2])' "$work/job.json")"
ran="$(PATH="$work/bin:$PATH" sh -c "$body" 2>&1)"
rc=$?
if [[ $rc == 0 && "$ran" == "backend=nccl master=nowhere.invalid run=ddp-bad-address-1 script=$want_sha" ]]; then
  ok "the command decodes train.py intact, exports nccl, and keeps the arm's own environment"
else
  bad "the command ran as rc=$rc: $ran (want script=$want_sha)"
fi

# A script altered in transit must not run: the container checks the hash before python starts.
tampered="$(sed 's/base64 -d >/base64 -d | sed "1s|^|# |" >/' <<<"$body")"
[[ "$tampered" != "$body" ]] || bad "the tamper did not apply"
ran="$(PATH="$work/bin:$PATH" sh -c "$tampered" 2>&1)"
rc=$?
if [[ $rc == 86 && "$ran" != *backend=* ]]; then
  ok "an altered script exits 86 before python runs"
else
  bad "an altered script ran as rc=$rc: $ran"
fi

# --- one arm against a stub cluster that finishes at once -------------------------------------------------------------
# What the arm leaves behind is what the analyzer reads; the node objects above all, which only the nccl profile needs.
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CALLS"
case "$*" in
  *"get mltrainingjob"*jsonpath*) printf 'Succeeded' ;;
  # The first read of the Job fails, as it does while the operator is still creating it.
  *"get job"*jsonpath*) [[ -e "$STUB_CALLS.job" ]] || { touch "$STUB_CALLS.job"; echo 'Error from server (NotFound): jobs.batch "x" not found' >&2; exit 1; }; printf 'Complete' ;;
  *"get pods"*) echo '{"items": []}' ;;
  *"get nodes"*) echo '{"items": [{"metadata": {"name": "ip-a", "labels": {"eks.amazonaws.com/nodegroup": "gpu"}}}]}' ;;
  *apply*) echo created ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$work/bin/kubectl"
log() { :; }
export STUB_CALLS="$work/calls.log"
: >"$STUB_CALLS"
DDP_CONTEXT=stub DDP_OUT="$work/out" DDP_BUDGET=5
mkdir -p "$DDP_OUT"
# Under errexit, as the session runs: a failed poll must be retried, not end the arm.
# An arm that aborts leaves its log collector looping, holding this test's output open; the trap stops it either way.
# shellcheck disable=SC2154  # DDP_COLLECTORS is set by the library inside the subshell
(set -e; trap 'rc=$?; for p in "${DDP_COLLECTORS[@]}"; do kill "$p" 2>/dev/null || true; done; exit $rc' EXIT; PATH="$work/bin:$PATH" ddp_run_arm pass)
rc=$?
missing=""
for f in mltrainingjob.yaml timeline.jsonl final-mltj.json final-job.json final-workloads.json final-service.json name; do
  [[ -s "$DDP_OUT/pass/$f" ]] || missing="$missing $f"
done
groups="$(python3 -c 'import json,sys; print([n["metadata"]["labels"]["eks.amazonaws.com/nodegroup"] for n in json.load(open(sys.argv[1]))["items"]])' "$DDP_OUT/pass/nodes.json" 2>&1)"
if [[ $rc == 0 && -z "$missing" && "$groups" == "['gpu']" ]]; then
  ok "an arm leaves every file the analyzer reads, nodes.json with its node-group labels among them"
else
  bad "the arm returned $rc, missing:${missing:- none}, nodes.json read as $groups"
fi
grep -q -- "--context stub get nodes -o json" "$STUB_CALLS" && ok "the nodes are read from the arm's own context" || bad "the nodes were not read from the arm's context: $(grep nodes "$STUB_CALLS")"
[[ -e "$DDP_OUT/pass/VOID" ]] && bad "a finished arm wrote VOID" || ok "a finished arm is not void"

if [[ $fails -ne 0 ]]; then
  echo "check-ddp-arms-lib: $fails failure(s)"
  exit 1
fi
echo "check-ddp-arms-lib: all checks passed"
