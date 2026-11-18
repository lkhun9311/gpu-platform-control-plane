#!/usr/bin/env bash
#
# Offline checks for hack/vllm-tpot-session.sh, the runner and state script it ships, and its verdict, run before anything
# is bought.
# The EC2 lifecycle is hack/lib/spot-run.sh's, which the 58420 and 67811 tests cover; these checks cover what is new:
# the schedule and its cost refusal, the user-data's backstop, BEFORE then AFTER in fresh containers, the import check,
# and that a failing BEFORE with a passing AFTER is the only outcome called "confirmed".
# The runner's whole path runs against a fake docker that executes state.sh on a fake tree, and a fake pytest that fails
# exactly when the imported loggers.py lacks the fix line, so a defect in a later step shows here rather than on a card.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/hack/vllm-tpot-session.sh"
R="$ROOT/hack/vllm-tpot/runner.sh"
ST="$ROOT/hack/vllm-tpot/state.sh"
V="$ROOT/hack/vllm-tpot/verdict.py"
PINS="$ROOT/hack/vllm-tpot/pins.txt"
WORK=$(mktemp -d)
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
REAL_PY=$(command -v python3)

check "the session, the runner and the state script parse, and the verdict compiles" \
  "bash -n '$S' && bash -n '$R' && bash -n '$ST' && python3 -m py_compile '$V'"

# ---------------------------------------------------------------- schedule, cost and refusals
same=1
for pair in PULL_BOUND_S:PULL_S IMAGE_ID_S:IMAGE_ID_S MODEL_BOUND_S:MODEL_S SETUP_S:SETUP_S BEFORE_TEST_S:BEFORE_TEST_S \
  AFTER_TEST_S:AFTER_TEST_S FILE_TEST_S:FILE_TEST_S STOP_S:STOP_S; do
  a=$(grep -m1 "^${pair%%:*}=" "$S" | cut -d= -f2); b=$(grep -m1 "^${pair#*:}=" "$R" | cut -d= -f2)
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "  ${pair%%:*}=$a in the session, ${pair#*:}=$b in the runner" >&2; same=0; }
done
check "every step bound in the session is the runner's own" "[ $same = 1 ]"
sched=$(bash "$S" --print-schedule 2>&1)
check "the schedule is the bounds' sum ($sched)" "[ '$sched' = 'harness_end_s=4320 evidence_s=4440 stop_s=4500 termination_s=4800' ]"
worst=$(python3 -c 'print(f"{4800 / 3600 * 0.7792:.4f}")')
check "the worst case, 4,800 s at the all-in rate, is \$$worst and under \$2" \
  "[ \"\$(grep -m1 '^ALL_IN_RATE=' '$S' | cut -d= -f2)\" = 0.7792 ] && [ \"\$(grep -m1 '^COST_CAP_USD=' '$S' | cut -d= -f2)\" = 2.00 ] && python3 -c 'import sys; sys.exit(0 if $worst < 2 else 1)'"
cp "$S" "$WORK/costly.sh"; sed -i 's/^ALL_IN_RATE=.*/ALL_IN_RATE=1.50/' "$WORK/costly.sh"
check "a rate that puts the worst case at \$2 or more is refused, before the schedule prints" \
  "! bash '$WORK/costly.sh' --print-schedule > '$WORK/costly.out' 2>&1 && grep -qF 'is not under \$2.00' '$WORK/costly.out'"
cp "$S" "$WORK/slow.sh"; sed -i 's/^FILE_TEST_S=.*/FILE_TEST_S=6000/' "$WORK/slow.sh"
check "a bound that stretches the schedule past \$2 is refused too" "! bash '$WORK/slow.sh' --print-schedule >/dev/null 2>&1"

