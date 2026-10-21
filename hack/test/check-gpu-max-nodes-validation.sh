#!/usr/bin/env bash
#
# Checks infra/aws/cluster's gpu_max_nodes validations against the values a session could pass, without a cluster.
#
#   bash hack/test/check-gpu-max-nodes-validation.sh
#
# The cluster root cannot evaluate a variable offline (its backend must be initialised first), so the variable block
# is copied verbatim into a throwaway module with no provider, which terraform plans without network or credentials.
# The block is copied, not retyped, so a change to the real validation is what this tests.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# The repository's pinned download, which `make harness-check` passes in; CI has no terraform on PATH, so a bare
# `terraform` passed only on a machine that happened to have one.
TERRAFORM="${TERRAFORM:-$PWD/bin/terraform}"
# Made absolute here, because init and plan run from a temporary directory, where ./bin/terraform does not resolve.
if [[ "$TERRAFORM" == */* && "$TERRAFORM" != /* ]]; then
  TERRAFORM="$PWD/$TERRAFORM"
elif [[ "$TERRAFORM" != */* ]]; then
  TERRAFORM="$(command -v "$TERRAFORM" || echo "$TERRAFORM")"
fi
if [[ ! -x "$TERRAFORM" ]]; then
  echo "FAIL: no terraform at $TERRAFORM; run 'make terraform' or set TERRAFORM"
  exit 1
fi

fails=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - infra/aws/cluster/variables.tf "$work/v.tf" <<'PY' || { echo "FAIL: no gpu_max_nodes block to copy"; exit 1; }
import sys
s = open(sys.argv[1]).read()
i = s.index('variable "gpu_max_nodes"')
depth = 0
for j, ch in enumerate(s[i:], i):
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            break
open(sys.argv[2], "w").write(s[i:j + 1] + '\noutput "n" { value = var.gpu_max_nodes }\n')
PY
if ! (cd "$work" && "$TERRAFORM" init -input=false >"$work/init.log" 2>&1); then
  echo "FAIL: terraform init of the copied block: $(tail -3 "$work/init.log")"
  exit 1
fi

# want is "accepted" or the text of the refusal that value must meet.
check() {
  local value="$1" want="$2" out
  out=$(cd "$work" && "$TERRAFORM" plan -input=false -no-color -var "gpu_max_nodes=$value" 2>&1)
  local status=$?
  if [[ "$want" == accepted ]]; then
    if [[ $status -eq 0 ]]; then echo "ok: $value is accepted"; else echo "FAIL: $value was refused: $(tail -4 <<<"$out")"; fails=$((fails + 1)); fi
  elif [[ $status -ne 0 && "$out" == *"$want"* ]]; then
    echo "ok: $value is refused: $want"
  else
    echo "FAIL: $value was not refused for '$want' (exit $status): $(tail -4 <<<"$out")"
    fails=$((fails + 1))
  fi
}

check 1 accepted
check 2 accepted
check 1.5 "must be a whole number"
check 3 "one or two workers"

if [[ $fails -ne 0 ]]; then
  echo "check-gpu-max-nodes-validation: $fails failure(s)"
  exit 1
fi
echo "check-gpu-max-nodes-validation: all checks passed"
