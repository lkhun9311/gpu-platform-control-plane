#!/usr/bin/env bash
#
# The run pre-registered in docs/superpowers/specs/2026-09-05-the-price-of-protection.md.
#
# It asks what protection costs: is there an engine configuration that holds the premium tail WITHOUT
# deleting the contending tenant's work, and what does the protected tenant pay for it. The factors are
# vLLM's chunked-prefill token budget and its scheduling policy. There is no gateway in the path -- M5-b's
# own evidence says the gateway cannot observe the pressure it gated on, so a control plane layered on a
# misconfigured engine measures the wrong thing.
#
# WHAT MAKES THIS DIFFERENT FROM hack/m5b-scheduler-microtest.sh
#
# That test sent two requests and reported a median. This replays a real open-loop trace through the Go
# harness, which is where the fault-injected measurement lives: per-tenant output share, aggregate
# throughput over summed per-repetition spans, TPOT over sorted samples, and a refusal when the evidence
# cannot answer the question. Reimplementing any of that in the user-data Python would be a second
# measurement nobody has adversarially reviewed.
#
# So the benchharness binary is built here, checksummed, and shipped to the instance. The instance verifies
# the checksum before running it, because a truncated download that still executes is the kind of failure
# that produces numbers rather than errors.
#
# COST
#
# One Spot g5.xlarge in a DEFAULT PUBLIC SUBNET, about $0.65/h effective, with no NAT data charge. The
# pre-registration is explicit that the pilot's price has NOT been re-derived for its current four-arm
# scope, so the operator sets ARMS and knows what they are buying.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

REGION="${AWS_REGION:-ap-northeast-2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.xlarge}"
MAX_SPOT_PRICE="${MAX_SPOT_PRICE:-0.80}"
BACKSTOP_SECONDS="${BACKSTOP_SECONDS:-7200}"
REPS="${REPS:-1}"
OUT="${OUT:-hack/pop-$(date -u +%Y%m%d-%H%M%S)}"
STACK="m5b-pop"
STUDY="price-of-protection-2026-09-05"

# The arms to run, as "name:budget:policy". An empty budget means "pass no budget flag at all", which is
# how the control is defined: the pre-registration deliberately does not name a number, because nothing in
# the evidence establishes what this image defaults to.
#
# The pilot is these four. The confirmatory run is all ten. Both are this script with a different ARMS.
ARMS="${ARMS:-R1::,default-fcfs::,mbt-0512-fcfs:512:fcfs,mbt-0512-priority:512:priority}"

