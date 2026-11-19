#!/bin/bash
# Derives one item's pins file, or its list of files that differ from the image, from a vLLM clone, so every pinned hash comes from git and not from a hand edit.
#
#   derive-pins.sh kda|stride <vLLM clone>                 > the item's pins file
#   derive-pins.sh kda-differs|stride-differs <vLLM clone> > the item's differs file
#
# Run 3's image is vLLM CI's for 428c371b32, which is #68415's diff base.
# 8700cc9ba0, the image of runs 1 and 2, differs from both diff bases in vllm/utils/torch_utils.py, which both new tests import.
# Every state pins the same eight files: the three items' sources and tests together, and torch_utils.py.
# A state's own item's files are what its diff makes of 428c371b32, and every other file stays 428c371b32's.
# That is the isolation proof: no item's fix or test can be in another item's container and still pass its pins.
# The last two blocks pin the same eight files at the commit the item's diff was written on and at the item's own fix commit.
# Those lines are records, which the state scripts do not read, and the offline test holds them equal to the base and AFTER lines.
# The differs file lists every file that differs between the image's commit and the item's diff base.
# Each state refuses a run whose test process loaded any of them, so no file the tests import can differ from the base the diff was written on.
# #68414 is not part of run 3, and its pins.txt stays run 2's, derived on 8700cc9ba0.
set -euo pipefail
ITEM=$1
SRC=$2
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=428c371b32c18a788def35abea1cb9f579278381
OPS=vllm/third_party/flash_linear_attention/ops
PATHS="$OPS/index.py tests/kernels/fla/test_chunk_indices.py $OPS/kda.py tests/kernels/fla/test_fused_recurrent_kda.py $OPS/fused_recurrent.py $OPS/fused_sigmoid_gating.py tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py vllm/utils/torch_utils.py"
case $ITEM in
  # #68415's diff is commit 841cd50ff0 on 428c371b32, the image's own commit.
  kda | kda-differs) STATES="base: before:kda-test.diff after:kda-fix.diff"; DIFFBASE=428c371b32c18a788def35abea1cb9f579278381; FIXCOMMIT=841cd50ff065f983c49f0cbd3cb63ac662de4ed7 ;;
  # #68416's diff is commit efdbec4e2d on 545ef08189, six commits after the image's, for which CI published no image.
  stride | stride-differs) STATES="base: before:stride-test.diff after:stride-fix.diff"; DIFFBASE=545ef081895681ba4c2aa3c6699326e3a2f3cbf7; FIXCOMMIT=efdbec4e2d161d8a9e5daa87f0fd75181889cf61 ;;
  gdn) echo "#68414 is not part of run 3; pins.txt is run 2's, derived on 8700cc9ba0" >&2; exit 2 ;;
  *) echo "unknown item $ITEM" >&2; exit 2 ;;
esac
if [ "${ITEM%-differs}" != "$ITEM" ]; then
  git -C "$SRC" diff --name-only "$BASE" "$DIFFBASE" | LC_ALL=C sort
  exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# tree DIR COMMIT: the eight paths as they are at COMMIT, absent ones left absent.
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
tree "$T/diffbase" "$DIFFBASE"
pins "diffbase-${DIFFBASE:0:10}" "$T/diffbase"
tree "$T/fixcommit" "$FIXCOMMIT"
pins "fixcommit-${FIXCOMMIT:0:10}" "$T/fixcommit"
