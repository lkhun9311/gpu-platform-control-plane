#!/usr/bin/env bash
#
# Offline checks for hack/vllm-gdn-68414-session.sh, the runner, state script and repro wrapper it ships, and its verdict, run before anything is bought.
# The EC2 lifecycle is hack/lib/spot-run.sh's, which the 58420 and 67811 tests cover; these checks cover what is new: the schedule and its cost refusal, the pins, the repro's two ways of running, BEFORE then AFTER in fresh containers, the import check, the run commands, and that only the expected combination is called "confirmed".
# The runner's whole path runs against a fake docker that executes state.sh on a fake tree, a stub torch, a fake kernel_repro.py that answers from the index.py Python imports, and a fake pytest that answers per test file.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/hack/vllm-gdn-68414-session.sh"
DIR="$ROOT/hack/vllm-gdn-68414"
R="$DIR/runner.sh"
ST="$DIR/state.sh"
V="$DIR/verdict.py"
RR="$DIR/run_repro.py"
PINS="$DIR/pins.txt"
WORK=$(mktemp -d)
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
REAL_PY=$(command -v python3)
IDX=vllm/third_party/flash_linear_attention/ops/index.py
NEWT=tests/kernels/mamba/test_fla_chunk_indices.py
CORE=tests/kernels/mamba/test_gdn_forward_core_split.py
ROCM=tests/kernels/mamba/test_gdn_rocm_layout_dispatch.py
FIXED='unwritten 0 o_err 0.0 state_err 0.0 empty_keeps_h0 True'
BUGGY='unwritten 70 o_err 2.83984375 state_err nan empty_keeps_h0 True'

check "the session, the runner and the state script parse, and the verdict and wrapper compile" \
  "bash -n '$S' && bash -n '$R' && bash -n '$ST' && python3 -m py_compile '$V' '$RR'"

# ---------------------------------------------------------------- schedule, cost and refusals
same=1
for pair in PULL_BOUND_S:PULL_S IMAGE_ID_S:IMAGE_ID_S SETUP_S:SETUP_S ASIS_S:ASIS_S CUDA_S:CUDA_S UNIT_S:UNIT_S \
  EXIST_S:EXIST_S STOP_S:STOP_S; do
  a=$(grep -m1 "^${pair%%:*}=" "$S" | cut -d= -f2); b=$(grep -m1 "^${pair#*:}=" "$R" | cut -d= -f2)
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "  ${pair%%:*}=$a in the session, ${pair#*:}=$b in the runner" >&2; same=0; }
done
check "every step bound in the session is the runner's own" "[ $same = 1 ]"
# The runner's container bounds are its step bounds' sums, the ones the session's schedule adds up.
check "the runner bounds BEFORE by setup + as-is + CUDA + stop, and AFTER by those + the new test + two existing tests" \
  "grep -qF 'state before \$(( SETUP_S + ASIS_S + CUDA_S + STOP_S ))' '$R' && grep -qF 'state after \$(( SETUP_S + ASIS_S + CUDA_S + UNIT_S + 2 * EXIST_S + STOP_S ))' '$R'"
sched=$(bash "$S" --print-schedule 2>&1)
check "the schedule is the bounds' sum ($sched)" "[ '$sched' = 'harness_end_s=3660 evidence_s=3780 stop_s=3840 termination_s=4140' ]"
worst=$(python3 -c 'print(f"{4140 / 3600 * 0.7792:.4f}")')
check "the worst case, 4,140 s at the all-in rate, is \$$worst and under \$1.50" \
  "[ \"\$(grep -m1 '^ALL_IN_RATE=' '$S' | cut -d= -f2)\" = 0.7792 ] && [ \"\$(grep -m1 '^COST_CAP_USD=' '$S' | cut -d= -f2)\" = 1.50 ] && python3 -c 'import sys; sys.exit(0 if $worst < 1.5 else 1)'"
check "the session's header states the same worst case" "grep -qF '\$0.8961, under \$1.50' '$S'"
check "the instance is a g5.xlarge with the reclaimed zone tried last" \
  "grep -qx 'INSTANCE_TYPE_FIXED=g5.xlarge' '$S' && grep -qx 'RECLAIMED_ZONES=\"ap-northeast-2a\"' '$S'"
cp "$S" "$WORK/costly.sh"; sed -i 's/^ALL_IN_RATE=.*/ALL_IN_RATE=1.40/' "$WORK/costly.sh"
check "a rate that puts the worst case at \$1.50 or more is refused, before the schedule prints" \
  "! bash '$WORK/costly.sh' --print-schedule > '$WORK/costly.out' 2>&1 && grep -qF 'is not under \$1.50' '$WORK/costly.out'"
cp "$S" "$WORK/slow.sh"; sed -i 's/^CUDA_S=.*/CUDA_S=3000/' "$WORK/slow.sh"
check "a bound that stretches the schedule past \$1.50 is refused too" "! bash '$WORK/slow.sh' --print-schedule >/dev/null 2>&1"

# A fake aws that records every call, so a refusal is shown to come before anything reaches AWS.
mkdir -p "$WORK/awsbin"
printf '#!/bin/bash\necho "aws $*" >> "%s/aws-calls"\nexit 0\n' "$WORK" > "$WORK/awsbin/aws"; chmod +x "$WORK/awsbin/aws"
refused() { : > "$WORK/aws-calls"; env -u SESSION_CONFIRM -u VLLMGDN_AMI_ID PATH="$WORK/awsbin:$PATH" OUT="$WORK/never" "$@" bash "$S" > "$WORK/refusal.out" 2>&1; }
refused env
check "without SESSION_CONFIRM=yes the session is refused and calls no AWS API" \
  "grep -q 'SESSION_CONFIRM=yes is required' '$WORK/refusal.out' && [ ! -s '$WORK/aws-calls' ] && [ ! -e '$WORK/never' ]"
