#!/usr/bin/env bash
# Records why the lab passes one flag in VLLM_EXTRA_ARGS_D and appends the second itself.
#
# Upstream's scripts/kind-dev-env.sh pipes kustomize output through an awk filter that splits a quoted "--a --b" list
# item into separate arguments. kustomize emits the ${VLLM_EXTRA_ARGS_D} item unquoted, so the filter never matches and
# two flags reach the simulator as one argv element. The simulator then rejects the first flag's value and exits.
# This prints both halves: what kustomize emits, and what the simulator does with such an argument.
#
# Usage: hack/llmd-kv-lab/evidence-extra-args.sh > hack/llmd-kv-lab/runs/<stamp>/extra-args-one-argv.txt
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CHECKOUT=${LAB_HOME:-$REPO/tmp/llmd-kv-lab}/llm-d-router
SIM_IMAGE=ghcr.io/llm-d/llm-d-inference-sim:v1.2.0

echo "router checkout: $(git -C "$CHECKOUT" rev-parse HEAD)"
echo "kubectl: $(kubectl version --client 2>/dev/null | head -2 | tr '\n' ' ')"
echo
echo "\$ kubectl kustomize --enable-helm test/e2e/artifacts/environments/dev/epd | grep -n -e render-url -e VLLM_EXTRA_ARGS_D"
(cd "$CHECKOUT" && kubectl kustomize --enable-helm test/e2e/artifacts/environments/dev/epd | grep -n -e render-url -e VLLM_EXTRA_ARGS_D)
echo
echo "\$ grep -n 'match(\$0' scripts/kind-dev-env.sh  # the splitter only matches a quoted list item"
grep -n -e '/\^\[\[:space:\]\]\*-\[\[:space:\]\]+"' "$CHECKOUT/scripts/kind-dev-env.sh"
echo
echo "\$ docker run --rm $SIM_IMAGE --model=TinyLlama/TinyLlama-1.1B-Chat-v1.0 \"--kv-cache-size=256 --enable-request-id-headers\""
out=$(timeout 30 docker run --rm "$SIM_IMAGE" --model=TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
  "--kv-cache-size=256 --enable-request-id-headers" 2>&1)
echo "container exit status: $?"
echo "$out" | tail -3