# A fake aws that records every call, so a refusal is shown to come before anything reaches AWS.
mkdir -p "$WORK/awsbin"
printf '#!/bin/bash\necho "aws $*" >> "%s/aws-calls"\nexit 0\n' "$WORK" > "$WORK/awsbin/aws"; chmod +x "$WORK/awsbin/aws"
refused() { : > "$WORK/aws-calls"; env -u SESSION_CONFIRM -u VLLMTPOT_AMI_ID PATH="$WORK/awsbin:$PATH" OUT="$WORK/never" "$@" bash "$S" > "$WORK/refusal.out" 2>&1; }
refused env
check "without SESSION_CONFIRM=yes the session is refused and calls no AWS API" \
  "grep -q 'SESSION_CONFIRM=yes is required' '$WORK/refusal.out' && [ ! -s '$WORK/aws-calls' ] && [ ! -e '$WORK/never' ]"
refused env SESSION_CONFIRM=yes
check "without a pinned AMI ID the session is refused and calls no AWS API" \
  "grep -q 'VLLMTPOT_AMI_ID is unset' '$WORK/refusal.out' && [ ! -s '$WORK/aws-calls' ]"
refused env SESSION_CONFIRM=yes VLLMTPOT_AMI_ID=ami-0123456789abcdef0 MODEL=other/model
check "a caller who sets one of the session's own values is refused" \
  "grep -q 'MODEL is set' '$WORK/refusal.out' && [ ! -s '$WORK/aws-calls' ]"

# ---------------------------------------------------------------- the user-data
bash "$S" --print-user-data > "$WORK/ud.sh" 2> "$WORK/ud.err"
first_cmd=$(grep -n -v -E '^(#|$)' "$WORK/ud.sh" | sed -n '4p')
first_aws=$(grep -n -m1 'aws ' "$WORK/ud.sh" | cut -d: -f1)
check "the user-data parses, is under 16 KB, and has no placeholder left" \
  "[ -s '$WORK/ud.sh' ] && bash -n '$WORK/ud.sh' && [ \$(wc -c < '$WORK/ud.sh') -lt 16384 ] && ! grep -q _PLACEHOLDER '$WORK/ud.sh'"
check "the instance arms its 4,500 s backstop before anything else can fail ($first_cmd)" \
  "[ '${first_cmd#*:}' = '( sleep 4500; shutdown -h now ) &' ] && [ '${first_cmd%%:*}' -lt '$first_aws' ]"
check "the precise backstop counts from LaunchTime, and the runner ends at LaunchTime + 4,320 s" \
  "grep -q '( sleep \$(( L + 4500 - ' '$WORK/ud.sh' && grep -q 'HE=\$(( L + 4320 ))' '$WORK/ud.sh' && grep -q 'EV=\$(( L + 4440 ))' '$WORK/ud.sh'"

# ---------------------------------------------------------------- pins
check "the session pins the two diffs at their own sha256" \
  "[ \"\$(sha256sum '$ROOT/hack/vllm-tpot/serving-test-only.diff' | cut -d' ' -f1)\" = \"\$(grep -m1 '^SERVING_DIFF_SHA256=' '$S' | cut -d= -f2)\" ] && [ \"\$(sha256sum '$ROOT/hack/vllm-tpot/fix.diff' | cut -d' ' -f1)\" = \"\$(grep -m1 '^FIX_DIFF_SHA256=' '$S' | cut -d= -f2)\" ]"
paths=$(grep -h '^diff --git' "$ROOT/hack/vllm-tpot/fix.diff" "$ROOT/hack/vllm-tpot/serving-test-only.diff" | awk '{print substr($3,3)}' | sort -u)
pinok=1
for st in base before after; do
  [ "$(awk -v s=$st '$1 == s {print $3}' "$PINS" | sort | paste -sd' ')" = "$(paste -sd' ' <<<"$paths")" ] || pinok=0
done
check "pins.txt names every file either diff touches, once per state" "[ $pinok = 1 ]"
check "the fix changes loggers.py and the test-only diff leaves it at the commit's" \
  "[ \"\$(awk '\$3 == \"vllm/v1/metrics/loggers.py\" {print \$1, \$2}' '$PINS' | awk '{a[\$1]=\$2} END {print (a[\"base\"] == a[\"before\"] && a[\"after\"] != a[\"base\"])}')\" = 1 ]"