refused env SESSION_CONFIRM=yes
check "without a pinned AMI ID the session is refused and calls no AWS API" \
  "grep -q 'VLLMGDN_AMI_ID is unset' '$WORK/refusal.out' && [ ! -s '$WORK/aws-calls' ]"
refused env SESSION_CONFIRM=yes VLLMGDN_AMI_ID=ami-0123456789abcdef0 VLLM_COMMIT=0000000
check "a caller who sets one of the session's own values is refused" \
  "grep -q 'VLLM_COMMIT is set' '$WORK/refusal.out' && [ ! -s '$WORK/aws-calls' ]"

# ---------------------------------------------------------------- the user-data
bash "$S" --print-user-data > "$WORK/ud.sh" 2> "$WORK/ud.err"
first_cmd=$(grep -n -v -E '^(#|$)' "$WORK/ud.sh" | sed -n '4p')
first_aws=$(grep -n -m1 'aws ' "$WORK/ud.sh" | cut -d: -f1)
check "the user-data parses, is under 16 KB, and has no placeholder left" \
  "[ -s '$WORK/ud.sh' ] && bash -n '$WORK/ud.sh' && [ \$(wc -c < '$WORK/ud.sh') -lt 16384 ] && ! grep -q _PLACEHOLDER '$WORK/ud.sh'"
check "the instance refuses a driver older than 580 before the pull" \
  "grep -q 'PREFLIGHT FAILED: driver' '$WORK/ud.sh' && [ \"\$(grep -n 'PREFLIGHT FAILED: driver' '$WORK/ud.sh' | cut -d: -f1)\" -lt \"\$(grep -n 'runner.sh' '$WORK/ud.sh' | head -1 | cut -d: -f1)\" ]"
check "the instance arms its 3,840 s backstop before anything else can fail ($first_cmd)" \
  "[ '${first_cmd#*:}' = '( sleep 3840; shutdown -h now ) &' ] && [ '${first_cmd%%:*}' -lt '$first_aws' ]"
check "the precise backstop counts from LaunchTime, and the runner ends at LaunchTime + 3,660 s" \
  "grep -q '( sleep \$(( L + 3840 - ' '$WORK/ud.sh' && grep -q 'HE=\$(( L + 3660 ))' '$WORK/ud.sh' && grep -q 'EV=\$(( L + 3780 ))' '$WORK/ud.sh'"
check "the instance runs this session's runner and returns this session's records" \
  "grep -q 'bash /opt/gdn/in/runner.sh /opt/gdn/in /src/gdn-run/sweep' '$WORK/ud.sh' && ! grep -qE 'tp-run|/opt/tp/' '$WORK/ud.sh'"

# ---------------------------------------------------------------- pins
check "the session pins the diff and the repro at their own sha256, and the state script holds the same repro pin" \
  "[ \"\$(sha256sum '$DIR/fix.diff' | cut -d' ' -f1)\" = \"\$(grep -m1 '^FIX_DIFF_SHA256=' '$S' | cut -d= -f2)\" ] && [ \"\$(sha256sum '$DIR/kernel_repro.py' | cut -d' ' -f1)\" = \"\$(grep -m1 '^REPRO_SHA256=' '$S' | cut -d= -f2)\" ] && [ \"\$(grep -m1 '^REPRO_SHA256=' '$ST' | cut -d= -f2)\" = \"\$(grep -m1 '^REPRO_SHA256=' '$S' | cut -d= -f2)\" ]"
check "the repro is the reporter's script as the runtime session recorded it" \
  "[ \"\$(sha256sum '$DIR/kernel_repro.py' | cut -d' ' -f1)\" = 766ccd795b2e1f71ba9c48dc99e22deec8f17047467b70866acf7378310af3af ] && grep -q '^print(\"unwritten\"' '$DIR/kernel_repro.py' && ! grep -q 'cuda' '$DIR/kernel_repro.py'"
check "the session ships the wrapper, the repro and the diff in its inputs" \
  "grep -qF 'cp \"\$RUNNER\" \"\$STATE\" \"\$PINS\" \"\$FIX_DIFF\" \"\$REPRO\" \"\$RUN_REPRO\" \"\$OUT/in/\"' '$S'"
paths=$( { grep -h '^diff --git' "$DIR/fix.diff" | awk '{print substr($3,3)}'; echo "$CORE"; echo "$ROCM"; } | sort -u)
pinok=1
for st in base before after; do
  [ "$(awk -v s=$st '$1 == s {print $3}' "$PINS" | sort | paste -sd' ')" = "$(paste -sd' ' <<<"$paths")" ] || pinok=0
done
check "pins.txt names every file the diff touches and both existing tests, once per state" "[ $pinok = 1 ]"
pin() { awk -v s="$1" -v p="$2" '$1 == s && $3 == p {print $2}' "$PINS"; }
check "BEFORE is the commit unpatched: its pins are the base pins, and the new test is absent from both" \
  "[ \"\$(awk '\$1 == \"base\" {print \$2, \$3}' '$PINS')\" = \"\$(awk '\$1 == \"before\" {print \$2, \$3}' '$PINS')\" ] && [ \"\$(pin base $NEWT)\" = absent ]"
