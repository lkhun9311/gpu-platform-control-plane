#!/usr/bin/env bash
#
# Checks hack/lib/allreduce-arms.sh without a cluster, credentials or money: the arm shapes, the registered job order,
# the rendered jobs, the shell each Pod runs (executed here against stub tools), the qualification job's output as
# the scorer reads it, and the smoke stop rule.
#
#   bash hack/test/check-allreduce-arms-lib.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
log() { echo "log: $*" >>"$work/log"; }

# shellcheck source=hack/lib/allreduce-arms.sh
source hack/lib/allreduce-arms.sh
AR_NS=train-a AR_QUEUE=gpu-train-a AR_GPU_CLASS=a10g
AR_TORCH_IMAGE=docker.io/pytorch/pytorch@sha256:c8268a92a69bd500f8be0e665b2630ee006dadaf7bfbc24249141b15ff622755
AR_NCCLTESTS_IMAGE=registry.example/nccl-tests@sha256:0000000000000000000000000000000000000000000000000000000000000000
AR_BENCH_FILE=experiments/multi-gpu-throughput/allreduce_bench.py
AR_STEP_FILE=experiments/multi-gpu-throughput/ddp_step_bench.py

# --- shapes -------------------------------------------------------------------------------------------------------
for pair in "nccltests-1pod4gpu 1 4" "allreduce-1pod4gpu 1 4" "allreduce-4pod1gpu 4 1" "ddp-1pod4gpu 1 4" "ddp-4pod1gpu 4 1"; do
  read -r arm want <<<"$pair"
  got="$(ar_shape "$arm")"
  [[ "$got" == "${pair#* }" ]] && ok "$arm is ${pair#* }" || bad "$arm is '$got', want '${pair#* }'"
done
ar_shape allreduce-2pod2gpu >/dev/null && bad "an unregistered arm has a shape" || ok "an unregistered arm is refused"
[[ "$(wc -w <<<"$AR_ARMS")" == 5 ]] && ok "five arms" || bad "AR_ARMS is '$AR_ARMS'"

# --- the registered order -----------------------------------------------------------------------------------------
order="$(ar_job_order)"
[[ "$(wc -l <<<"$order")" == 25 ]] && ok "25 registered jobs" || bad "$(wc -l <<<"$order") jobs"
for arm in $AR_ARMS; do
  n="$(awk -v a="$arm" '$2 == a' <<<"$order" | wc -l)"
  reps="$(awk -v a="$arm" '$2 == a {print $3}' <<<"$order" | sort -n | paste -sd' ')"
  [[ "$n" == 5 && "$reps" == "1 2 3 4 5" ]] && ok "$arm runs repetitions 1 to 5" || bad "$arm: $n jobs, repetitions '$reps'"
done
# The order the registration publishes, pinned: a change to the seed, the arm list or the shuffle shows here.
pinned="$(cat <<'EOF'
1 nccltests-1pod4gpu 2
2 ddp-4pod1gpu 2
3 allreduce-4pod1gpu 5
4 allreduce-4pod1gpu 1
5 ddp-1pod4gpu 4
6 allreduce-4pod1gpu 4
7 nccltests-1pod4gpu 3
8 allreduce-1pod4gpu 3
9 ddp-1pod4gpu 5
10 ddp-4pod1gpu 3
11 ddp-1pod4gpu 2
12 allreduce-4pod1gpu 3
13 nccltests-1pod4gpu 5
14 allreduce-1pod4gpu 4
15 nccltests-1pod4gpu 4
16 nccltests-1pod4gpu 1
17 allreduce-4pod1gpu 2
18 ddp-1pod4gpu 1
19 ddp-1pod4gpu 3
20 allreduce-1pod4gpu 5
21 ddp-4pod1gpu 4
22 allreduce-1pod4gpu 2
23 ddp-4pod1gpu 5
24 allreduce-1pod4gpu 1
25 ddp-4pod1gpu 1
EOF
)"
[[ "$order" == "$pinned" ]] && ok "seed $AR_ORDER_SEED gives the published order" || bad "the order moved:
$(diff <(echo "$pinned") <(echo "$order"))"
[[ "$(ar_job_order 1)" != "$order" ]] && ok "another seed gives another order" || bad "the seed does not reach the shuffle"