# The pins are rederived from a vLLM checkout when one is given, since only that proves them the commit's.
if [ -n "${VLLM_SRC:-}" ]; then
  mkdir -p "$WORK/rederive"
  for st in base before after; do
    for p in $paths; do mkdir -p "$WORK/rederive/$st/$(dirname "$p")"; git -C "$VLLM_SRC" show "3a1c6c43df:$p" > "$WORK/rederive/$st/$p"; done
  done
  (cd "$WORK/rederive/before" && git apply "$ROOT/hack/vllm-tpot/serving-test-only.diff") &&
    (cd "$WORK/rederive/after" && git apply "$ROOT/hack/vllm-tpot/fix.diff")
  for st in base before after; do (cd "$WORK/rederive/$st" && sha256sum $paths) | awk -v s=$st '{print s, $1, $2}'; done > "$WORK/rederived"
  check "pins.txt is what the two diffs make of 3a1c6c43df in $VLLM_SRC" "diff -q <(sort '$PINS') <(sort '$WORK/rederived') >/dev/null"
else
  echo "skip pins.txt against a vLLM checkout (set VLLM_SRC to rederive them)"
fi

# ---------------------------------------------------------------- the runner's whole path, against fakes
# A fake tree with the same shape: a package file under vllm/ and a checkout file, and diffs made the way the real ones are.
mkdir -p "$WORK/pristine/site/vllm/v1/metrics" "$WORK/pristine/w/tests" "$WORK/mk"
for d in vllm vllm/v1 vllm/v1/metrics; do : > "$WORK/pristine/site/$d/__init__.py"; done
printf 'def record(n):\n    observe(n)\n' > "$WORK/pristine/site/vllm/v1/metrics/loggers.py"
printf 'def test_tpot():\n    pass\n' > "$WORK/pristine/w/tests/test_metrics.py"
mkdiff() { # mkdiff OUT: the diff from the pristine files to what the callback leaves in $WORK/mk/t
  rm -rf "$WORK/mk/t"; mkdir -p "$WORK/mk/t"; cp -r "$WORK/pristine/site/vllm" "$WORK/pristine/w/tests" "$WORK/mk/t/"
  (cd "$WORK/mk/t" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && "${@:2}" && git diff > "$1")
}
mkdiff "$WORK/serving.diff" sh -c 'printf "def test_tpot_skips():\n    assert True\n" >> tests/test_metrics.py'
mkdiff "$WORK/fix.diff" sh -c 'printf "def test_tpot_skips():\n    assert True\n" >> tests/test_metrics.py && sed -i "s/    observe(n)/    if num_generation_tokens > 1:\n        observe(n)/" vllm/v1/metrics/loggers.py'
mkpins() {
  local st d
  : > "$WORK/in/pins.txt"
  for st in base before after; do
    rm -rf "$WORK/mk/p"; mkdir -p "$WORK/mk/p"; cp -r "$WORK/pristine/site/vllm" "$WORK/pristine/w/tests" "$WORK/mk/p/"
    case $st in before) d=$WORK/serving.diff ;; after) d=$WORK/fix.diff ;; *) d="" ;; esac
    [ -z "$d" ] || (cd "$WORK/mk/p" && git apply "$d")
    (cd "$WORK/mk/p" && sha256sum vllm/v1/metrics/loggers.py tests/test_metrics.py) | awk -v s=$st '{print s, $1, $2}' >> "$WORK/in/pins.txt"
  done
}
mkdir -p "$WORK/in"
cp "$WORK/serving.diff" "$WORK/in/serving-test-only.diff"; cp "$WORK/fix.diff" "$WORK/in/fix.diff"
mkpins
# The state script with its container paths moved onto the fake tree; nothing else in it changes.
sed -e "s|^SITE=.*|SITE=$WORK/site|" -e "s|^W=.*|W=$WORK/w|" -e "s|/in/|$WORK/in/|g" -e "s|^O=/out/|O=$WORK/out/|" \
  -e "s|/tmp/vllm-wheel.sha256|$WORK/wheel.sha256|" "$ST" > "$WORK/in/state.sh"
echo "sha256:abc  vllm-0.0.0-cp38-abi3-linux_x86_64.whl" > "$WORK/wheel.sha256"
check "the moved state script still reads every container path from the fake tree" \
  "! grep -nE '/usr/local/lib|/vllm-workspace|[ \"=]/in/|[ \"=]/out/' '$WORK/in/state.sh' | grep -v '^[0-9]*:#'"