check "the fix changes index.py and adds the new test, and leaves the two existing tests at the commit's" \
  "[ \"\$(pin after $IDX)\" != \"\$(pin base $IDX)\" ] && [ \"\$(pin after $NEWT)\" != absent ] && [ \"\$(pin after $CORE)\" = \"\$(pin base $CORE)\" ] && [ \"\$(pin after $ROCM)\" = \"\$(pin base $ROCM)\" ]"
fixl=$(grep -m1 "^FIX_LINE=" "$ST" | cut -d"'" -f2); bugl=$(grep -m1 "^BUG_LINE=" "$ST" | cut -d"'" -f2)
check "the state's fix line is what fix.diff adds and its bug line is what fix.diff removes" \
  "[ -n '$fixl' ] && [ -n '$bugl' ] && grep -qF -- '+    $fixl' '$DIR/fix.diff' && grep -qF -- '-    chunk_indices = torch.stack([$bugl' '$DIR/fix.diff'"
check "the verdict judges the index.py the state script imports from the image's site-packages" \
  "grep -qF 'INDEX = \"/usr/local/lib/python3.12/dist-packages/$IDX\"' '$V' && grep -qx 'SITE=/usr/local/lib/python3.12/dist-packages' '$ST' && grep -qx 'INDEX_MOD=vllm.third_party.flash_linear_attention.ops.index' '$ST'"
check "the runner, the verdict and the session name the same image digest and commit" \
  "[ \"\$(grep -ho 'sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed' '$R' '$V' | wc -l)\" -ge 3 ] && grep -qx 'VLLM_COMMIT=8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd' '$R' && grep -qF 'VLLM_COMMIT = \"8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd\"' '$V'"
# The pins are rederived from a vLLM checkout when one is given, since only that proves them the commit's.
if [ -n "${VLLM_SRC:-}" ]; then
  mkdir -p "$WORK/rederive"
  for st in base after; do
    for p in $paths; do
      if git -C "$VLLM_SRC" cat-file -e "8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd:$p" 2>/dev/null; then
        mkdir -p "$WORK/rederive/$st/$(dirname "$p")"; git -C "$VLLM_SRC" show "8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd:$p" > "$WORK/rederive/$st/$p"
      fi
    done
  done
  (cd "$WORK/rederive/after" && git apply "$DIR/fix.diff")
  for st in base before after; do
    for p in $paths; do
      f="$WORK/rederive/$([ $st = after ] && echo after || echo base)/$p"
      if [ -e "$f" ]; then echo "$st $(sha256sum "$f" | cut -d' ' -f1) $p"; else echo "$st absent $p"; fi
    done
  done > "$WORK/rederived"
  check "pins.txt is what fix.diff makes of 8700cc9ba0 in $VLLM_SRC" "diff -q <(sort '$PINS') <(sort '$WORK/rederived') >/dev/null"
else
  echo "skip pins.txt against a vLLM checkout (set VLLM_SRC to rederive them)"
fi

# ---------------------------------------------------------------- the wrapper on its own, against a stub torch
# The stub records the default device, and the fake repro reports the device it saw, so the order of the two is shown.
mkdir -p "$WORK/stubs/torch"
cat > "$WORK/stubs/torch/__init__.py" <<'EOF'
import os
_default = "cuda" if os.environ.get("FAKE_ASIS_WORKS") else "cpu"
def set_default_device(d):
    global _default
    _default = d
EOF
mkdir -p "$WORK/wr"
printf 'import sys, torch\nprint("device", torch._default, "name", __name__, "argv0", sys.argv[0])\n' > "$WORK/wr/repro.py"
wsha=$(sha256sum "$WORK/wr/repro.py" | cut -d' ' -f1)
PYTHONPATH="$WORK/stubs" "$REAL_PY" "$RR" "$WORK/wr/repro.py" "$wsha" > "$WORK/wr/out" 2>&1; wrc=$?
check "the wrapper checks the sha256, sets CUDA as the default before the file runs, and runs it as __main__" \
  "[ $wrc = 0 ] && grep -qx 'REPRO_SHA256=$wsha' '$WORK/wr/out' && grep -q '^device cuda name __main__ ' '$WORK/wr/out' && grep -qx 'REPRO_INDEX_FILE=not-imported' '$WORK/wr/out'"
PYTHONPATH="$WORK/stubs" "$REAL_PY" "$RR" "$WORK/wr/repro.py" "0000" > "$WORK/wr/bad" 2>&1; wrc=$?
check "the wrapper refuses a file that is not the pinned one, before running it" \
  "[ $wrc = 3 ] && grep -q '^REPRO_SHA_MISMATCH ' '$WORK/wr/bad' && ! grep -q '^device' '$WORK/wr/bad'"

# ---------------------------------------------------------------- the runner's whole path, against fakes
# A fake tree with the same shape: the package's index.py, the two existing tests, and a diff made the way the real one is.
mkdir -p "$WORK/pristine/site/vllm/third_party/flash_linear_attention/ops" "$WORK/pristine/w/tests/kernels/mamba" "$WORK/mk"
for d in vllm vllm/third_party vllm/third_party/flash_linear_attention vllm/third_party/flash_linear_attention/ops; do
  : > "$WORK/pristine/site/$d/__init__.py"
