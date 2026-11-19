#!/usr/bin/env bash
#
# Offline checks for hack/llmd-prefix-hunt-session.sh, its runner, its probe and its verdict, run before anything is bought.
# The EC2 lifecycle is hack/lib/spot-run.sh's, which the 58420 and 67811 tests cover; these checks cover what is new here.
# That is the cost and its refusals, the schedule, the purchase option, the user-data, the runner's pins and its order of steps against a fake docker, the probe against a fake vLLM, and that the verdict calls a hypothesis confirmed or refuted only on records that support it.
#
#   bash hack/llmd-prefix-hunt-session-test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/hack/llmd-prefix-hunt-session.sh"
DIR="$ROOT/hack/llmd-prefix-hunt"
R="$DIR/runner.sh"
V="$DIR/verdict.py"
# Scratch space lives on disk, since /tmp is RAM-backed on the owner's machine.
SCRATCH="${SCRATCH:-$HOME/.cache/llmd-prefix-hunt}"
mkdir -p "$SCRATCH"
WORK=$(mktemp -d -p "$SCRATCH")
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
sv() { grep -m1 "^$1=" "$S" | cut -d= -f2; }
rv() { grep -m1 "^$1=" "$R" | cut -d= -f2; }

check "the session and the runner parse, and the verdict compiles" \
  "bash -n '$S' && bash -n '$R' && python3 -m py_compile '$V'"

# ---------------------------------------------------------------- schedule and cost
same=1
for pair in PULL_BOUND_S:PULL_S IMAGE_ID_S:IMAGE_ID_S START_A_S:START_A_S START_B_S:START_B_S PROBE_S:PROBE_S COLLECT_S:COLLECT_S STOP_S:STOP_S; do
  a=$(sv "${pair%%:*}"); b=$(rv "${pair#*:}")
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "  ${pair%%:*}=$a in the session, ${pair#*:}=$b in the runner" >&2; same=0; }
done
check "every step bound in the session is the runner's own" "[ $same = 1 ]"
check "the session's harness end is the sum of the bring-up, the pull, the identity and every runner step" \
  "grep -qxF 'STATES_S=\$(( START_A_S + START_B_S + PROBE_S + COLLECT_S + STOP_S ))' '$S' && grep -qxF 'HARNESS_END_S=\$(( BRINGUP_S + PULL_BOUND_S + IMAGE_ID_S + STATES_S ))' '$S'"
sched=$(PURCHASE=spot bash "$S" --print-schedule 2>&1)
check "the schedule is the bounds' sum ($sched)" "[ '$sched' = 'harness_end_s=3720 evidence_s=3780 stop_s=3840 termination_s=4140' ]"
check "the schedule is the same for both purchase options" "[ \"\$(PURCHASE=on-demand bash '$S' --print-schedule 2>&1)\" = '$sched' ]"
spot_worst=$(python3 -c 'print(f"{4140 / 3600 * 0.7792:.4f}")')
od_worst=$(python3 -c 'print(f"{4140 / 3600 * (1.237 + 0.0792):.4f}")')
check "the spot worst case, 4,140 s at \$0.7792/h, is \$$spot_worst, and the on-demand one at the pinned \$1.237 + \$0.0792/h is \$$od_worst, both under \$3.00" \
  "[ \"\$(sv SPOT_ALL_IN_RATE)\" = 0.7792 ] && [ \"\$(sv ON_DEMAND_RATE_PINNED)\" = 1.237 ] && [ \"\$(sv EBS_IP_RATE)\" = 0.0792 ] && [ \"\$(sv COST_CAP_USD)\" = 3.00 ] && [ '$spot_worst' = 0.8961 ] && [ '$od_worst' = 1.5136 ]"
check "the header states both worst cases, the highest on-demand rate it accepts, and the stop" \
  "grep -qF 'so \$0.7792/h all in, and \$0.8961.' '$S' && grep -qF 'it is \$1.3162/h all in, and \$1.5136;' '$S' && grep -qF 'any compute rate of \$2.5295/h or more' '$S' && grep -qF 'stopped by itself 3,840 s after launch' '$S'"
check "the instance is a g5.xlarge, and Spot tries the reclaimed zone last" \
  "grep -qx 'INSTANCE_TYPE_FIXED=g5.xlarge' '$S' && grep -qx '    RECLAIMED_ZONES=\"ap-northeast-2a\"' '$S'"
