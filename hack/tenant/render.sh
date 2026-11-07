#!/usr/bin/env bash
# Renders one tenant's boundary from config/tenant/bundle.yaml.tmpl.
#   hack/tenant/render.sh <tenant> <namespace>           # writes config/tenants/<tenant>/bundle.yaml
#   hack/tenant/render.sh <tenant> <namespace> --stdout  # prints it
# The rendered file is committed and reviewed like any other manifest; Argo CD applies it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
[ $# -ge 2 ] || { echo "usage: $0 <tenant> <namespace> [--stdout]" >&2; exit 2; }
tenant=$1 ns=$2
# Both become object names and a group name; a value outside DNS-1123 labels would render a bundle the API refuses
# half-way through an apply.
for v in "$tenant" "$ns"; do
  [[ "$v" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || { echo "refuse: '$v' is not a DNS-1123 label" >&2; exit 2; }
done
out=$(sed -e "s/__TENANT__/$tenant/g" -e "s/__NAMESPACE__/$ns/g" "$REPO/config/tenant/bundle.yaml.tmpl")
if grep -q '__[A-Z]*__' <<<"$out"; then echo "refuse: a placeholder survived the render" >&2; exit 1; fi
if [ "${3:-}" = --stdout ]; then printf '%s\n' "$out"; exit 0; fi
mkdir -p "$REPO/config/tenants/$tenant"
printf '%s\n' "$out" > "$REPO/config/tenants/$tenant/bundle.yaml"
echo "wrote config/tenants/$tenant/bundle.yaml"
