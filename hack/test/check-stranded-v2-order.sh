#!/usr/bin/env bash
#
# Checks that the second stranded-GPU campaign's block order is the one its seed draws, without a cluster.
#
#   bash hack/test/check-stranded-v2-order.sh
#
# The registration fixes the order as Python's random.Random(seed) shuffling the list once per block, and the file
# carries both the seed and the twelve blocks it drew.
# Go cannot redraw Python's shuffle, so check-campaign-v2 checks only that every block is a permutation of the
# list; this checks that the blocks are the seed's and not a hand edit.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

PROTOCOL="${PROTOCOL:-hack/stranded-protocol-v2.yaml}"
python3 - "$PROTOCOL" <<'PY'
import random
import re
import sys

# Read without a yaml module, which the CI runner is not guaranteed to have: the three keys have fixed shapes,
# and a file whose order section does not match them is refused rather than skipped.
text = open(sys.argv[1]).read()
section = re.search(r"^order:\n((?:  .*\n)+)", text, re.M)
seed = re.search(r"^  seed: (\d+)$", section.group(1), re.M) if section else None
listed = re.search(r"^  list: \[(.*)\]$", section.group(1), re.M) if section else None
if not (section and seed and listed):
    print(f"FAIL: no order section with a seed and a list in {sys.argv[1]}")
    sys.exit(1)
order = {
    "seed": int(seed.group(1)),
    "list": [x.strip() for x in listed.group(1).split(",")],
    "blocks": [[x.strip() for x in b.split(",")] for b in re.findall(r"^    - \[(.*)\]$", section.group(1), re.M)],
}
rng = random.Random(order["seed"])
drawn = []
for _ in order["blocks"]:
    block = list(order["list"])
    rng.shuffle(block)
    drawn.append(block)
bad = [i + 1 for i, (got, want) in enumerate(zip(order["blocks"], drawn)) if got != want]
if len(order["blocks"]) != 12 or bad:
    print(f"FAIL: {len(order['blocks'])} blocks; blocks that differ from seed {order['seed']}'s draw: {bad}")
    sys.exit(1)
print(f"ok: the 12 blocks are the ones seed {order['seed']} draws")
PY
