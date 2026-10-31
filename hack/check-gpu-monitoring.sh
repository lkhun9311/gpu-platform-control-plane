#!/usr/bin/env bash
# Validates config/prometheus/gpu_rules.yaml and config/prometheus/gpu_dashboard.json with promtool.
#
#   1. the rule groups parse and type-check            (promtool check rules)
#   2. every alert fires on the input it is for, and on nothing beside it   (promtool test rules, gpu_rules_test.yaml)
#   3. every dashboard expression parses               (hack/check-dashboard.sh with DASH set)
#
# Whether each metric those expressions name is one this repository's components actually emit is not promtool's
# question; test/monitoring/monitoring_test.go asks it, and runs with `go test`.
set -euo pipefail
cd "$(dirname "$0")/.."

PROMTOOL="${PROMTOOL:-./bin/promtool}"
command -v "$PROMTOOL" >/dev/null 2>&1 || [ -x "$PROMTOOL" ] || {
  echo "promtool not found. Set PROMTOOL=/path/to/promtool" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# promtool reads plain rule groups; a PrometheusRule wraps them in spec.groups.
python3 - config/prometheus/gpu_rules.yaml "$tmp/gpu_rules.groups.yaml" <<'PY'
import json, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
groups = doc["spec"]["groups"]
if not groups:
    sys.exit("gpu_rules.yaml declares no rule groups")
json.dump({"groups": groups}, open(sys.argv[2], "w"))
PY
cp config/prometheus/gpu_rules_test.yaml "$tmp/"

echo "1. promtool check rules"
"$PROMTOOL" check rules "$tmp/gpu_rules.groups.yaml"

echo "2. promtool test rules"
(cd "$tmp" && "$PROMTOOL" test rules gpu_rules_test.yaml)

echo "3. dashboard expressions"
DASH=config/prometheus/gpu_dashboard.json PROMTOOL="$PROMTOOL" hack/check-dashboard.sh

echo "gpu monitoring checks passed"
