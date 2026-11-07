#!/usr/bin/env bash
#
# Checks hack/slurm-ec2/score.py against the evidence of a local rehearsal (hack/test/slurm-ec2/rehearsal-evidence,
# rehearsal of a1a48f43 on 2026-11-07, host names replaced and the per-node journals left out) and against copies of it
# with one thing changed.
#
#   bash hack/test/check-slurm-ec2-score.sh
#
# Each change is a way the session could behave otherwise or an instrument could fail, and must move the verdict of the
# check it touches in the registered direction: a rule that did not hold, or INVALID, or VOID.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

FIX=hack/test/slurm-ec2/rehearsal-evidence
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export PYTHONDONTWRITEBYTECODE=1

copy() { rm -rf "$work/ev"; cp -r "$FIX" "$work/ev"; }
score() { python3 hack/slurm-ec2/score.py "$work/ev" "$work/v.json" >"$work/out.txt" 2>&1 || echo "scorer exited $?" >>"$work/out.txt"; }
# q EXPR: a Python expression over v, the verdict, printed.
q() { python3 -c "import json; v = json.load(open('$work/v.json')); print($1)"; }
expect() {
  local name=$1 got=$2 want=$3
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name: got '$got', want '$want'"; cat "$work/out.txt"; fi
}
# A GPU the probes could use: the rehearsal has none, so its allocated probe is given the reading a real card gives.
with_gpu() {
  local f
  for f in "$work"/ev/b1/rep-*/alloc.json; do
    python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("cuda_error", None)
d["cuda_sum"] = float(sum(range(1024)))
d["device_count"] = 1
json.dump(d, open(sys.argv[1], "w"))
PY
  done
}

copy; score
expect "the rehearsal: B1a's CUDA rule did not hold (no GPU) in every repetition" "$(q 'sum(1 for r in v["b1"] for x in r["rules"] if "CUDA" in x["rule"] and not x["held"])')" 4
expect "the rehearsal: B1b is INVALID behind it" "$(q 'sorted({r["b1b"]["status"] for r in v["b1"]})')" "['INVALID']"
expect "the rehearsal: every B2, B3 and B4 rule held" "$(q 'all(x["held"] for r in v["b2"] + list(v["b3"].values()) + [v["b4"]] for x in r["rules"])')" True
expect "the rehearsal is not complete, because B1b is INVALID" "$(q 'v["complete"]')" False

copy; with_gpu; score
expect "with a usable card, B1a and B1b are observed and held: the unallocated probe got EPERM" "$(q 'all(r["status"] == "observed" and "b1b" not in r and all(x["held"] for x in r["rules"]) for r in v["b1"])')" True
expect "with a usable card, the session is complete" "$(q 'v["complete"]')" True

copy; with_gpu; sed -i 's/"open_nvidia0": "EPERM"/"open_nvidia0": "ok"/' "$work"/ev/b1/rep-2/unalloc.json; score
expect "an unallocated job that can open the device: B1b did not hold" "$(q '[x["held"] for x in v["b1"][1]["rules"] if "EPERM" in x["rule"]]')" "[False]"

copy; sed -i 's/|OUT_OF_MEMORY|/|COMPLETED|/' "$work"/ev/b2/rep-1/sacct.txt; score
expect "a step not OUT_OF_MEMORY: that B2 rule did not hold" "$(q '[x["held"] for x in v["b2"][0]["rules"] if "OUT_OF_MEMORY" in x["rule"]]')" "[False]"
copy; echo 1 >"$work"/ev/b2/rep-2/kernel.txt.rc; score
expect "a failed journal read makes B2 INVALID, not a rule that did not hold" "$(q 'v["b2"][1]["status"]')" INVALID
copy; echo 99999 >"$work"/ev/b2/rep-3/slurmd-pid-after.txt; score
expect "slurmd restarted during B2: that rule did not hold" "$(q '[x["held"] for x in v["b2"][2]["rules"] if "MainPID" in x["rule"]]')" "[False]"
copy; sed -i '/Memory cgroup out of memory/d' "$work"/ev/b2/rep-1/kernel.txt; score
expect "no kernel OOM report for the job: that B2 rule did not hold" "$(q '[x["held"] for x in v["b2"][0]["rules"] if "kernel" in x["rule"]]')" "[False]"

copy
python3 - "$work/ev/b3/a/sacct.txt" <<'PY'
import sys
p = sys.argv[1]
rows = open(p).read().splitlines()
f = rows[1].split("|")
f[3] = "2026-11-07T02:57:40"
rows[1] = "|".join(f)
open(p, "w").write("\n".join(rows) + "\n")
PY
score
expect "a second job that starts before the first ends: B3a's gap rule did not hold" "$(q '[x["held"] for x in v["b3"]["a"]["rules"] if "not before" in x["rule"]]')" "[False]"
copy; echo "1794020235.000 READ-FAILED" >>"$work"/ev/b3/b/poll.txt; score
expect "a failed squeue during B3b makes it INVALID" "$(q 'v["b3"]["b"]["status"]')" INVALID
copy; sed -i 's/AssocGrpGRES/Priority/g' "$work"/ev/b3/a/poll.txt; score
expect "a pending reason other than AssocGrpGRES: B3a's reason rule did not hold" "$(q '[x["held"] for x in v["b3"]["a"]["rules"] if "PENDING" in x["rule"]]')" "[False]"

