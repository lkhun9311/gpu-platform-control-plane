#!/usr/bin/env bash
# Runs verify-webhook-live.sh's two manager-log checks against a stubbed kubectl.
# Both checks pass on the absence of a string, so the case that matters is a log that cannot be read:
# it once earned "no TLS failures" and "started with its certificate" from an empty string.
set -uo pipefail
cd "$(dirname "$0")/../.."
SRC=hack/verify-webhook-live.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The log section is taken from the production script, from its comment to the end, so this runs the shipped code.
SECTION=$(sed -n '/^# Both checks below pass on the absence of a string/,$p' "$SRC")
[ -n "$SECTION" ] || { echo "FAIL  the log section's anchor comment is missing from $SRC"; exit 1; }
HELPERS=$(grep -E '^(ok|bad)\(\) ' "$SRC")
[ "$(wc -l <<<"$HELPERS")" -eq 2 ] || { echo "FAIL  expected the ok and bad helpers in $SRC"; exit 1; }

failures=0
case_() { # name, kubectl stub body, expected exit, expected output fragment
  { echo 'pass=0; fail=0; SYS=s; MGR=m'; echo "$HELPERS"; echo "kubectl() { $2; }"; echo "$SECTION"; } >"$TMP/case.sh"
  out=$(bash "$TMP/case.sh" 2>&1); rc=$?
  if [ "$rc" -eq "$3" ] && grep -qF -- "$4" <<<"$out"; then echo "ok    $1"
  else echo "FAIL  $1: exit $rc, wanted $3 and \"$4\""; sed 's/^/      /' <<<"$out"; failures=$((failures+1)); fi
}

case_ "an unreadable log fails both checks"  'echo "Error from server (Forbidden)" >&2; return 1' 1 "could not be read, so neither log check ran: Error from server (Forbidden)"
case_ "an empty log fails both checks"       ':' 1 "is empty"
# kubectl prints this notice on stderr when a Pod has more than one container; it is not a log line.
case_ "a stderr notice with no log fails both checks" 'echo "Defaulted container \"manager\" out of: manager, sidecar" >&2' 1 "is empty"
case_ "a healthy log passes both checks"     'echo "starting manager"' 0 "pass=2 fail=0"
case_ "a TLS failure in the log fails"       'echo "remote error: tls: bad certificate"' 1 "TLS failure"
case_ "a manager without its certificate fails" 'echo "admission validation is NOT running"' 1 "started without a certificate"

[ "$failures" -eq 0 ] && echo "PASS  check-webhook-live-logs" || { echo "FAIL  check-webhook-live-logs: $failures"; exit 1; }
