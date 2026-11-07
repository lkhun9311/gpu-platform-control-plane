#!/usr/bin/env bash
# The Slurm on EC2 session's last step on head: what the nodes and daemons recorded, into /shared/evidence, then the
# archive and the DONE marker to S3, and the END mark that lets the workers stop.
# It runs whether the procedure finished, ran out of time or never started (instance.sh's die), so every step is
# best effort and says when it failed; the marker is written last, and only once the archive is uploaded or its upload
# has failed, because the runner terminates everything as soon as it sees it.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=hack/slurm-ec2/common.sh
. hack/slurm-ec2/common.sh
mkdir -p "$EVID/nodes" "$EVID/head"
errs=$EVID/collect-errors.txt

for n in gpu1 gpu2; do
  mkdir -p "$EVID/nodes/$n"
  # A worker that never registered cannot run these; the error says so and the rest goes on.
  timeout 120 srun -w "$n" -N1 -n1 --mem=100M -t 2 bash -c \
    'journalctl -k -o short-iso --no-pager; echo "== slurmd"; cat /var/log/slurm/slurmd.log; echo "== status"; systemctl status slurmd --no-pager; echo "== setup"; cat /var/log/slurmec2*.log' \
    >"$EVID/nodes/$n/node.txt" 2>>"$errs" || echo "collect from $n failed" >>"$errs"
done
cp /var/log/slurm/slurmctld.log /var/log/slurm/slurmdbd.log /var/log/slurmec2*.log "$EVID/head/" 2>>"$errs"
sacct -a -n -P -D -S "$(date -u -d "@${T0:-0}" +%Y-%m-%dT%H:%M:%S)" \
  -o JobID,User,Account,QOS,State,ExitCode,NodeList,Submit,Start,End,Reason,AllocTRES >"$EVID/sacct-all.txt" 2>>"$errs"
sinfo -N -l >"$EVID/sinfo-end.txt" 2>>"$errs"
cp -r "$SHARED/gpuhc" "$EVID/" 2>>"$errs"

tar -czf /tmp/evidence.tgz -C "$SHARED" evidence 2>>/tmp/collect-tar.err || echo "tar failed: $(cat /tmp/collect-tar.err)" >/tmp/DONE.reason
s3put /tmp/evidence.tgz evidence.tgz || echo "the evidence upload failed" >>/tmp/DONE.reason
touch "$SHARED/control/END"
if [ -s "$EVID/VOID" ]; then echo "VOID: $(cat "$EVID/VOID")" >/tmp/DONE; else echo "ok" >/tmp/DONE; fi
cat /tmp/DONE.reason >>/tmp/DONE 2>>"$errs"
s3put /var/log/slurmec2.log log-head.txt
s3put /tmp/DONE DONE
