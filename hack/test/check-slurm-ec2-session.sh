#!/usr/bin/env bash
#
# Runs hack/slurm-ec2-session.sh against a stub aws, without credentials, an instance or money.
#
#   bash hack/test/check-slurm-ec2-session.sh
#
# Modelled on hack/test/check-gpu-fault-session.sh. What it pins:
# - every pre-purchase refusal stops before run-instances;
# - the purchase is the three registered instances, in one zone, each at its cap, terminating on shutdown, tagged for
#   the sweeper; a zone that cannot hold all three is left with nothing running before the next is tried;
# - cluster.env carries T0, the latest LaunchTime, and the three addresses; the tags move to T0 + 4,470 s;
# - the end: all three are terminated, the munge key is removed from S3 and never written into the run directory,
#   the real scorer reads what came back, and an unconfirmed termination fails the session.
#
# The session runs from a throwaway commit of the working tree, because it refuses a dirty tree.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git ls-files -co --exclude-standard | grep -v '^hack/slurm-ec2-20\|^hack/slurm-ec2-rehearsal-\|^hack/gpu-fault-20\|^hack/m5c-20\|^hack/mpscap-' |
  tar -cf - -T - | tar -xf - -C "$work" || { echo "could not copy the tree"; exit 1; }
mkdir -p "$work/repo" && (cd "$work" && find . -mindepth 1 -maxdepth 1 ! -name repo -exec mv {} repo/ \;)
(cd "$work/repo" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm test) || { echo "could not commit the copy"; exit 1; }
REPO="$work/repo"

mkdir -p "$work/bin"
# Rules matched in order, answers taken in turn; a failing answer goes to stderr, as the CLI's does.
cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env python3
import fnmatch, os, shutil, sys
stub = os.environ["STUB"]
args = sys.argv[1:]
line = " ".join(args)
with open(os.path.join(stub, "calls.log"), "a") as f:
    f.write(line + "\n")
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
    if len(paths) == 2 and paths[1].startswith("s3://"):
        os.makedirs(os.path.join(stub, "uploaded"), exist_ok=True)
        shutil.copy(paths[0], os.path.join(stub, "uploaded", os.path.basename(paths[1])))
        sys.exit(0)
for i, rule in enumerate(open(os.path.join(stub, "rules")).read().splitlines()):
    if not rule:
        continue
    glob, files, rcs = rule.split("\t")
    if fnmatch.fnmatchcase(line, glob):
        counter = os.path.join(stub, f"count.{i}")
        n = int(open(counter).read()) if os.path.exists(counter) else 0
        open(counter, "w").write(str(n + 1))
        seq, rcseq = files.split("|"), rcs.split("|")
        name, rc = seq[min(n, len(seq) - 1)], int(rcseq[min(n, len(rcseq) - 1)])
        if name != "-":
            (sys.stdout if rc == 0 else sys.stderr).write(open(os.path.join(stub, name)).read())
        sys.exit(rc)
sys.exit(0)
EOF
printf '#!/bin/sh\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin/"*

