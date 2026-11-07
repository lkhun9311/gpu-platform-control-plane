#!/usr/bin/env bash
# The Slurm on EC2 session's last step on head: the evidence shipped first, then what the nodes and daemons recorded,
# shipped again, then the DONE marker and the END mark that lets the workers stop.
# It runs whether the procedure finished, ran out of time or never started (instance.sh's die), so every step is
# best effort and says when it failed. DONE says whether the last shipped archive was verified in S3 at its size; the
# runner terminates everything when it sees DONE, so DONE is written last.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=hack/slurm-ec2/common.sh
. hack/slurm-ec2/common.sh
mkdir -p "$EVID/nodes" "$EVID/head"
errs=$EVID/collect-errors.txt

# What exists now goes out before anything that can hang.
cp /var/log/slurm/slurmctld.log /var/log/slurm/slurmdbd.log /var/log/slurmec2*.log "$EVID/head/" 2>>"$errs"
cp -r "$SHARED/gpuhc" "$EVID/" 2>>"$errs"
shipped=no
ship && shipped=yes

# The diagnostics: each worker's journal and slurmd log through a job, each bounded, then everything again.
for n in gpu1 gpu2; do
  mkdir -p "$EVID/nodes/$n"
  timeout 30 srun -w "$n" -N1 -n1 --mem=100M -t 1 bash -c \
    'journalctl -k -o short-iso --no-pager; echo "== slurmd"; cat /var/log/slurm/slurmd.log; echo "== setup"; cat /var/log/slurmec2*.log' \
    >"$EVID/nodes/$n/node.txt" 2>>"$errs" || echo "collect from $n failed" >>"$errs"
done
sacct -a -n -P -D -S "$(date -u -d "@${T0:-0}" +%Y-%m-%dT%H:%M:%S)" \
  -o JobID,User,Account,QOS,State,ExitCode,NodeList,Submit,Start,End,Reason,AllocTRES >"$EVID/sacct-all.txt" 2>>"$errs"
sinfo -N -l >"$EVID/sinfo-end.txt" 2>>"$errs"
final=no
ship && final=yes
# Nothing verified yet: keep trying until the evidence deadline, because DONE lets the runner terminate the only copy.
while [ ! -s /tmp/evidence.sha ] && [ "$(date +%s)" -lt $(( ${T0:-0} + EVIDENCE_S + 30 )) ]; do
  sleep 15
  ship && final=yes
done

touch "$SHARED/control/END"
# The digest of the archive S3 holds as verified, which the runner checks its download against: the final one, or the
# earlier one when only that upload was verified.
{
  if [ ! -s /tmp/evidence.sha ]; then echo "NO-EVIDENCE: no archive was verified in S3 by the evidence deadline"
  elif [ -s "$EVID/VOID" ]; then echo "VOID: $(cat "$EVID/VOID")"; else echo "ok"; fi
  echo "evidence_verified=$shipped"
  echo "evidence_final=$final"
  [ ! -s /tmp/evidence.latest ] || cat /tmp/evidence.latest
} >/tmp/DONE
s3put /var/log/slurmec2.log log-head.txt
s3put /tmp/DONE DONE
