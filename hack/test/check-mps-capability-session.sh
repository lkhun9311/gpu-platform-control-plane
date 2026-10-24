#!/usr/bin/env bash
#
# Runs hack/mps-capability-session.sh against a stub aws, without credentials, a card or money.
#
#   bash hack/test/check-mps-capability-session.sh
#
# What it pins, because each is a way the paid session could buy the wrong thing or report the wrong outcome:
# - every pre-purchase refusal stops before run-instances: no approval, no pinned AMI, another account, a caller's
#   load, an AMI that is not the GPU base image, a price over the ceiling, too little quota, a sweeper not seen
#   running, credentials that expire too soon, and an earlier instance still live;
# - the launch carries the sweeper's tag at the request plus 2,040 s, and the tag is rewritten to LaunchTime plus
#   2,070 s; LaunchTime is handed to the instance; an instance running another image is terminated at once;
# - the session waits for the marker, terminates, downloads the journal, records termination in it, and the real
#   classifier reads the result;
# - the rendered user-data has no placeholder left, carries the bring-up spliced from hack/m5c-gpu-session.sh, and
#   parses.
#
# The session runs from a throwaway commit of the working tree, because it refuses a dirty tree and the tree under
# test may not be committed yet. The stub answers each call from rules: a glob over the arguments, then answer files
# taken in turn on repeated calls, then an exit code. A download (s3 cp from s3:// to a path) copies a fixture.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The tree as it stands, committed in a copy, so the session's clean-tree refusal and its pins see a commit.
git ls-files -co --exclude-standard | grep -v '^hack/m5c-20\|^hack/mpscap-' | tar -cf - -T - | tar -xf - -C "$work" 2>/dev/null
mkdir -p "$work/repo" && (cd "$work" && find . -mindepth 1 -maxdepth 1 ! -name repo -exec mv {} repo/ \;)
(cd "$work/repo" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm test) || { echo "could not commit the copy"; exit 1; }
REPO="$work/repo"

mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env python3
import fnmatch, os, shutil, sys
stub = os.environ["STUB"]
args = sys.argv[1:]
line = " ".join(args)
with open(os.path.join(stub, "calls.log"), "a") as f:
    f.write(line + "\n")
# A download: copy the fixture named by the key, or fail as S3 would for a missing key.
if args[:2] == ["s3", "cp"]:
    paths = [a for a in args[2:] if not a.startswith("--")]
    if len(paths) == 2 and paths[0].startswith("s3://") and not paths[1].startswith("s3://"):
        key = paths[0].split("/", 3)[3]
        fx = os.path.join(stub, "fixtures", key.split("/", 1)[1] if "/" in key else key)
        if os.path.exists(fx):
            shutil.copy(fx, paths[1])
            sys.exit(0)
        sys.stderr.write("fatal error: An error occurred (404) when calling the HeadObject operation\n")
        sys.exit(1)
for i, rule in enumerate(open(os.path.join(stub, "rules")).read().splitlines()):
    if not rule:
        continue
    glob, files, rc = rule.split("\t")
    if fnmatch.fnmatchcase(line, glob):
        counter = os.path.join(stub, f"count.{i}")
        n = int(open(counter).read()) if os.path.exists(counter) else 0
        open(counter, "w").write(str(n + 1))
        seq = files.split("|")
        name = seq[min(n, len(seq) - 1)]
        if name != "-":
            sys.stdout.write(open(os.path.join(stub, name)).read())
        sys.exit(int(rc))
sys.exit(0)
EOF
chmod +x "$work/bin/aws"
# Polling sleeps return at once; the session's own arithmetic is what is under test, not its patience.
printf '#!/bin/sh\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin/sleep"

