#!/bin/bash
# Derives one item's pins file, or its list of files that differ from the image, from a vLLM clone, so every pinned hash comes from git and not from a hand edit.
#
#   derive-pins.sh kda|stride <vLLM clone>                 > the item's pins file
#   derive-pins.sh kda-differs|stride-differs <vLLM clone> > the item's differs file
#
# Run 4's image is vLLM CI's for 3e469e9ffb, whose tree differs from #68416's diff base 545ef08189 only in a recipe yaml.
# Run 3's image, 428c371b32, differed from 545ef08189 in vllm/v1/core/kv_cache_planning.py and vllm/v1/engine/detokenizer.py, which run 3's collection loaded.
# Every state pins the same eight files: the three items' sources and tests together, and torch_utils.py.
# A state's own item's files are what its diff makes of 3e469e9ffb, and every other file stays 3e469e9ffb's.
# That is the isolation proof: no item's fix or test can be in another item's container and still pass its pins.
# The last two blocks pin the same eight files at the commit the item's diff was written on and at the item's own fix commit.
# Those lines are records, which the state scripts do not read, and the offline test holds them equal to the base and AFTER lines.
# The differs file lists every file that differs between the image's commit and the item's diff base.
# Each state refuses a run whose test process loaded any of them, so no file the tests import can differ from the base the diff was written on.
# #68414 and #68415 are not part of run 4: pins.txt stays run 2's, derived on 8700cc9ba0, and kda-pins.txt and kda-differs.txt stay run 3's, derived on 428c371b32.
set -euo pipefail
ITEM=$1
SRC=$2
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=3e469e9ffbef4c54595327df14d209ba9c2481f7
OPS=vllm/third_party/flash_linear_attention/ops
PATHS="$OPS/index.py tests/kernels/fla/test_chunk_indices.py $OPS/kda.py tests/kernels/fla/test_fused_recurrent_kda.py $OPS/fused_recurrent.py $OPS/fused_sigmoid_gating.py tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py vllm/utils/torch_utils.py"
case $ITEM in
  # #68416's diff is commit 541d8b9771 on 545ef08189, the commit after the image's, for which CI published no image.
  stride | stride-differs) STATES="base: before:stride-test.diff after:stride-fix.diff"; DIFFBASE=545ef081895681ba4c2aa3c6699326e3a2f3cbf7; FIXCOMMIT=541d8b97713b42540deff2f124fc75c0409292d2 ;;
  gdn) echo "#68414 is not part of run 4; pins.txt is run 2's, derived on 8700cc9ba0" >&2; exit 2 ;;
  kda | kda-differs) echo "#68415 is not part of run 4; run 3 confirmed it, and kda-pins.txt is run 3's, derived on 428c371b32" >&2; exit 2 ;;
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
