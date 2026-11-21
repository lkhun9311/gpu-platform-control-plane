#!/usr/bin/env bash
#
# Offline checks for the SGLang #51628 kit r3 in docs/oss/sglang-51628/kit-r3, run before any GPU is bought.
# No GPU, no network and no AWS: the fakes in hack/sglang-51628-fake stand in for docker, nvidia-smi, SGLang, Triton, torch and the Hub,
# and for r3 the fake server prints Triton's autotune report and compiles with constants, attrs and warps the classifier reads.
# Each rule is also run against a mutant that breaks it, and the mutant must be caught.
# The session checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
#
#   bash hack/sglang-51628-kit-r3-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE CONTROL BUDGET_S KIT_DRY_RUN KIT_OFFLINE_TEST MODEL IMAGE SGLANG_IMAGE BURSTS THRESHOLD \
  SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS SGL51628_COMPILE_LOG SGL51628_ROOT SGL51628_HOST_ROOT SGL51628_OFFLINE_TEST FAKE_SCENARIO FAKE_DIR FAKE_VENV \
  FAKE_BURST_FAIL FAKE_SHORT FAKE_NO_LISTENER FAKE_DOWNLOAD_FAIL FAKE_PULL_FAIL FAKE_DIGEST FAKE_REVISION FAKE_DRIVER FAKE_SPLICE
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/sglang-51628/kit-r3"
FAKES="$ROOT/hack/sglang-51628-fake"
CHECK="$ROOT/hack/sglang-51628-kit-r3-check.py"
SCRATCH="${SCRATCH:-$HOME/.cache/sglang-51628}"
mkdir -p "$SCRATCH"
WORK=$(mktemp -d -p "$SCRATCH")
export SCRATCH
# The kit is force-added past the docs ignore rule, so no bytecode may be left in it for a later git add -f to pick up.
export PYTHONDONTWRITEBYTECODE=1
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
mcheck() { if [ -n "$m" ]; then check "$@"; else echo "FAIL $1 (the mutant was not made)" >&2; failures=$((failures + 1)); fi; }
mutant() {
  local d
  d="$WORK/m-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
  cp -r "$KIT" "$d"
  sed -i "$3" "$d/$2"
  cmp -s "$KIT/$2" "$d/$2" && { echo "the mutant $1 changed nothing" >&2; return 1; }
  echo "$d"
}

# ---------------------------------------------------------------- parse and compile
check "run.sh, measure.sh, the fakes and this test parse" \
  "bash -n '$KIT/run.sh' && bash -n '$KIT/measure.sh' && bash -n '$FAKES/docker' && bash -n '$0'"
check "the kit's Python, the fakes and the checker compile" \
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/probe_hook.py' '$KIT/sgl51628_compile_hook.py' '$CHECK' \$(find '$FAKES/py' -name '*.py')"
check "r2-reference.json is JSON" "python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' '$KIT/r2-reference.json'"

# ---------------------------------------------------------------- the units
units() { python3 -I "$CHECK" "$1" "$FAKES" "$ROOT" >"$2" 2>&1; }
units "$KIT" "$WORK/units.log"; rc=$?
check "the unit checks pass ($(command grep -c '^ok' "$WORK/units.log") ok, $(command grep -c '^FAIL' "$WORK/units.log") failed)" "[ $rc = 0 ]"
command grep -E '^FAIL|Traceback' "$WORK/units.log" >&2

