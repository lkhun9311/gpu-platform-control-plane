#!/usr/bin/env bash
#
# Re-derives C3 calibration's published verdict from its published evidence, and exits 0 only when it matches.
#
#   hack/verify-c3-evidence.sh [DIR]     DIR holds the release's asset; without it the asset is downloaded
#   hack/verify-c3-evidence.sh --self-test
#
# The evidence is the GitHub release evidence-c3-calibration-2026-10-25: the raw cells of the one paid session
# docs/superpowers/specs/2026-10-24-c3-headroom-calibration.md reports in "Result, 2026-10-25: feasible".
# The asset is checked against the checksum committed beside the verdict before anything is read, then scored by
# this checkout's hack/prospective-pilot/pilot_report.py headroom, and compared with the committed verdict file.
#
# What is compared: the verdict sentence, each length's engine prefill median, S, and the size-aware spacings.
# A scorer changed since the verdict was committed shows up here as a mismatch, which is the point.
#
# It is a separate script from hack/verify-admission-evidence.sh because that one reproduces v27 and is not
# repointed (the C3 page, "What must be built before purchase").
# What it cannot do: it re-scores rows collected once; it does not re-run the calibration or touch a GPU.
set -euo pipefail
# A relative DIR names a place in the caller's directory, so it is resolved before moving to the repository root.
if [ -n "${1:-}" ] && [ "$1" != --self-test ]; then
  [ -d "$1" ] || { printf 'FAIL: %s is not a directory\n' "$1" >&2; exit 1; }
  set -- "$(cd "$1" && pwd)"
fi
cd "$(dirname "$0")/.."

TAG=evidence-c3-calibration-2026-10-25
SUMS=docs/superpowers/specs/data/c3-evidence-SHA256SUMS
ASSET=admission-headroom-calibration-2026-10-24
say() { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# fail exits from inside verify, where a RETURN trap would not run, so every temporary directory is removed on exit.
TMPS=()
cleanup() { [ "${#TMPS[@]}" -eq 0 ] || rm -rf "${TMPS[@]}"; }
trap cleanup EXIT

verify() {
  local dir="$1" work
  [ -s "$SUMS" ] || fail "the committed checksum list $SUMS is missing"
  (cd "$dir" && sha256sum --check --strict "$OLDPWD/$SUMS") >/dev/null 2>&1 \
    || fail "the asset in $dir is missing or does not match $SUMS"
  say "checksum matches $SUMS"
  work=$(mktemp -d)
  TMPS+=("$work")
  tar -xzf "$dir/$ASSET.tgz" -C "$work" || fail "$ASSET.tgz could not be unpacked"
  python3 hack/prospective-pilot/pilot_report.py headroom "$work/m5c-run" > "$work/headroom.json" \
    || fail "the scorer could not score the calibration"
  python3 - "$work/headroom.json" <<'PY' || fail "the re-derived verdict differs from the published one"
import json, sys
got = json.load(open(sys.argv[1]))
want = json.load(open("docs/superpowers/specs/data/2026-10-25-c3-calibration-results/verdict.json"))
pairs = [("verdict", got["verdict"], want["verdict"])]
for l in want["measured"]:
    pairs.append(("%s engine prefill p50" % l, round(got["measured"][l]["engine_prefill_p50_ms"], 1),
                  round(want["measured"][l]["engine_prefill_p50_ms"], 1)))
pairs.append(("S", got["fixed_spacing_ms"], want["fixed_spacing_ms"]))
pairs.append(("size-aware spacings", got["size_aware_spacings_ms"], want["size_aware_spacings_ms"]))
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
  say "C3 calibration's published verdict re-derives from the published evidence"
}

self_test() {
  # A checksum that does not match must fail, or a corrupted download would pass.
  local tmp
  tmp=$(mktemp -d)
  TMPS+=("$tmp")
  printf 'not the archive\n' > "$tmp/$ASSET.tgz"
  if (trap cleanup EXIT; verify "$tmp") >/dev/null 2>&1; then fail "self-test: an altered asset passed the checksum check"; fi
  say "self-test: an altered asset is refused -- the check can fail"
}

case "${1:-}" in
  --self-test) self_test ;;
  "")
    dl=$(mktemp -d)
    TMPS+=("$dl")
    gh release download "$TAG" --dir "$dl" --pattern '*.tgz' || fail "could not download the asset of $TAG"
    verify "$dl" ;;
  *) verify "$1" ;;
esac