AMI=ami-097edab977037f65f
case_n=0
scene() {
  case_n=$((case_n + 1))
  STUB="$work/s$case_n"
  export STUB
  mkdir -p "$STUB/fixtures"
  : >"$STUB/rules"
  : >"$STUB/calls.log"
  put account "007635145730"
  put ami "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20261016	available"
  put prices $'ap-northeast-2a\t0.683000\nap-northeast-2c\t0.675900'
  put quota "48.0"
  put active "Active"; put enabled $'ENABLED\trate(5 minutes)'
  put target "arn:aws:lambda:ap-northeast-2:007635145730:function:gpu-platform-study-sweeper"
  put runs "6.0"; put errors "0.0"
  put creds "{\"Expiration\": \"$(date -u -d '+3 hours' +%Y-%m-%dT%H:%M:%SZ)\"}"
  put none ""
  put subnet "subnet-0a"
  put iid "i-0capability"
  LT=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
  put launched "$LT	$AMI"
  put terminated "terminated"
}
put() { printf '%s\n' "$2" >"$STUB/$1"; }
rule() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-0}" >>"$STUB/rules"; }
# The rules every case starts from, each a scene() file; a case adds rules ahead of them to change one answer.
base_rules() {
  rule "sts get-caller-identity*" account
  rule "ec2 describe-images*" ami
  rule "ec2 describe-spot-price-history*" prices
  rule "service-quotas get-service-quota*" quota
  rule "lambda get-function*" active
  rule "events describe-rule*" enabled
  rule "events list-targets-by-rule*" target
  rule "cloudwatch get-metric-statistics*Invocations*" runs
  rule "cloudwatch get-metric-statistics*Errors*" errors
  rule "configure export-credentials*" creds
  rule "ec2 describe-instances*tag:purpose*" none
  rule "ec2 describe-subnets*" subnet
  rule "ec2 run-instances*" iid
  rule "ec2 describe-instances*LaunchTime*" launched
  rule "ec2 describe-instances*State.Name*" terminated
}
# A journal the instance would have written: six passing bars and every fact but termination, which the session adds.
passing_journal() {
  local f="$STUB/fixtures/journal.jsonl" b
  : >"$f"
  for b in B0 B1 B2 B3 B4 B5; do
    printf '{"type":"bar","bar":"%s","state":"started","at":"t"}\n{"type":"bar","bar":"%s","state":"decided","result":"pass","at":"t"}\n' "$b" "$b" >>"$f"
  done
  for b in launch_time_read overlay_pinned manifests_pinned images_pulled schedulable diagnostics_uploaded provenance_complete; do
    printf '{"type":"fact","name":"%s","value":true,"at":"t"}\n' "$b" >>"$f"
  done
  printf '{"type":"fact","name":"no_healthy_devices_event","value":false,"at":"t"}\n{"type":"fact","name":"daemon_rejected_client","value":false,"at":"t"}\n' >>"$f"
  echo nonce >"$STUB/fixtures/DONE"
}
# session NAME [VAR=VALUE...]: the session from the copy, under the stubs, with the caller's environment emptied.
session() {
  shift
  out="$(cd "$REPO" && env -i HOME="$HOME" PATH="$work/bin:$PATH" STUB="$STUB" GOCACHE="${GOCACHE:-$HOME/.cache/go-build}" \
    GOPATH="${GOPATH:-$HOME/go}" GOFLAGS=-mod=mod SESSION_CONFIRM=yes MPSCAP_AMI_ID="$AMI" OUT="$STUB/out" \
    SPOT_TERMINATE_WAIT=0 SPOT_TERMINATE_TRIES=2 "$@" timeout 600 bash hack/mps-capability-session.sh 2>&1)"
  rc=$?
  printf '%s\n' "$out" >"$STUB/session.out"
}
launched() { grep -q '^ec2 run-instances' "$STUB/calls.log"; }
refused() { # NAME NEEDLE [VAR=VALUE...]
  local name="$1" needle="$2"
  shift 2
  session "$name" "$@"
  if [ "$rc" = 0 ]; then bad "$name: the session exited 0"
  elif launched; then bad "$name: the session launched before refusing"
  elif [[ "$out" != *"$needle"* ]]; then bad "$name: no '$needle' in: $(tail -2 <<<"$out")"
  else ok "$name: refused before any launch"; fi
}

