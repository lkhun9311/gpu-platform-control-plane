#!/usr/bin/env bash
#
# Checks hack/eks-gitops-runbook.sh serve-sync's judgement of which sync operation answered its request, with kubectl
# and the request's clock replaced by stubs, without a cluster.
#
#   bash hack/test/check-serve-sync.sh
#
# The API server stamps startedAt in whole seconds, so an operation stamped in the request's own second may be the one
# that ran before it: only a later second may be accepted.
# The clock stub fixes the request at 2026-10-22T00:00:00Z, so each case names the operation's start relative to it.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_CALLS"
case "$*" in
  "config get-contexts -o name") echo stub-ctx ;;
  *"patch application"*) ;;
  *"operationState.startedAt"*) printf '%s' "$STUB_STARTED" ;;
  *"operationState.phase"*) printf Succeeded ;;
  *"sync.status"*) printf Synced ;;
  *"sync.revision"*) printf 0123abcd ;;
  *"get application"*"-o json"*) echo '{}' ;;
  *) echo "stub: no answer for: $*" >&2; exit 97 ;;
esac
EOF
# Only the request's own stamp is fixed; every other format, the log's millisecond clock among them, is the real one.
cat >"$work/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-u +%Y-%m-%dT%H:%M:%SZ" ]]; then echo 2026-10-22T00:00:00Z; exit 0; fi
exec /usr/bin/date "$@"
EOF
chmod +x "$work/bin/kubectl" "$work/bin/date"

# run_case NAME STARTED: runs serve-sync against an operation started at STARTED, leaving its exit code in $rc.
run_case() {
  local dir="$work/$1"
  mkdir -p "$dir"
  # A recorded key skips the Secret patch, which is not what this checks.
  echo serve-test >"$dir/serve-key.txt"
  : >"$dir/calls.log"
  PATH="$work/bin:$PATH" CONTEXT=stub-ctx EXDIR="$dir" WAIT_SERVE_SYNC=1 STUB_STARTED="$2" STUB_CALLS="$dir/calls.log" \
    hack/eks-gitops-runbook.sh serve-sync >"$dir/out.txt" 2>&1
  rc=$?
}

run_case later 2026-10-22T00:00:01Z
if [[ $rc -eq 0 ]] && grep -q 'ok   gpu-platform-serving synced at 0123abcd' "$work/later/out.txt"; then
  ok "an operation started the second after the request is accepted"
else
  bad "an operation started the second after the request was not accepted (rc=$rc): $(tail -3 "$work/later/out.txt")"
fi
if grep -q 'patch application gpu-platform-serving' "$work/later/calls.log"; then
  ok "the sync was requested through the stub"
else
  bad "the stub never saw the sync request, so the case did not exercise serve-sync: $(head -5 "$work/later/calls.log")"
fi

run_case same 2026-10-22T00:00:00Z
if [[ $rc -ne 0 ]] && grep -q 'did not sync within 1s (operation started 2026-10-22T00:00:00Z for a request at 2026-10-22T00:00:00Z' "$work/same/out.txt"; then
  ok "an operation stamped in the request's own second is not taken as its answer"
else
  bad "an operation stamped in the request's own second was accepted (rc=$rc): $(tail -3 "$work/same/out.txt")"
fi

run_case earlier 2026-10-21T23:59:59Z
if [[ $rc -ne 0 ]] && grep -q 'did not sync within 1s (operation started 2026-10-21T23:59:59Z' "$work/earlier/out.txt"; then
  ok "an operation started before the request is not taken as its answer"
else
  bad "an operation started before the request was accepted (rc=$rc): $(tail -3 "$work/earlier/out.txt")"
fi

run_case never ""
if [[ $rc -ne 0 ]] && grep -q 'did not sync within 1s (operation started never' "$work/never/out.txt"; then
  ok "no operation at all is reported as never started"
else
  bad "a missing operation was not reported as never started (rc=$rc): $(tail -3 "$work/never/out.txt")"
fi

if ((fails > 0)); then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all serve-sync checks passed"