costly() { cp "$S" "$WORK/costly.sh"; sed -i "$1" "$WORK/costly.sh"; ! PURCHASE=$2 bash "$WORK/costly.sh" --print-schedule > "$WORK/costly.out" 2>&1 && grep -qF "$3" "$WORK/costly.out"; }
check "a Spot rate that puts the worst case at \$3.00 or more is refused, before the schedule prints" \
  "costly 's/^SPOT_ALL_IN_RATE=.*/SPOT_ALL_IN_RATE=2.70/' spot 'the spot worst case'"
check "a pinned on-demand rate over the cap is refused even for a Spot run" \
  "costly 's/^ON_DEMAND_RATE_PINNED=.*/ON_DEMAND_RATE_PINNED=2.60/' spot 'the on-demand worst case'"
check "a bound that stretches the schedule past \$3.00 is refused too" \
  "costly 's/^PROBE_S=.*/PROBE_S=12000/' spot 'is not under \$3.00'"

# ---------------------------------------------------------------- the purchase option
mkdir -p "$WORK/awsbin"
cat > "$WORK/awsbin/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >> "$AWS_CALLS"
case "$1 $2" in
  "pricing get-products")
    [ -z "${FAKE_PRICING_FAIL:-}" ] || { echo "An error occurred (AccessDeniedException)" >&2; exit 254; }
    python3 -c '
import json, sys
items = [json.dumps({"terms": {"OnDemand": {"t%d" % i: {"priceDimensions": {"d": {"unit": "Hrs", "pricePerUnit": {"USD": p}}}}}}})
         for i, p in enumerate(sys.argv[1].split(","))]
print(json.dumps(items))' "$FAKE_OD_PRICE" ;;
  "ec2 describe-spot-price-history") printf 'ap-northeast-2a\t0.6178\nap-northeast-2c\t0.6328\nap-northeast-2d\t0.7500\n' ;;
  "ec2 describe-instance-type-offerings") printf 'ap-northeast-2d\tap-northeast-2a\tap-northeast-2c\n' ;;
  "sts get-caller-identity") echo 007635145730 ;;
  "ec2 run-instances") echo i-0fake ;;
esac
EOF
chmod +x "$WORK/awsbin/aws"
export AWS_CALLS="$WORK/aws-calls"
fake_session() {
  local out=$1; shift
  : > "$AWS_CALLS"
  env -u SESSION_CONFIRM -u LLMDHUNT_AMI_ID -u PURCHASE PATH="$WORK/awsbin:$PATH" OUT="$WORK/never" "$@" > "$out" 2>&1
}
fake_session "$WORK/p-unset" bash "$S" --print-schedule; rc=$?
check "without PURCHASE even the schedule is refused, before any AWS call" \
  "[ $rc != 0 ] && grep -qF 'PURCHASE is unset' '$WORK/p-unset' && [ ! -s '$AWS_CALLS' ]"
fake_session "$WORK/p-bogus" PURCHASE=reserved bash "$S" --print-schedule; rc=$?
check "a PURCHASE other than spot or on-demand is refused" "[ $rc != 0 ] && grep -qF \"PURCHASE is 'reserved', not spot or on-demand\" '$WORK/p-bogus'"
fake_session "$WORK/p-spot" PURCHASE=spot bash "$S" --print-purchase; rc=$?
check "spot's rate is its cap and needs no AWS call" \
  "[ $rc = 0 ] && grep -qx 'purchase=spot compute_rate=0.70 all_in_rate=0.7792 worst_case_usd=0.8961' '$WORK/p-spot' && [ ! -s '$AWS_CALLS' ]"
fake_session "$WORK/p-od" PURCHASE=on-demand FAKE_OD_PRICE=1.2370000000 bash "$S" --print-purchase; rc=$?
check "on-demand reads the price with one read-only Price List call, and its worst case is \$1.5136" \
  "[ $rc = 0 ] && grep -qx 'purchase=on-demand compute_rate=1.237 all_in_rate=1.3162 worst_case_usd=1.5136' '$WORK/p-od' && [ \"\$(grep -c '^aws pricing get-products ' '$AWS_CALLS')\" = 1 ]"