# The runner with its host cache directory moved under WORK; nothing else in it changes.
sed "s|/opt/tp/|$WORK/opt/|g" "$R" > "$WORK/runner.sh"
mkfakes() {
  local bin="$WORK/bin"
  rm -rf "$bin" "$WORK/calls" "$WORK/site" "$WORK/w"; mkdir -p "$bin"
  cat > "$bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$WORK/calls"
case "$1" in
  pull) exit 0 ;;
  image) echo "[\"public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:9f77cb6501aa29d5bfa70d0819c153ecebd604d41fc77a9e8cc097cb0e4145bb\"] ${FAKE_REVISION:-3a1c6c43df5eb5344a3f853c34fac93c274a372f}" ;;
  run)
    if printf '%s\n' "$@" | grep -qx /in/state.sh; then
      # A fresh container: the image's tree as built, unless the fake is told to leave the last state's edits.
      if [ -z "${FAKE_STALE:-}" ] || [ ! -d "$WORK/site" ]; then
        rm -rf "$WORK/site" "$WORK/w"; cp -r "$WORK/pristine/site" "$WORK/site"; cp -r "$WORK/pristine/w" "$WORK/w"
      fi
      args=$(printf '%s\n' "$@" | sed -n '/^\/in\/state.sh$/,$p' | tail -n +2)
      PYTHONPATH="$WORK/site" bash "$WORK/in/state.sh" $args; exit $?
    fi
    printf '%s\n' "$@" | grep -qx cat && { cat "$WORK/wheel.sha256"; exit 0; }
    printf '%s\n' "$@" | grep -q snapshot_download && { echo /root/.cache/huggingface/hub/models--x/snapshots/0123abcd; exit 0; }
    exit 1 ;;
  inspect) exit 1 ;;
  rm) exit 0 ;;
esac
EOF
  # python3 -m pytest answers as the real test would: three servers, each failing with the 5-sample delta unless the
  # loggers.py that Python imports carries the fix.
  cat > "$bin/python3" <<EOF
#!/bin/bash
if [ "\$1 \$2" = "-m pytest" ]; then
  echo "pytest \$*" >> "$WORK/calls"
  x=""; for a in "\$@"; do case \$a in --junitxml=*) x=\${a#--junitxml=} ;; esac; done
  lf=\$($REAL_PY -c 'import vllm.v1.metrics.loggers as l; print(l.__file__)')
  if [ -n "\${FAKE_PYTEST_ERROR:-}" ]; then
    echo '<testsuites><testsuite errors="1" failures="0" tests="1"><testcase classname="t" name="test_tpot_skips_single_token_requests[text-]"><error message="failed to start server">x</error></testcase></testsuite></testsuites>' > "\$x"
    echo "ERROR tests/t.py::test_tpot_skips_single_token_requests[text-]"; exit 1
  fi
  case "\$*" in *"tpot_skips and text"*) n=3 ;; *) n=5 ;; esac
  if grep -q 'num_generation_tokens > 1' "\$lf"; then
    { echo '<testsuites><testsuite>'
      for i in \$(seq 1 \$n); do echo "<testcase classname=\"t\" name=\"test_tpot_skips_single_token_requests[text-\$i]\" time=\"1\"/>"; done
      echo '</testsuite></testsuites>'; } > "\$x"
    echo "PASSED tests/t.py::test_tpot_skips_single_token_requests[text-1]"; echo "==== \$n passed in 9.00s ===="; exit 0
  fi
  echo '<testsuites><testsuite errors="0" failures="1" tests="1"><testcase classname="t" name="test_tpot_skips_single_token_requests[text-]"><failure message="assert (5.0 - 0.0) == 2&#10; +  where 5.0 = _tpot_count(&lt;S&gt;)">E   assert (5.0 - 0.0) == 2</failure></testcase></testsuite></testsuites>' > "\$x"
  echo "FAILED tests/t.py::test_tpot_skips_single_token_requests[text-] - assert (5.0 ..."; echo "==== 1 failed in 9.00s ===="; exit 1
