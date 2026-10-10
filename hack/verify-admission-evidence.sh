#!/usr/bin/env bash
#
# Re-derives the admission study's published verdicts from its published evidence, and exits 0 only when every
# one of them matches.
#
#   hack/verify-admission-evidence.sh [DIR]     DIR holds the release's assets; without it they are downloaded
#   hack/verify-admission-evidence.sh --self-test
#
# The evidence is the GitHub release evidence-admission-2026-10-10: the raw cells of the three paid sessions the
# design page reports, the admission diagnostic, v26 and v27's calibration
# (docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md). Each asset is checked against the
# checksums committed beside the verdicts before anything is read, then scored by this checkout's
# hack/prospective-pilot/pilot_report.py, and the result is compared with the committed verdict files.
#
# What is compared: each study's verdict sentence; v26's pooled premium p99 per arm; the calibration's engine prefill
# medians and its size-aware spacings. A scorer changed since the verdicts were committed shows up here as a
# mismatch, which is the point: a published verdict that this checkout no longer reproduces is not one to cite.
#
# What it cannot do: it re-scores rows collected once. It does not re-run an experiment or touch a GPU, and the
# predicted claims on the design page come from the replay, not from this evidence.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=evidence-admission-2026-10-10
SUMS=docs/superpowers/specs/data/admission-evidence-SHA256SUMS
say() { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

verify() {
  local dir="$1" work
  [ -s "$SUMS" ] || fail "the committed checksum list $SUMS is missing"
  # Every listed asset must be there and match; an asset the list does not name is not read.
  (cd "$dir" && sha256sum --check --strict "$OLDPWD/$SUMS") >/dev/null 2>&1 \
    || fail "an asset in $dir is missing or does not match $SUMS"
  say "checksums match $SUMS"
  work=$(mktemp -d)
  # shellcheck disable=SC2064 # expanded now, on purpose: the directory is this call's
  trap "rm -rf '$work'" RETURN
  local name study
  for name in admission-diagnostic-2026-10-09 admission-frontier-2026-10-10 admission-length-calibration-2026-10-10; do
    mkdir -p "$work/$name"
    tar -xzf "$dir/$name.tgz" -C "$work/$name" || fail "$name.tgz could not be unpacked"
  done
  for study in diagnostic frontier calibration; do
    local src
    case "$study" in
      diagnostic) src=admission-diagnostic-2026-10-09 ;;
      frontier) src=admission-frontier-2026-10-10 ;;
      calibration) src=admission-length-calibration-2026-10-10 ;;
    esac
    python3 hack/prospective-pilot/pilot_report.py "$study" "$work/$src/m5c-run" > "$work/$study.json" \
      || fail "the scorer could not score $study"
  done
  python3 - "$work" <<'PY' || fail "a re-derived verdict differs from the published one"
import json, sys
work = sys.argv[1]
D = "docs/superpowers/specs/data/"
pub = {"diagnostic": D + "2026-10-09-diagnostic-results/verdict.json",
       "frontier": D + "2026-10-10-frontier-results/verdict.json",
       "calibration": D + "2026-10-10-calibration-results/verdict.json"}
bad = []
for study, path in pub.items():
    got, want = json.load(open("%s/%s.json" % (work, study))), json.load(open(path))
    pairs = [("verdict", got["verdict"], want["verdict"])]
    if study == "frontier":
        for arm in want["pooled"]:
            pairs.append(("%s pooled premium p99" % arm, round(got["pooled"][arm]["premium_p99_sched_hi"], 1),
                          round(want["pooled"][arm]["premium_p99_sched_hi"], 1)))
    if study == "calibration":
        for l in want["measured"]:
            pairs.append(("%s engine prefill p50" % l, round(got["measured"][l]["engine_prefill_p50_ms"], 1),
                          round(want["measured"][l]["engine_prefill_p50_ms"], 1)))
        pairs.append(("size-aware spacings", got["size_aware_spacings_ms"], want["size_aware_spacings_ms"]))
    for name, g, w in pairs:
        if g != w:
            bad.append("%s %s: re-derived %r, published %r" % (study, name, g, w))
        else:
            print("ok   %s %s: %s" % (study, name, str(g)[:100]))
for b in bad:
    print("DIFF " + b)
sys.exit(1 if bad else 0)
PY
  say "every published admission verdict re-derives from the published evidence"
}

self_test() {
  # A checksum that does not match must fail, or a corrupted download would pass.
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  printf 'not the archive\n' > "$tmp/admission-diagnostic-2026-10-09.tgz"
  : > "$tmp/admission-frontier-2026-10-10.tgz"
  : > "$tmp/admission-length-calibration-2026-10-10.tgz"
  if (verify "$tmp") >/dev/null 2>&1; then fail "self-test: altered assets passed the checksum check"; fi
  say "self-test: altered assets are refused -- the check can fail"
}

case "${1:-}" in
  --self-test) self_test ;;
  "")
    dl=$(mktemp -d)
    trap 'rm -rf "$dl"' EXIT
    gh release download "$TAG" --dir "$dl" --pattern '*.tgz' || fail "could not download the assets of $TAG"
    verify "$dl" ;;
  *) verify "$1" ;;
esac
