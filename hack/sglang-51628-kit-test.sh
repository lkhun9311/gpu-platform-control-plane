#!/usr/bin/env bash
#
# Offline checks for the SGLang #51628 kit r2 in docs/oss/sglang-51628/kit-r2, run before any GPU is bought.
# No GPU, no network and no AWS: docker, nvidia-smi, the SGLang server and client, Triton, torch and the Hub are the fakes in hack/sglang-51628-fake.
# The fake docker runs measure.sh on the host with a venv whose site-packages hold those fakes, so the real compile hook is installed and fires.
# Each rule is also run against a mutant that breaks it, and the mutant must be caught, so a check that cannot fail does not pass silently.
# The session checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
#
#   bash hack/sglang-51628-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE CONTROL BUDGET_S KIT_DRY_RUN KIT_OFFLINE_TEST MODEL IMAGE SGLANG_IMAGE BURSTS THRESHOLD \
  SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS SGL51628_COMPILE_LOG SGL51628_ROOT SGL51628_HOST_ROOT SGL51628_OFFLINE_TEST FAKE_SCENARIO FAKE_DIR FAKE_VENV \
  FAKE_BURST_FAIL FAKE_SHORT FAKE_NO_LISTENER FAKE_DOWNLOAD_FAIL FAKE_PULL_FAIL FAKE_DIGEST FAKE_REVISION FAKE_DRIVER
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/sglang-51628/kit-r2"
FAKES="$ROOT/hack/sglang-51628-fake"
CHECK="$ROOT/hack/sglang-51628-kit-check.py"
# Scratch space lives on disk, since /tmp is RAM-backed on the development machine.
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

# mutant NAME FILE SED: a copy of the kit with SED applied to FILE, and its directory; a SED that changes nothing is an error.
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
  "bash -n '$KIT/run.sh' && bash -n '$KIT/measure.sh' && bash -n '$FAKES/docker' && bash -n '$FAKES/nvidia-smi' && bash -n '$0'"
check "the kit's Python, the fakes and the checker compile" \
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/probe_hook.py' '$KIT/sgl51628_compile_hook.py' '$CHECK' \
   \$(find '$FAKES/py' -name '*.py')"

# ---------------------------------------------------------------- the units
units() { python3 -I "$CHECK" "$1" "$FAKES" >"$2" 2>&1; }
units "$KIT" "$WORK/units.log"; rc=$?
check "the unit checks pass ($(command grep -c '^ok' "$WORK/units.log") ok, $(command grep -c '^FAIL' "$WORK/units.log") failed)" "[ $rc = 0 ]"
command grep -E '^FAIL|Traceback' "$WORK/units.log" >&2

