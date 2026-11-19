#!/usr/bin/env bash
# The comparison arms on the same seeded burst load as matrix.sh:
# fail-open (#2883's short-term fix), #3173 cherry-picked onto e922a7ae, and requests mode from before #3065.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BURST=(-bursts 40 -burst-size 24 -mean-gap 1.5s -window 20ms)
PR3173_ON_MAIN=19a68cfe1099d881aa22d7b4b2bbecda3d08f183
PRE3065=69a3af43a9ca0dc24a300e13f887051f0578f30e
for seed in 1 2 3; do
  "$HERE/run.sh" tokens-failopen burst "$seed" "${BURST[@]}"
  "$HERE/run.sh" hybrid-failopen burst "$seed" "${BURST[@]}"
  LAB_EPP_COMMIT=$PR3173_ON_MAIN "$HERE/run.sh" tokens burst-pr3173 "$seed" "${BURST[@]}"
  LAB_EPP_COMMIT=$PR3173_ON_MAIN "$HERE/run.sh" hybrid burst-pr3173 "$seed" "${BURST[@]}"
  LAB_EPP_COMMIT=$PRE3065 "$HERE/run.sh" requests burst-pre3065 "$seed" "${BURST[@]}"
done