# --- the refusals ------------------------------------------------------------------------------------------------
scene; base_rules; refused "no approval" "SESSION_CONFIRM=yes is required" SESSION_CONFIRM=
scene; base_rules; refused "no pinned AMI" "pins the AMI by ID" MPSCAP_AMI_ID=
scene; base_rules; refused "a caller's rate" "RATE is set" RATE=9.85
scene; base_rules; refused "a caller's instance type" "INSTANCE_TYPE is set" INSTANCE_TYPE=g5.xlarge
scene; put acct2 "123456789012"; rule "sts get-caller-identity*" acct2; base_rules; refused "another account" "paid sessions run only in gpu-lab"
scene; put ami2 "Ubuntu Server 22.04	available"; rule "ec2 describe-images*" ami2; base_rules; refused "an AMI that is not the GPU base image" "not an available Deep Learning Base"
scene; put dear $'ap-northeast-2a\t1.500000'; rule "ec2 describe-spot-price-history*" dear; base_rules; refused "a price over the ceiling" "at or under \$1.1324/h"
scene; put q4 "4.0"; rule "service-quotas get-service-quota*" q4; base_rules; refused "too little Spot quota" "needs 8"
scene; put inactive "Pending"; rule "lambda get-function*" inactive; base_rules; refused "a sweeper not Active" "is Pending, not Active"
scene; put disabled $'DISABLED\trate(5 minutes)'; rule "events describe-rule*" disabled; base_rules; refused "a sweeper's rule disabled" "not ENABLED rate(5 minutes)"
scene; put few "2.0"; rule "cloudwatch get-metric-statistics*Invocations*" few; base_rules; refused "a sweeper seen running twice" "at least 4 clean runs"
scene; put errs "1.0"; rule "cloudwatch get-metric-statistics*Errors*" errs; base_rules; refused "a sweeper with an error" "1.0 error(s)"
scene; put silent "None"; rule "cloudwatch get-metric-statistics*Invocations*" silent; base_rules; refused "a sweeper with no invocation datapoint" "ran None time(s)"
scene; put soon "{\"Expiration\": \"$(date -u -d '+30 min' +%Y-%m-%dT%H:%M:%SZ)\"}"; rule "configure export-credentials*" soon; base_rules; refused "credentials that expire too soon" "Re-authenticate"
scene; put earlier "i-0earlier"; rule "ec2 describe-instances*tag:purpose*" earlier; base_rules; refused "an earlier capability instance still live" "still live (i-0earlier)"

# --- the whole session, with a passing journal -------------------------------------------------------------------
# Run 2 of 2026-10-24: every bar passed and the run was INVALID, because the wait for "terminated" ended at a fixed
# 300 s with the instance still shutting-down. Seventy polls of shutting-down outlast the library's sixty tries.
scene; put shut "shutting-down"; rule "ec2 describe-instances*State.Name*" "shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|shut|terminated"; base_rules; passing_journal
session "a slow shutdown"
grep -qx "MPS: PASS" "$STUB/out/verdict.txt" 2>/dev/null && grep -q '"name":"termination_confirmed","value":true' "$STUB/out/journal.jsonl" &&
  ok "a shutdown slower than five minutes is still waited for and confirmed" || bad "a slow shutdown was not confirmed: $(head -1 "$STUB/out/verdict.txt" 2>/dev/null); $(tail -3 "$STUB/session.out")"
grep -qE "waiting up to (2[0-9]{3}|1[0-9]{3})s for EC2" "$STUB/session.out" && ok "the wait runs to the registered 2,400 s from LaunchTime" ||
  bad "the wait was: $(grep 'waiting up to' "$STUB/session.out")"

scene; base_rules; passing_journal
t0=$(date +%s)
session "a whole session"
if [ "$rc" != 0 ]; then
  bad "a whole session exited $rc: $(tail -4 "$STUB/session.out")"
else
  ok "a whole session exited 0"
