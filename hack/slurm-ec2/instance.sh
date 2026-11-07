#!/usr/bin/env bash
# The instance side of the Slurm on EC2 session: bash hack/slurm-ec2/instance.sh, run as root from /src by the user-data
# hack/lib/slurm-ec2.sh renders, with ROLE (head, gpu1 or gpu2), BUCKET, PREFIX, BOOT and STOP_S in the environment.
#
# head brings up MariaDB, slurmdbd, the NFS export, slurmctld and the accounts, waits for both workers, then runs
# hack/slurm-ec2/procedure.sh and ships the evidence. A worker mounts /shared, reports its hardware, writes a healthy
# GPU signal and starts slurmd from head's configuration, then serves jobs until the session ends.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=hack/slurm-ec2/common.sh
. hack/slurm-ec2/common.sh
: "${ROLE:?}" "${BUCKET:?}" "${PREFIX:?}" "${BOOT:?}" "${STOP_S:?}"

# A stop is reported where the runner and head look for it, so nobody waits out a deadline for an instance that gave up.
# head ships what evidence exists with the reason, which ends the runner's wait; a worker leaves a marker head reads.
die() {
  log "STOPPED: $*"
  echo "$*" >"/tmp/stopped-$ROLE"
  if [ "$ROLE" = head ]; then
    mkdir -p "$EVID" && echo "$*" >"$EVID/VOID"
    bash hack/slurm-ec2/collect.sh
  else
    s3put "/tmp/stopped-$ROLE" "stopped-$ROLE"
  fi
  exit 1
}

# worker_stopped: whether either worker reported a stop.
worker_stopped() {
  local n
  for n in gpu1 gpu2; do
    aws s3api head-object --bucket "$BUCKET" --key "$PREFIX/stopped-$n" >/dev/null 2>>/var/log/slurmec2-probe.log && return 0
  done
  return 1
}

# head_wait END CMD...: until_true with an early stop when a worker has given up.
head_wait() {
  local end=$1
  shift
  while :; do
    "$@" && return 0
    worker_stopped && die "a worker stopped: $(for n in gpu1 gpu2; do s3get "stopped-$n" - 2>>/var/log/slurmec2-probe.log; done | paste -sd';')"
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep 5
  done
}

# ------------------------------------------------------------- the cluster's addresses and T0, from the runner
until_true $(( BOOT + 600 )) 5 s3get cluster.env /tmp/cluster.env || die "cluster.env never arrived"
# shellcheck disable=SC1091
. /tmp/cluster.env
: "${T0:?}" "${HEAD_IP:?}" "${GPU1_IP:?}" "${GPU2_IP:?}"
# Exported, because procedure.sh and collect.sh are child processes and read T0 from their environment.
export T0 HEAD_IP GPU1_IP GPU2_IP
now=$(date +%s)
{ [[ "$T0" =~ ^[0-9]+$ ]] && [ "$T0" -le "$now" ] && [ $(( now - T0 )) -le 900 ]; } || die "T0 is '$T0' at $now"
# The precise backstop: T0 is no later than this instance's LaunchTime plus a few seconds, so this always fires
# before the boot-relative one the user-data armed.
( sleep "$(left $(( T0 + STOP_S )))"; [ "${SLURMEC2_REHEARSAL:-0}" = 1 ] || shutdown -h now ) &
BRINGUP_END=$(( T0 + BRINGUP_END_S ))
log "T0=$T0 head=$HEAD_IP gpu1=$GPU1_IP gpu2=$GPU2_IP bring-up ends $BRINGUP_END"

# The node names Slurm uses are the roles, and every node resolves every other by them.
hostnamectl set-hostname "$ROLE" || [ "${SLURMEC2_REHEARSAL:-0}" = 1 ] || die "hostnamectl"
printf '%s head\n%s gpu1\n%s gpu2\n' "$HEAD_IP" "$GPU1_IP" "$GPU2_IP" >>/etc/hosts