fi
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
  serving_sha=$(sha256sum "$WORK/in/serving-test-only.diff" | cut -d' ' -f1); fix_sha=$(sha256sum "$WORK/in/fix.diff" | cut -d' ' -f1)
  python3 "$V" "$WORK/out" "$serving_sha" "$fix_sha" > "$WORK/verdict-$1.txt" 2>&1
  echo $? > "$WORK/vrc-$1"
  cp -r "$WORK/out" "$WORK/out-$1"
}
runfake good env
check "the runner does BEFORE, then AFTER, and ends" \
  "[ \"\$(cat '$WORK/rc-good')\" = 0 ] && grep -q 'both states done' '$WORK/out-good/steps.log' && [ \"\$(grep -n 'state before: start\\|state after: start' '$WORK/out-good/steps.log' | cut -d' ' -f3 | paste -sd' ')\" = 'before: after:' ]"
check "BEFORE applies the test-only diff, AFTER applies the fix, each in its own container" \
  "[ \"\$(grep -o 'run --rm --name tp-[a-z]*' '$WORK/calls' | paste -sd' ')\" = 'run --rm --name tp-before run --rm --name tp-after' ] && grep -q \"^diff_sha256=\$(sha256sum '$WORK/in/serving-test-only.diff' | cut -d' ' -f1)\\\$\" '$WORK/out-good/before/state.txt' && grep -q \"^diff_sha256=\$(sha256sum '$WORK/in/fix.diff' | cut -d' ' -f1)\\\$\" '$WORK/out-good/after/state.txt'"
check "the BEFORE pytest is the -x TPOT run, and AFTER runs it then the whole file with -k text" \
  "[ \"\$(grep '^pytest' '$WORK/calls' | sed 's/ --junitxml=.*//' | paste -sd'|')\" = 'pytest -m pytest -x tests/entrypoints/serve/instrumentator/test_metrics.py -k tpot_skips and text -rA -p no:cacheprovider|pytest -m pytest -x tests/entrypoints/serve/instrumentator/test_metrics.py -k tpot_skips and text -rA -p no:cacheprovider|pytest -m pytest tests/entrypoints/serve/instrumentator/test_metrics.py -k text -rA -p no:cacheprovider' ]"
check "the import check records the imported loggers.py, with no fix line BEFORE and the fix line AFTER" \
  "grep -qx 'loggers_file=$WORK/site/vllm/v1/metrics/loggers.py' '$WORK/out-good/before/state.txt' && grep -qx 'grep_rc=1' '$WORK/out-good/before/state.txt' && grep -qx 'grep_rc=0' '$WORK/out-good/after/state.txt' && grep -q 'num_generation_tokens > 1' '$WORK/out-good/after/grep.txt' && [ ! -s '$WORK/out-good/before/grep.txt' ]"
check "the run records the image identity, the wheel hash, both junit files and the pass/fail lines" \
  "grep -q ' 3a1c6c43df5eb5344a3f853c34fac93c274a372f\$' '$WORK/out-good/image-identity.txt' && grep -q whl '$WORK/out-good/wheel-sha256.txt' && [ -s '$WORK/out-good/before/tpot.xml' ] && [ -s '$WORK/out-good/after/tpot.xml' ] && [ -s '$WORK/out-good/after/file.xml' ] && grep -q '^FAILED' '$WORK/out-good/before/tpot-lines.txt' && grep -q '^PASSED' '$WORK/out-good/after/tpot-lines.txt'"
# The verdict on the fake run reads the fake tree's loggers path, so it is judged with that path standing in.
sed "s|^LOGGERS = .*|LOGGERS = \"$WORK/site/vllm/v1/metrics/loggers.py\"|" "$V" > "$WORK/verdict-local.py"
# Both print the verdict whatever its exit status, which pipefail would otherwise turn into the pipeline's.
fake_verdict() { python3 "$WORK/verdict-local.py" "$WORK/out-$1" "$(sha256sum "$WORK/in/serving-test-only.diff" | cut -d' ' -f1)" "$(sha256sum "$WORK/in/fix.diff" | cut -d' ' -f1)"; true; }
check "the fake run, with BEFORE failing and AFTER passing, is confirmed" \
  "fake_verdict good | grep -qx 'verdict=confirmed' && fake_verdict good | grep -qx 'before_delta=5'"