# --- rendered jobs ------------------------------------------------------------------------------------------------
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
j="$(ar_render_job c-x allreduce-1pod4gpu "true")"
[[ "$(field 'd["spec"]["gpuCount"], "distributed" in d["spec"], d["spec"]["image"]' <<<"$j")" == "(4, False, '$AR_TORCH_IMAGE')" ]] &&
  ok "one Pod of four renders gpuCount 4, no distributed, the torch image" || bad "one Pod of four: $j"
j="$(ar_render_job c-x ddp-4pod1gpu "true")"
[[ "$(field 'd["spec"]["gpuCount"], d["spec"]["distributed"]["worldSize"]' <<<"$j")" == "(1, 4)" ]] &&
  ok "four Pods of one render gpuCount 1, worldSize 4" || bad "four Pods of one: $j"
j="$(ar_render_job c-x nccltests-1pod4gpu "true")"
[[ "$(field 'd["spec"]["image"], d["spec"]["gpuClass"], d["spec"]["queue"]' <<<"$j")" == "('$AR_NCCLTESTS_IMAGE', 'a10g', 'gpu-train-a')" ]] &&
  ok "nccl-tests renders its own image, the class and the queue" || bad "nccl-tests: $j"
AR_GPU_CLASS="" ar_render_job c-x ddp-1pod4gpu true >/dev/null 2>&1 && bad "a job without a class rendered" || ok "a job without a class is refused"

# --- each Pod's shell, executed against stub tools ---------------------------------------------------------------
mkdir -p "$work/bin" "$work/home" "$work/tmp"
cat >"$work/bin/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nshm 1048576 0 1048576 0%% /dev/shm\n'
EOF
for t in torchrun python mpirun; do printf '#!/bin/sh\necho "STUB %s $*"\n' "$t" >"$work/bin/$t"; done
# topo -m underlines its header as the paid session of 2026-10-27 captured it, with no terminal attached; the
# plain header this stub printed before is what let a scorer that could not read the real one pass here.
# The bus IDs and the topo -p2p r matrix are run 2's capture (hack/four-gpu/2026-10-27-run2/c/qualification): one bus,
# 00, and devices 1B to 1E, where this stub had put the cards on buses 1B to 1E.
cat >"$work/bin/nvidia-smi" <<'EOF'
#!/bin/sh
n="${STUB_GPUS:-4}"
case "$*" in
  -L) i=0; while [ "$i" -lt "$n" ]; do echo "GPU $i: NVIDIA A10G (UUID: GPU-5c1d5a84-0000-0000-0000-00000000000$i)"; i=$((i + 1)); done ;;
  --query-gpu*) i=0; while [ "$i" -lt "$n" ]; do echo "$i, GPU-5c1d5a84-0000-0000-0000-00000000000$i, 00000000:00:1$(printf %X $((i + 11))).0, 580.178.04"; i=$((i + 1)); done ;;
  "topo -m") printf '\t\033[4mGPU0\tGPU1\tGPU2\tGPU3\tCPU Affinity\tNUMA Affinity\tGPU NUMA ID\033[0m\nGPU0\t X \tPHB\tPHB\tPHB\t0-47\nGPU1\tPHB\t X \tPHB\tPHB\t0-47\nGPU2\tPHB\tPHB\t X \tPHB\t0-47\nGPU3\tPHB\tPHB\tPHB\t X \t0-47\n' ;;
  "topo -p2p r") printf ' \t\033[4mGPU0\tGPU1\tGPU2\tGPU3\t\033[0m\n GPU0\tX\tNS\tNS\tNS\t\n GPU1\tNS\tX\tNS\tNS\t\n GPU2\tNS\tNS\tX\tNS\t\n GPU3\tNS\tNS\tNS\tX\t\n' ;;
  *) echo "stub nvidia-smi $*" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$work/bin/sleep"
chmod +x "$work/bin/"*
runpod() { (cd "$work/tmp" && HOME="$work/home" PATH="$work/bin:$PATH" sh -c "$1" 2>&1); }