done
printf 'def prepare_chunk_indices(indices):\n    chunk_indices = torch.stack([%s, indices], 1)\n' "$bugl" > "$WORK/pristine/site/$IDX"
echo "core split" > "$WORK/pristine/w/$CORE"; echo "rocm layout" > "$WORK/pristine/w/$ROCM"
mkdiff() { # mkdiff OUT CMD...: the diff from the pristine files to what CMD leaves in $WORK/mk/t
  rm -rf "$WORK/mk/t"; mkdir -p "$WORK/mk/t"; cp -r "$WORK/pristine/site/vllm" "$WORK/pristine/w/tests" "$WORK/mk/t/"
  (cd "$WORK/mk/t" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && "${@:2}" && git add -A && git diff --cached > "$1")
}
mkdiff "$WORK/fix.diff" sh -c "printf 'def test_x():\n    pass\n' > $NEWT && sed -i 's/    chunk_indices = torch.stack.*/    $fixl\n        indices)\n    chunk_indices = torch.stack([seq_ids, indices], 1)/' $IDX"
mkpins() {
  local st
  : > "$WORK/in/pins.txt"
  for st in base before after; do
    rm -rf "$WORK/mk/p"; mkdir -p "$WORK/mk/p"; cp -r "$WORK/pristine/site/vllm" "$WORK/pristine/w/tests" "$WORK/mk/p/"
    # The fix-already-in-the-image case pins a tree the fix cannot apply to, so its refusal goes to a log, not the screen.
    [ "$st" != after ] || (cd "$WORK/mk/p" && git apply "$WORK/in/fix.diff") 2>>"$WORK/mkpins.err"
    for p in "$IDX" "$NEWT" "$CORE" "$ROCM"; do
      if [ -e "$WORK/mk/p/$p" ]; then echo "$st $(sha256sum "$WORK/mk/p/$p" | cut -d' ' -f1) $p"; else echo "$st absent $p"; fi
    done >> "$WORK/in/pins.txt"
  done
}
mkdir -p "$WORK/in"
cp "$WORK/fix.diff" "$WORK/in/fix.diff"; cp "$RR" "$WORK/in/run_repro.py"
mkpins
# The fake repro answers from the index.py Python imports, and fails as Triton does when the default device is the CPU.
cat > "$WORK/in/kernel_repro.py" <<EOF
import os, torch
import vllm.third_party.flash_linear_attention.ops.index as m
if torch._default != "cuda":
    raise ValueError("Pointer argument (at 0) cannot be accessed from Triton (cpu tensor?)")
if os.environ.get("FAKE_NO_BUG"):
    print("$FIXED")
elif "$fixl" in open(m.__file__).read():
    print(os.environ.get("FAKE_AFTER_LINE") or "$FIXED")
else:
    print("$BUGGY")
EOF
FAKE_REPRO_SHA=$(sha256sum "$WORK/in/kernel_repro.py" | cut -d' ' -f1)
# The state script with its container paths and its repro pin moved onto the fake tree; nothing else in it changes.
sed -e "s|^SITE=.*|SITE=$WORK/site|" -e "s|^W=.*|W=$WORK/w|" -e "s|/in/|$WORK/in/|g" -e "s|^O=/out/|O=$WORK/out/|" \
  -e "s|/tmp/vllm-wheel.sha256|$WORK/wheel.sha256|" -e "s|^REPRO_SHA256=.*|REPRO_SHA256=$FAKE_REPRO_SHA|" "$ST" > "$WORK/in/state.sh"
echo "sha256:abc  vllm-0.0.0-cp38-abi3-linux_x86_64.whl" > "$WORK/wheel.sha256"
check "the moved state script still reads every container path from the fake tree" \
  "! grep -nE '/usr/local/lib|/vllm-workspace|[ \"=]/in/|[ \"=]/out/' '$WORK/in/state.sh' | grep -v '^[0-9]*:#'"

sed "s|/opt/gdn/|$WORK/opt/|g" "$R" > "$WORK/runner.sh"
mkfakes() {
  local bin="$WORK/bin"
  rm -rf "$bin" "$WORK/calls" "$WORK/site" "$WORK/w"; mkdir -p "$bin"
  cat > "$bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$WORK/calls"
case "$1" in
  pull) exit 0 ;;
  image) echo "[\"public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed\"] ${FAKE_REVISION:-8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd}" ;;
  run)
    if printf '%s\n' "$@" | grep -qx /in/state.sh; then
      # A fresh container: the image's tree as built, unless the fake is told to leave the last state's edits.
      if [ -z "${FAKE_STALE:-}" ] || [ ! -d "$WORK/site" ]; then
        rm -rf "$WORK/site" "$WORK/w"; cp -r "$WORK/pristine/site" "$WORK/site"; cp -r "$WORK/pristine/w" "$WORK/w"
      fi
      [ -z "${FAKE_IMAGE_DRIFT:-}" ] || echo "# drift" >> "$WORK/site/vllm/third_party/flash_linear_attention/ops/index.py"
      args=$(printf '%s\n' "$@" | sed -n '/^\/in\/state.sh$/,$p' | tail -n +2)
      PYTHONPATH="$WORK/site:$WORK/stubs" bash "$WORK/in/state.sh" $args; exit $?
    fi
    printf '%s\n' "$@" | grep -qx cat && { cat "$WORK/wheel.sha256"; exit 0; }
    exit 1 ;;
  ps) [ -z "${FAKE_PS_FAIL:-}" ] || exit 1 ;;
  rm) exit 0 ;;
esac
EOF
  # python3 -m pytest answers per file, as the real tests would on an sm_86 GPU; anything else is the real interpreter.
  cat > "$bin/python3" <<EOF