# ---------------------------------------------------------------- run.sh's settings
dry() { local k=$1; shift; rm -rf "$WORK/dry"; env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/dry" "$@" bash "$k/run.sh" >"$WORK/dry.out" 2>&1; }
check "the default settings are accepted: control on, budget 3150, the pinned image, model and traffic" \
  "dry '$KIT' && command grep -qx 'control=on (--warmups prefill_shapes)' '$WORK/dry/settings.txt' && command grep -qx 'budget_s=3150' '$WORK/dry/settings.txt' \
   && command grep -qx 'sglang_sha=03fde9cc392a5f84a54a365635ffed0061cdf1b8' '$WORK/dry/settings.txt' \
   && command grep -qx 'model=nvidia/Nemotron-H-4B-Instruct-128K@f3c0b6c3b7fcb39e132b6007386e33a586d6e6cb' '$WORK/dry/settings.txt'"
check "CONTROL=off is accepted" "dry '$KIT' CONTROL=off && command grep -qx 'control=off (--warmups prefill_shapes)' '$WORK/dry/settings.txt'"
check "CONTROL=maybe is refused" "! dry '$KIT' CONTROL=maybe && command grep -qF 'it is on or off' '$WORK/dry.out'"
check "BUDGET_S over 3250 is refused" "! dry '$KIT' BUDGET_S=3300 && command grep -qF 'at most 3250' '$WORK/dry.out'"
check "BUDGET_S that is not whole seconds is refused" "! dry '$KIT' BUDGET_S=1e3 && command grep -qF 'whole seconds' '$WORK/dry.out'"
for v in MODEL=x IMAGE=x SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS=0; do
  check "${v%%=*} is refused rather than ignored" "! dry '$KIT' $v && command grep -qF '${v%%=*} is set' '$WORK/dry.out'"
done
mkdir -p "$WORK/used" && echo old >"$WORK/used/verdict.json"
env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/used" bash "$KIT/run.sh" >"$WORK/used.out" 2>&1; rc=$?
check "an OUT that holds an earlier run is refused" "[ $rc != 0 ] && command grep -qF 'is not empty' '$WORK/used.out'"
m=$(mutant budget run.sh 's/-le 3250 \]/-le 99999 ]/')
mcheck "mutant: a run.sh that takes BUDGET_S=3300 is caught" "! { ! dry '$m' BUDGET_S=3300 && command grep -qF 'at most 3250' '$WORK/dry.out'; }"
m=$(mutant usedout run.sh 's/if \[ -n "\$(ls -A "\$OUT")" \]; then/if false; then/')
mcheck "mutant: a run.sh that reuses a non-empty OUT is caught" \
  "env -i PATH='$PATH' HOME='$HOME' KIT_DRY_RUN=1 OUT='$WORK/used' bash '$m/run.sh' >'$WORK/used2.out' 2>&1; ! command grep -qF 'is not empty' '$WORK/used2.out'"

# ---------------------------------------------------------------- measure.sh's arguments
mkdir -p "$WORK/margs/in" "$WORK/margs/out" "$WORK/margs/models"
marg() { bash "$1/measure.sh" "${@:2}" >"$WORK/marg.out" 2>&1; }
A3=("$WORK/margs/in" "$WORK/margs/out" "$WORK/margs/models")
marg "$KIT" "${A3[0]}"; rc=$?
check "measure.sh refuses a call without its five arguments" "[ $rc = 2 ] && command grep -qF usage '$WORK/marg.out'"
marg "$KIT" "${A3[@]}" 12x on; rc=$?
check "measure.sh refuses a deadline that is not an epoch" "[ $rc = 2 ] && command grep -qF 'is not an epoch' '$WORK/marg.out'"
marg "$KIT" "${A3[@]}" 99 maybe; rc=$?
check "measure.sh refuses a control that is not on or off" "[ $rc = 2 ] && command grep -qF 'not on or off' '$WORK/marg.out'"
marg "$KIT" "$WORK/margs/none" "${A3[1]}" "${A3[2]}" 99 on; rc=$?
check "measure.sh refuses directories that do not exist" "[ $rc = 2 ] && command grep -qF 'must exist' '$WORK/marg.out'"

# ---------------------------------------------------------------- end to end on the fakes
mkdir -p "$WORK/fakebin"
cp "$FAKES/docker" "$FAKES/nvidia-smi" "$WORK/fakebin/"
ln -s "$(command -v python3)" "$WORK/fakebin/python"
# The fake container's python3, with the fakes on its path through a .pth that sorts before the hook's.
python3 -m venv --without-pip "$WORK/venv" || { echo "FAIL could not make the fake container's venv" >&2; exit 1; }
VSITE=$("$WORK/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
echo "$FAKES/py" >"$VSITE/_sgl51628_fakes.pth"
# e2e KIT NAME [VAR=VALUE...]: the whole kit on the fakes into $WORK/e2e-NAME/out; its exit status is run.sh's.
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

e2e "$KIT" repro; rc=$?
check "repro: the chunked scan compiling in the first burst gives REPRODUCED and exit 0" "[ $rc = 0 ] && command grep -qx 'VERDICT: REPRODUCED' \"\$(V repro)\""
check "repro: each late compile is named with its duration and the burst it landed in" \
  "command grep -qE '^  _chunk_scan_fwd_kernel 1\.45 s in warmup \(' \"\$(V repro)\" && command grep -qE '^  _chunk_scan_fwd_kernel 1\.00 s in warmup \(' \"\$(V repro)\""
check "repro: the small copy kernel is listed apart from the verdict" \
  "command grep -qx 'OTHER KERNELS AFTER READY (main, not part of the verdict): 1' \"\$(V repro)\""
check "repro: the first-burst TTFT hit is measured against CONTROL" "command grep -qE '^FIRST-BURST TTFT HIT: MEASURED: mean \+2750\.0 ms' \"\$(V repro)\""
check "repro: the server ran with exactly the spec's flags, and CONTROL added only --warmups prefill_shapes" \
  "command grep -qE -- '-m sglang\.launch_server --model-path [^ ]+/nemotron-h-4b-instruct-128k --trust-remote-code \$' \"\$(C repro)/main/commands.txt\" \
   && command grep -qE -- '--trust-remote-code --warmups prefill_shapes \$' \"\$(C repro)/control/commands.txt\""
check "repro: no server ran with the compile warning threshold moved from its default" \
  "! command grep -q SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS \"\$(C repro)/main/commands.txt\" \"\$(C repro)/control/commands.txt\""
check "repro: the client ran the spec's traffic with its own seed per burst" \
  "[ \"\$(command grep -c -- '--dataset-name random-ids --random-input-len 1024 --random-output-len 512 --random-range-ratio 1.0' \"\$(C repro)/main/commands.txt\")\" = 10 ] \
   && [ \"\$(command grep -oE -- '--seed [0-9]+' \"\$(C repro)/main/commands.txt\" | sort -u | wc -l)\" = 10 ]"
check "repro: the compile records come from the server through the installed .pth hook" \
  "command grep -q '\"event\": \"install\", \"exe\": \"[^\"]*\", \"installed\": true' \"\$(C repro)/main/compiles.jsonl\""
check "repro: the run leaves checksums of everything it wrote" "( cd '$WORK/e2e-repro/out' && sha256sum -c --quiet SHA256SUMS )"
check "repro: the port is free after the run" "ports_free"

e2e "$KIT" norepro FAKE_SCENARIO=norepro; rc=$?
check "norepro: Mamba2 compiled only at startup gives NOT REPRODUCED, said plainly, exit 0" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: NOT REPRODUCED' \"\$(V norepro)\" && command grep -qF 'no Mamba2 kernel compiled after the server reported ready' \"\$(V norepro)\" \
   && command grep -qx 'MAMBA2 KERNELS COMPILED BEFORE READY (main): _chunk_scan_fwd_kernel, _chunk_state_fwd_kernel' \"\$(V norepro)\""

e2e "$KIT" gatefail FAKE_SCENARIO=gatefail; rc=$?
check "gatefail: a prefill capture gives GATE FAILED, exit 4, and no traffic or CONTROL" \
  "[ $rc = 4 ] && command grep -qx 'VERDICT: GATE FAILED' \"\$(V gatefail)\" && [ -z \"\$(ls -A \"\$(C gatefail)/main/bursts\")\" ] && [ ! -d \"\$(C gatefail)/control\" ]"
e2e "$KIT" latedisable FAKE_SCENARIO=latedisable; rc=$?
check "latedisable: a disabling line beside a prefill capture still fails the gate" "[ $rc = 4 ] && command grep -qx 'VERDICT: GATE FAILED' \"\$(V latedisable)\""

e2e "$KIT" hookdead FAKE_SCENARIO=hookdead; rc=$?
check "hookdead: a hook that recorded nothing in the server is INCOMPLETE, not NOT REPRODUCED" \
  "[ $rc = 3 ] && command grep -qx 'VERDICT: INCOMPLETE' \"\$(V hookdead)\" && command grep -qF 'the hook was not shown live' \"\$(V hookdead)\" \
   && command grep -qF 'SGLang logged compile(s) the hook did not record' \"\$(V hookdead)\""
e2e "$KIT" nolistener FAKE_NO_LISTENER=1; rc=$?
check "nolistener: a failed positive control stops before any server, INCOMPLETE" \
  "[ $rc = 3 ] && command grep -qF 'positive control' \"\$(V nolistener)\" && [ ! -d \"\$(C nolistener)/main\" ]"
e2e "$KIT" burstfail FAKE_BURST_FAIL=1282; rc=$?
check "burstfail: a burst without a result is INCOMPLETE and named" \
  "[ $rc = 3 ] && command grep -qF 'c128-r2: the client exited 1' \"\$(V burstfail)\""
e2e "$KIT" short FAKE_SHORT=101; rc=$?
check "short: a burst with a request missing is INCOMPLETE" "[ $rc = 3 ] && command grep -qF 'c1-r1: 3 of 4 requests completed' \"\$(V short)\""
e2e "$KIT" timeout BUDGET_S=450; rc=$?
check "timeout: a burst the budget could not hold is INCOMPLETE, never a default" \
  "[ $rc = 3 ] && command grep -qF 'c128-r1: skipped, the time ran out' \"\$(V timeout)\""
e2e "$KIT" ctloff CONTROL=off; rc=$?
check "ctloff: without CONTROL the compile verdict stands and the TTFT hit says INCOMPLETE" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: REPRODUCED' \"\$(V ctloff)\" && command grep -qx 'FIRST-BURST TTFT HIT: INCOMPLETE: the CONTROL arm did not run: CONTROL=off' \"\$(V ctloff)\""
e2e "$KIT" nodl FAKE_DOWNLOAD_FAIL=1; rc=$?
check "nodl: a model that did not download stops before any server, INCOMPLETE" "[ $rc = 3 ] && command grep -qF 'stopped at the model step' \"\$(V nodl)\""
e2e "$KIT" driver FAKE_DRIVER=570.10; rc=$?
check "driver: a driver older than 580 stops before the pull" \
  "[ $rc = 1 ] && command grep -qF 'older than 580' '$WORK/e2e-driver/out/STOPPED' && [ ! -e '$WORK/e2e-driver/fd/docker-calls' ]"
e2e "$KIT" digest FAKE_DIGEST=sha256:0000; rc=$?
check "digest: an image with another digest stops before it runs" \
  "[ $rc = 1 ] && command grep -qF 'is not sha256:d797' '$WORK/e2e-digest/out/STOPPED' && ! command grep -q '^run' '$WORK/e2e-digest/fd/docker-calls'"
e2e "$KIT" revision FAKE_REVISION=deadbeef; rc=$?
check "revision: an image built from another commit stops before it runs" \
  "[ $rc = 1 ] && command grep -qF \"label is 'deadbeef'\" '$WORK/e2e-revision/out/STOPPED' && ! command grep -q '^run' '$WORK/e2e-revision/fd/docker-calls'"
e2e "$KIT" pull FAKE_PULL_FAIL=1; rc=$?
check "pull: a failed pull stops and says so" "[ $rc = 1 ] && command grep -qF 'the pull failed' '$WORK/e2e-pull/out/STOPPED'"
check "the port is free after every run" "ports_free"

# ---------------------------------------------------------------- mutants of measure.sh, caught end to end
m=$(mutant gate measure.sh 's/if \[ -z "\$gate_line" \] || \[ -n "\$capture_line" \]; then/if false; then/')
e2e "$m" m-gate FAKE_SCENARIO=gatefail
mcheck "mutant: a measure.sh that sends traffic past a failed gate is caught" "[ -n \"\$(ls -A \"\$(C m-gate)/main/bursts\")\" ]"
m=$(mutant thresh measure.sh 's/TRITON_PRINT_AUTOTUNING=1 /TRITON_PRINT_AUTOTUNING=1 SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS=0 /')
e2e "$m" m-thresh
mcheck "mutant: a measure.sh that moves the server's compile threshold is caught" \
  "command grep -q SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS \"\$(C m-thresh)/main/commands.txt\""
m=$(mutant probe measure.sh '/  kv stopped probe/{n;s/  exit 3/  :/}')
e2e "$m" m-probe FAKE_NO_LISTENER=1
mcheck "mutant: a measure.sh that starts the server after a failed positive control is caught" "[ -d \"\$(C m-probe)/main\" ]"
m=$(mutant seed measure.sh 's/c1-r2:1:4:102/c1-r2:1:4:101/')
e2e "$m" m-seed
mcheck "mutant: a measure.sh whose bursts repeat a seed is caught by the plan check" "command grep -qF 'a different burst plan' \"\$(V m-seed)\""
m=$(mutant cache measure.sh 's/rm -rf "\$cache"; mkdir -p "\$cache"/mkdir -p "$cache"; touch "$cache\/stale"/')
e2e "$m" m-cache
mcheck "mutant: a measure.sh that starts on a Triton cache that is not empty is caught" "command grep -qF 'entries at the start, not 0' \"\$(V m-cache)\""
m=$(mutant warmups measure.sh 's/--warmups prefill_shapes/--warmups voice_chat/')
e2e "$m" m-warmups
mcheck "mutant: a CONTROL without SGLang's prefill warmup is caught" "! command grep -qx 'VERDICT: REPRODUCED' \"\$(V m-warmups)\" || ! command grep -q 'TTFT HIT: MEASURED' \"\$(V m-warmups)\""
m=$(mutant driver run.sh 's/\[ "\$drv" -ge 580 \]/true/')
e2e "$m" m-driver FAKE_DRIVER=570.10
mcheck "mutant: a run.sh that pulls with a driver older than 580 is caught" "command grep -q '^pull' '$WORK/e2e-m-driver/fd/docker-calls'"
m=$(mutant rev run.sh 's/\[ "\$(head -n 1 "\$OUT\/image-revision.txt")" = "\$SGLANG_SHA" \] ||/true ||/')
e2e "$m" m-rev FAKE_REVISION=deadbeef
mcheck "mutant: a run.sh that runs an image from another commit is caught" "command grep -q '^run' '$WORK/e2e-m-rev/fd/docker-calls'"
check "the port is free after the mutants" "ports_free"

# ---------------------------------------------------------------- mutants of verdict.py, each caught by the unit checks
vmut() { # NAME SED
  m=$(mutant "v-$1" verdict.py "$2")
  units "$m" "$WORK/units-$1.log"
  mcheck "mutant: verdict.py $1 is caught by the unit checks" "command grep -q '^FAIL\|Traceback' '$WORK/units-$1.log'"
}
vmut "that counts a cache hit as a compile" 's/if c\["cache_hit"\] or c\["t"\] < ready:/if c["t"] < ready:/'
vmut "that counts every kernel as Mamba2" 's/    if name in MAMBA2_KERNELS:/    if True:/'
vmut "that ignores a prefill capture beside a disabling line" 's/    if capture is not None:/    if False:/'
vmut "that passes the gate without a disabling line" 's/    if gate is None:/    if False:/'
vmut "that ignores SGLang warnings the hook missed" 's/    if lost:/    if False:/'
vmut "that does not require the hook live before ready" 's/    if not any(c\["t"\] < ready for c in compiles):/    if False:/'
vmut "that lets a skipped burst pass" 's/            missing.append(f"{e\[.label.\]}: skipped, the time ran out")/            pass/'
vmut "that lets a short burst pass" 's/if r.get("completed") != e\["prompts"\] or not isinstance(ttfts, list) or len(ttfts) != e\["prompts"\]:/if not isinstance(ttfts, list):/'
vmut "that misses a burst edge" 's/if b\["start"\] <= t <= b\["end"\]:/if b["start"] < t < b["end"]:/'
vmut "that skips the positive control" 's/if mkv.get("probe_hook") != "ok" or not/if False and not/'
vmut "that exits 0 on a failed gate" 's/return v, 4/return v, 0/'
vmut "that takes a TTFT hit from an incomplete CONTROL" 's/    if control\["status"\] != "COMPLETE":/    if False:/'
vmut "that ignores a non-empty Triton cache" 's/if kv.get("triton_cache_entries_at_start") != "0":/if False:/'
vmut "that lets one record match two warnings" 's/            pool.remove(hit)/            pass/'

# ---------------------------------------------------------------- the session: the cost print and the dirty-tree refusal
sched() { env -i PATH="$PATH" HOME="$HOME" INSTANCE_TYPE="$1" bash "$ROOT/hack/gpu-kit-session.sh" --print-schedule 2>&1; }
s2=$(sched g5.2xlarge)
check "the session prints the g5.2xlarge worst case, \$0.9696 to the 4,020 s termination deadline, under \$2.00" \
  "[ \"$s2\" = 'instance_type=g5.2xlarge harness_end_s=3600 evidence_s=3660 stop_s=3720 termination_s=4020 worst_case_usd=0.9696' ] \
   && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 2.0 else 1)' \"\${s2##*=}\""
sched g6.xlarge >"$WORK/sched-g6.out"
check "the session refuses an instance type outside g5" "command grep -qF 'is not one of the listed types' '$WORK/sched-g6.out'"
git clone -q "$ROOT" "$WORK/clone" 2>"$WORK/clone.err" || echo "FAIL could not clone HEAD: $(cat "$WORK/clone.err")" >&2
mkdir -p "$WORK/awsbin"
printf '#!/bin/bash\necho "fake aws $*" >> "%s/aws-calls"\necho "fake aws: no network here" >&2\nexit 1\n' "$WORK" >"$WORK/awsbin/aws"
chmod +x "$WORK/awsbin/aws"
session() { ( cd "$WORK/clone" && env -i PATH="$WORK/awsbin:$PATH" HOME="$HOME" SESSION_CONFIRM=yes OUT="$WORK/sess-$1" INSTANCE_TYPE=g5.2xlarge \
  bash hack/gpu-kit-session.sh docs/oss/sglang-51628/kit-r2 >"$WORK/sess-$1.log" 2>&1 ); }
check "the clone of HEAD holds the committed kit" "[ -f '$WORK/clone/docs/oss/sglang-51628/kit-r2/run.sh' ]"
echo "# edit" >>"$WORK/clone/docs/oss/sglang-51628/kit-r2/run.sh"
session edited; rc=$?
check "the session refuses an uncommitted edit to the kit, before any AWS call" \
  "[ $rc != 0 ] && command grep -qF 'SESSION REFUSED: the working tree is dirty' '$WORK/sess-edited.log' && [ ! -e '$WORK/aws-calls' ]"
git -C "$WORK/clone" checkout -q -- docs/oss/sglang-51628/kit-r2/run.sh
echo stray >"$WORK/clone/hack/stray.txt"
session untracked; rc=$?
check "the session refuses an untracked file in the tree, before any AWS call" \
  "[ $rc != 0 ] && command grep -qF 'SESSION REFUSED: the working tree is dirty' '$WORK/sess-untracked.log' && [ ! -e '$WORK/aws-calls' ]"
rm "$WORK/clone/hack/stray.txt"
# docs/ is ignored, so a stray file inside the kit is not "dirty" to git; it is also never shipped, since the session archives the commit.
echo stray >"$WORK/clone/docs/oss/sglang-51628/kit-r2/stray.txt"
check "an ignored stray file in the kit is not in what the session ships, the committed tree" \
  "! git -C '$WORK/clone' archive --format=tar HEAD:docs/oss/sglang-51628/kit-r2 | tar -t | command grep -q stray"
rm "$WORK/clone/docs/oss/sglang-51628/kit-r2/stray.txt"
session clean; rc=$?
check "a clean tree passes the dirty-tree check and stops only at the first AWS call" \
  "[ $rc != 0 ] && command grep -qF 'the account check failed' '$WORK/sess-clean.log' && ! command grep -qF 'dirty' '$WORK/sess-clean.log'"

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed" >&2; fi
[ "$failures" = 0 ]