body="$(AR_BENCH_TARGET="$work/tmp/b.py" ar_arm_body c-1 allreduce-1pod4gpu)"
out="$(AR_BENCH_TARGET="$work/tmp/b.py" runpod "$body")"
grep -qx "AR_RUN_ID c-1 $(hostname)" <<<"$out" && ok "the run id is printed" || bad "no run id: $out"
grep -qx "AR_NCCL_CONF absent /etc/nccl.conf" <<<"$out" && grep -qx "AR_NCCL_CONF absent $work/home/.nccl.conf" <<<"$out" &&
  ok "both NCCL configuration files are reported" || bad "configuration files: $out"
[[ "$(grep '^AR_NCCL_ENV ' <<<"$out" | sort | paste -sd' ')" == "AR_NCCL_ENV NCCL_DEBUG=INFO AR_NCCL_ENV NCCL_DEBUG_SUBSYS=INIT,GRAPH,ENV" ]] &&
  ok "the Pod starts with exactly the two NCCL variables" || bad "NCCL env: $(grep AR_NCCL_ENV <<<"$out")"
grep -qx "AR_SHM_KB 1048576" <<<"$out" && ok "/dev/shm's size is printed" || bad "no shm: $out"
grep -q "^STUB torchrun --standalone --nproc-per-node=4 $work/tmp/b.py" <<<"$out" && ok "one Pod of four runs torchrun with four processes" || bad "launcher: $out"
cmp -s "$work/tmp/b.py" "$AR_BENCH_FILE" && ok "the bench arrives byte for byte" || bad "the decoded bench differs"
echo '# a ~/.nccl.conf' >"$work/home/.nccl.conf"
out="$(AR_BENCH_TARGET="$work/tmp/b.py" runpod "$body")"
grep -qx "AR_NCCL_CONF present $work/home/.nccl.conf" <<<"$out" && ok "a ~/.nccl.conf is reported present" || bad "a present file: $out"
rm "$work/home/.nccl.conf"
# A tampered copy: the line that decodes the bench is altered so the hash cannot match.
tampered="$(sed "s|base64 -d >$work/tmp/b.py|base64 -d >$work/tmp/b.py; echo x >>$work/tmp/b.py|" <<<"$body")"
out="$(AR_BENCH_TARGET="$work/tmp/b.py" runpod "$tampered"; echo "rc=$?")"
grep -qx "rc=86" <<<"$out" && ! grep -q "^STUB torchrun" <<<"$out" && ok "a script that is not the approved one exits 86 before it runs" ||
  bad "tampered script: $out"

out="$(AR_STEP_TARGET="$work/tmp/s.py" runpod "$(AR_STEP_TARGET="$work/tmp/s.py" ar_arm_body c-2 ddp-4pod1gpu)")"
grep -q "^STUB python $work/tmp/s.py" <<<"$out" && ok "four Pods of one run python, one process each" || bad "ddp-4pod1gpu: $out"
grep -q "STEP_REHEARSAL_CPU" <<<"$(ar_arm_body c-2 ddp-4pod1gpu)" && bad "a paid body carries the CPU rehearsal switch" ||
  ok "a paid body carries no CPU rehearsal switch"
grep -q "STEP_REHEARSAL_CPU=1" <<<"$(AR_REHEARSAL=1 ar_arm_body c-2 ddp-4pod1gpu)" && ok "AR_REHEARSAL=1 switches the DDP arms to CPU" ||
  bad "the rehearsal switch is missing"
body="$(ar_arm_body c-3 nccltests-1pod4gpu)"
for flag in "-b 1M" "-e 256M" "-f 4" "-g 1" "-c 1" "-n 100" "-w 20" "-a 3" "-np 4"; do
  grep -q -- " $flag " <<<"$body " || bad "nccl-tests is not run with $flag"
done
ok "nccl-tests carries the registered flags"
out="$(runpod "$body")"
[[ "$(grep -c '^AR_GPU ' <<<"$out")" == 4 ]] && grep -q "^STUB mpirun --allow-run-as-root -np 4" <<<"$out" &&
  ok "nccl-tests records each card and starts four processes" || bad "nccl-tests Pod: $out"