fake_session "$WORK/p-od-ok" PURCHASE=on-demand FAKE_OD_PRICE=2.5294 bash "$S" --print-purchase; rc1=$?
fake_session "$WORK/p-od-no" PURCHASE=on-demand FAKE_OD_PRICE=2.5295 bash "$S" --print-purchase; rc2=$?
check "the on-demand cap falls between \$2.5294/h, accepted, and \$2.5295/h, refused" "[ $rc1 = 0 ] && [ $rc2 != 0 ] && grep -qF 'not under \$3.00' '$WORK/p-od-no'"
fake_session "$WORK/p-odfail" PURCHASE=on-demand FAKE_PRICING_FAIL=1 bash "$S" --print-purchase; rc=$?
check "a failed price read falls back to the pinned \$1.237/h and says so" \
  "[ $rc = 0 ] && grep -q '^rate_source=pinned: ' '$WORK/p-odfail' && grep -qF 'compute_rate=1.237 ' '$WORK/p-odfail'"
fake_session "$WORK/p-zones" PURCHASE=spot bash "$S" --print-zones; rc=$?
check "spot tries only zones under its cap, with the reclaimed zone last" \
  "[ $rc = 0 ] && grep -qx 'zones=ap-northeast-2c ap-northeast-2a' '$WORK/p-zones'"
fake_session "$WORK/p-model" PURCHASE=spot MODEL=other bash "$S" --print-schedule; rc=$?
check "a caller who sets MODEL is refused rather than ignored" "[ $rc != 0 ] && grep -qF 'MODEL is set' '$WORK/p-model'"
fake_session "$WORK/p-noconfirm" PURCHASE=spot LLMDHUNT_AMI_ID=ami-0123456789abcdef0 bash "$S"; rc=$?
check "without SESSION_CONFIRM=yes nothing is built or bought" \
  "[ $rc != 0 ] && grep -qF 'SESSION_CONFIRM=yes is required' '$WORK/p-noconfirm' && [ ! -s '$AWS_CALLS' ]"

# ---------------------------------------------------------------- the user-data
PURCHASE=spot bash "$S" --print-user-data > "$WORK/ud.sh" 2>&1; rc=$?
check "the user-data renders, parses, has no placeholder and fits EC2's 16 KB" \
  "[ $rc = 0 ] && bash -n '$WORK/ud.sh' && ! grep -q _PLACEHOLDER '$WORK/ud.sh' && [ \$(wc -c < '$WORK/ud.sh') -lt 16384 ]"
check "the instance stops itself at 3,840 s, refuses a GPU other than one A10G or a driver older than 580, and runs the runner with the harness end" \
  "grep -qF 'sleep 3840; shutdown -h now' '$WORK/ud.sh' && grep -qF 'PREFLIGHT FAILED: not one A10G' '$WORK/ud.sh' && grep -qF -- '-ge 580' '$WORK/ud.sh' && grep -qF 'bash /opt/hunt/in/runner.sh /opt/hunt/in /src/hunt-run/sweep \"\$HE\"' '$WORK/ud.sh'"
check "the user-data logs in to no registry, since the image is anonymous Docker Hub" "! grep -q 'docker login' '$WORK/ud.sh'"
check "the instance role reaches only the results bucket" \
  "grep -qF 'ROLE_POLICY=\"{\\\"Version\\\":\\\"2012-10-17\\\",\\\"Statement\\\":[{\\\"Effect\\\":\\\"Allow\\\",\\\"Action\\\":[\\\"s3:PutObject\\\",\\\"s3:GetObject\\\"],\\\"Resource\\\":\\\"arn:aws:s3:::\$BUCKET/*\\\"}]}\"' '$S'"

# ---------------------------------------------------------------- the runner's pins
check "the runner pins vllm-openai v0.34.0 by digest and its revision label" \
  "[ \"\$(rv IMG)\" = '\"vllm/vllm-openai@sha256:20fdb089454afbb324efa4110a2c025ff7b27cc1a086e07aa580b18df8ad1ce1\"' ] && [ \"\$(rv VLLM_COMMIT)\" = 62d4bc3c7e33b1b6c906e233e6af2d3506c482ca ] && grep -qF 'grep -q \" \$VLLM_COMMIT\\\$\" \"\$D/image-identity.txt\"' '$R'"
check "the runner pins Qwen2-VL-2B-Instruct at its Hugging Face commit" \
  "[ \"\$(rv MODEL)\" = Qwen/Qwen2-VL-2B-Instruct ] && [ \"\$(rv MODEL_REV)\" = 895c3a49bc3fa70a340399125c650a463535e71c ] && grep -qF -- '--revision \"\$MODEL_REV\"' '$R'"
