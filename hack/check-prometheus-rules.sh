#!/usr/bin/env bash
# Validates the PrometheusRule's PromQL with promtool.
#
# It exists because the rules were committed once with the expressions only structurally checked — parentheses
# balanced, YAML well-formed — and that is not the same as valid PromQL. An alert rule that silently never
# fires is worse than no alert at all, because the absence of pages reads as the absence of trouble.
#
# promtool takes a plain rules file, not a PrometheusRule custom resource, so the spec is lifted out first.
set -euo pipefail
cd "$(dirname "$0")/.."

PROMTOOL="${PROMTOOL:-promtool}"
command -v "$PROMTOOL" >/dev/null || {
  echo "promtool not found. Install it from a prometheus release, or set PROMTOOL=/path/to/promtool" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for f in config/prometheus/*rules*.yaml; do
  [ -e "$f" ] || continue
  python3 -c "
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
if doc.get('kind') != 'PrometheusRule':
    sys.exit(0)
yaml.safe_dump({'groups': doc['spec']['groups']}, open(sys.argv[2], 'w'), sort_keys=False, allow_unicode=True)
" "$f" "$tmp/rules.yaml"
  [ -s "$tmp/rules.yaml" ] || continue
  echo "== $f"
  "$PROMTOOL" check rules "$tmp/rules.yaml"
done