# --- the qualification job, read by the scorer ---------------------------------------------------------------------
mkdir -p "$work/q"
runpod "$(ar_qualification_body)" >"$work/q/qualification.log"
q="$(python3 -c '
import sys
sys.path.insert(0, "experiments/multi-gpu-throughput")
import analyze
from pathlib import Path
print(analyze.judge_qualification(Path(sys.argv[1])))' "$work/q")"
[[ "$q" == "[]" ]] && ok "the qualification output is a valid Q" || bad "Q from the qualification body: $q"
out="$(STUB_GPUS=3 runpod "$(ar_qualification_body)"; echo "rc=$?")"
grep -qx "rc=3" <<<"$out" && grep -q "AR_QUALIFY_REFUSED 3 distinct" <<<"$out" && ok "three cards refuse the qualification" || bad "three cards: $out"

# --- a terminal answer that arrives after the budget ---------------------------------------------------------------
# The status query begins inside the budget and answers Succeeded after it; the job must still be marked a timeout.
mkdir -p "$work/kbin"
cat >"$work/kbin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"get mltrainingjob"*jsonpath*) python3 -c 'import time; time.sleep(2)'; echo Succeeded ;;
  *"get job"*jsonpath*) echo Complete ;;
  *"get pods"*) echo '{"items": []}' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$work/kbin/kubectl"
(
  PATH="$work/kbin:$PATH" AR_CONTEXT=stub AR_OUT="$work/late" AR_BUDGET=1
  mkdir -p "$AR_OUT"
  ar_run_job c-late ddp-1pod4gpu "$AR_OUT/job" >/dev/null 2>&1
)
grep -q "not terminal within the 1s budget" "$work/late/job/TIMEOUT" 2>/dev/null &&
  ok "a Succeeded read after the budget is a timeout: $(cat "$work/late/job/TIMEOUT")" ||
  bad "a late Succeeded was accepted: TIMEOUT is '$(cat "$work/late/job/TIMEOUT" 2>&1)', elapsed $(cat "$work/late/job/elapsed-seconds" 2>&1)"

# --- the smoke stop rule -------------------------------------------------------------------------------------------
AR_OUT="$work/run" AR_SCORER="$work/scorer" AR_SCORER_ARGS=""
mkdir -p "$AR_OUT"
cat >"$work/scorer" <<'EOF'
import sys
job = sys.argv[sys.argv.index("--job") + 1]
arm = open(job + "/arm").read().strip()
print(("INVALID " if arm == "allreduce-4pod1gpu" else "VALID ") + job)
sys.exit(1 if arm == "allreduce-4pod1gpu" else 0)
EOF
ar_run_job() { mkdir -p "$3"; echo "$2" >"$3/arm"; echo "$2" >>"$work/ran"; }
ar_run_all >/dev/null && bad "a failing smoke job did not stop the run" || ok "a failing smoke job stops the run"
[[ "$(paste -sd' ' "$work/ran")" == "nccltests-1pod4gpu allreduce-1pod4gpu allreduce-4pod1gpu" ]] &&
  ok "nothing ran after the failing smoke job" || bad "ran: $(paste -sd' ' "$work/ran")"
grep -q "smoke job allreduce-4pod1gpu is not valid" "$AR_OUT/STOPPED" && ok "STOPPED names the job" || bad "STOPPED: $(cat "$AR_OUT/STOPPED")"
rm -rf "$AR_OUT" "$work/ran"
mkdir -p "$AR_OUT"
printf 'import sys\nsys.exit(0)\n' >"$work/scorer"
ar_run_all >/dev/null && ok "passing smoke jobs run on" || bad "passing smoke jobs stopped"
[[ "$(wc -l <"$work/ran")" == 30 ]] && ok "five smoke jobs and twenty-five registered jobs ran" || bad "$(wc -l <"$work/ran") jobs ran"

if [[ $fails -ne 0 ]]; then
  echo "check-allreduce-arms-lib: $fails failure(s)"
  exit 1
fi
echo "check-allreduce-arms-lib: all checks passed"