check "the replicas publish KV events on 5557 under kv@<served model>, report cached tokens, and keep vLLM's default block size" \
  "grep -qF '\"enable_kv_cache_events\":true,\"publisher\":\"zmq\",\"endpoint\":\"tcp://*:5557\",\"topic\":\"kv@' '$R' && grep -qF -- '--enable-prompt-tokens-details' '$R' && ! grep -q -- '--block-size' '$R' && ! grep -q -- '--prefix-match-unit' '$R'"
check "the session's go.mod pin and its stated router commit agree" \
  "grep -qxF \"	github.com/llm-d/llm-d-router \$(sv ROUTER_MODULE_VERSION)\" '$DIR/probe/go.mod' && [ \"\$(sv ROUTER_MODULE_VERSION | sed 's/.*-//')\" = \"\$(sv ROUTER_COMMIT | cut -c1-12)\" ]"

# ---------------------------------------------------------------- the runner against a fake docker
mkdir -p "$WORK/fakebin" "$WORK/in"
cat > "$WORK/fakebin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$FAKE_LOG"
case "$1" in
  pull) [ -z "${FAKE_PULL_FAIL:-}" ] || exit 1; echo pulled ;;
  image) echo "[\"vllm/vllm-openai@${FAKE_DIGEST:-sha256:20fdb089454afbb324efa4110a2c025ff7b27cc1a086e07aa580b18df8ad1ce1}\"] ${FAKE_REV:-62d4bc3c7e33b1b6c906e233e6af2d3506c482ca}" ;;
  run) case " $* " in *" --rm "*) echo 0.34.0 ;; *) echo cid ;; esac ;;
  network) echo net ;;
  inspect) echo "${FAKE_RUNNING:-true}" ;;
  logs) [ -n "${FAKE_NO_KV:-}" ] || echo "INFO GPU KV cache size: ${FAKE_KV:-107,520} tokens, Maximum concurrency for 4,096 tokens per request: 26.25x" ;;
  rm) ;;