# ---------------------------------------------------------------- run.sh's settings and measure.sh's arguments
dry() { local k=$1; shift; rm -rf "$WORK/dry"; env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/dry" "$@" bash "$k/run.sh" >"$WORK/dry.out" 2>&1; }
check "the default settings are accepted: the control arm only, with --warmups prefill_shapes, budget 3150" \
  "dry '$KIT' && command grep -qx 'arm=control only (r2'\\''s main arm is the reference)' '$WORK/dry/settings.txt' \
   && command grep -qx 'server=python -m sglang.launch_server --model-path <model> --trust-remote-code --warmups prefill_shapes' '$WORK/dry/settings.txt' \
   && command grep -qx 'budget_s=3150' '$WORK/dry/settings.txt'"
check "CONTROL is refused, r3 is the control arm and nothing else" "! dry '$KIT' CONTROL=off && command grep -qF 'CONTROL is set' '$WORK/dry.out'"
check "BUDGET_S over 3250 is refused" "! dry '$KIT' BUDGET_S=3300 && command grep -qF 'at most 3250' '$WORK/dry.out'"
check "MODEL is refused rather than ignored" "! dry '$KIT' MODEL=x && command grep -qF 'MODEL is set' '$WORK/dry.out'"
mkdir -p "$WORK/margs/in" "$WORK/margs/out" "$WORK/margs/models"
bash "$KIT/measure.sh" "$WORK/margs/in" "$WORK/margs/out" "$WORK/margs/models" 99 on >"$WORK/marg.out" 2>&1; rc=$?
check "measure.sh refuses r2's five arguments" "[ $rc = 2 ] && command grep -qF usage '$WORK/marg.out'"
bash "$KIT/measure.sh" "$WORK/margs/in" "$WORK/margs/out" "$WORK/margs/models" 9x >"$WORK/marg.out" 2>&1; rc=$?
check "measure.sh refuses a deadline that is not an epoch" "[ $rc = 2 ] && command grep -qF 'is not an epoch' '$WORK/marg.out'"
m=$(mutant control run.sh 's/^for v in CONTROL MODEL/for v in MODEL/')
mcheck "mutant: a run.sh that takes a CONTROL setting is caught" "! { ! dry '$m' CONTROL=off && command grep -qF 'CONTROL is set' '$WORK/dry.out'; }"

# ---------------------------------------------------------------- end to end on the fakes
mkdir -p "$WORK/fakebin"
cp "$FAKES/docker" "$FAKES/nvidia-smi" "$WORK/fakebin/"
ln -s "$(command -v python3)" "$WORK/fakebin/python"
python3 -m venv --without-pip "$WORK/venv" || { echo "FAIL could not make the fake container's venv" >&2; exit 1; }
VSITE=$("$WORK/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
echo "$FAKES/py" >"$VSITE/_sgl51628_fakes.pth"
e2e() {
  local k=$1 n=$2; shift 2
  local d="$WORK/e2e-$n"
  mkdir -p "$d/fd" "$d/cwd"
  rm -f "$VSITE/sgl51628_compile_hook.pth"
  ( cd "$d/cwd" && env PATH="$WORK/fakebin:$PATH" FAKE_DIR="$d/fd" FAKE_VENV="$WORK/venv" KIT_OFFLINE_TEST=1 SGL51628_HOST_ROOT="$d/host" OUT="$d/out" "$@" \
    bash "$k/run.sh" >"$d/run.log" 2>&1 )
}
ports_free() { ! ss -ltn 2>/dev/null | command grep -qE '127\.0\.0\.1:30000\b'; }
check "the server port is free before the end-to-end runs" "ports_free"
V() { echo "$WORK/e2e-$1/out/verdict.txt"; }
C() { echo "$WORK/e2e-$1/out/c"; }

e2e "$KIT" some FAKE_SCENARIO=movesome; rc=$?
check "movesome: WARMUP MOVES SOME with r3's count against r2's 53, exit 0" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: WARMUP MOVES SOME' \"\$(V some)\" && command grep -qF '5 Mamba2 compile(s) after ready, against 53' \"\$(V some)\""
check "movesome: per kernel, r3 before and after beside r2's, the bursts and the classes" \
  "command grep -qx '  _chunk_scan_fwd_kernel | 3, 5 | 19, 24 | warmup 4, c16-r1 1 | autotune-config 3, post-autotune specialisation 2' \"\$(V some)\""
check "movesome: each autotune is reported with its configs, key, choice and where its compiles ran" \
  "command grep -qE \"^  _chunk_scan_fwd_kernel #1 \\| 3 \\| \\(256, 64, 128, True, 'torch.float32'\\) \\| 1.5 \\| .* \\| 3 compiles, startup\$\" \"\$(V some)\" \
   && command grep -qE '^  _chunk_scan_fwd_kernel #2 \| 3 \| .* \| 3 compiles, warmup\$' \"\$(V some)\""
check "movesome: the first-burst TTFT and the startup time are shown beside r2's" \
  "command grep -qE '^FIRST-BURST TTFT ms \(warmup burst\): r3 mean [0-9.]+, .*; r2 MAIN mean 50110.7, median 49119.5, p99 82974.7; ' \"\$(V some)\" \
   && command grep -qE '^STARTUP launch to ready: r3 [0-9.]+ s with --warmups prefill_shapes, r2 MAIN 153.8 s without' \"\$(V some)\""
check "movesome: the server ran r2's command plus --warmups prefill_shapes, unbuffered, with the threshold at its default" \
  "command grep -qE -- 'PYTHONUNBUFFERED=1 .*-m sglang\.launch_server --model-path [^ ]+/nemotron-h-4b-instruct-128k --trust-remote-code --warmups prefill_shapes \$' \"\$(C some)/control/commands.txt\" \
   && ! command grep -q SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS \"\$(C some)/control/commands.txt\" && [ ! -d \"\$(C some)/main\" ]"
check "movesome: the compile records carry attrs, num_warps and num_stages" \
  "command grep -q '\"attrs\": \"{(0,): \[\[.tt.divisibility., 16\]\]}\".*\"num_stages\": 1, \"num_warps\": 4' \"\$(C some)/control/compiles.jsonl\""
check "movesome: the run leaves checksums of everything it wrote" "( cd '$WORK/e2e-some/out' && sha256sum -c --quiet SHA256SUMS )"
e2e "$KIT" all FAKE_SCENARIO=moveall; rc=$?
check "moveall: WARMUP MOVES ALL, and both autotunes ran before ready" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: WARMUP MOVES ALL' \"\$(V all)\" && [ \"\$(command grep -c '| 3 compiles, startup\$' \"\$(V all)\")\" = 2 ] \
   && command grep -qx '  _chunk_scan_fwd_kernel | 7, 0 | 19, 24 | - | -' \"\$(V all)\""
e2e "$KIT" none FAKE_SCENARIO=noeffect; rc=$?
check "noeffect: NO EFFECT, and with no autotune report the classes say so rather than infer" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: NO EFFECT' \"\$(V none)\" && command grep -qF '| warmup 60 | no autotune report 60' \"\$(V none)\" \
   && command grep -qx 'AUTOTUNE: the log holds no Triton autotune report, so configs and classes are not shown' \"\$(V none)\""
e2e "$KIT" splice FAKE_SCENARIO=movesome FAKE_SPLICE=1; rc=$?
check "splice: a log line glued into a config line still leaves a whole report" \
  "[ $rc = 0 ] && command grep -qE '^  _chunk_scan_fwd_kernel #1 \| 3 \| .* \| 3 compiles, startup\$' \"\$(V splice)\" && command grep -q 'maxnreg: None\[2026' \"\$(C splice)/control/server.log\""
e2e "$KIT" gate FAKE_SCENARIO=gatefail; rc=$?
check "gatefail: GATE FAILED, exit 4, no traffic" "[ $rc = 4 ] && command grep -qx 'VERDICT: GATE FAILED' \"\$(V gate)\" && [ -z \"\$(ls -A \"\$(C gate)/control/bursts\")\" ]"
e2e "$KIT" hookdead FAKE_SCENARIO=hookdead; rc=$?
check "hookdead: a hook that recorded nothing in the server is INCOMPLETE" "[ $rc = 3 ] && command grep -qF 'the hook was not shown live' \"\$(V hookdead)\""
e2e "$KIT" nolistener FAKE_NO_LISTENER=1; rc=$?
check "nolistener: a failed positive control stops before any server" "[ $rc = 3 ] && [ ! -d \"\$(C nolistener)/control\" ]"
e2e "$KIT" burstfail FAKE_SCENARIO=movesome FAKE_BURST_FAIL=1282; rc=$?
check "burstfail: a burst without a result is INCOMPLETE and named" "[ $rc = 3 ] && command grep -qF 'c128-r2: the client exited 1' \"\$(V burstfail)\""
e2e "$KIT" timeout FAKE_SCENARIO=movesome BUDGET_S=450; rc=$?
check "timeout: a burst the budget could not hold is INCOMPLETE" "[ $rc = 3 ] && command grep -qF 'skipped, the time ran out' \"\$(V timeout)\""
check "the port is free after every run" "ports_free"

# ---------------------------------------------------------------- mutants of measure.sh, caught end to end
m=$(mutant warmups measure.sh 's/ --warmups prefill_shapes$/ /')
e2e "$m" m-warmups FAKE_SCENARIO=movesome
mcheck "mutant: a measure.sh whose server runs without --warmups prefill_shapes is caught" \
  "! command grep -qE -- '--warmups prefill_shapes \$' \"\$(C m-warmups)/control/commands.txt\""
m=$(mutant unbuf measure.sh 's/ PYTHONUNBUFFERED=1 / /')
e2e "$m" m-unbuf FAKE_SCENARIO=movesome
mcheck "mutant: a measure.sh whose server output is buffered is caught" "! command grep -q PYTHONUNBUFFERED=1 \"\$(C m-unbuf)/control/commands.txt\""
m=$(mutant gate measure.sh 's/if \[ -z "\$gate_line" \] || \[ -n "\$capture_line" \]; then/if false; then/')
e2e "$m" m-gate FAKE_SCENARIO=gatefail
mcheck "mutant: a measure.sh that sends traffic past a failed gate is caught" "[ -n \"\$(ls -A \"\$(C m-gate)/control/bursts\")\" ]"
m=$(mutant hookattrs sgl51628_compile_hook.py 's/                "attrs": _short(getattr(src, "attrs", None), 20000),//')
e2e "$m" m-attrs FAKE_SCENARIO=movesome
mcheck "mutant: a hook that drops attrs leaves every compile unclassified, which the end-to-end check catches" \
  "! command grep -qF 'autotune-config 3, post-autotune specialisation 2' \"\$(V m-attrs)\""
check "the port is free after the mutants" "ports_free"

# ---------------------------------------------------------------- mutants of verdict.py, each caught by the unit checks
vmut() {
  # The name goes into an eval string as a file name, so only letters, digits and dashes are kept.
  local id
  id=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')
  m=$(mutant "v-$1" verdict.py "$2")
  units "$m" "$WORK/units-$id.log"
  mcheck "mutant: verdict.py $1 is caught by the unit checks" "command grep -q '^FAIL\|Traceback' '$WORK/units-$id.log'"
}
vmut "that calls 53 SOME" 's/    elif n_after < r2_total:/    elif n_after <= r2_total:/'
vmut "that calls any late compile NO EFFECT" 's/    if n_after == 0:/    if n_after < 0:/'
vmut "that counts a cache hit" 's/fresh = sorted((c for c in compiles if not c\["cache_hit"\]), key=lambda c: c\["t"\])/fresh = sorted(compiles, key=lambda c: c["t"])/'
vmut "that counts every kernel as Mamba2" 's/    if name in MAMBA2_KERNELS:/    if True:/'
vmut "that anchors the config pattern at the line end" 's/AT_CONFIG_RE = re.compile(r"Autotuning kernel (\\S+) with config " + _CFG)/AT_CONFIG_RE = re.compile(r"Autotuning kernel (\\S+) with config " + _CFG + "$")/'
vmut "that reads only adjacent report lines" 's/^AT_BLOCK_SPAN = 40$/AT_BLOCK_SPAN = 3/'
vmut "that lets a header take the next report's fields" 's/            if AT_HEAD_RE.search(nxt):/            if False:/'
vmut "that classes compiles without attrs" 's/    if rec.get("attrs") is None or rec.get("num_warps") is None or rec.get("num_stages") is None:/    if False:/'
vmut "that infers a class from no report" 's/classes\[i\] = "no autotune report"/classes[i] = "post-autotune specialisation"/'
vmut "that classes a lone unchosen config" 's/cls = "post-autotune specialisation" if next(iter(cfgs)) in bests else "unclassified"/cls = "post-autotune specialisation"/'
vmut "that classes from an incomplete report" 's/        if not all(b\["complete"\] for b in kb):/        if False:/'
vmut "that links without checking the choice" 's/link\["linked"\] = len(cfgs) == len(b\["configs"\]) and best_identity(b\["best"\], params) in cfgs/link["linked"] = True/'
vmut "that does not check the reference exists" '/^def load_reference/,/^    if text is None:/s/^    if text is None:/    if False:/'
vmut "that does not require the warmup to have ended" 's/    if "Warmup ended" not in log:/    if False:/'
vmut "that does not require a launch time" 's/    if launch is None or launch > ready:/    if False:/'
vmut "that exits 0 on a failed gate" 's/return v, 4/return v, 0/'
vmut "that ignores a non-empty Triton cache" 's/if kv.get("triton_cache_entries_at_start") != "0":/if False:/'

# ---------------------------------------------------------------- the session: the cost print and the dirty-tree refusal
s2=$(env -i PATH="$PATH" HOME="$HOME" INSTANCE_TYPE=g5.2xlarge bash "$ROOT/hack/gpu-kit-session.sh" --print-schedule 2>&1)
check "the session's g5.2xlarge worst case is \$0.9696 with a 3,720 s stop, under \$1.00" \
  "[ \"$s2\" = 'instance_type=g5.2xlarge harness_end_s=3600 evidence_s=3660 stop_s=3720 termination_s=4020 worst_case_usd=0.9696' ]"
git clone -q "$ROOT" "$WORK/clone" 2>"$WORK/clone.err" || echo "FAIL could not clone HEAD: $(cat "$WORK/clone.err")" >&2
mkdir -p "$WORK/awsbin"
printf '#!/bin/bash\necho "fake aws $*" >> "%s/aws-calls"\necho "fake aws: no network here" >&2\nexit 1\n' "$WORK" >"$WORK/awsbin/aws"
chmod +x "$WORK/awsbin/aws"
session() { ( cd "$WORK/clone" && env -i PATH="$WORK/awsbin:$PATH" HOME="$HOME" SESSION_CONFIRM=yes OUT="$WORK/sess-$1" INSTANCE_TYPE=g5.2xlarge \
  bash hack/gpu-kit-session.sh docs/oss/sglang-51628/kit-r3 >"$WORK/sess-$1.log" 2>&1 ); }
check "the clone of HEAD holds the committed r3 kit and its reference" "[ -f '$WORK/clone/docs/oss/sglang-51628/kit-r3/run.sh' ] && [ -f '$WORK/clone/docs/oss/sglang-51628/kit-r3/r2-reference.json' ]"
echo '{}' >"$WORK/clone/docs/oss/sglang-51628/kit-r3/r2-reference.json"
session edited; rc=$?
check "the session refuses an uncommitted edit to the r3 reference, before any AWS call" \
  "[ $rc != 0 ] && command grep -qF 'SESSION REFUSED: the working tree is dirty' '$WORK/sess-edited.log' && [ ! -e '$WORK/aws-calls' ]"
git -C "$WORK/clone" checkout -q -- docs/oss/sglang-51628/kit-r3/r2-reference.json
session clean; rc=$?
check "a clean tree passes the dirty-tree check and stops only at the first AWS call" \
  "[ $rc != 0 ] && command grep -qF 'the account check failed' '$WORK/sess-clean.log' && ! command grep -qF 'dirty' '$WORK/sess-clean.log'"

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed" >&2; fi
[ "$failures" = 0 ]