say()  { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

spot_say()  { say "$@"; }
spot_fail() { fail "$@"; }
# shellcheck source=hack/lib/spot-run.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/spot-run.sh"

ACCOUNT=$(spot_account) || fail "not authenticated"
BUCKET="${BUCKET:-$STACK-$ACCOUNT}"
RUN_ID="$(basename "$OUT")"

# The engine and model come from the manifest, not from defaults here, so this measures the same engine the
# arms measured. A default would let this answer a question about a different scheduler without anything
# saying so.
ENGINE_IMAGE=$(grep -oP '^\s*(- )?image:\s*\Kvllm/vllm-openai@sha256:\S+' config/vllm/deployment.yaml | head -1)
[ -n "$ENGINE_IMAGE" ] || fail "no digest-pinned vLLM image in config/vllm/deployment.yaml"
MODEL=$(python3 -c "
import re
args=re.search(r'args:\n((?:\s*(?:-|#).*\n)+)', open('config/vllm/deployment.yaml').read())
for line in (args.group(1).splitlines() if args else []):
    v=line.strip()
    if v.startswith('- ') and not v.startswith('- --'):
        print(v[2:].strip()); break
")
[ -n "$MODEL" ] || fail "could not read the served model from config/vllm/deployment.yaml"

mkdir -p "$OUT"
say "study  $STUDY"
say "engine $ENGINE_IMAGE"
say "model  $MODEL"
say "arms   $ARMS"
say "output $OUT"

# ---------------------------------------------------------------- the harness binary
#
# Built statically, because the deep-learning AMI's libc is not this host's and a dynamically linked binary
# would fail on the instance after the image and weights had already been pulled -- twenty minutes into a
# paid hour.
say "building the harness for the instance"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/benchharness" ./cmd/benchharness \
  || fail "could not build benchharness"
HARNESS_SHA=$(sha256sum "$OUT/benchharness" | cut -d' ' -f1)
say "harness sha256 $HARNESS_SHA"

# ---------------------------------------------------------------- AWS scaffolding
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"

# This runner READS as well as writes: the instance downloads the harness binary it was sent. The microtest
# needs PutObject only, which is why the policy is the caller's rather than the library's.
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"

say "uploading the harness"
aws s3 cp "$OUT/benchharness" "s3://$BUCKET/$RUN_ID/bin/benchharness" >/dev/null \
  || fail "could not upload the harness"

AMI=$(spot_resolve_ami "$REGION" \
  /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id) \
  || fail "could not resolve a GPU AMI"

ZONES=$(spot_zones_offering "$REGION" "$INSTANCE_TYPE")
[ -n "$ZONES" ] || fail "$INSTANCE_TYPE is offered in no availability zone of $REGION"
say "$INSTANCE_TYPE is offered in: $ZONES"

# ---------------------------------------------------------------- what the instance runs
MEASURE=$(mktemp)
cat > "$MEASURE" <<'PYEOF'
"""Run one cell per arm: launch the engine, prove it is configured as claimed, replay, keep the evidence.

The measurement itself is the Go harness. This orchestrates it, and its one piece of judgement is the
guard below: an arm is only an arm if the engine agrees it is.
"""

import json, os, re, subprocess, sys, time, urllib.request

IMAGE = os.environ["IMAGE"]; MODEL = os.environ["MODEL"]
STUDY = os.environ["STUDY"]; REPS = int(os.environ["REPS"])
OUT = "/tmp/evidence"; BASE = "http://127.0.0.1:8000"
HARNESS = "/usr/local/bin/benchharness"

# name:budget:policy, an empty budget meaning "pass no flag".
ARMS = [a.split(":") for a in os.environ["ARMS"].split(",") if a]
# Derived from the same list the trace generator uses, so the map cannot drift from the tenants.
PRIORITIES = "premium-1=0,standard-noisy=5,standard-probe-under=5,standard-probe-over=5"


def wait_healthy(deadline=900):
    end = time.time() + deadline
    while time.time() < end:
        try:
            urllib.request.urlopen(BASE + "/health", timeout=5).read()
            return True
        except Exception:
            time.sleep(3)
    return False


def engine_config(name):
    """Return the engine's own resolved startup lines, and save them beside the evidence."""
    logs = subprocess.run(["docker", "logs", "vllm"], capture_output=True).stdout.decode("utf-8", "replace")
    kept = [l.strip() for l in logs.splitlines()
            if any(k in l for k in ("non-default args", "Chunked prefill", "scheduling", "KV cache"))]
    with open(f"{OUT}/engine-config-{name}.txt", "w") as f:
        f.write("\n".join(kept) + "\n")
    return "\n".join(kept)


def agrees(config, budget, policy):
    """Refuse an arm the engine does not agree it is.

    A name is not evidence. `mbt-0512-priority` pointed at an engine running 1024, or at one that silently
    ignored the policy flag, produces a full set of healthy-looking rows under a label that is false -- and
    a string check on the arm name cannot catch it, because the typo names another VALID cell.

    vLLM reports its resolved settings as a Python dict, `'scheduling_policy': 'priority'` with a colon, so
    the separator is matched as one to four non-alphanumeric characters rather than assuming an equals sign.
    """
    if budget:
        if not re.search(r"max_num_batched_tokens[^0-9]{1,4}%s\b" % budget, config):
            return f"the engine does not report max_num_batched_tokens={budget}"
    if policy == "priority":
        if not re.search(r"scheduling[-_]policy[^a-zA-Z0-9]{1,4}priority", config, re.I):
            return "the engine does not report the priority scheduling policy"
    elif policy == "fcfs":
        if re.search(r"scheduling[-_]policy[^a-zA-Z0-9]{1,4}priority", config, re.I):
            return "the engine reports the priority policy for an arm that must be fcfs"
    return None


os.makedirs(OUT, exist_ok=True)
manifest = {"study": STUDY, "image": IMAGE, "model": MODEL, "arms": [], "reps": REPS}

for name, budget, policy in ARMS:
    subprocess.run(["docker", "rm", "-f", "vllm"], capture_output=True)
    args = ["docker", "run", "-d", "--name", "vllm", "--gpus", "all", "--network", "host",
            "-v", "/hf:/root/.cache/huggingface", "--shm-size", "8g", IMAGE,
            "--model", MODEL, "--dtype", "half", "--max-model-len", "16384",
            "--max-num-seqs", "64", "--gpu-memory-utilization", "0.90",
            "--no-enable-prefix-caching", "--port", "8000"]
    if budget:
        args += ["--max-num-batched-tokens", budget]
    if policy:
        args += ["--scheduling-policy", policy]
    subprocess.run(args, check=False, capture_output=True)

    entry = {"arm": name, "requested_budget": budget or "engine default", "requested_policy": policy or "engine default"}
    if not wait_healthy():
        entry["error"] = "engine never became healthy"
        manifest["arms"].append(entry); continue

    config = engine_config(name)
    # The resolved budget, recorded whether or not we asked for one. For the control this is B0, the number
    # the pre-registration deliberately refuses to guess.
    resolved = re.search(r"max_num_batched_tokens[^0-9]{1,4}(\d+)", config)
    entry["resolved_budget"] = resolved.group(1) if resolved else None

    why = agrees(config, budget, policy)
    if why:
        entry["error"] = f"refused before replay: {why}"
        manifest["arms"].append(entry)
        print(f"REFUSED {name}: {why}", file=sys.stderr)
        continue

    # The trace arm name is the study's, and gen-trace validates it against the study registry.
    for rep in range(1, REPS + 1):
        trace = f"{OUT}/trace-{name}-{rep}.jsonl"
        mani = f"{OUT}/manifest-{name}-{rep}.yaml"
        raw = f"{OUT}/raw-{name}-{rep}.jsonl"
        gen = [HARNESS, "gen-trace", "--seed", "7", "--study", STUDY, "--arm", name,
               "--model", MODEL, "--gateway-url", BASE, "--engine-image", IMAGE,
               "--trace-out", trace, "--manifest-out", mani]
        r = subprocess.run(gen, capture_output=True)
        if r.returncode != 0:
            entry["error"] = "gen-trace: " + r.stderr.decode("utf-8", "replace")[-400:]
            break
        rep_cmd = [HARNESS, "replay", "--manifest", mani, "--target", BASE, "--raw-out", raw]
        if policy == "priority":
            rep_cmd += ["--priorities", PRIORITIES]
        r = subprocess.run(rep_cmd, capture_output=True)
        if r.returncode != 0:
            entry["error"] = "replay: " + r.stderr.decode("utf-8", "replace")[-400:]
            break
        entry.setdefault("raw", []).append(os.path.basename(raw))
    manifest["arms"].append(entry)

subprocess.run(["docker", "rm", "-f", "vllm"], capture_output=True)
with open(f"{OUT}/run.json", "w") as f:
    json.dump(manifest, f, indent=2)

# The exit status is what gates the completion marker. An arm that produced no rows is not a result.
served = [a for a in manifest["arms"] if a.get("raw")]
print(json.dumps(manifest, indent=2))
sys.exit(0 if served else 1)
PYEOF

RUNSCRIPT=$(mktemp)
cat > "$RUNSCRIPT" <<'USERDATA'
#!/bin/bash
exec > >(tee /var/log/pop.log) 2>&1
set -x
( sleep BACKSTOP_SECONDS_PLACEHOLDER; shutdown -h now ) &

IMAGE="ENGINE_IMAGE_PLACEHOLDER"
MODEL="MODEL_PLACEHOLDER"
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
HARNESS_SHA="HARNESS_SHA_PLACEHOLDER"

upload() { aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/pop.log log.txt; shutdown -h now' EXIT

# The harness is verified before it is trusted. A truncated download that still executes produces numbers
# rather than an error, which is the failure this whole study exists to avoid.
aws s3 cp "s3://$BUCKET/$PREFIX/bin/benchharness" /usr/local/bin/benchharness
chmod +x /usr/local/bin/benchharness
got=$(sha256sum /usr/local/bin/benchharness | cut -d' ' -f1)
if [ "$got" != "$HARNESS_SHA" ]; then
  echo "harness checksum mismatch: expected $HARNESS_SHA, got $got"
  exit 1
fi

docker pull "$IMAGE"
mkdir -p /hf /tmp/evidence

rc=0
python3 /usr/local/bin/pop.py > /tmp/run-stdout.json 2>/tmp/pop.err || rc=$?
tar -czf /tmp/evidence.tgz -C /tmp evidence
upload /tmp/evidence.tgz evidence.tgz
upload /tmp/run-stdout.json run.json
upload /tmp/pop.err stderr.txt

# DONE means the run produced usable evidence, not that the script reached its last line.
if [ "$rc" -eq 0 ] && [ -s /tmp/evidence.tgz ]; then
  touch /tmp/DONE && upload /tmp/DONE DONE
else
  echo "no arm produced rows (exit $rc); DONE withheld"
fi
USERDATA

UD=$(mktemp)
{
  echo "#!/bin/bash"
  echo "mkdir -p /usr/local/bin"
  echo "cat > /usr/local/bin/pop.py <<'MEASUREEOF'"
  cat "$MEASURE"
  echo "MEASUREEOF"
  echo "export IMAGE='$ENGINE_IMAGE' MODEL='$MODEL' STUDY='$STUDY' ARMS='$ARMS' REPS='$REPS'"
  sed -e "s|BACKSTOP_SECONDS_PLACEHOLDER|$BACKSTOP_SECONDS|" \
      -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" \
      -e "s|ENGINE_IMAGE_PLACEHOLDER|$ENGINE_IMAGE|" \
      -e "s|MODEL_PLACEHOLDER|$MODEL|" \
      -e "s|BUCKET_PLACEHOLDER|$BUCKET|" \
      -e "s|HARNESS_SHA_PLACEHOLDER|$HARNESS_SHA|" "$RUNSCRIPT" | tail -n +2
} > "$UD"
cp "$UD" "$OUT/user-data.sh"
cp "$MEASURE" "$OUT/pop.py"

# ---------------------------------------------------------------- launch
say "launching $INSTANCE_TYPE spot (max \$$MAX_SPOT_PRICE/h)"
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=price-of-protection}]"
IID=""
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  say "trying $z ($SUBNET)"
  IID=$(spot_launch "$REGION" "$AMI" "$INSTANCE_TYPE" "$SUBNET" "$STACK" \
        "$MAX_SPOT_PRICE" 200 "$UD" "$TAGS" 2>>"$OUT/launch-errors.txt") \
    && [ -n "$IID" ] && [ "$IID" != "None" ] && break
  IID=""
done
[ -n "$IID" ] || fail "no zone would launch $INSTANCE_TYPE; see $OUT/launch-errors.txt"
echo "$IID" > "$OUT/instance-id"
say "instance $IID"

# The trap belongs to whoever owns the instance id. The library offers termination and arms nothing.
cleanup() { spot_terminate "$REGION" "$IID"; }
trap cleanup EXIT INT TERM

say "waiting for results (the engine has an image and weights to pull first)"
done_seen=0
ended_early=""
marker_rc=0
ended_early=$(spot_wait_for_marker "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" 160 30) || marker_rc=$?
case "$marker_rc" in
  0) say "results are up"; done_seen=1 ;;
  2) say "instance ended before writing DONE" ;;
