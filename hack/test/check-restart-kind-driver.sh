#!/usr/bin/env bash
#
# The kind restart rehearsal's driver, hack/restart-lifecycle-kind.sh, checked where it decides what is its own and
# whether it may report success, with no cluster.
#
#   bash hack/test/check-restart-kind-driver.sh
#
# Parts:
#   1. a kind cluster list that cannot be read stops the driver before it creates or removes anything;
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=hack/lib/restart-kind-driver.sh
. hack/lib/restart-kind-driver.sh

# --- 1. the cluster lookup ----------------------------------------------------------------------------------------
mkdir -p "$work/bin"
# kind, docker, kubectl and make record their calls; kind answers `get clusters` from STUB_KIND and refuses to create.
cat >"$work/bin/stub" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"${STUB_CALLS:?}"
case "$(basename "$0") $*" in
  "kind get clusters")
    case "${STUB_KIND:-}" in
      fail) echo "ERROR: failed to list clusters: permission denied" >&2; exit 1 ;;
      none) echo "No kind clusters found." >&2 ;;
      *) printf '%s\n' $STUB_KIND ;;
    esac ;;
  "kind create"*) echo "stub kind refuses to create" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$work/bin/stub"
for t in kind docker kubectl make; do ln -s stub "$work/bin/$t"; done

lookup() { STUB_CALLS="$work/lookup.calls" STUB_KIND="$1" PATH="$work/bin:$PATH" rstk_cluster_listed rstlife; echo "rc=$?"; }
for c in "ckad m6clean rstlife:rc=0" "ckad m6clean platform:rc=1" "none:rc=1" "fail:rc=2"; do
  got="$(lookup "${c%%:*}" 2>&1 | tail -1)"
  if [[ "$got" == "${c#*:}" ]]; then ok "kind listing '${c%%:*}' reads ${c#*:}"; else bad "kind listing '${c%%:*}' reads $got, want ${c#*:}"; fi
done

# The driver itself, with the list unreadable: it must stop, and neither create nor remove a cluster or a node.
: >"$work/driver.calls"
out="$(STUB_CALLS="$work/driver.calls" STUB_KIND=fail RSTK_OUT="$work/evidence" PATH="$work/bin:$PATH" bash hack/restart-lifecycle-kind.sh 2>&1)"
rc=$?
touched="$(grep -cE '^kind (create|delete)|^docker (rm|kill|build)|^make ' "$work/driver.calls")"
if [[ "$rc" != 0 && "$touched" == 0 && "$(cat "$work/evidence/VOID" 2>&1)" == "could not tell whether a cluster rstlife exists"* ]]; then
  ok "an unreadable cluster list stops the driver before it builds, creates or removes anything"
else
  bad "with the cluster list unreadable the driver exited $rc after $touched build, create or remove call(s): $(tail -2 <<<"$out")"
fi

if ((fails)); then
  echo "check-restart-kind-driver: $fails failure(s)"
  exit 1
fi
echo "check-restart-kind-driver: all checks passed"
