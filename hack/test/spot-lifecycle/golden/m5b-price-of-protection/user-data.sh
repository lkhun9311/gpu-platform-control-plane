#!/bin/bash
mkdir -p /usr/local/bin
cat > /usr/local/bin/pop.py <<'MEASUREEOF'
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
MEASUREEOF
export IMAGE='vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967' MODEL='Qwen/Qwen2.5-3B-Instruct' STUDY='price-of-protection-2026-09-05' ARMS='R1::,default-fcfs::,mbt-0512-fcfs:512:fcfs,mbt-0512-priority:512:priority' REPS='1'
exec > >(tee /var/log/pop.log) 2>&1
set -x
( sleep 7200; shutdown -h now ) &

IMAGE="vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967"
MODEL="Qwen/Qwen2.5-3B-Instruct"
BUCKET="stub-bucket"
PREFIX="run"
HARNESS_SHA="<SHA>"

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