esac
EOF
cat > "$WORK/fakebin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$FAKE_LOG"
case "$*" in *"/health"*) [ -z "${FAKE_UNHEALTHY:-}" ] ;; *"/metrics"*) echo "vllm:prefix_cache_hits_total 0" ;; esac
EOF
printf '#!/bin/bash\necho "name, memory.used [MiB], memory.total [MiB]"\n' > "$WORK/fakebin/nvidia-smi"
cat > "$WORK/in/probe" <<'EOF'
#!/bin/bash
echo "probe $*" >> "$FAKE_LOG"
out=""; while [ $# -gt 0 ]; do [ "$1" = -out ] && out=$2; shift; done
mkdir -p "$out"; : > "$out/requests.jsonl"; : > "$out/events.jsonl"
exit "${FAKE_PROBE_RC:-0}"
EOF
chmod +x "$WORK/fakebin/"* "$WORK/in/probe"
cp "$V" "$WORK/in/"
fake_runner() {
  local name=$1; shift
  export FAKE_LOG="$WORK/$name.calls"; : > "$FAKE_LOG"
  env PATH="$WORK/fakebin:$PATH" "$@" bash "$R" "$WORK/in" "$WORK/$name" $(( $(date +%s) + 4000 )) > "$WORK/$name.out" 2>&1
}
fake_runner happy; rc=$?
check "the runner's whole path ends in 'all items done' and exits 0" "[ $rc = 0 ] && grep -q 'all items done, probe exited 0' '$WORK/happy/steps.log'"
check "replica A is ready before B is started, and both before the probe" \
  "awk '/docker run -d --name hunt-a/{a=NR} /docker run -d --name hunt-b/{b=NR} /^probe /{p=NR} END{exit !(a && b && p && a < b && b < p)}' '$WORK/happy.calls' && grep -q 'replica a: ready' '$WORK/happy/steps.log'"
check "the flood is A's logged KV capacity one and a half times over, in 1,024-token prompts (107,520 tokens -> 158)" \
  "grep -qx 'kv_cache_tokens=107520 flood_prompts=158' '$WORK/happy/flood.txt' && grep -qE '^probe .*-flood 158( |\$)' '$WORK/happy.calls'"
check "the probe gets both replicas, the served model, A as its renderer, two repetitions and the registered seed" \
  "grep -qE '^probe -pods a=172.30.0.10,b=172.30.0.11 -model qwen2vl -render-url http://172.30.0.10:8000 -out .* -seed 20261119 -reps 2 ' '$WORK/happy.calls'"
fake_runner pullfail FAKE_PULL_FAIL=1; rc=$?
check "a failed pull stops the run before any replica starts" "[ $rc = 2 ] && grep -q 'PULL FAILED' '$WORK/pullfail/steps.log' && ! grep -q 'docker run -d' '$WORK/pullfail.calls'"
fake_runner wrongdigest FAKE_DIGEST=sha256:00; rc=$?
check "an image whose digest is not the pinned one stops the run" "[ $rc = 2 ] && grep -q 'IMAGE IDENTITY FAILED' '$WORK/wrongdigest/steps.log'"
fake_runner wrongrev FAKE_REV=deadbeef; rc=$?
check "an image whose revision label is not v0.34.0's commit stops the run" "[ $rc = 2 ] && grep -q 'IMAGE IDENTITY FAILED' '$WORK/wrongrev/steps.log'"
fake_runner exited FAKE_UNHEALTHY=1 FAKE_RUNNING=false; rc=$?
check "a replica that exited stops the run without waiting out its bound, and its log is kept" \
  "[ $rc = 2 ] && grep -q 'REPLICA A NOT READY' '$WORK/exited/steps.log' && [ -e '$WORK/exited/replica-a.log' ] && ! grep -q '^probe ' '$WORK/exited.calls'"
fake_runner nokv FAKE_NO_KV=1; rc=$?
check "a KV capacity that cannot be read stops the run before the probe, since the flood could not be sized" \
  "[ $rc = 2 ] && grep -q 'KV CAPACITY UNREAD' '$WORK/nokv/steps.log' && ! grep -q '^probe ' '$WORK/nokv.calls'"
fake_runner hugekv FAKE_KV=500,000; rc=$?
check "a KV capacity the probe's bound cannot flood stops the run" "[ $rc = 2 ] && grep -q 'over the 400' '$WORK/hugekv/steps.log'"
fake_runner probefail FAKE_PROBE_RC=1; rc=$?
check "a failed probe still collects both replicas' metrics and logs, and the run exits 3" \
  "[ $rc = 3 ] && [ -e '$WORK/probefail/metrics-a-after.txt' ] && [ -e '$WORK/probefail/replica-b.log' ] && grep -q 'probe: exited 1' '$WORK/probefail/steps.log'"

# ---------------------------------------------------------------- the probe against a fake vLLM, and the verdict on its records
FX="$WORK/fx"
( cd "$DIR/probe" && GOFLAGS=-mod=readonly GOTMPDIR="$SCRATCH" PROBE_OUT="$FX" go test -count=1 ./... ) > "$WORK/go-test.log" 2>&1; rc=$?
check "the probe's offline tests pass: calibration agrees, H1 and H2 show as predicted, the #3788 control reproduces, and without reports nothing is stale" \
  "[ $rc = 0 ] && grep -q '^ok ' '$WORK/go-test.log'"
judge() {
  local name=$1 src=$2
  mkdir -p "$WORK/j-$name/sweep" "$WORK/j-$name/out"
  [ -z "$src" ] || cp -r "$src" "$WORK/j-$name/sweep/probe"
  OUT="$WORK/j-$name/out" PURCHASE=spot bash "$S" --judge "$WORK/j-$name/sweep" > "$WORK/j-$name.out" 2>&1
}
judge report "$FX/report"; rc=$?
check "on the fake's records the session judges calib=pass bias=confirmed dedup=confirmed salt=reproduced, mm void (the fake has no /render), and exits 0" \
  "[ $rc = 0 ] && grep -qx 'verdicts=calib=pass bias=confirmed dedup=confirmed salt=reproduced mm=void' '$WORK/j-report.out'"
check "the confirmed dedup verdict names four stores and one removal per engine block for the full-report prefix, and one of each for the control" \
  "grep -qF 'dedup_detail=rep0 full: 16 engine blocks, stores per block [4], removals per block [1], post-eviction predicted r16=1024 r64=1024 realized=0' '$WORK/j-report/out/verdict.txt' && grep -qF 'rep0 incremental: 16 engine blocks, stores per block [1], removals per block [1]' '$WORK/j-report/out/verdict.txt'"
judge noreport "$FX/noreport"; rc=$?
check "an engine that sends no reused-block reports gives dedup=refuted, which is a result, so the session still exits 0" \
  "[ $rc = 0 ] && grep -qF 'dedup=refuted' '$WORK/j-noreport.out'"
judge empty ""; rc=$?
check "a sweep with no probe records exits 2" "[ $rc = 2 ]"

# mutate_fx NAME PYTHON: a copy of the report fixture with requests or events rewritten, judged as the session would.
mutate_fx() {
  local name=$1 code=$2
  cp -r "$FX/report" "$WORK/fx-$name"
  python3 - "$WORK/fx-$name" "$code" <<'EOF'
import json, sys
d, code = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(f"{d}/requests.jsonl")]
events = [json.loads(l) for l in open(f"{d}/events.jsonl")]
exec(code)
open(f"{d}/requests.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in rows))
open(f"{d}/events.jsonl", "w").write("".join(json.dumps(e) + "\n" for e in events))
EOF
  judge "$name" "$WORK/fx-$name"
}
mutate_fx calib 'next(r for r in rows if r["hyp"] == "calib" and r["measured"])["predictions"]["r16"]["a"]["cached_tokens"] = 496'
rc=$?
check "a calibration row where the router and the engine disagree voids every hypothesis and exits 2" \
  "[ $rc = 2 ] && grep -qx 'verdicts=calib=fail bias=void dedup=void salt=void mm=void' '$WORK/j-calib.out'"
mutate_fx noevict 'next(r for r in rows if r["id"].endswith("dedup-full-r0-post-a"))["realized_cached_tokens"] = 1024'
rc=$?
check "a post-flood row the engine still served voids dedup, since the flood did not evict" \
  "[ $rc = 2 ] && grep -qF 'dedup=void' '$WORK/j-noevict.out' && grep -qF 'the flood did not evict' '$WORK/j-noevict/out/verdict.txt'"
mutate_fx noremove 'events[:] = [dict(e, events=[x for x in (e.get("events") or []) if x["type"] != "BlockRemoved"]) for e in events]'
rc=$?
check "without BlockRemoved on the wire for the prefix, dedup is void, since nothing shows the engine announced the eviction" \
  "[ $rc = 2 ] && grep -qF 'dedup=void' '$WORK/j-noremove.out' && grep -qF 'never removed on the wire' '$WORK/j-noremove/out/verdict.txt'"
mutate_fx stalecontrol 'next(r for r in rows if r["id"].endswith("dedup-incremental-r0-post-a"))["predictions"]["r16"]["a"]["cached_tokens"] = 1024'
rc=$?
check "a stale control voids dedup, since then the reports are not what kept the prefix" \
  "[ $rc = 2 ] && grep -qF 'dedup=void' '$WORK/j-stalecontrol.out'"
mutate_fx parity 'next(r for r in rows if r["id"].endswith("bias-repeat512-r0-probe-a"))["engine_prompt_tokens"] = 513'
rc=$?
check "a row where the router and the engine counted different prompts voids its hypothesis" \
  "[ $rc = 2 ] && grep -qF 'bias=void' '$WORK/j-parity.out' && grep -qF 'token parity' '$WORK/j-parity/out/verdict.txt'"
mutate_fx engineoff 'next(r for r in rows if r["id"].endswith("bias-shared544-r0-probe-a"))["realized_cached_tokens"] = 544'
rc=$?
check "an engine that served more than its block rule allows voids bias rather than refuting it" \
  "[ $rc = 2 ] && grep -qF 'bias=void' '$WORK/j-engineoff.out' && grep -qF 'not the 512 its block rule gives' '$WORK/j-engineoff/out/verdict.txt'"
mutate_fx nobias 'exec("for r in rows:\n if r[\"hyp\"] == \"bias\" and r[\"measured\"]:\n  r[\"predictions\"][\"r16\"][\"a\"][\"cached_tokens\"] = r[\"realized_cached_tokens\"]; r[\"predictions\"][\"r64\"][\"a\"][\"cached_tokens\"] = r[\"realized_cached_tokens\"]")'
rc=$?
check "routers that predict exactly what the engine served refute bias" "[ $rc = 0 ] && grep -qF 'bias=refuted' '$WORK/j-nobias.out'"
mutate_fx twosizes 'events.append({"unix_nanos": 1, "pod": "a", "events": [{"type": "BlockStored", "block_size": 16}]})'
rc=$?
check "an engine that announced two block sizes voids every hypothesis" "[ $rc = 2 ] && grep -qF 'bias=void dedup=void' '$WORK/j-twosizes.out'"
mutate_fx error 'next(r for r in rows if r["id"].endswith("dedup-full-r0-pre-a"))["error"] = "send: reset"'
rc=$?
check "a failed row voids its hypothesis" "[ $rc = 2 ] && grep -qF 'dedup=void' '$WORK/j-error.out'"

echo "$failures failure(s)"
[ "$failures" = 0 ]
