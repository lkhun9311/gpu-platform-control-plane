#!/usr/bin/env bash
# Pins what the committed kind runs of the restart trainer's directed cases show, scored from the repository alone.
#
#   bash hack/test/check-restart-directed-kind.sh
#
# The cases induce, through a restart on kind over NFS, each failure the trainer was fixed for after the paid full stage:
# a malformed newest manifest, one naming another checkpoint's directory, an unreadable shard, a peer let in late, and a
# peer that never comes (hack/distributed-restart-kind.sh, nfs-fallback-* and nfs-rendezvous-*).
# The tree's trainer must pass every check; the trainer before the fallbacks, and the one before the rendezvous setting,
# must each fail the cases that were written for what they lack, and for that reason.
# The timelines are committed xz-compressed, so this also pins that the scorer reads them.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
score() { python3 experiments/distributed-restart/score_kind.py "hack/distributed-restart-kind-$1" 2>&1; }

# The tree's trainer at e8b8410e: every case passes.
out=$(score 20261104T120147Z)
rc=$?
if [ "$rc" = 0 ] && [ "$(tail -1 <<<"$out")" = "all checks passed" ]; then
  ok "the tree's trainer passes every directed case"
else
  bad "the tree's trainer: exit $rc, $(grep -c '^FAIL' <<<"$out") failed: $(grep -m3 '^FAIL' <<<"$out")"
fi
for want in \
  "ok   nfs-fallback-malformed every rank resumed from step 5" \
  "ok   nfs-fallback-otherdir every rank resumed from step 5" \
  "ok   nfs-fallback-unreadable every rank resumed from step 5" \
  "ok   nfs-fallback-unreadable every rank passed over step 6 together, for the registered reason" \
  "ok   nfs-rendezvous-late the peer started 420 s or more after the first rank" \
  "ok   nfs-rendezvous-never attempt 2's lone rank ended between 600 and 660 s after it started" \
  "ok   nfs-rendezvous-never-unset attempt 2's lone rank ended between 60 and 120 s after it started"; do
  if grep -qF "$want" <<<"$out"; then ok "the tree's trainer: '${want#ok   }'"; else bad "the tree's trainer lacks '$want'"; fi
done

# The trainer before #490 (8d3c83c1, sha256 2db31cbd...): the malformed manifest and the unreadable shard end the job,
# and the manifest of another directory is taken for step 6.
out=$(score 20261104T122732Z)
for want in \
  "FAIL ran the tree's trainer: image train.py 2db31cbd3ea0" \
  "FAIL nfs-fallback-malformed succeeded on attempt 2: phase Failed" \
  "FAIL nfs-fallback-otherdir every rank resumed from step 5: attempt 2 resumed from 6" \
  "FAIL nfs-fallback-unreadable succeeded on attempt 2: phase Failed"; do
  if grep -qF "$want" <<<"$out"; then ok "the trainer before the fallbacks: '${want#FAIL }'"; else bad "the trainer before the fallbacks lacks '$want'"; fi
done
for c in malformed unreadable; do
  said=$(cat hack/distributed-restart-kind-20261104T122732Z/nfs-fallback-$c/log-*.txt | grep -cE "KeyError: 'rank'|IsADirectoryError")
  if [ "$said" -ge 1 ]; then ok "the trainer before the fallbacks raised out of the search in nfs-fallback-$c"; else bad "no raise recorded in nfs-fallback-$c"; fi
done

# The trainer before the rendezvous setting (d1e8a0ba): the lone rank gives up at the collective timeout either way.
out=$(score 20261104T124600Z)
for want in \
  "FAIL nfs-rendezvous-late succeeded on attempt 2: phase Failed" \
  "FAIL nfs-rendezvous-never attempt 2's lone rank ended between 600 and 660 s after it started, its peer never with it" \
  "Timed out after 61 seconds waiting for clients. 1/2 clients joined"; do
  if grep -qF "$want" <<<"$out"; then ok "the trainer before the rendezvous setting: '${want#FAIL }'"; else bad "the trainer before the rendezvous setting lacks '$want'"; fi
done

# The first run, whose spoil was made below the NFS server and which the server's cache hid from rank 1.
out=$(score 20261104T113421Z)
if grep -qF "FAIL nfs-fallback-unreadable every rank resumed from step 5: attempt 2 resumed from 6" <<<"$out"; then
  ok "the spoil made below the server is recorded as not reaching rank 1"
else
  bad "the first run's unreadable case: $(grep -m2 'nfs-fallback-unreadable' <<<"$out")"
fi

if [ "$fails" = 0 ]; then echo "check-restart-directed-kind: all checks passed"; else echo "check-restart-directed-kind: $fails failed"; exit 1; fi