check "the real verdict refuses the fake run, whose loggers.py is not the image's path" \
  "grep -q '^import_check=wrong-file' '$WORK/verdict-good.txt' && [ \"\$(cat '$WORK/vrc-good')\" = 2 ]"

runfake stale env FAKE_STALE=1
check "an AFTER container that still holds BEFORE's edits is refused before the fix is applied" \
  "grep -qx 'base_identity=bad' '$WORK/out-stale/after/state.txt' && ! grep -q '^apply=' '$WORK/out-stale/after/state.txt' && [ \"\$(cat '$WORK/rc-stale')\" = 2 ]"
runfake badrev env FAKE_REVISION=deadbeef
check "an image whose label is not 3a1c6c43df is refused before any state runs" \
  "grep -q 'IMAGE IDENTITY FAILED' '$WORK/out-badrev/steps.log' && ! grep -q 'tp-before' '$WORK/calls'"
runfake pyerr env FAKE_PYTEST_ERROR=1
check "a BEFORE whose server never started is an error, not the expected failure, and is not confirmed" \
  "fake_verdict pyerr | grep -q '^before=error' && fake_verdict pyerr | grep -qx 'verdict=not-confirmed'"
# The fix already in the image: BEFORE then passes, and the report must lead with the import check.
cp "$WORK/fix.diff" "$WORK/in/serving-test-only.diff"; mkpins
sed -i 's/^before /x /; s/^after \(.*\)/after \1\nbefore \1/' "$WORK/in/pins.txt"
runfake fixedbefore env
check "a BEFORE that imported the fix passes, and the verdict names the import check first and is not confirmed" \
  "[ \"\$(fake_verdict fixedbefore | head -1)\" = 'import_check=fix-present-or-unread-before(grep_rc=0)' ] && fake_verdict fixedbefore | grep -qx 'before=passed' && fake_verdict fixedbefore | grep -qx 'verdict=before-passed'"
cp "$WORK/serving.diff" "$WORK/in/serving-test-only.diff"; mkpins

# ---------------------------------------------------------------- the verdict, case by case
LG=/usr/local/lib/python3.12/dist-packages/vllm/v1/metrics/loggers.py
FAIL5='<testsuites><testsuite errors="0" failures="1" tests="1"><testcase classname="tests.entrypoints.serve.instrumentator.test_metrics" name="test_tpot_skips_single_token_requests[text-]" time="40.1"><failure message="assert (5.0 - 0.0) == 2&#10; +  where 5.0 = _tpot_count(&lt;tests.utils.RemoteOpenAIServer object at 0x7f&gt;)">E       assert (5.0 - 0.0) == 2</failure></testcase></testsuite></testsuites>'
pass_n() { local i; echo '<testsuites><testsuite errors="0" failures="0">'
  for i in $(seq 1 "$1"); do echo "<testcase classname=\"t\" name=\"test_tpot_skips_single_token_requests[text-p$i]\" time=\"30\"/>"; done
  echo '</testsuite></testsuites>'; }
case_dir() { # case_dir NAME, then edits; writes a confirmed run that each case mutates
  local d="$WORK/vc/$1"; rm -rf "$d"; mkdir -p "$d/before" "$d/after"
  printf 'started=100\ndiff_sha256=SERV\nbase_identity=ok\napply=ok\napplied_identity=ok\nloggers_file=%s\ngrep_rc=1\ntpot_rc=1\nended=200\n' "$LG" > "$d/before/state.txt"
  printf 'started=300\ndiff_sha256=FIX\nbase_identity=ok\napply=ok\napplied_identity=ok\nloggers_file=%s\ngrep_rc=0\ntpot_rc=0\nfile_rc=0\nended=900\n' "$LG" > "$d/after/state.txt"
  echo "$FAIL5" > "$d/before/tpot.xml"; pass_n 3 > "$d/after/tpot.xml"; pass_n 7 > "$d/after/file.xml"
  echo "$d"
}
vd() { python3 "$V" "$1" SERV FIX; true; }
vdrc() { python3 "$V" "$1" SERV FIX > /dev/null; }
d=$(case_dir good)
check "the verdict confirms BEFORE failing on a delta of 5 and AFTER passing three servers" \
  "vd '$d' | grep -qx 'verdict=confirmed' && vdrc '$d'"
