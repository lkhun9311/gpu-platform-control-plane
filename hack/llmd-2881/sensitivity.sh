#!/usr/bin/env bash
# Sensitivity arm on the same seeded burst load: tokens mode with a 2048-token budget instead of 1024.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
for seed in 1 2 3; do
  "$HERE/run.sh" tokens-2048 burst "$seed" -bursts 40 -burst-size 24 -mean-gap 1.5s -window 20ms
done