case "$ROLE" in
  head) pkgs="slurmctld=$SLURM_PKG_VERSION slurmdbd=$SLURM_PKG_VERSION slurm-client=$SLURM_PKG_VERSION munge=$MUNGE_PKG_VERSION mariadb-server=$MARIADB_PKG_VERSION nfs-kernel-server python3-venv" ;;
  *) pkgs="slurmd=$SLURM_PKG_VERSION slurm-client=$SLURM_PKG_VERSION munge=$MUNGE_PKG_VERSION nfs-common" ;;
esac
for svc in slurm:$SLURM_UID munge:$MUNGE_UID; do
  u=${svc%%:*} want=${svc##*:}
  if id "$u" >/dev/null 2>>/var/log/slurmec2-setup.log; then
    [ "$(id -u "$u")" = "$want" ] || die "$u already exists with uid $(id -u "$u"), not $want"
  else
    groupadd -g "$want" "$u" && useradd -r -u "$want" -g "$want" -d /nonexistent -s /usr/sbin/nologin "$u" || die "create $u ($want)"
  fi
done
export DEBIAN_FRONTEND=noninteractive
# shellcheck disable=SC2086
# A fresh Ubuntu instance's own apt runs (cloud-init, unattended-upgrades) hold the dpkg lock for minutes after boot;
# waiting for it inside the bring-up budget is cheaper than failing on it.
timeout "$(left "$BRINGUP_END")" bash -c "apt-get -o DPkg::Lock::Timeout=900 update -q && apt-get -o DPkg::Lock::Timeout=900 install -y -q --no-install-recommends $pkgs" \
  >/var/log/slurmec2-apt.log 2>&1 || die "apt install failed or ran out of time; see /var/log/slurmec2-apt.log"

until_true $(( BOOT + 900 )) 5 s3get munge.key /etc/munge/munge.key || die "munge.key"
chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key
systemctl restart munge || die "munge"
id "$TENANT" >>/var/log/slurmec2-setup.log 2>&1 || useradd -u "$TENANT_UID" -m -s /bin/bash "$TENANT" || die "useradd $TENANT"
mkdir -p /var/log/slurm && chown slurm:slurm /var/log/slurm

head_bringup() {
  mkdir -p "$SHARED"
  if [ "${SLURMEC2_REHEARSAL:-0}" != 1 ]; then
    # Exported to the two workers by address, and nowhere else.
    printf '%s %s(rw,sync,no_root_squash,no_subtree_check) %s(rw,sync,no_root_squash,no_subtree_check)\n' \
      "$SHARED" "$GPU1_IP" "$GPU2_IP" >/etc/exports
    systemctl restart nfs-kernel-server && exportfs -ra || die "nfs export"
  fi
  # The rehearsal's /shared is a volume all three containers mount; there is no NFS in it (the design says so).
  mkdir -p "$EVID" "$SHARED/gpuhc" "$SHARED/nodeinfo" "$SHARED/control" "$SHARED/ckpt" "$SHARED/jobs"
  chmod 1777 "$SHARED/ckpt" "$SHARED/jobs" "$EVID"
  echo requeue >"$SHARED/gpuhc/policy"

  # The trainer's PyTorch, once, into the shared volume, while the rest comes up.
  ( python3 -m venv "$SHARED/venv" && "$SHARED/venv/bin/pip" install -q "torch==$TORCH_VERSION" ) \
    >/var/log/slurmec2-venv.log 2>&1 &
  venv_pid=$!

  local pw
  pw=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
  systemctl enable --now mariadb >>/var/log/slurmec2-setup.log 2>&1 || die "mariadb"
  mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db; CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '$pw'; GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;" ||
    die "mariadb grants"
  sed "s|@STORAGE_PASS@|$pw|" hack/slurm-ec2/slurmdbd.conf >/etc/slurm/slurmdbd.conf
  chown slurm:slurm /etc/slurm/slurmdbd.conf && chmod 600 /etc/slurm/slurmdbd.conf
  systemctl restart slurmdbd || die "slurmdbd"
  # sacctmgr reads slurm.conf to find slurmdbd, so the cluster-wide part is in place before the nodes are known;
  # the full file, with the nodes, replaces it before slurmctld starts.
  cp hack/slurm-ec2/slurm.conf /etc/slurm/slurm.conf
  until_true $(( $(date +%s) + 60 )) 2 sacctmgr -n show cluster >>/var/log/slurmec2-setup.log 2>&1 || die "slurmdbd never answered sacctmgr"

  # Each worker's own slurmd -C, so a declared node never exceeds its machine.
  head_wait "$BRINGUP_END" test -s "$SHARED/nodeinfo/gpu1.conf" -a -s "$SHARED/nodeinfo/gpu2.conf" ||
    die "a worker never reported its hardware"
  local nodes="" n line mem
  for n in gpu1 gpu2; do
    line=$(grep -m1 "^NodeName=$n " "$SHARED/nodeinfo/$n.conf") || die "$n's slurmd -C has no NodeName line"
    mem=$(grep -oE 'RealMemory=[0-9]+' <<<"$line" | cut -d= -f2)
    [[ "$mem" =~ ^[0-9]+$ ]] && [ "$mem" -gt 2048 ] || die "$n reported RealMemory '$mem'"
    line=$(sed -E "s/RealMemory=[0-9]+/RealMemory=$(( mem - 1024 ))/; s/ UpTime=.*//" <<<"$line")
    nodes+="$line NodeAddr=$n Gres=gpu:1 State=UNKNOWN"$'\n'
  done
  { cat hack/slurm-ec2/slurm.conf; printf '%s' "$nodes"; echo "PartitionName=gpu Nodes=gpu[1-2] Default=YES MaxTime=60 State=UP"; } >/etc/slurm/slurm.conf
  cp hack/slurm-ec2/cgroup.conf hack/slurm-ec2/gres.conf /etc/slurm/
  mkdir -p /var/spool/slurmctld && chown slurm:slurm /var/spool/slurmctld

  sacctmgr -i add cluster ec2lab >>/var/log/slurmec2-setup.log 2>&1 || die "sacctmgr add cluster"
  sacctmgr -i add account acct-a,acct-b Cluster=ec2lab >>/var/log/slurmec2-setup.log 2>&1 || die "accounts"
  sacctmgr -i add user "$TENANT" Account=acct-b DefaultAccount=acct-b >>/var/log/slurmec2-setup.log 2>&1 || die "tenant in acct-b"
  sacctmgr -i add user "$TENANT" Account=acct-a >>/var/log/slurmec2-setup.log 2>&1 || die "tenant in acct-a"
  sacctmgr -i add qos qone MaxJobsPerUser=1 >>/var/log/slurmec2-setup.log 2>&1 || die "qos qone"
  sacctmgr -i modify user "$TENANT" set QOS+=qone >>/var/log/slurmec2-setup.log 2>&1 || die "tenant qos"

  systemctl restart slurmctld || die "slurmctld"
  # The gres/gpu TRES exists in accounting only once slurmctld, configured with AccountingStorageTRES=gres/gpu, has
  # registered with slurmdbd, so the GPU limit is set after it starts.
  until_true $(( $(date +%s) + 60 )) 3 sacctmgr -i modify account acct-a set GrpTRES=gres/gpu=1 >>/var/log/slurmec2-setup.log 2>&1 ||
    die "acct-a GrpTRES"
  sacctmgr -n -P show assoc format=account,user,grptres,qos >"$EVID/associations.txt"
  touch "$SHARED/control/CONF_READY"
  head_wait "$BRINGUP_END" bash -c '[ "$(sinfo -h -N -o "%N %t" | grep -cE "^gpu[12] (idle|mix)")" = 2 ]' ||
    die "both workers did not register idle: $(sinfo -h -N -o '%N %t %E' | paste -sd';')"
  local venv_left
  venv_left=$(left "$BRINGUP_END")
  timeout "$venv_left" tail --pid="$venv_pid" -f /dev/null || die "the venv was not ready by the bring-up deadline"
  wait "$venv_pid" || die "the venv install failed; see /var/log/slurmec2-venv.log"
  log "bring-up complete"
  echo "bringup_done=$(date +%s)" >"$EVID/bringup.env"
}

worker_bringup() {
  if [ "${SLURMEC2_REHEARSAL:-0}" = 1 ]; then
    # No GPU in the rehearsal: a device node with no driver behind it and an nvidia-smi that names one A10G.
    [ -e /dev/nvidia0 ] || mknod -m 666 /dev/nvidia0 c 195 0
    install -m 755 hack/slurm-ec2/rehearsal-nvidia-smi /usr/local/bin/nvidia-smi
  else
    # The Deep Learning AMI has no /shared; a mount onto a missing directory fails every time.
    mkdir -p "$SHARED" || die "mkdir $SHARED"
    until_true "$BRINGUP_END" 5 mount -t nfs4 -o hard,timeo=600 head:"$SHARED" "$SHARED" || die "/shared did not mount"
  fi
  local cards
  cards=$(nvidia-smi -L) || die "nvidia-smi failed"
  [ "$(grep -c 'A10G' <<<"$cards")" = 1 ] && [ "$(wc -l <<<"$cards")" = 1 ] || die "not one A10G: $cards"
  mkdir -p "$SHARED/nodeinfo"
  # The worker's own write, read back, is the shared-volume check the registration asks for before any job.
  echo "$ROLE $(date +%s)" >"$SHARED/nodeinfo/$ROLE.rw" && grep -q "^$ROLE " "$SHARED/nodeinfo/$ROLE.rw" || die "/shared write"
  {
    echo "cards=$cards"
    echo "driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
    echo "slurmd=$(dpkg-query -W -f '${Version}' slurmd)"
    echo "kernel=$(uname -r)"
    echo "slurm_uid=$(id -u slurm)"
    echo "nvml_plugin=$(test -e /usr/lib/x86_64-linux-gnu/slurm-wlm/gpu_nvml.so && echo present || echo absent)"
  } >"$SHARED/nodeinfo/$ROLE.env"
  slurmd -C >"$SHARED/nodeinfo/$ROLE.conf.tmp" && mv "$SHARED/nodeinfo/$ROLE.conf.tmp" "$SHARED/nodeinfo/$ROLE.conf" || die "slurmd -C"

  # The GPU fault signal gpuhc.py reads: this card's UUID, healthy, until the procedure writes a fault into it.
  local uuid
  uuid=$(nvidia-smi --query-gpu=uuid --format=csv,noheader | head -1)
  [ -n "$uuid" ] || die "no GPU UUID"
  printf 'DCGM_FI_DEV_XID_ERRORS{gpu="0",UUID="%s"} 0\nDCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu="0",UUID="%s"} 0\n' "$uuid" "$uuid" \
    >"$SHARED/gpuhc/$ROLE.prom"
  mkdir -p /opt/slurm-ec2 /var/lib/gpuhc
  cp experiments/slurm-lab/etc/gpuhc.py /opt/slurm-ec2/gpuhc.py
  sed "s|@ROLE@|$ROLE|g" hack/slurm-ec2/gpuhc-ec2.sh >/etc/slurm/gpuhc-ec2.sh
  chmod 755 /etc/slurm/gpuhc-ec2.sh /opt/slurm-ec2/gpuhc.py
  echo 'SLURMD_OPTIONS="--conf-server head:6817"' >/etc/default/slurmd

  until_true "$BRINGUP_END" 5 test -e "$SHARED/control/CONF_READY" || die "head never wrote CONF_READY"
  systemctl enable slurmd >>/var/log/slurmec2-setup.log 2>&1
  systemctl restart slurmd || die "slurmd"
  log "slurmd started"
}

case "$ROLE" in
  head)
    head_bringup
    # The procedure gets the checks' deadline and a little; collect.sh gets what is left before the evidence deadline.
    timeout "$(left $(( T0 + CHECKS_END_S + 30 )))" bash hack/slurm-ec2/procedure.sh
    log "the procedure exited $?"
    # collect.sh ships the evidence first and the diagnostics after, and must end before the self-shutdown.
    timeout "$(left $(( T0 + EVIDENCE_S + 60 )))" bash hack/slurm-ec2/collect.sh
    ;;
  gpu1|gpu2)
    worker_bringup
    # Workers serve jobs until head says the evidence is in, or the session's end.
    until_true $(( T0 + STOP_S - 60 )) 10 test -e "$SHARED/control/END"
    ;;
  *) die "unknown role $ROLE" ;;
esac