copy; sed -i 's/DCGM_FI_DEV_XID_ERRORS=79/something-else/' "$work"/ev/b4/gpu1-state.txt; score
expect "no drain naming Xid 79: B4a did not hold" "$(q '[x["held"] for x in v["b4"]["rules"] if x["rule"].startswith("B4a")]')" "[False]"
copy; sed -i '0,/State=/s/^\([0-9.]*\) .*/\1 READ-FAILED/' "$work"/ev/b4/gpu1-state.txt; score
expect "a failed node read before the drain makes B4 INVALID" "$(q 'v["b4"]["status"]')" INVALID
copy; sed -i 's/"params_sha256": "[0-9a-f]*"/"params_sha256": "0000"/' "$work"/ev/b4/reference.jsonl; score
expect "final parameters unlike the reference's: B4d did not hold" "$(q '[x["held"] for x in v["b4"]["rules"] if x["rule"].startswith("B4d")]')" "[False]"
copy; echo 1 >"$work"/ev/b4/run-sacct.txt.rc; score
expect "a failed sacct for the run makes B4 INVALID" "$(q 'v["b4"]["status"]')" INVALID
copy; sed -i 's/"resumed_from": [0-9]*/"resumed_from": 5/' "$work"/ev/b4/run.jsonl; score
expect "a resume from an older checkpoint than the last logged: B4c did not hold" "$(q '[x["held"] for x in v["b4"]["rules"] if "one step after" in x["rule"]]')" "[False]"

copy; sed -i 's/^slurm_uid=.*/slurm_uid=998/' "$work"/ev/config/gpu2.env; score
expect "a worker whose slurm uid differs makes the session VOID" "$(q 'any("uid" in r for r in v["void"])')" True
copy; sed -i 's|^CgroupPlugin *=.*|CgroupPlugin            = cgroup/v1|' "$work"/ev/config/scontrol-config.txt; score
expect "a cgroup plugin other than v2 makes the session VOID" "$(q 'any("cgroup/v2" in r for r in v["void"])')" True

copy; sed -i 's/|COMPLETED|/|FAILED|/' "$work"/ev/b4/run-sacct.txt; score
expect "a resumed run that FAILED is observed, its completion rule did not hold, the others still read" "$(q 'v["b4"]["status"] + " " + str([x["held"] for x in v["b4"]["rules"] if "COMPLETED" in x["rule"]]) + " " + str([x["held"] for x in v["b4"]["rules"] if x["rule"].startswith("B4a")])')" "observed [False] [True]"
copy; echo "the bring-up finished after its deadline" >"$work/ev/NOTRUN_ALL"; score
expect "a late bring-up leaves every check NOTRUN and the session not VOID" "$(q 'str(v["void"]) + " " + str(sorted({r["status"] for r in v["b1"] + v["b2"] + list(v["b3"].values()) + [v["b4"]]}))')" "[] ['NOTRUN']"
copy; sed -i 's/^bringup_done=.*/bringup_done=9999999999/' "$work/ev/bringup.env"; score
expect "a bring-up recorded after T0 + 1,500 s is NOTRUN, not VOID" "$(q 'str(v["void"]) + " " + v["b4"]["status"]')" "[] NOTRUN"

copy; rm -rf "$work/ev/config" "$work/ev/bringup.env" "$work"/ev/b?; echo "both workers did not register idle by the bring-up deadline" >"$work/ev/NOTRUN_ALL"; score
expect "a deadline miss that never recorded the configuration is NOTRUN, not VOID" "$(q 'str(v["void"]) + " " + v["b4"]["status"]')" "[] NOTRUN"
copy; echo "gpu2 still drained after the resume" >"$work/ev/b4/setup-failed"; score
expect "a B4 whose stimulus failed is INVALID" "$(q 'v["b4"]["status"]')" INVALID

copy; with_gpu; python3 - "$work/ev/b1/rep-1/alloc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["torch_error"] = "ModuleNotFoundError: No module named 'torch'"; d.pop("cuda_sum", None)
json.dump(d, open(sys.argv[1], "w"))
PY
score
expect "an allocated probe that could not import PyTorch is INVALID, not a CUDA rule that did not hold" "$(q 'v["b1"][0]["status"]')" INVALID
copy; rm "$work/ev/b4/gpu1-state.txt"; score
expect "a B4 with no node polls is INVALID" "$(q 'v["b4"]["status"]')" INVALID

if [ "$fails" -ne 0 ]; then
  echo "check-slurm-ec2-score: $fails failure(s)"
  exit 1
fi
echo "check-slurm-ec2-score: all checks passed"
