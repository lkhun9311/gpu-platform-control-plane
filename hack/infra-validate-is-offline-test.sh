#!/usr/bin/env bash
# Assert that `make infra-validate`'s Terraform step needs no AWS access.
#
# The target is documented as "Validate Terraform (offline)" and for months it was not. Two things made it
# reach AWS, and either alone was enough:
#
#   1. A stale static [default] in ~/.aws/credentials, which the default chain prefers over every SSO
#      profile, so STS answered 403 instead of "no credentials".
#   2. A reused .terraform/terraform.tfstate recording `backend.type = s3`. `-backend=false` does not mean
#      "no backend" -- init reconfigures the backend from those stored settings, and that authenticates.
#
# CI never saw either: a fresh checkout has no .terraform and the job has no credentials. So the same commit
# was red locally and green in CI, decided by a developer's home directory. That is the failure this test
# exists to keep out, and it is the reason the test injects bad credentials rather than removing them --
# absent credentials were always fine; invalid ones were not.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TERRAFORM="${TERRAFORM:-$ROOT/bin/terraform}"
fail=0

note() { printf '%s\n' "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
bad() {
  printf 'FAIL %s\n' "$*" >&2
  fail=1
}

if [[ ! -x "$TERRAFORM" ]]; then
  note "terraform is not built at $TERRAFORM; run 'make terraform' first"
  exit 1
fi

# The roots the Makefile would validate, discovered the same way it discovers them.
roots=()
for d in infra/aws/*/; do
  [[ -f "$d/versions.tf" ]] && roots+=("$d")
done
if ((${#roots[@]} == 0)); then
  bad "no terraform roots found; this test would pass by having nothing to check"
  exit 1
fi
note "checking ${#roots[@]} terraform roots"

# Run one root exactly as the Makefile does, under a caller-supplied environment.
#
# Duplicating the recipe is deliberate: importing it would make the test pass whenever the recipe changed,
# including changes that reintroduce the defect. What is under test is the CONTRACT, not the implementation.
validate_root() {
  local root="$1"
  local tfdata
  tfdata="$(mktemp -d)"
  (
    cd "$root"
    TF_DATA_DIR="$tfdata" "$TERRAFORM" init -backend=false -input=false -lockfile=readonly >/dev/null 2>&1 &&
      TF_DATA_DIR="$tfdata" "$TERRAFORM" validate >/dev/null 2>&1
  )
  local rc=$?
  rm -rf "$tfdata"
  return $rc
}

# 1. Credentials that exist and are invalid must not matter.
#
# This is the exact shape of the original failure. Absent credentials already worked, so a test that merely
# unset them would have passed against the broken recipe.
for root in "${roots[@]}"; do
  if AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
    AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
    AWS_SESSION_TOKEN=invalid \
    AWS_REGION=ap-northeast-2 \
    validate_root "$root"; then
    ok "$root validates with invalid AWS credentials in the environment"
  else
    bad "$root needs working AWS credentials; the Terraform step is not offline"
  fi
done

# 2. A root that was previously initialised for real must not drag its backend into the check.
#
# Simulated rather than waited for: a developer who has ever run a real `terraform init` has this file, and
# a test that only passes on machines that never deployed would never have caught the defect.
probe_root="${roots[0]}"
probe_state="$probe_root.terraform/terraform.tfstate"
restore_probe() {
  if [[ -n "${probe_saved:-}" && -f "$probe_saved" ]]; then
    mkdir -p "$(dirname "$probe_state")"
    mv "$probe_saved" "$probe_state"
  elif [[ "${probe_created:-0}" == "1" ]]; then
    rm -f "$probe_state"
    rmdir "$(dirname "$probe_state")" 2>/dev/null || true
  fi
}
trap restore_probe EXIT

probe_saved=""
probe_created=0
if [[ -f "$probe_state" ]]; then
  probe_saved="$(mktemp)"
  cp "$probe_state" "$probe_saved"
else
  probe_created=1
  mkdir -p "$(dirname "$probe_state")"
fi

cat >"$probe_state" <<'STATE'
{
  "version": 3,
  "serial": 1,
  "lineage": "00000000-0000-0000-0000-000000000000",
  "backend": {
    "type": "s3",
    "config": {
      "bucket": "example-state-bucket",
      "key": "probe/terraform.tfstate",
      "region": "ap-northeast-2",
      "encrypt": true
    },
    "hash": 1
  },
  "modules": []
}
STATE

if AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  AWS_SESSION_TOKEN=invalid \
  AWS_REGION=ap-northeast-2 \
  validate_root "$probe_root"; then
  ok "$probe_root validates even with a cached s3 backend and invalid credentials"
else
  bad "$probe_root reuses its cached s3 backend; init is authenticating when it should not"
fi

restore_probe
probe_saved=""
probe_created=0
trap - EXIT

if ((fail != 0)); then
  echo "the terraform step of infra-validate is not offline" >&2
  exit 1
fi
echo "the terraform step needs no AWS access, with or without a cached backend"
