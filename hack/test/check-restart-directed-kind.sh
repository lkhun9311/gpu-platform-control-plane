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

# The case budget holds the whole job, to its terminal phase, and not its last step or a rank's exit
# (gpt-6-astra review of 116092ef): the late case's last step was 447.760 s after its creation, its Succeeded 451 s.
out=$(score 20261104T120147Z)
for want in \
  "ok   nfs-rendezvous-late the job was Succeeded inside the paid session's 720 s case budget from its creation: created 2026-11-04T12:07:06.000+00:00, Succeeded 2026-11-04T12:14:37.000+00:00: 451.0 s" \
  "ok   nfs-rendezvous-never the job was Failed inside the paid session's 720 s case budget from its creation: created 2026-11-04T12:14:43.000+00:00, Failed 2026-11-04T12:25:30.000+00:00: 647.0 s"; do
  if grep -qF "$want" <<<"$out"; then ok "the budget is read at the job's end: '${want#ok   }'"; else bad "the budget line lacks '$want'"; fi
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A job whose last step fits but whose end does not: the same archive with its Succeeded moved to 730 s.
cp -r hack/distributed-restart-kind-20261104T120147Z "$tmp/late"
python3 - "$tmp/late/nfs-rendezvous-late/final-mltj.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["status"]["lastTransitionTime"] = "2026-11-04T12:19:16Z"
json.dump(d, open(sys.argv[1], "w"))
EOF
out=$(python3 experiments/distributed-restart/score_kind.py "$tmp/late" 2>&1)
if grep -qF "FAIL nfs-rendezvous-late the job was Succeeded inside the paid session's 720 s case budget" <<<"$out"; then
  ok "a job that ends past the budget fails it, though its last step was inside"
else
  bad "a job ending at 730 s: $(grep -m1 'nfs-rendezvous-late the job' <<<"$out")"
fi

# A hold is observed throughout and for as long as it was kept, not vouched for by one sample: the 20261101T003147Z run
# with every timeline sample after the first of each hold removed must fail each hold's check.
cp -r hack/distributed-restart-kind-20261101T003147Z "$tmp/thin"
python3 - "$tmp/thin" <<'EOF'
import datetime, json, pathlib, sys
ts = lambda s: datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
holds = {"stale-workload": ("hold-start", "hold-end"), "deactivated": ("deactivated", "hold-end"),
         "node-lost": ("pods-hold-start", "fence-hold-end")}
for case, (start, end) in holds.items():
    d = pathlib.Path(sys.argv[1]) / case
    marks = {json.loads(l)["mark"].split()[0]: ts(json.loads(l)["at"]) for l in open(d / "marks.jsonl")}
    a, b = marks[start], marks[end]
    rows = [json.loads(l) for l in open(d / "timeline.jsonl") if l.strip()]
    first = next(i for i, r in enumerate(rows) if a <= ts(r["observed"]) <= b)
    kept = [r for i, r in enumerate(rows) if i == first or not a <= ts(r["observed"]) <= b]
    (d / "timeline.jsonl").write_text("".join(json.dumps(r) + "\n" for r in kept))
EOF
out=$(python3 experiments/distributed-restart/score_kind.py "$tmp/thin" 2>&1)
for want in \
  "FAIL stale-workload no second attempt while the Workload was held" \
  "FAIL deactivated no restart after an operator's deactivation" \
  "FAIL node-lost no second attempt while the lost node's Pods remained" \
  "FAIL node-lost no second attempt until the node was fenced"; do
  if grep -qF "$want" <<<"$out"; then ok "a hold seen once is not a hold watched: '${want#FAIL }'"; else bad "the thinned run lacks '$want'"; fi
done
# A hold shorter than the one the harness keeps says nothing of the rest of it: the same run with stale-workload's
# hold-end mark moved to 30 s after its hold-start.
cp -r hack/distributed-restart-kind-20261101T003147Z "$tmp/short"
python3 - "$tmp/short/stale-workload/marks.jsonl" <<'EOF'
import datetime, json, sys
ts = lambda s: datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
start = next(ts(r["at"]) for r in rows if r["mark"] == "hold-start")
for r in rows:
    if r["mark"] == "hold-end":
        r["at"] = (start + datetime.timedelta(seconds=30)).isoformat().replace("+00:00", "Z")
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
EOF
out=$(python3 experiments/distributed-restart/score_kind.py "$tmp/short" 2>&1)
if grep -qE "FAIL stale-workload no second attempt while the Workload was held: .*the hold lasted 30.0 s of 60 s" <<<"$out"; then
  ok "a hold kept for half its time is not the registered hold"
else
  bad "the shortened hold: $(grep -m1 'stale-workload no second' <<<"$out")"
fi

# A legacy sample with an empty status is a status read that failed, and no_second_attempt, which wants exactly one
# attempt in every sample, refuses the hold for it.
cp -r hack/distributed-restart-kind-20261101T003147Z "$tmp/unread"
python3 - "$tmp/unread/stale-workload" <<'EOF'
import datetime, json, pathlib, sys
ts = lambda s: datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
d = pathlib.Path(sys.argv[1])
marks = {json.loads(l)["mark"].split()[0]: ts(json.loads(l)["at"]) for l in open(d / "marks.jsonl")}
rows = [json.loads(l) for l in open(d / "timeline.jsonl") if l.strip()]
hit = next(r for r in rows if marks["hold-start"] < ts(r["observed"]) < marks["hold-end"])
hit["status"] = {}
(d / "timeline.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
EOF
out=$(python3 experiments/distributed-restart/score_kind.py "$tmp/unread" 2>&1)
if grep -qF "FAIL stale-workload no second attempt while the Workload was held: 53 samples over 60.2 s" <<<"$out"; then
  ok "a legacy sample whose status read failed does not vouch for the hold"
else
  bad "the unread sample: $(grep -m1 'stale-workload no second' <<<"$out")"
fi

# And the run as recorded still passes them, with the gap and the duration it was held to.
out=$(score 20261101T003147Z)
if grep -qF "ok   stale-workload no second attempt while the Workload was held: 53 samples over 60.2 s, longest unobserved 1.1 s" <<<"$out" &&
  [ "$(tail -1 <<<"$out")" = "all checks passed" ]; then
  ok "the recorded 20261101T003147Z run passes its holds observed throughout"
else
  bad "the recorded run: $(grep -m2 'stale-workload no second' <<<"$out"); $(tail -1 <<<"$out")"
fi

if [ "$fails" = 0 ]; then echo "check-restart-directed-kind: all checks passed"; else echo "check-restart-directed-kind: $fails failed"; exit 1; fi
