#!/usr/bin/env bash
# The measured matrix: each mode under the bursty load and under a low-load control, three seeds each.
# The seeds are shared across modes, so every mode sees the same arrivals, prompts and max_tokens.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
for mode in requests tokens hybrid; do
  for seed in 1 2 3; do
    "$HERE/run.sh" "$mode" burst "$seed" -bursts 40 -burst-size 24 -mean-gap 1.5s -window 20ms
    "$HERE/run.sh" "$mode" control "$seed" -bursts 40 -burst-size 2 -mean-gap 1.5s -window 20ms
  done
done