#!/bin/bash
if [ "\$1 \$2" = "-m pytest" ]; then
  echo "pytest \$*" >> "$WORK/calls"
  x=""; for a in "\$@"; do case \$a in --junitxml=*) x=\${a#--junitxml=} ;; esac; done
  [ -z "\${FAKE_PYTEST_TIMEOUT:-}" ] || exit 124
  lf=\$($REAL_PY -c 'import vllm.third_party.flash_linear_attention.ops.index as m; print(m.__file__)')
  case "\$*" in
    *test_fla_chunk_indices.py*)
      if [ -z "\${FAKE_UNIT_FAIL:-}" ] && grep -qF '$fixl' "\$lf"; then
        { echo '<testsuites><testsuite>'
          for i in 0 1 2 3 4; do echo "<testcase classname=\"t\" name=\"test_chunk_indices_keep_ids_of_empty_sequences[seq_lens\$i]\"/>"; done
          echo '</testsuite></testsuites>'; } > "\$x"
        echo "==== 5 passed in 1.00s ===="; exit 0
      fi
      echo '<testsuites><testsuite><testcase classname="t" name="test_chunk_indices_keep_ids_of_empty_sequences[seq_lens0]"><failure message="assert [[0, 0], [1, 0]] == [[0, 0], [2, 0]]">E</failure></testcase></testsuite></testsuites>' > "\$x"
      echo "==== 1 failed in 1.00s ===="; exit 1 ;;
    *test_gdn_forward_core_split.py*)
      msg="GDN _forward_core split test uses the CuteDSL prefill backend (requires CUDA SM10x)."
      [ -z "\${FAKE_CORE_IMPORT_SKIP:-}" ] || msg="could not import 'cutlass': No module named 'cutlass'"
      echo "<testsuites><testsuite><testcase classname=\"\" name=\"tests.kernels.mamba.test_gdn_forward_core_split\"><skipped type=\"pytest.skip\" message=\"\$msg\">x</skipped></testcase></testsuite></testsuites>" > "\$x"
      echo "==== 1 skipped in 1.00s ===="; exit 0 ;;
    *test_gdn_rocm_layout_dispatch.py*)
      if [ -n "\${FAKE_ROCM_FAIL:-}" ]; then
        echo '<testsuites><testsuite><testcase classname="t" name="test_pure_decode_takes_the_fast_path[True]"><failure message="boom">E</failure></testcase></testsuite></testsuites>' > "\$x"
        echo "==== 1 failed in 1.00s ===="; exit 1
      fi
      { echo '<testsuites><testsuite>'
        for i in 1 2 3; do echo "<testcase classname=\"t\" name=\"test_pure_decode_takes_the_fast_path[\$i]\"><skipped type=\"pytest.skip\" message=\"ROCm-specific tests\">x</skipped></testcase>"; done
        echo '</testsuite></testsuites>'; } > "\$x"
      echo "==== 3 skipped in 1.00s ===="; exit 0 ;;
  esac
  exit 4
fi
case "\$1" in *kernel_repro.py|*run_repro.py) echo "python3 \$*" >> "$WORK/calls" ;; esac
exec $REAL_PY "\$@"
EOF
  printf '#!/bin/bash\necho "$*" >> "%s/calls"\n' "$WORK" > "$bin/nvidia-smi"
  chmod +x "$bin"/*
}
runfake() {
  mkfakes; rm -rf "$WORK/out"; mkdir -p "$WORK/out"
  env WORK="$WORK" PATH="$WORK/bin:$PATH" "${@:2}" \
    timeout 120 bash "$WORK/runner.sh" "$WORK/in" "$WORK/out" $(( $(date +%s) + 100000 )) > "$WORK/runner-$1.out" 2>&1
  echo $? > "$WORK/rc-$1"
  python3 "$V" "$WORK/out" "$(sha256sum "$WORK/in/fix.diff" | cut -d' ' -f1)" "$FAKE_REPRO_SHA" > "$WORK/verdict-$1.txt" 2>&1
  echo $? > "$WORK/vrc-$1"
  cp -r "$WORK/out" "$WORK/out-$1"; cp "$WORK/calls" "$WORK/out-$1/calls"
}
# The verdict on the fake run reads the fake tree's index path, so it is judged with that path standing in.
sed "s|^INDEX = .*|INDEX = \"$WORK/site/$IDX\"|" "$V" > "$WORK/verdict-local.py"
# Both print the verdict whatever its exit status, which pipefail would otherwise turn into the pipeline's.
fake_verdict() { python3 "$WORK/verdict-local.py" "$WORK/out-$1" "$(sha256sum "$WORK/in/fix.diff" | cut -d' ' -f1)" "$FAKE_REPRO_SHA"; true; }

runfake good env
check "the runner does BEFORE, then AFTER, and ends" \
  "[ \"\$(cat '$WORK/rc-good')\" = 0 ] && grep -q 'both states done' '$WORK/out-good/steps.log' && [ \"\$(grep -n 'state before: start\\|state after: start' '$WORK/out-good/steps.log' | cut -d' ' -f3 | paste -sd' ')\" = 'before: after:' ]"
check "each state runs in its own container, with the GPU, and BEFORE applies nothing while AFTER applies the fix" \
  "[ \"\$(grep -o 'run --rm --name gdn-[a-z]* --gpus all' '$WORK/calls' | paste -sd' ')\" = 'run --rm --name gdn-before --gpus all run --rm --name gdn-after --gpus all' ] && grep -qx 'diff_sha256=none' '$WORK/out-good/before/state.txt' && grep -qx 'apply=none' '$WORK/out-good/before/state.txt' && grep -qx \"diff_sha256=\$(sha256sum '$WORK/in/fix.diff' | cut -d' ' -f1)\" '$WORK/out-good/after/state.txt' && grep -qx 'apply=ok' '$WORK/out-good/after/state.txt'"
check "the repro runs as-is first, then through the wrapper with its pinned sha256, in each state" \
  "[ \"\$(grep '^python3 ' '$WORK/calls' | paste -sd'|')\" = \"python3 $WORK/in/kernel_repro.py|python3 $WORK/in/run_repro.py $WORK/in/kernel_repro.py $FAKE_REPRO_SHA|python3 $WORK/in/kernel_repro.py|python3 $WORK/in/run_repro.py $WORK/in/kernel_repro.py $FAKE_REPRO_SHA\" ] && grep -q 'cpu tensor' '$WORK/out-good/before/repro-asis.log' && grep -qx 'repro_mode=cuda-default' '$WORK/out-good/before/state.txt' && grep -qx 'repro_mode=cuda-default' '$WORK/out-good/after/state.txt'"
check "BEFORE records the buggy line and AFTER the fixed one" \
  "grep -qx 'repro_line=$BUGGY' '$WORK/out-good/before/state.txt' && grep -qx 'repro_line=$FIXED' '$WORK/out-good/after/state.txt'"
check "BEFORE runs no pytest, and AFTER runs the new test then the two existing tests, one file each" \
  "[ \"\$(grep '^pytest' '$WORK/calls' | sed 's/ --junitxml=.*//' | paste -sd'|')\" = 'pytest -m pytest $NEWT -rA -p no:cacheprovider|pytest -m pytest $CORE -rA -p no:cacheprovider|pytest -m pytest $ROCM -rA -p no:cacheprovider' ]"