esac

for k in evidence.tgz run.json log.txt stderr.txt; do
  aws s3 cp "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" >/dev/null 2>&1 || true
done

if [ "$done_seen" -eq 0 ]; then
  if [ -n "$ended_early" ]; then
    fail "the instance was $ended_early before it wrote its completion marker; $OUT/log.txt is whatever it managed to upload"
  fi
  fail "no completion marker after 160 polls; the run either is still going or hung, and $IID has been terminated"
fi

[ -s "$OUT/evidence.tgz" ] || fail "no evidence archive was written; $OUT/log.txt may say why"
tar -xzf "$OUT/evidence.tgz" -C "$OUT" && say "evidence unpacked to $OUT/evidence"

say "resolved engine configuration per arm"
python3 - "$OUT/run.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"{'arm':<20} {'asked':>16} {'resolved':>10}  {'reps':>4}  note")
for a in d.get("arms", []):
    print(f"{a['arm']:<20} {a.get('requested_budget',''):>16} {str(a.get('resolved_budget')):>10}"
          f"  {len(a.get('raw',[])):>4}  {a.get('error','')}")
PY

say "the report is NOT run here: it needs every arm of the study and this may be a pilot"
say "when the arms are complete:  benchharness report --raw '$OUT/evidence/raw-*.jsonl' -json-out ..."