fi
grep -qx "MPS: PASS" "$STUB/out/verdict.txt" 2>/dev/null && ok "the verdict, read by the real classifier, is PASS" || bad "the verdict is: $(head -1 "$STUB/out/verdict.txt" 2>/dev/null)"
grep -q '"name":"termination_confirmed","value":true' "$STUB/out/journal.jsonl" && ok "the session recorded the termination it confirmed" || bad "no termination fact in the journal"
tag_at_launch=$(grep -o 'Key=study-deadline,Value=[0-9TZ:-]*' <(grep '^ec2 run-instances' "$STUB/calls.log") | head -1 | sed 's/.*Value=//')
want_lo=$(( t0 + 2040 )); got=$(date -u -d "$tag_at_launch" +%s 2>/dev/null || echo 0)
(( got >= want_lo && got <= want_lo + 60 )) && ok "the launch carries the sweeper's tag at the request plus 2,040 s ($tag_at_launch)" || bad "the launch's tag is '$tag_at_launch'"
lt_epoch=$(date -u -d "$LT" +%s)
want_tag=$(date -u -d "@$(( lt_epoch + 2070 ))" +%Y-%m-%dT%H:%M:%SZ)
grep -q "^ec2 create-tags .*--resources i-0capability --tags Key=study-deadline,Value=$want_tag" "$STUB/calls.log" &&
  ok "the tag is rewritten to LaunchTime plus 2,070 s ($want_tag)" || bad "the tag rewrite was: $(grep create-tags "$STUB/calls.log")"
grep -q '^s3 cp --only-show-errors .*launch-time.txt s3://mpscap-gpu-007635145730/.*/launch-time.txt' "$STUB/calls.log" &&
  ok "LaunchTime is handed to the instance through the run's prefix" || bad "LaunchTime was not uploaded: $(grep launch-time "$STUB/calls.log")"
[[ "$(cat "$STUB/out/launch-time.txt")" == "$LT" ]] && ok "the session kept the LaunchTime EC2 returned" || bad "launch-time.txt holds $(cat "$STUB/out/launch-time.txt")"
grep -q '^ec2 run-instances .*--image-id ami-097edab977037f65f --instance-type g5.2xlarge .*--instance-initiated-shutdown-behavior terminate' "$STUB/calls.log" &&
  grep -q 'MaxPrice\\\?":\\\?"1.1324' "$STUB/calls.log" &&
  ok "the launch is the pinned AMI on a g5.2xlarge at the \$1.1324 ceiling, terminating on shutdown" || bad "the launch was: $(grep '^ec2 run-instances' "$STUB/calls.log" | cut -c1-300)"
grep -q '^ec2 terminate-instances .*i-0capability' "$STUB/calls.log" && ok "the instance is terminated" || bad "no terminate call"
ud="$STUB/out/user-data.sh"
# The patterns below are the user-data's own text, so its dollar signs are matched literally.
# shellcheck disable=SC2016
! grep -q '_PLACEHOLDER' "$ud" && ok "the user-data has no placeholder left" || bad "a placeholder survived: $(grep -o '[A-Z_]*_PLACEHOLDER' "$ud" | sort -u | paste -sd' ')"
bash -n "$ud" && ok "the user-data parses" || bad "the user-data does not parse"
grep -qx 'docker exec m5cgpu-worker systemctl restart containerd || exit 1' "$ud" && grep -qx 'kind create cluster --config /tmp/kind.yaml --kubeconfig "$KUBECONFIG" --wait 300s || exit 1' "$ud" &&
  ok "the user-data carries the bring-up spliced from hack/m5c-gpu-session.sh" || bad "the bring-up is not in the user-data"
grep -q 'export STUDY=mps-capability-2026-10-24 ARMS=mps REPS=1 RATE=2 PREMIUM_WEIGHT=1 NOISY_WEIGHT=0.054 PROBE_WEIGHT=0 DURATION_MS=120000' "$ud" &&
  ok "the user-data runs the registered study at its frozen load" || bad "the study or its load is not the registered one in the user-data"
grep -q 'P1=$(( L + 720 )); P2=$(( L + 1200 )); P3=$(( L + 1920 )); EV=$(( L + 2040 ))' "$ud" &&
  ok "the phases end at 720, 1,200 and 1,920 s after LaunchTime and the evidence at 2,040 s" || bad "the phase arithmetic in the user-data is not the registered one"
