#!/usr/bin/env bash
# The old bring-up barrier, run once on its own in the t3 real-NFS rehearsal before the session's own bring-up, as an
# attempt to reproduce the first paid run (registration, "The t3 real-NFS rehearsal").
#
# Head exports /nfsprobe with the first run's export options and no control directory; each worker mounts it with the
# first run's mount options (`hard,timeo=600`, the version left to negotiation) and starts polling `test -e
# /nfsprobe/control/CONF_READY` at once, so its client has looked the path up and found nothing before head creates it.
# Thirty seconds after both workers report polling, head runs the first run's `mkdir -p` and `touch`. Each worker records
# when it first sees the marker, or that it did not within 180 s, with an errno-bearing stat of each path component.
# The first run waited 21 minutes; 180 s is three times the longest attribute cache nfs(5) gives by default.
# Every operation on the mount runs under timeout, because a hard mount blocks on an unreachable server forever.
# Results go to S3 as nfsprobe-ROLE; nothing here decides the session, and nothing in it can stop it.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=hack/slurm-ec2/common.sh
. hack/slurm-ec2/common.sh
P=/nfsprobe
OUTF=/tmp/nfsprobe-$ROLE
: >"$OUTF"
note() { printf '%s %s\n' "$(date +%s.%N | cut -c1-14)" "$*" >>"$OUTF"; }
stats() {
  timeout --kill-after=5 20 python3 - "$P" "$P/control" "$P/control/CONF_READY" <<'PY' >>"$OUTF" 2>&1
import os, sys
for p in sys.argv[1:]:
    try:
        s = os.stat(p); print("  stat", p, "OK", s.st_ino, s.st_mtime_ns)
    except OSError as e:
        print("  stat", p, "ERROR", e.errno, e.strerror)
PY
}
# Both keys present; each call bounded by awsb, its errors kept in the probe's own record.
both() { awsb s3api head-object --bucket "$BUCKET" --key "$PREFIX/$1" >/dev/null 2>>"$OUTF" && awsb s3api head-object --bucket "$BUCKET" --key "$PREFIX/$2" >/dev/null 2>>"$OUTF"; }

case "$ROLE" in
  head)
    mkdir -p "$P" || { note "mkdir $P failed"; exit 0; }
    printf '%s %s(rw,sync,no_root_squash,no_subtree_check) %s(rw,sync,no_root_squash,no_subtree_check)\n' \
      "$P" "$GPU1_IP" "$GPU2_IP" >/etc/exports
    systemctl restart nfs-kernel-server && exportfs -ra || { note "export failed"; s3put "$OUTF" nfsprobe-head; exit 0; }
    note "exported $P without a control directory"
    # Both workers polling, or 240 s.
    until_true $(( $(date +%s) + 240 )) 5 both nfsprobe-polling-gpu1 nfsprobe-polling-gpu2 ||
      note "not both workers reported polling within 240 s"
    sleep 30
    mkdir -p "$P/control"; note "mkdir control rc=$?"
    touch "$P/control/CONF_READY"; note "touch CONF_READY rc=$?"
    stats
    # Both results, or 210 s; then the probe export is withdrawn so the session's own export is the only one.
    until_true $(( $(date +%s) + 210 )) 5 both nfsprobe-gpu1 nfsprobe-gpu2 ||
      note "not both worker results within 210 s"
    : >/etc/exports; exportfs -ra; note "probe export withdrawn"
    s3put "$OUTF" nfsprobe-head
    ;;
  gpu1|gpu2)
    mkdir -p "$P"
    if ! until_true $(( $(date +%s) + 240 )) 5 mount -t nfs4 -o hard,timeo=600 head:"$P" "$P"; then
      note "mount failed"; s3put "$OUTF" "nfsprobe-$ROLE"; exit 0
    fi
    timeout --kill-after=5 10 findmnt -T "$P" -o OPTIONS -n >>"$OUTF" 2>&1
    timeout --kill-after=5 10 test -e "$P/control/CONF_READY"; note "first test -e rc=$?"
    stats
    echo polling >/tmp/polling && s3put /tmp/polling "nfsprobe-polling-$ROLE"
    start=$(date +%s); seen=""
    while [ $(( $(date +%s) - start )) -lt 180 ]; do
      if timeout --kill-after=5 10 test -e "$P/control/CONF_READY"; then seen=$(date +%s.%N | cut -c1-14); break; fi
      sleep 1
    done
    if [ -n "$seen" ]; then note "SEEN at $seen"; else note "NOT SEEN within 180 s"; fi
    stats
    timeout --kill-after=5 30 umount "$P"; note "umount rc=$?"
    timeout --kill-after=5 10 mountpoint -q "$P" && { umount -l "$P"; note "lazy umount rc=$?"; }
    s3put "$OUTF" "nfsprobe-$ROLE"
    ;;
esac
exit 0