check "the import check records the imported index.py, with the bug line and no fix BEFORE and the reverse AFTER" \
  "grep -qx 'index_file=$WORK/site/$IDX' '$WORK/out-good/before/state.txt' && grep -qx 'fix_grep_rc=1' '$WORK/out-good/before/state.txt' && grep -qx 'bug_grep_rc=0' '$WORK/out-good/before/state.txt' && grep -qx 'fix_grep_rc=0' '$WORK/out-good/after/state.txt' && grep -qx 'bug_grep_rc=1' '$WORK/out-good/after/state.txt' && grep -qx 'repro_index_file=$WORK/site/$IDX' '$WORK/out-good/after/state.txt'"
check "the fake run, with the bug BEFORE and the fixed line and tests AFTER, is confirmed with the skip reasons recorded" \
  "fake_verdict good | grep -qx 'verdict=confirmed' && fake_verdict good | grep -qx 'after_core_split=skipped(GDN _forward_core split test uses the CuteDSL prefill backend (requires CUDA SM10x).)' && fake_verdict good | grep -qx 'after_rocm_layout=skipped(ROCm-specific tests)' && fake_verdict good | grep -qx 'repro_mode=cuda-default,cuda-default'"
check "the real verdict refuses the fake run, whose index.py is not the image's path" \
  "grep -q '^import_check=wrong-file-before' '$WORK/verdict-good.txt' && [ \"\$(cat '$WORK/vrc-good')\" = 2 ]"

runfake asis env FAKE_ASIS_WORKS=1
check "a repro that answers as-is is not rerun through the wrapper, and the mode says so" \
  "! grep -q 'run_repro.py' '$WORK/out-asis/calls' && grep -qx 'repro_mode=asis' '$WORK/out-asis/before/state.txt' && fake_verdict asis | grep -qx 'verdict=confirmed'"
runfake drift env FAKE_IMAGE_DRIFT=1
check "an image whose index.py is not the commit's is refused before anything runs" \
  "grep -qx 'base_identity=bad' '$WORK/out-drift/before/state.txt' && ! grep -q '^repro_line=' '$WORK/out-drift/before/state.txt' && [ \"\$(cat '$WORK/rc-drift')\" = 2 ] && ! grep -q 'gdn-after' '$WORK/out-drift/calls' && fake_verdict drift | grep -qx 'verdict=void-identity'"
runfake badrev env FAKE_REVISION=deadbeef
check "an image whose label is not 8700cc9ba0 is refused before any state runs" \
  "grep -q 'IMAGE IDENTITY FAILED' '$WORK/out-badrev/steps.log' && ! grep -q 'gdn-before' '$WORK/out-badrev/calls'"
runfake nobug env FAKE_NO_BUG=1
check "a BEFORE that does not show the bug still runs AFTER, and is named, not confirmed" \
  "grep -q 'both states done' '$WORK/out-nobug/steps.log' && fake_verdict nobug | grep -qx 'before_repro=no-bug' && fake_verdict nobug | grep -qx 'verdict=before-did-not-reproduce'"
runfake inexact env FAKE_AFTER_LINE='unwritten 0 o_err 0.0009765625 state_err 1e-06 empty_keeps_h0 True'
check "an AFTER that is fixed but not bit-exact is named after-fixed-inexact" \
  "fake_verdict inexact | grep -qx 'after_repro=fixed-inexact' && fake_verdict inexact | grep -qx 'verdict=after-fixed-inexact'"
runfake unitfail env FAKE_UNIT_FAIL=1
check "an AFTER whose new test fails is named" \
  "grep -qx 'unit_rc=1' '$WORK/out-unitfail/after/state.txt' && fake_verdict unitfail | grep -qx 'verdict=after-unit-test-not-passed'"
runfake rocmfail env FAKE_ROCM_FAIL=1
check "an existing test that ran and failed is named" \
  "fake_verdict rocmfail | grep -q '^after_rocm_layout=not-passed' && fake_verdict rocmfail | grep -qx 'verdict=after-existing-tests-not-passed'"
