#!/usr/bin/env bash
#
# The case list, run in order on the node as root from the directory holding run-case.sh and the pod manifests.
#
#   sudo bash run-all.sh <out-root> <case>...
set -uo pipefail
ROOT="$1"; shift
below='{"spec":{"containers":[{"name":"app","resources":{"limits":{"swap":"64Mi"}}}]}}'
control='{"spec":{"containers":[{"name":"app","resources":{"limits":{"swap":"384Mi"}}}]}}'
# 512Mi to 128Mi of memory request moves the LimitedSwap-derived swap limit to a quarter of its value.
derived='{"spec":{"containers":[{"name":"app","resources":{"requests":{"memory":"128Mi"}}}]}}'
for c in "$@"; do
  case $c in
    A*) bash run-case.sh "$c" "$ROOT/$c" pod-explicit.yaml "$below" ;;
    B*) bash run-case.sh "$c" "$ROOT/$c" pod-explicit.yaml "$control" ;;
    C*) bash run-case.sh "$c" "$ROOT/$c" pod-limitedswap.yaml "$derived" ;;
    # The A PATCH sent as soon as the allocator is done, with no settle.
    S*) SETTLE_S=0 bash run-case.sh "$c" "$ROOT/$c" pod-explicit.yaml "$below" ;;
    # The stuck decrease, then the limit raised back to 512Mi, the way out the PR thread names.
    R*) PATCH2='{"spec":{"containers":[{"name":"app","resources":{"limits":{"swap":"512Mi"}}}]}}' PATCH2_AT_S=60 \
          bash run-case.sh "$c" "$ROOT/$c" pod-explicit.yaml "$below" ;;
  esac
  echo "$c rc=$?"
done
