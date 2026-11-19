#!/bin/bash
# Derives one item's pins file from a vLLM clone, so every pinned hash comes from git and not from a hand edit.
#
#   derive-pins.sh gdn|kda|stride <vLLM clone>   > the item's pins file
#
# Every state pins the same seven files, the three items' sources and tests together.
# A state's own item's files are what its diff makes of 8700cc9ba0, and the other items' files stay 8700cc9ba0's.
# That is the isolation proof: no item's fix or test can be in another item's container and still pass its pins.
# The last block of lines pins the same seven files at the commit the item's diff was written on.
# Those lines are records, which the state scripts do not read, and the offline test holds them equal to the base or AFTER lines.
set -euo pipefail
ITEM=$1
SRC=$2
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd
OPS=vllm/third_party/flash_linear_attention/ops
PATHS="$OPS/index.py tests/kernels/fla/test_chunk_indices.py $OPS/kda.py tests/kernels/fla/test_fused_recurrent_kda.py $OPS/fused_recurrent.py $OPS/fused_sigmoid_gating.py tests/kernels/fla/test_state_index_stride.py"
case $ITEM in
  # #68414's diff is commit d713349e52, whose parent is 8700cc9ba0, so that commit's files are its AFTER.
  gdn) STATES="base: after:fix.diff"; REF=fixcommit-d713349e52; REF_COMMIT=d713349e52fed2b2746ce1e48fae6077c79d1cc2 ;;
  kda) STATES="base: before:kda-test.diff after:kda-fix.diff"; REF=diffbase-428c371b32; REF_COMMIT=428c371b32c18a788def35abea1cb9f579278381 ;;
  stride) STATES="base: before:stride-test.diff after:stride-fix.diff"; REF=diffbase-545ef08189; REF_COMMIT=545ef081895681ba4c2aa3c6699326e3a2f3cbf7 ;;
  *) echo "unknown item $ITEM" >&2; exit 2 ;;
esac
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# tree DIR COMMIT: the seven paths as they are at COMMIT, absent ones left absent.
tree() {
  local p
  for p in $PATHS; do
    if git -C "$SRC" cat-file -e "$2:$p" 2>/dev/null; then
      mkdir -p "$1/$(dirname "$p")"
      git -C "$SRC" show "$2:$p" > "$1/$p"
    fi
  done
}
# pins NAME DIR: one line per path.
pins() {
  local p
  for p in $PATHS; do
    if [ -e "$2/$p" ]; then echo "$1 $(sha256sum "$2/$p" | cut -d' ' -f1) $p"; else echo "$1 absent $p"; fi
  done
}
for sd in $STATES; do
  st=${sd%%:*}; d=${sd#*:}
  tree "$T/$st" "$BASE"
  # git apply outside a repository applies to the directory it runs in, as it does in the image's dist-packages.
  [ -z "$d" ] || (cd "$T/$st" && git apply "$HERE/$d")
  pins "$st" "$T/$st"
done
tree "$T/ref" "$REF_COMMIT"
pins "$REF" "$T/ref"