runfake coreimport env FAKE_CORE_IMPORT_SKIP=1
check "an existing test skipped for a reason other than its own is named, not passed" \
  "fake_verdict coreimport | grep -q '^after_core_split=skipped-unexpectedly(could not import' && fake_verdict coreimport | grep -qx 'verdict=after-existing-tests-not-passed'"
runfake timeout env FAKE_PYTEST_TIMEOUT=1
check "a pytest that timed out is recorded with its 124 and not confirmed" \
  "grep -qx 'unit_rc=124' '$WORK/out-timeout/after/state.txt' && ! fake_verdict timeout | grep -qx 'verdict=confirmed'"
runfake psfail env FAKE_PS_FAIL=1
check "a container whose removal cannot be shown stops the run" \
  "grep -q 'state before: container was not shown removed' '$WORK/out-psfail/steps.log' && ! grep -q 'gdn-after' '$WORK/out-psfail/calls'"
# A repro other than the pinned one: the state script refuses it before applying anything or running it.
cp "$WORK/in/kernel_repro.py" "$WORK/kernel_repro.keep"; echo "# edited" >> "$WORK/in/kernel_repro.py"
runfake edited env
check "a kernel_repro.py that is not the pinned one is refused before it runs" \
  "grep -q 'kernel_repro.py is not the pinned' '$WORK/out-edited/before/steps.log' && ! grep -q '^python3 .*kernel_repro.py' '$WORK/out-edited/calls' && fake_verdict edited | grep -qx 'verdict=void-identity'"
cp "$WORK/kernel_repro.keep" "$WORK/in/kernel_repro.py"
# The fix already in the image: BEFORE then has no bug, and the report must lead with the import check.
cp -r "$WORK/pristine" "$WORK/pristine.keep"
cp "$WORK/mk/t/$IDX" "$WORK/pristine/site/$IDX"
mkpins
runfake fixedbefore env
check "a BEFORE that imported the fix is void, and the verdict's first line is the import check that says why" \
  "[ \"\$(fake_verdict fixedbefore | head -1)\" = 'import_check=lines-before(fix_grep_rc=0,bug_grep_rc=1)' ] && fake_verdict fixedbefore | grep -qx 'before_repro=no-bug' && ! fake_verdict fixedbefore | grep -qx 'verdict=confirmed'"
rm -rf "$WORK/pristine"; mv "$WORK/pristine.keep" "$WORK/pristine"; mkpins

# ---------------------------------------------------------------- the verdict, case by case
IX=/usr/local/lib/python3.12/dist-packages/$IDX
pass_unit() { local i; echo '<testsuites><testsuite>'
  for i in 0 1 2 3 4; do echo "<testcase classname=\"t\" name=\"test_chunk_indices_keep_ids_of_empty_sequences[seq_lens$i]\"/>"; done
  echo '</testsuite></testsuites>'; }
fail_unit() { echo '<testsuites><testsuite><testcase classname="t" name="test_chunk_indices_keep_ids_of_empty_sequences[seq_lens0]"><failure message="x">E</failure></testcase></testsuite></testsuites>'; }
skip_xml() { echo "<testsuites><testsuite><testcase classname=\"t\" name=\"$1\"><skipped type=\"pytest.skip\" message=\"$2\">x</skipped></testcase></testsuite></testsuites>"; }
case_dir() { # case_dir NAME: writes a confirmed run that each case mutates
  local d="$WORK/vc/$1"; rm -rf "$d"; mkdir -p "$d/before" "$d/after"
  printf 'started=100\ndiff_sha256=none\nrepro_sha256=REPRO\nbase_identity=ok\napply=none\napplied_identity=ok\nindex_file=%s\nfix_grep_rc=1\nbug_grep_rc=0\nrepro_asis_rc=1\nrepro_cuda_rc=0\nrepro_mode=cuda-default\nrepro_index_file=%s\nrepro_line=%s\nended=200\n' "$IX" "$IX" "$BUGGY" > "$d/before/state.txt"
  printf 'started=300\ndiff_sha256=FIX\nrepro_sha256=REPRO\nbase_identity=ok\napply=ok\napplied_identity=ok\nindex_file=%s\nfix_grep_rc=0\nbug_grep_rc=1\nrepro_asis_rc=1\nrepro_cuda_rc=0\nrepro_mode=cuda-default\nrepro_index_file=%s\nrepro_line=%s\nunit_rc=0\ncore_split_rc=0\nrocm_layout_rc=0\nended=900\n' "$IX" "$IX" "$FIXED" > "$d/after/state.txt"
  pass_unit > "$d/after/unit.xml"
  skip_xml tests.kernels.mamba.test_gdn_forward_core_split "GDN _forward_core split test uses the CuteDSL prefill backend (requires CUDA SM10x)." > "$d/after/core_split.xml"
  skip_xml "test_pure_decode_takes_the_fast_path[True]" "ROCm-specific tests" > "$d/after/rocm_layout.xml"
  echo '["public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed"] 8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd' > "$d/image-identity.txt"
  echo "abc123  vllm.whl" > "$d/wheel-sha256.txt"
  echo "$d"
}
vd() { python3 "$V" "$1" FIX REPRO; true; }
vdrc() { python3 "$V" "$1" FIX REPRO > /dev/null; }
d=$(case_dir good)
check "the verdict confirms the bug BEFORE, the exact fixed line AFTER, and the tests" \
  "vd '$d' | grep -qx 'verdict=confirmed' && vdrc '$d'"
