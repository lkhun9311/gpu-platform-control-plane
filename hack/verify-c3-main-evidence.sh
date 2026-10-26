#!/usr/bin/env bash
#
# Re-derives C3 main study's published verdicts from its published evidence, and exits 0 only when they match.
#
#   hack/verify-c3-main-evidence.sh [DIR]     DIR holds the release's three assets; without it they are downloaded
#   hack/verify-c3-main-evidence.sh --self-test
#
# The evidence is the GitHub release evidence-c3-main-2026-10-26: the raw cells of the three paid sessions
# docs/superpowers/specs/2026-10-25-c3-headroom-main.md reports, one asset per block.
# Every asset is checked against the checksum committed beside the verdicts before anything is read, then the three are
# scored together by this checkout's hack/prospective-pilot/pilot_report.py headroom-main, block 1's archive first,
# and compared with the committed verdict file.
#
# What is compared: the primary, size-aware and cap-only verdicts, whether hold-cap was ahead at the reference, the
# interaction, every arm's admissibility, each block's engine prefill medians and the count of distinct GPUs.
# A scorer changed since the verdicts were committed shows up here as a mismatch, which is the point.
#
# It is a separate script from hack/verify-c3-evidence.sh because that one reproduces the calibration, whose verdict
# the main study's registration froze.
# What it cannot do: it re-scores rows collected once; it does not re-run a session or touch a GPU.
set -euo pipefail
# A relative DIR names a place in the caller's directory, so it is resolved before moving to the repository root.
if [ -n "${1:-}" ] && [ "$1" != --self-test ]; then
  [ -d "$1" ] || { printf 'FAIL: %s is not a directory\n' "$1" >&2; exit 1; }
  set -- "$(cd "$1" && pwd)"
fi
cd "$(dirname "$0")/.."

TAG=evidence-c3-main-2026-10-26
SUMS=docs/superpowers/specs/data/c3-main-evidence-SHA256SUMS
VERDICT=docs/superpowers/specs/data/2026-10-25-c3-main/verdict.json
ASSET=admission-headroom-main-2026-10-25-block
say() { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# fail exits from inside verify, where a RETURN trap would not run, so every temporary directory is removed on exit.
TMPS=()
cleanup() { [ "${#TMPS[@]}" -eq 0 ] || rm -rf "${TMPS[@]}"; }
trap cleanup EXIT

verify() {
  local dir="$1" work b
  [ -s "$SUMS" ] || fail "the committed checksum list $SUMS is missing"
  # Three lines, one per block, so a list that lost a block cannot pass by checking only what it still names.
  [ "$(grep -cE "  $ASSET[123]\.tgz\$" "$SUMS")" = 3 ] || fail "$SUMS does not name exactly the three blocks' assets"
  (cd "$dir" && sha256sum --check --strict "$OLDPWD/$SUMS") >/dev/null 2>&1 \
    || fail "an asset in $dir is missing or does not match $SUMS"
  say "checksums match $SUMS"
  work=$(mktemp -d)
  TMPS+=("$work")
  for b in 1 2 3; do
    mkdir "$work/$b"
    tar -xzf "$dir/$ASSET$b.tgz" -C "$work/$b" || fail "$ASSET$b.tgz could not be unpacked"
    [ -d "$work/$b/m5c-run" ] || fail "$ASSET$b.tgz holds no m5c-run"
  done
  python3 hack/prospective-pilot/pilot_report.py headroom-main "$work/1/m5c-run" "$work/2/m5c-run" "$work/3/m5c-run" \
    > "$work/main.json" || fail "the scorer could not score the three blocks"
  python3 - "$work/main.json" "$VERDICT" <<'PY' || fail "the re-derived verdicts differ from the published ones"
import json, sys
got, want = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
r = lambda x: round(x, 4) if isinstance(x, float) else x
pairs = [(k, got[k], want[k]) for k in ("verdict", "size_aware", "cap_only", "hold_cap_ahead_at_ref", "distinct_gpus")]
pairs.append(("interaction", r(got["interaction"]), r(want["interaction"])))
pairs.append(("admissible", got["admissible"], want["admissible"]))
for k in want["engine_prefill_p50_ms"]:
    pairs.append(("engine prefill p50, %s" % k, round(got["engine_prefill_p50_ms"][k], 1),
                  round(want["engine_prefill_p50_ms"][k], 1)))
bad = []
for name, g, w in pairs:
    if g != w:
        bad.append("%s: re-derived %r, published %r" % (name, g, w))
    else:
        print("ok   %s: %s" % (name, str(g)[:100]))
for b in bad:
    print("DIFF " + b)
sys.exit(1 if bad else 0)
PY
  say "C3 main study's published verdicts re-derive from the published evidence"
}

self_test() {
  # An asset that does not match its checksum must fail, or a corrupted download would pass.
  local tmp b
  tmp=$(mktemp -d)
  TMPS+=("$tmp")
  for b in 1 2 3; do printf 'not the archive\n' > "$tmp/$ASSET$b.tgz"; done
  if (trap cleanup EXIT; verify "$tmp") >/dev/null 2>&1; then fail "self-test: altered assets passed the checksum check"; fi
  say "self-test: altered assets are refused -- the check can fail"
}

case "${1:-}" in
  --self-test) self_test ;;
  "")
    dl=$(mktemp -d)
    TMPS+=("$dl")
    gh release download "$TAG" --dir "$dl" --pattern '*.tgz' || fail "could not download the assets of $TAG"
    verify "$dl" ;;
  *) verify "$1" ;;
esac
