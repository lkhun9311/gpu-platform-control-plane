#!/usr/bin/env bash
#
# Runs hack/gpu-fault-session.sh against a stub aws, docker and make, without credentials, a card or money.
#
#   bash hack/test/check-gpu-fault-session.sh
#
# Modelled on hack/test/check-mps-capability-session.sh, whose stub it reuses in shape. What it pins:
# - every pre-purchase refusal stops before run-instances;
# - the launch is the pinned AMI on a g5.2xlarge at the $1.1324 cap, terminating on shutdown, carrying the sweeper's
#   tag at the request plus 6,940 s, rewritten to LaunchTime plus 6,970 s; LaunchTime is handed to the instance;
# - the rendered user-data has no placeholder, parses, carries the spliced bring-up, runs the instance procedure
#   under the registered phase arithmetic, and fits EC2's 16 KB;
# - the end: the instance is terminated, the evidence is scored by the real scorer, and an unconfirmed termination
#   or an instance on another image fails the session.
#
# The session runs from a throwaway commit of the working tree, because it refuses a dirty tree.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git ls-files -co --exclude-standard | grep -v '^hack/gpu-fault-20\|^hack/gpu-fault-rehearsal-\|^hack/m5c-20\|^hack/mpscap-' |
  tar -cf - -T - | tar -xf - -C "$work" || { echo "could not copy the tree"; exit 1; }
mkdir -p "$work/repo" && (cd "$work" && find . -mindepth 1 -maxdepth 1 ! -name repo -exec mv {} repo/ \;)
(cd "$work/repo" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm test) || { echo "could not commit the copy"; exit 1; }
REPO="$work/repo"

mkdir -p "$work/bin"
# The aws stub of check-mps-capability-session.sh: rules matched in order, answers taken in turn, downloads from fixtures.
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
# Images are not built here: make succeeds without building, and docker save writes a minimal OCI archive, which is
# all hack/image-archive-check.py reads. With $STUB/attested present it writes the archive the first paid session
# produced, an image manifest plus the attestation naming it, which a kind node's import refuses.
python3 - "$work" <<'PY2'
import io, json, sys, tarfile
def archive(path, entries):
    with tarfile.open(path, "w") as t:
        def add(name, obj):
            data = json.dumps(obj).encode()
            info = tarfile.TarInfo(name); info.size = len(data); t.addfile(info, io.BytesIO(data))
        index = []
        for digest, layer_type, annotations in entries:
            add("blobs/sha256/" + digest, {"layers": [{"mediaType": layer_type, "digest": "sha256:" + "0" * 64}]})
            index.append({"digest": "sha256:" + digest, "annotations": annotations})
        add("index.json", {"manifests": index})
image = ("a" * 64, "application/vnd.oci.image.layer.v1.tar+gzip", {})
attestation = ("b" * 64, "application/vnd.in-toto+json", {"io.containerd.manifest.subject": "sha256:" + "a" * 64})
archive(sys.argv[1] + "/image.tar", [image])
archive(sys.argv[1] + "/attested.tar", [image, attestation])
PY2
printf '#!/bin/sh\necho "make $*" >>"$STUB/calls.log"\nexit 0\n' >"$work/bin/make"
printf '#!/bin/sh\necho "docker $*" >>"$STUB/calls.log"\nif [ "$1" = save ]; then if [ -e "$STUB/attested" ]; then cat "%s/attested.tar"; else cat "%s/image.tar"; fi; fi\nexit 0\n' "$work" "$work" >"$work/bin/docker"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin/"*