check "the verdict's first line is the import check" "[ \"\$(vd '$d' | head -1)\" = 'import_check=ok' ]"
named() { # named VERDICT DESCRIPTION EDIT: a confirmed run with EDIT applied gets VERDICT, and exits non-zero
  local d; d=$(case_dir "x$RANDOM$RANDOM"); (cd "$d" && eval "$3")
  check "$2 -> $1" "vd '$d' | grep -qx 'verdict=$1' && ! vdrc '$d'"
}
named before-did-not-reproduce "BEFORE printed the fixed line" "sed -i 's/^repro_line=.*/repro_line=$FIXED/' before/state.txt"
named before-did-not-reproduce "BEFORE left 69 rows unwritten" "sed -i 's/^repro_line=unwritten 70/repro_line=unwritten 69/' before/state.txt"
named before-did-not-reproduce "BEFORE's state error was finite" "sed -i 's/state_err nan/state_err 0.5/' before/state.txt"
named before-did-not-reproduce "BEFORE printed no result" "sed -i 's/^repro_line=.*/repro_line=/' before/state.txt"
named after-not-fixed "AFTER still left rows unwritten" "sed -i 's/^repro_line=.*/repro_line=$BUGGY/' after/state.txt"
named after-not-fixed "AFTER printed no result" "sed -i 's/^repro_line=.*/repro_line=/' after/state.txt"
named after-not-fixed "AFTER overwrote the empty sequence's state" "sed -i 's/empty_keeps_h0 True/empty_keeps_h0 False/' after/state.txt"
named after-fixed-inexact "AFTER was off by a rounding error" "sed -i 's/o_err 0.0 /o_err 0.0009765625 /' after/state.txt"
named void-identity "AFTER is missing" "rm -r after"
named after-unit-test-not-passed "the new test failed" "fail_unit > after/unit.xml; sed -i 's/^unit_rc=0/unit_rc=1/' after/state.txt"
named after-unit-test-not-passed "the new test ran four cases" "pass_unit | grep -v 'seq_lens4' > after/unit.xml"
named after-unit-test-not-passed "the new test's five cases are one name repeated" "sed -i 's/seq_lens[0-9]/seq_lens0/' after/unit.xml"
named after-unit-test-not-passed "the new test's junit is missing" "rm after/unit.xml"
named after-unit-test-not-passed "the new test timed out" "sed -i 's/^unit_rc=0/unit_rc=124/' after/state.txt"
named after-existing-tests-not-passed "the core split test skipped on an import error" "skip_xml m \"could not import 'x'\" > after/core_split.xml"
named after-existing-tests-not-passed "the ROCm test failed" "sed -i 's/^rocm_layout_rc=0/rocm_layout_rc=1/' after/state.txt"
named after-existing-tests-not-passed "the core split test was not run" "sed -i '/^core_split_rc=/d' after/state.txt"
named void-import-check "BEFORE imported index.py from somewhere else" "sed -i 's|^index_file=.*|index_file=/vllm-workspace/vllm/x.py|' before/state.txt"
named void-import-check "AFTER imported index.py from somewhere else" "sed -i 's|^index_file=.*|index_file=/vllm-workspace/vllm/x.py|' after/state.txt"
named void-import-check "the wrapper's own process imported another index.py AFTER" "sed -i 's|^repro_index_file=.*|repro_index_file=not-imported|' after/state.txt"
named void-import-check "the fix line was in index.py BEFORE" "sed -i 's/^fix_grep_rc=1/fix_grep_rc=0/' before/state.txt"
named void-import-check "the bug line was still in index.py AFTER" "sed -i 's/^bug_grep_rc=1/bug_grep_rc=0/' after/state.txt"
named void-import-check "the grep could not read index.py" "sed -i 's/^fix_grep_rc=0/fix_grep_rc=2/' after/state.txt"
named repro-mode-differs "BEFORE answered as-is and AFTER through the wrapper" "sed -i 's/^repro_mode=.*/repro_mode=asis/' before/state.txt"
named void-identity "AFTER applied another diff" "sed -i 's/^diff_sha256=FIX/diff_sha256=OTHER/' after/state.txt"
named void-identity "BEFORE applied a diff" "sed -i 's/^apply=none/apply=ok/' before/state.txt"
named void-identity "the repro was another file" "sed -i 's/^repro_sha256=REPRO/repro_sha256=OTHER/' before/state.txt"
named void-identity "the image's files were not the commit's" "sed -i 's/^base_identity=ok/base_identity=bad/' after/state.txt"
named void-identity "the fix did not apply to the pinned result" "sed -i 's/^applied_identity=ok/applied_identity=bad/' after/state.txt"
named void-identity "AFTER started before BEFORE ended" "sed -i 's/^started=300/started=150/' after/state.txt"
named void-identity "the image identity record is missing" "rm image-identity.txt"
named void-identity "the image was built from another commit" "sed -i 's/ 8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd\$/ 0000000000000000000000000000000000000000/' image-identity.txt"
named void-identity "the wheel's hash is empty" ": > wheel-sha256.txt"
d=$(case_dir ran); (cd "$d" && echo '<testsuites><testsuite><testcase classname="t" name="test_a"/></testsuite></testsuites>' > after/rocm_layout.xml)
check "an existing test that ran and passed counts as passed" "vd '$d' | grep -qx 'after_rocm_layout=passed(1p,0s)' && vd '$d' | grep -qx 'verdict=confirmed'"

if [[ $failures -ne 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