HAMI=ami-05b2d28c4a1614552
GAMI=ami-040ebe879ae70cc30
case_n=0
put() { printf '%s\n' "$2" >"$STUB/$1"; }
rule() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-0}" >>"$STUB/rules"; }
scene() {
  case_n=$((case_n + 1))
  STUB="$work/s$case_n"
  export STUB
  mkdir -p "$STUB/fixtures"
  : >"$STUB/rules"
  : >"$STUB/calls.log"
  put account "007635145730"
  put hami $'ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20261023\tavailable\t099720109477'
  put gami $'Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) 20261106\tavailable\t898082745236'
  put prices $'g5.xlarge\tap-northeast-2a\t0.580600\ng5.xlarge\tap-northeast-2c\t0.593200\nt3.medium\tap-northeast-2a\t0.017500\nt3.medium\tap-northeast-2c\t0.017200'
  put quota "48.0"
  put active "Active"; put enabled $'ENABLED\trate(5 minutes)'
  put target "arn:aws:lambda:ap-northeast-2:007635145730:function:gpu-platform-study-sweeper"
  put runs $'1.0\t1.0\t1.0\t1.0\t1.0\t1.0'; put errors $'0.0\t0.0\t0.0\t0.0\t0.0\t0.0'
  put creds "{\"Expiration\": \"$(date -u -d '+4 hours' +%Y-%m-%dT%H:%M:%SZ)\"}"
  put none ""
  put subnet "subnet-0a"
  put ih "i-0head"; put i1 "i-0gpu1"; put i2 "i-0gpu2"
  put capacity "An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation"
  put denied "An error occurred (UnauthorizedOperation) when calling the RunInstances operation"
  LT_H=$(date -u -d '-20 sec' +%Y-%m-%dT%H:%M:%S+00:00)
  LT_G=$(date -u -d '-10 sec' +%Y-%m-%dT%H:%M:%S+00:00)
  put dh "$LT_H	$HAMI	172.31.0.10"
  put d1 "$LT_H	$GAMI	172.31.0.11"
  put d2 "$LT_G	$GAMI	172.31.0.12"
  put terminated "terminated"
}
base_rules() {
  rule "sts get-caller-identity*" account
  rule "ec2 describe-images*--image-ids $HAMI*" hami
  rule "ec2 describe-images*--image-ids $GAMI*" gami
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
  rule "ec2 run-instances*" "ih|i1|i2"
  rule "ec2 describe-instances*--instance-ids i-0head*LaunchTime*" dh
  rule "ec2 describe-instances*--instance-ids i-0gpu1*LaunchTime*" d1
  rule "ec2 describe-instances*--instance-ids i-0gpu2*LaunchTime*" d2
  rule "ec2 describe-instances*State.Name*" terminated
}
# Evidence the real scorer reads as VOID: head stopped, with the reason.
void_evidence() {
  mkdir -p "$STUB/ev/evidence"
  echo "a worker stopped: not one A10G" >"$STUB/ev/evidence/VOID"
  tar -czf "$STUB/fixtures/evidence.tgz" -C "$STUB/ev" evidence
  echo "VOID: a worker stopped" >"$STUB/fixtures/DONE"
}
session() {
  shift
  out="$(cd "$REPO" && env -i HOME="$HOME" PATH="$work/bin:$PATH" STUB="$STUB" SESSION_CONFIRM=yes \
    SLURMEC2_HEAD_AMI_ID="$HAMI" SLURMEC2_GPU_AMI_ID="$GAMI" OUT="$STUB/out" \
    SPOT_TERMINATE_WAIT=0 SPOT_TERMINATE_TRIES=2 "$@" timeout 600 bash hack/slurm-ec2-session.sh 2>&1)"
  rc=$?
  printf '%s\n' "$out" >"$STUB/session.out"
}
launched() { grep -q '^ec2 run-instances' "$STUB/calls.log"; }
refused() {
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
scene; base_rules; refused "no pinned head AMI" "SLURMEC2_HEAD_AMI_ID is unset" SLURMEC2_HEAD_AMI_ID=
scene; base_rules; refused "no pinned worker AMI" "SLURMEC2_GPU_AMI_ID is unset" SLURMEC2_GPU_AMI_ID=
scene; base_rules; refused "a rehearsal flag in the paid runner" "SLURMEC2_REHEARSAL is set" SLURMEC2_REHEARSAL=1
scene; put acct2 "123456789012"; rule "sts get-caller-identity*" acct2; base_rules; refused "another account" "paid sessions run only in gpu-lab"
scene; put hami2 $'ubuntu/images/hvm-ssd-gp3/ubuntu-jammy-22.04-amd64-server-20261023\tavailable\t099720109477'
rule "ec2 describe-images*--image-ids $HAMI*" hami2; base_rules; refused "a head AMI that is not Ubuntu 24.04" "not 'ubuntu/images"
scene; put hami3 $'ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20261023\tavailable\t111111111111'
rule "ec2 describe-images*--image-ids $HAMI*" hami3; base_rules; refused "a head AMI from another owner" "owned by 111111111111"
scene; put gami2 $'Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20261016\tavailable\t898082745236'
rule "ec2 describe-images*--image-ids $GAMI*" gami2; base_rules; refused "a worker AMI that is not the 24.04 base" "not 'Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)"
scene; put dear $'g5.xlarge\tap-northeast-2a\t0.900000\nt3.medium\tap-northeast-2a\t0.017500'
rule "ec2 describe-spot-price-history*" dear; base_rules; refused "a GPU price over its cap" "no zone offers g5.xlarge"
scene; put split $'g5.xlarge\tap-northeast-2a\t0.580000\nt3.medium\tap-northeast-2c\t0.017500'
rule "ec2 describe-spot-price-history*" split; base_rules; refused "no zone with both types" "no zone offers"
scene; put q4 "4.0"; rule "service-quotas get-service-quota*" q4; base_rules; refused "too little Spot quota" "two g5.xlarge need 8"
scene; put inactive "Pending"; rule "lambda get-function*" inactive; base_rules; refused "a sweeper not Active" "is Pending, not Active"
scene; put few $'1.0\t1.0'; rule "cloudwatch get-metric-statistics*Invocations*" few; base_rules; refused "a sweeper seen running twice" "at least 4 clean runs"
scene; put errs $'0.0\t1.0'; rule "cloudwatch get-metric-statistics*Errors*" errs; base_rules; refused "an error in a later datapoint" "at least 4 clean runs"
scene; put soon "{\"Expiration\": \"$(date -u -d '+100 min' +%Y-%m-%dT%H:%M:%SZ)\"}"; rule "configure export-credentials*" soon; base_rules
refused "credentials that expire before 120 minutes" "the session needs 120"
scene; put earlier "i-0earlier"; rule "ec2 describe-instances*tag:purpose*" earlier; base_rules; refused "an earlier instance still live" "still live (i-0earlier)"
scene; base_rules; mkdir -p "$STUB/out"; refused "an output directory that already exists" "already exists; each session writes a new directory"
scene; put later "{\"Expiration\": \"$(date -u -d '+60 min' +%Y-%m-%dT%H:%M:%SZ)\"}"; rule "configure export-credentials*" "creds|later"; base_rules
refused "credentials that ran short during the uploads" "too few for the session and its teardown"

# --- the whole session -------------------------------------------------------------------------------------------
scene; base_rules; void_evidence
t0=$(date +%s)
session "a whole session"
[ "$rc" = 0 ] && ok "a whole session exited 0" || bad "a whole session exited $rc: $(tail -4 "$STUB/session.out")"
grep -q "^SLURM ON EC2: VOID: head stopped: a worker stopped" "$STUB/out/verdict.txt" && grep -qx "termination=confirmed" "$STUB/out/verdict.txt" &&
  ok "the real scorer read the returned evidence, and the termination is recorded" || bad "the verdict: $(paste -sd';' "$STUB/out/verdict.txt")"
runs=$(grep '^ec2 run-instances' "$STUB/calls.log")
[ "$(wc -l <<<"$runs")" = 3 ] && ok "three launches" || bad "$(wc -l <<<"$runs") launches"
grep -q -- "--image-id $HAMI --instance-type t3.medium .*--instance-initiated-shutdown-behavior terminate .*\"VolumeSize\":30.*MaxPrice\":\"0.06\".*Key=role,Value=head" <<<"$runs" &&
  ok "head: the pinned Ubuntu AMI on a t3.medium at \$0.06, 30 GB, terminating on shutdown" || bad "the head launch: $(sed -n 1p <<<"$runs" | cut -c1-400)"
[ "$(grep -c -- "--image-id $GAMI --instance-type g5.xlarge .*--instance-initiated-shutdown-behavior terminate .*\"VolumeSize\":100.*MaxPrice\":\"0.80\"" <<<"$runs")" = 2 ] &&
  ok "two workers: the pinned base AMI on g5.xlarge at \$0.80, 100 GB, terminating on shutdown" || bad "the worker launches: $(sed -n 2,3p <<<"$runs" | cut -c1-300)"
[ "$(grep -o -- '--subnet-id [^ ]*' <<<"$runs" | sort -u | wc -l)" = 1 ] && ok "all three in one subnet" || bad "the launches span subnets"
tag=$(grep -o 'Key=study-deadline,Value=[0-9TZ:-]*' <<<"$runs" | head -1 | sed 's/.*Value=//')
got=$(date -u -d "$tag" +%s 2>/dev/null || echo 0)
(( got >= t0 + 4470 && got <= t0 + 4470 + 120 )) && ok "the launches carry the sweeper's tag at the request plus 4,470 s" || bad "the launch tag is '$tag'"
want_t0=$(date -u -d "$LT_G" +%s)
cl="$STUB/uploaded/cluster.env"
[ -s "$cl" ] && grep -qx "T0=$want_t0" "$cl" && grep -qx "HEAD_IP=172.31.0.10" "$cl" && grep -qx "GPU1_IP=172.31.0.11" "$cl" && grep -qx "GPU2_IP=172.31.0.12" "$cl" &&
  ok "cluster.env carries T0, the latest LaunchTime, and the three addresses" || bad "cluster.env: $(paste -sd' ' "$cl" 2>&1)"
want_tag=$(date -u -d "@$(( want_t0 + 4470 ))" +%Y-%m-%dT%H:%M:%SZ)
grep -q "^ec2 create-tags .*--resources i-0head i-0gpu1 i-0gpu2 --tags Key=study-deadline,Value=$want_tag" "$STUB/calls.log" &&
  ok "the tags move to T0 + 4,470 s ($want_tag)" || bad "the tag rewrite was: $(grep create-tags "$STUB/calls.log")"
for i in i-0head i-0gpu1 i-0gpu2; do
  grep -q "^ec2 terminate-instances .*$i" "$STUB/calls.log" || bad "$i was not terminated"
done
grep -q "^s3 rm .*munge.key" "$STUB/calls.log" && ok "the munge key is removed from S3 at the end" || bad "the munge key was left in S3"
[ -s "$STUB/uploaded/munge.key" ] && [ "$(wc -c <"$STUB/uploaded/munge.key")" = 1024 ] && ok "a 1,024-byte munge key was uploaded" || bad "no munge key uploaded"
! find "$STUB/out" -name 'munge.key' | grep -q . && ok "the munge key is not in the run directory" || bad "the munge key is in the run directory"
for r in head gpu1 gpu2; do
  ud="$STUB/out/user-data-$r.sh"
  bash -n "$ud" && grep -q "export ROLE=$r " "$ud" && grep -q '( sleep 4500; ' "$ud" && (( $(wc -c <"$ud") < 16384 )) ||
    bad "the $r user-data: role, backstop, parse or size"
done
ok "each user-data names its role, arms the 4,500 s backstop, parses and fits 16 KB"

# --- the ways the purchase and the end can go wrong ---------------------------------------------------------------
# A scene's own rule goes before base_rules, because the first matching rule answers.
scene; rule "ec2 run-instances*" "ih|capacity|ih|i1|i2" "0|1|0|0|0"; base_rules; void_evidence
session "a zone that cannot hold all three"
[ "$rc" = 0 ] && grep -q "terminated i-0head (head, ap-northeast-2a: the trio did not fit)" "$STUB/out/termination.txt" &&
  [ "$(grep -c '^ec2 run-instances' "$STUB/calls.log")" = 5 ] &&
  ok "the head launched in a zone short of a GPU is terminated before the next zone takes all three" ||
  bad "a short zone: exit $rc, $(paste -sd';' "$STUB/out/termination.txt" 2>&1), $(grep -c '^ec2 run-instances' "$STUB/calls.log") launches"
scene; rule "ec2 run-instances*" "ih|denied" "0|1"; base_rules
session "a launch refused for another reason"
[ "$rc" != 0 ] && [[ "$out" == *"refused for a reason that is not capacity"* ]] && grep -q "^ec2 terminate-instances .*i-0head" "$STUB/calls.log" &&
  ok "a refusal that is not capacity stops the session and terminates what was launched" || bad "a non-capacity refusal: exit $rc, $(tail -2 <<<"$out")"
scene; put other "$LT_G	ami-0other	172.31.0.12"; rule "ec2 describe-instances*--instance-ids i-0gpu2*LaunchTime*" other; base_rules; void_evidence
session "an instance running another image"
[ "$rc" != 0 ] && [[ "$out" == *"gpu2 runs ami-0other, not the pinned"* ]] &&
  [ "$(grep -c '^ec2 terminate-instances' "$STUB/calls.log")" -ge 3 ] && ok "an instance on another image ends the session and all three are terminated" ||
  bad "another image: exit $rc, $(grep -c '^ec2 terminate-instances' "$STUB/calls.log") terminations"
scene; put running "running"; rule "ec2 describe-instances*State.Name*" running; base_rules; void_evidence
session "termination not confirmed"
[ "$rc" != 0 ] && grep -qx "termination=unconfirmed" "$STUB/out/verdict.txt" && ok "an unconfirmed termination fails the session and is recorded" ||
  bad "an unconfirmed termination: exit $rc, $(tail -1 "$STUB/out/verdict.txt" 2>&1)"
scene; base_rules; echo "ok" >"$STUB/fixtures/DONE"
session "no evidence came back"
grep -q "NO-EVIDENCE (the evidence archive did not come back)" "$STUB/out/verdict.txt" && ok "a session whose evidence never came back says so" ||
  bad "no evidence gave: $(head -1 "$STUB/out/verdict.txt" 2>&1)"

if [[ $fails -ne 0 ]]; then
  echo "check-slurm-ec2-session: $fails failure(s)"
  exit 1
fi
echo "check-slurm-ec2-session: all checks passed"