AMI=ami-097edab977037f65f
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
  put ami "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20261016	available"
  put prices $'ap-northeast-2a\t0.683000\nap-northeast-2c\t0.675900'
  put quota "48.0"
  put active "Active"; put enabled $'ENABLED\trate(5 minutes)'
  put target "arn:aws:lambda:ap-northeast-2:007635145730:function:gpu-platform-study-sweeper"
  put runs "6.0"; put errors "0.0"
  put creds "{\"Expiration\": \"$(date -u -d '+4 hours' +%Y-%m-%dT%H:%M:%SZ)\"}"
  put none ""
  put subnet "subnet-0a"
  put iid "i-0gpufault"
  LT=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
  put launched "$LT	$AMI"
  put terminated "terminated"
}
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
# The evidence an instance whose smoke cell stopped the session would upload: real files, scored by the real scorer.
smoke_stopped_evidence() {
  local d="$STUB/ev/gf-run"
  mkdir -p "$d/reps"
  printf 'S1=pass\nstop=S4: field 311\narm_xid=skipped\narm_ecc=skipped\narm_benign=skipped\narm_none=skipped\n' >"$d/smoke.env"
  tar -czf "$STUB/fixtures/evidence.tgz" -C "$STUB/ev" gf-run
  echo nonce >"$STUB/fixtures/DONE"
}
session() {
  shift
  out="$(cd "$REPO" && env -i HOME="$HOME" PATH="$work/bin:$PATH" STUB="$STUB" GOCACHE="${GOCACHE:-$HOME/.cache/go-build}" \
    GOPATH="${GOPATH:-$HOME/go}" GOFLAGS=-mod=mod SESSION_CONFIRM=yes GPU_FAULT_AMI_ID="$AMI" OUT="$STUB/out" \
    SPOT_TERMINATE_WAIT=0 SPOT_TERMINATE_TRIES=2 "$@" timeout 600 bash hack/gpu-fault-session.sh 2>&1)"
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
scene; base_rules; refused "no pinned AMI" "pins the AMI by ID" GPU_FAULT_AMI_ID=
scene; base_rules; refused "a caller's block count" "GF_BLOCKS is set" GF_BLOCKS=1
scene; base_rules; refused "a caller's instance type" "INSTANCE_TYPE is set" INSTANCE_TYPE=g5.xlarge
scene; put acct2 "123456789012"; rule "sts get-caller-identity*" acct2; base_rules; refused "another account" "paid sessions run only in gpu-lab"
scene; put ami2 "Ubuntu Server 22.04	available"; rule "ec2 describe-images*" ami2; base_rules; refused "an AMI that is not the GPU base image" "not an available Deep Learning Base"
scene; put dear $'ap-northeast-2a\t1.500000'; rule "ec2 describe-spot-price-history*" dear; base_rules; refused "a price over the ceiling" "at or under \$1.1324/h"
scene; put q4 "4.0"; rule "service-quotas get-service-quota*" q4; base_rules; refused "too little Spot quota" "needs 8"
scene; put inactive "Pending"; rule "lambda get-function*" inactive; base_rules; refused "a sweeper not Active" "is Pending, not Active"
scene; put few "2.0"; rule "cloudwatch get-metric-statistics*Invocations*" few; base_rules; refused "a sweeper seen running twice" "at least 4 clean runs"
scene; put errs "1.0"; rule "cloudwatch get-metric-statistics*Errors*" errs; base_rules; refused "a sweeper with an error" "1.0 error(s)"
scene; put soon "{\"Expiration\": \"$(date -u -d '+120 min' +%Y-%m-%dT%H:%M:%SZ)\"}"; rule "configure export-credentials*" soon; base_rules
refused "credentials that expire before 155 minutes" "the session needs 155"
scene; put earlier "i-0earlier"; rule "ec2 describe-instances*tag:purpose*" earlier; base_rules; refused "an earlier instance still live" "still live (i-0earlier)"
scene; base_rules; mkdir -p "$STUB/out"; refused "an output directory that already exists" "already exists; each session writes a new directory"
scene; base_rules; touch "$STUB/attested"; refused "an image archive carrying an attestation" "an image archive the kind node would refuse to import"

# --- the whole session -------------------------------------------------------------------------------------------
scene; base_rules; smoke_stopped_evidence
t0=$(date +%s)
session "a whole session"
[ "$rc" = 0 ] && ok "a whole session exited 0" || bad "a whole session exited $rc: $(tail -4 "$STUB/session.out")"
grep -q "^GPU FAULT REACTION: NO-EVIDENCE" "$STUB/out/verdict.txt" 2>/dev/null && grep -qx "termination=confirmed" "$STUB/out/verdict.txt" &&
  ok "the real scorer read the returned evidence, and the termination is recorded" || bad "the verdict: $(head -3 "$STUB/out/verdict.txt" 2>/dev/null | paste -sd';')"
tag_at_launch=$(grep '^ec2 run-instances' "$STUB/calls.log" | grep -o 'Key=study-deadline,Value=[0-9TZ:-]*' | head -1 | sed 's/.*Value=//')
want_lo=$(( t0 + 6940 )); got=$(date -u -d "$tag_at_launch" +%s 2>/dev/null || echo 0)
(( got >= want_lo && got <= want_lo + 120 )) && ok "the launch carries the sweeper's tag at the request plus 6,940 s ($tag_at_launch)" || bad "the launch's tag is '$tag_at_launch'"
lt_epoch=$(date -u -d "$LT" +%s)
want_tag=$(date -u -d "@$(( lt_epoch + 6970 ))" +%Y-%m-%dT%H:%M:%SZ)
grep -q "^ec2 create-tags .*--resources i-0gpufault --tags Key=study-deadline,Value=$want_tag" "$STUB/calls.log" &&
  ok "the tag is rewritten to LaunchTime plus 6,970 s ($want_tag)" || bad "the tag rewrite was: $(grep create-tags "$STUB/calls.log")"
grep -q '^s3 cp --only-show-errors .*launch-time.txt s3://gpufault-gpu-007635145730/.*/launch-time.txt' "$STUB/calls.log" &&
  ok "LaunchTime is handed to the instance through the run's prefix" || bad "LaunchTime was not uploaded"
grep -q '^ec2 run-instances .*--image-id ami-097edab977037f65f --instance-type g5.2xlarge .*--instance-initiated-shutdown-behavior terminate' "$STUB/calls.log" &&
  grep -q 'MaxPrice\\\?":\\\?"1.1324' "$STUB/calls.log" &&
  ok "the launch is the pinned AMI on a g5.2xlarge at the \$1.1324 cap, terminating on shutdown" || bad "the launch was: $(grep '^ec2 run-instances' "$STUB/calls.log" | cut -c1-300)"
for n in controller gpu-simulator job; do
  grep -q "^s3 cp --only-show-errors .*/images/$n.tar.gz s3://gpufault-gpu-007635145730/.*/images/$n.tar.gz" "$STUB/calls.log" ||
    bad "the $n image was not uploaded"
done
grep -q '^make docker-build IMG=controller:gpufault' "$STUB/calls.log" && grep -q '^make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:gpufault' "$STUB/calls.log" &&
  ok "both images are built from the committed tree" || bad "the image builds were not called"
grep -q '^ec2 terminate-instances .*i-0gpufault' "$STUB/calls.log" && ok "the instance is terminated" || bad "no terminate call"
ud="$STUB/out/user-data.sh"
# The patterns below are the user-data's own text, so its dollar signs are matched literally.
# shellcheck disable=SC2016
! grep -q '_PLACEHOLDER' "$ud" && ok "the user-data has no placeholder left" || bad "a placeholder survived"
bash -n "$ud" && ok "the user-data parses" || bad "the user-data does not parse"
grep -qx 'docker exec m5cgpu-worker systemctl restart containerd || exit 1' "$ud" && ok "the user-data carries the bring-up spliced from hack/m5c-gpu-session.sh" ||
  bad "the bring-up is not in the user-data"
# shellcheck disable=SC2016
grep -q 'P1=$(( L + 720 )); P2=$(( L + 1320 )); P3=$(( L + 6520 )); P4=$(( L + 6820 )); EV=$(( L + 6940 ))' "$ud" &&
  ok "the phases end at 720, 1,320, 6,520 and 6,820 s after LaunchTime and the evidence at 6,940 s" || bad "the phase arithmetic is not the registered one"
grep -q '( sleep 7000; shutdown -h now ) &' "$ud" && ok "the first backstop stops the instance at 7,000 s" || bad "no 7,000 s backstop"
# shellcheck disable=SC2016
grep -q 'GF_ARMS_END="$P3" GF_CHECKS_END="$P4"' "$ud" && grep -q 'bash hack/gpu-fault-instance.sh' "$ud" &&
  ok "the instance procedure runs under the phase deadlines" || bad "the instance procedure is not run with its deadlines"
(( $(wc -c <"$ud") < 16384 )) && ok "the user-data is $(wc -c <"$ud") bytes, under EC2's 16 KB" || bad "the user-data is $(wc -c <"$ud") bytes"

# --- the ways the end can go wrong -------------------------------------------------------------------------------
scene; put other "$LT	ami-0other"; rule "ec2 describe-instances*LaunchTime*" other; base_rules; smoke_stopped_evidence
session "an instance running another image"
[ "$rc" != 0 ] && [[ "$out" == *"runs ami-0other, not the pinned"* ]] && ok "an instance running another image is refused" || bad "another image was accepted (exit $rc)"
grep -q '^ec2 terminate-instances .*i-0gpufault' "$STUB/calls.log" && ok "and it is terminated at once" || bad "the wrong-image instance was not terminated"
scene; put running "running"; rule "ec2 describe-instances*State.Name*" running; base_rules; smoke_stopped_evidence
session "termination not confirmed"
[ "$rc" != 0 ] && grep -qx "termination=unconfirmed" "$STUB/out/verdict.txt" && ok "an unconfirmed termination fails the session and is recorded" ||
  bad "an unconfirmed termination: exit $rc, $(tail -1 "$STUB/out/verdict.txt" 2>/dev/null)"
scene; base_rules; echo nonce >"$STUB/fixtures/DONE"
session "no evidence came back"
grep -q "NO-EVIDENCE (the evidence archive did not come back)" "$STUB/out/verdict.txt" 2>/dev/null && ok "a session whose evidence never came back says so" ||
  bad "no evidence gave: $(head -1 "$STUB/out/verdict.txt" 2>/dev/null)"

if [[ $fails -ne 0 ]]; then
  echo "check-gpu-fault-session: $fails failure(s)"
  exit 1
fi
echo "check-gpu-fault-session: all checks passed"