check "the verdict's first line is the import check" "[ \"\$(vd '$d' | head -1)\" = 'import_check=ok' ]"
notconf() { # notconf DESCRIPTION EDIT: a confirmed run with EDIT applied must not be confirmed
  local d; d=$(case_dir "x$RANDOM"); (cd "$d" && eval "$2")
  check "not confirmed: $1" "! vd '$d' | grep -qx 'verdict=confirmed' && ! vdrc '$d'"
}
notconf "BEFORE passed" "pass_n 1 > before/tpot.xml; sed -i 's/^tpot_rc=1/tpot_rc=0/' before/state.txt"
notconf "BEFORE failed with a delta of 4" "sed -i 's/(5.0 - 0.0)/(4.0 - 0.0)/g' before/tpot.xml"
notconf "BEFORE failed on another assertion" "sed -i 's/assert (5.0 - 0.0) == 2/assert 503 == 200/g' before/tpot.xml"
notconf "BEFORE errored in setup" "sed -i 's/<failure /<error /; s/<\\/failure>/<\\/error>/' before/tpot.xml"
notconf "BEFORE ran no test" "echo '<testsuites><testsuite tests=\"0\"/></testsuites>' > before/tpot.xml; sed -i 's/^tpot_rc=1/tpot_rc=5/' before/state.txt"
notconf "BEFORE's junit is missing" "rm before/tpot.xml"
notconf "AFTER failed" "echo \"\$FAIL5\" > after/tpot.xml; sed -i 's/^tpot_rc=0/tpot_rc=1/' after/state.txt"
notconf "AFTER passed only two of the three servers" "pass_n 2 > after/tpot.xml"
notconf "AFTER timed out" "sed -i 's/^tpot_rc=0/tpot_rc=124/' after/state.txt"
notconf "AFTER is missing" "rm -r after"
notconf "the fix line is in loggers.py BEFORE" "sed -i 's/^grep_rc=1/grep_rc=0/' before/state.txt"
notconf "the fix line is not in loggers.py AFTER" "sed -i 's/^grep_rc=0/grep_rc=1/' after/state.txt"
notconf "the loggers.py grep could not read the file" "sed -i 's/^grep_rc=0/grep_rc=2/' after/state.txt"
notconf "Python imported loggers.py from somewhere else" "sed -i 's|^loggers_file=.*|loggers_file=/vllm-workspace/src/vllm/v1/metrics/loggers.py|' after/state.txt"
notconf "AFTER started before BEFORE ended" "sed -i 's/^started=300/started=150/' after/state.txt"
notconf "BEFORE applied another diff" "sed -i 's/^diff_sha256=SERV/diff_sha256=OTHER/' before/state.txt"
notconf "the image's files were not the commit's" "sed -i 's/^base_identity=ok/base_identity=bad/' after/state.txt"
notconf "the fix did not apply to the pinned result" "sed -i 's/^applied_identity=ok/applied_identity=bad/' after/state.txt"
d=$(case_dir bp); (cd "$d" && pass_n 1 > before/tpot.xml && sed -i 's/^tpot_rc=1/tpot_rc=0/; s/^grep_rc=1/grep_rc=0/' before/state.txt)
check "a BEFORE that passed is named, with the import check that explains it on the first line" \
  "vd '$d' | grep -qx 'verdict=before-passed' && [ \"\$(vd '$d' | head -1)\" = 'import_check=fix-present-or-unread-before(grep_rc=0)' ]"
d=$(case_dir ff); (cd "$d" && sed -i 's/^file_rc=0/file_rc=1/' after/state.txt)
check "the whole-file run is reported but does not decide the verdict" \
  "vd '$d' | grep -q '^after_file=not-passed rc=1' && vd '$d' | grep -qx 'verdict=confirmed'"

if [[ $failures -ne 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