grep -q 'mpscap_supervise "$P1" "$P2" "$P3" 90 -- bash hack/m5c-matrix.sh' "$ud" && ok "the matrix runs under the phase supervisor" || bad "the matrix is not supervised"
# codex, review of 96bb69fd: phase 1 includes the bring-up, so the bring-up runs under a timeout that ends with it.
grep -q 'bringup_left=$(( P1 - $(date +%s) ))' "$ud" && grep -q 'timeout --kill-after=15 "$bringup_left" bash /tmp/bringup.sh' "$ud" &&
  ok "the bring-up runs under a timeout that ends with phase 1" || bad "the bring-up is not bounded by phase 1"
grep -q "^cat > /tmp/bringup.sh <<'BRINGUP'$" "$ud" && grep -qx 'BRINGUP' "$ud" && ok "the bring-up is carried as its own script" || bad "the bring-up script is not written"
sed -n "/^cat > \/tmp\/bringup.sh <<'BRINGUP'$/,/^BRINGUP$/p" "$ud" | sed '1d;$d' >"$STUB/bringup-extracted.sh"
bash -n "$STUB/bringup-extracted.sh" && ok "the carried bring-up parses on its own" || bad "the carried bring-up does not parse"
grep -q 'grep -qx .required_failed=0. /src/m5c-run/mpscap/diag/complete' "$ud" &&
  ok "the diagnostics count as uploaded only with the collector's completion marker" || bad "the diagnostics fact does not require the completion marker"
(( $(wc -c <"$ud") < 16384 )) && ok "the user-data is $(wc -c <"$ud") bytes, under EC2's 16 KB" || bad "the user-data is $(wc -c <"$ud") bytes"
pin=$(cd "$REPO" && bash -c '. hack/lib/mps-capability.sh; mpscap_pin_hash "${MPSCAP_ENGINE_FILES[@]}"')
grep -q "MPSCAP_PIN_ENGINES=$pin" "$ud" && ok "the engines' pin is the commit's" || bad "the engines' pin in the user-data is not the commit's ($pin)"

# codex, review of 96bb69fd: an output directory that already exists could lend this session another run's journal.
scene; base_rules; passing_journal; mkdir -p "$STUB/out"; echo '{"type":"fact","name":"termination_confirmed","value":true,"at":"t"}' >"$STUB/out/journal.jsonl"
refused "an output directory that already exists" "already exists; each session writes a new directory"

# --- the ways the end can go wrong -------------------------------------------------------------------------------
scene; put other "$LT	ami-0other"; rule "ec2 describe-instances*LaunchTime*" other; base_rules; passing_journal
session "an instance running another image"
[ "$rc" != 0 ] && [[ "$out" == *"runs ami-0other, not the pinned"* ]] && ok "an instance running another image is refused" || bad "another image was accepted (exit $rc): $(tail -2 <<<"$out")"
grep -q '^ec2 terminate-instances .*i-0capability' "$STUB/calls.log" && ok "and it is terminated at once" || bad "the wrong-image instance was not terminated"
scene; put running "running"; rule "ec2 describe-instances*State.Name*" running; base_rules; passing_journal
session "termination not confirmed"
[ "$rc" != 0 ] && ok "an unconfirmed termination fails the session" || bad "an unconfirmed termination exited 0"
grep -qx "MPS: INVALID" "$STUB/out/verdict.txt" 2>/dev/null && grep -q "reason: termination_confirmed is not established" "$STUB/out/verdict.txt" &&
  ok "and the run is INVALID for it" || bad "the verdict with termination unconfirmed: $(head -3 "$STUB/out/verdict.txt" 2>/dev/null | paste -sd';')"
scene; base_rules; passing_journal; rm -f "$STUB/fixtures/journal.jsonl"
session "no journal came back"
grep -qx "MPS: INVALID" "$STUB/out/verdict.txt" 2>/dev/null && ok "a session whose journal never came back is INVALID, not unreadable" || bad "no journal gave: $(head -2 "$STUB/out/verdict.txt" 2>/dev/null | paste -sd';')"

if [[ $fails -ne 0 ]]; then
  echo "check-mps-capability-session: $fails failure(s)"
  exit 1
fi
echo "check-mps-capability-session: all checks passed"
