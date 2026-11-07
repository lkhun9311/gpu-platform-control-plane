#!/usr/bin/env bash
#
# Pins hack/alert-receipts.py, the counter hack/gpu-alert-delivery.sh waits on.
#
#   bash hack/test/check-alert-receipts.sh
#
# The archived sink is real Alertmanager output from the 2026-10-31 delivery run; the extra fixture adds what the review
# (astra r3, finding 9) said a name-only count would accept: a late, repeated Xid notification standing in for ECC.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

SINK=hack/gpu-alert-delivery-20261031T235222Z/sink.jsonl
n() { python3 hack/alert-receipts.py "$@"; }
expect() {
  local want=$1 got
  shift
  got=$(n "$@")
  [ "$got" = "$want" ] && ok "$* -> $got" || bad "$* -> $got, want $want"
}

# The archive: one firing and one resolved notification per field.
expect 1 "$SINK" GPUFaultSignalPresent firing field=xid
expect 1 "$SINK" GPUFaultSignalPresent firing field=ecc_dbe
expect 1 "$SINK" GPUFaultSignalPresent resolved field=ecc_dbe
expect 2 "$SINK" GPUFaultSignalPresent firing
expect 1 "$SINK" GPUExporterNotReporting firing

# A sink holding only Xid notifications, the second a repeat delivered after the ECC injection: no ECC receipt.
python3 - "$work/xid-only.jsonl" <<'PY'
import json, sys
def body(status):
    return {"received_at": "2026-11-07T00:00:00+00:00", "path": "/", "payload": {"status": status, "alerts": [
        {"status": status, "labels": {"alertname": "GPUFaultSignalPresent", "field": "xid", "gpu": "0"}}]}}
with open(sys.argv[1], "w") as f:
    f.write("not json, as the sink's own startup line is\n")
    for s in ("firing", "resolved", "firing", "resolved"):
        f.write(json.dumps(body(s)) + "\n")
PY
expect 2 "$work/xid-only.jsonl" GPUFaultSignalPresent firing
expect 0 "$work/xid-only.jsonl" GPUFaultSignalPresent firing field=ecc_dbe
expect 0 "$work/xid-only.jsonl" GPUFaultSignalPresent resolved field=ecc_dbe

# A malformed filter is refused rather than read as no filter.
if python3 hack/alert-receipts.py "$SINK" GPUFaultSignalPresent firing field >/dev/null 2>"$work/err"; then
  bad "a filter without '=' was accepted"
else
  ok "a filter without '=' is refused ($(cat "$work/err"))"
fi

if [[ $fails -ne 0 ]]; then
  echo "check-alert-receipts: $fails failure(s)"
  exit 1
fi
echo "check-alert-receipts: all checks passed"
