#!/usr/bin/env bash
#
# Checks that the capture step keeps what was measured and admits what it could not draw.
#
# The interesting cases are the negative ones. A capture directory that quietly omits a run, or that leaves
# an old drawing in place when a new series could not be drawn, is worse than having no captures: it looks
# complete. Each case below is run against a repository laid out in a temporary directory, so the real
# docs/captures is never touched.
set -uo pipefail

SCRIPT="${SCRIPT:-$PWD/hack/capture-evidence.sh}"
PLOT="${PLOT:-$PWD/hack/plot-device-observation.py}"
WORK=$(mktemp -d /tmp/capture-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# A repository shape with four runs: one that measured a series, one that only saw cards, one that wrote
# records, and one that produced nothing at all.
mkdir -p "$WORK/hack"
cd "$WORK"

mkdir -p hack/qlgpu-withseries
{
  for i in 0 1 2 3 4; do
    printf '%s\tDCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-a",Hostname="w1",namespace="ql",pod="a2-borrow"} %s\n' \
      "$((1788000000 + i * 2))" "$((70 + i))"
  done
} > hack/qlgpu-withseries/device-util.tsv
echo "i-0abc" > hack/qlgpu-withseries/instance-id

mkdir -p hack/qlgpu-cardsonly
printf 'index, name, memory.total [MiB]\n0, NVIDIA A10G, 23028 MiB\n' > hack/qlgpu-cardsonly/preflight-nvidia-smi.csv

mkdir -p hack/m5b-run-records
echo '{"arm":"kv-aware"}' > hack/m5b-run-records/raw-kv-aware-1.jsonl

mkdir -p hack/qlgpu-nothing
echo '#!/bin/bash' > hack/qlgpu-nothing/user-data.sh

mkdir -p hack/qlgpu-unreadable
printf '1788000000\tSCRAPE_FAILED\n' > hack/qlgpu-unreadable/device-util.tsv

run() { PLOT="$PLOT" EVIDENCE="$WORK/captures" REPO="$WORK" bash "$SCRIPT" "$@" 2>"$WORK/err.txt"; }

run > "$WORK/out.txt"; rc=$?

# 1. A run that measured nothing is left alone, rather than given an empty capture.
[ -d "$WORK/captures/qlgpu-nothing" ] && bad "a run that measured nothing was captured anyway" \
  || ok "a run that measured nothing is skipped"

# 2. Each kind of measurement is kept.
[ -s "$WORK/captures/qlgpu-withseries/numbers.md" ] && ok "a series run is captured" \
  || bad "a series run produced no numbers.md"
[ -s "$WORK/captures/qlgpu-cardsonly/numbers.md" ] && ok "a run that only saw cards is captured" \
  || bad "a run with nvidia-smi output was skipped"
[ -s "$WORK/captures/m5b-run-records/numbers.md" ] && ok "a .jsonl record run is captured" \
  || bad "a run whose records are .jsonl was skipped -- this omitted every M5-b measurement once already"

# 3. The drawing happens, and carries the attribution.
if [ -s "$WORK/captures/qlgpu-withseries/device.svg" ] \
   && grep -q 'a2-borrow' "$WORK/captures/qlgpu-withseries/device.svg"; then
  ok "the series is drawn and names the pod that held the card"
else
  bad "the series was not drawn, or the drawing lost the pod label"
fi

# 4. A series that cannot be read is admitted, not silently dropped, and never leaves a drawing behind.
if [ -s "$WORK/captures/qlgpu-unreadable/device-NOT-DRAWN.txt" ] \
   && [ ! -e "$WORK/captures/qlgpu-unreadable/device.svg" ]; then
  ok "an undrawable series is recorded as undrawable, with no drawing left in place"
else
  bad "an undrawable series left no explanation, or left a drawing"
fi
grep -q 'not drawable' "$WORK/captures/INDEX.md" \
  && ok "the index says which capture could not be drawn" \
  || bad "the index does not distinguish a drawn capture from an undrawable one"
[ "$rc" -ne 0 ] && ok "a capture with problems exits nonzero" \
  || bad "a capture that could not draw a series still exited zero"
grep -q 'could not draw' "$WORK/err.txt" \
  && ok "the problem is reported on stderr" \
  || bad "nothing was written to stderr about the failure"

# 5. The index is rewritten from disk, not appended to.
#
# The first version of this check deleted only the capture and expected it to vanish from the index. It came
# back, correctly: the run directory was still there, so the capture was simply remade. What the index must
# not do is keep a line for something that is gone, so both the capture and the run it came from go.
rm -rf "$WORK/captures/qlgpu-cardsonly" hack/qlgpu-cardsonly
touch hack/qlgpu-withseries/device-util.tsv
run > /dev/null
grep -q 'qlgpu-cardsonly' "$WORK/captures/INDEX.md" \
  && bad "the index still lists a capture that is no longer on disk" \
  || ok "the index is rebuilt from disk rather than appended to"

# And a capture whose run is gone is still kept: the run directory is the thing that does not survive, which
# is the entire reason this step exists.
[ -s "$WORK/captures/m5b-run-records/numbers.md" ] \
  && ok "a capture outlives the run directory it came from" \
  || bad "the capture was removed when its run directory was"

printf 'capture-evidence: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
