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
  phase "STOPPED: $*"
  echo "$*" >"/tmp/stopped-$ROLE"
  [ "$ROLE" = head ] || diag_ship final
  if [ "$ROLE" = head ]; then
    mkdir -p "$EVID" && echo "$*" >"$EVID/VOID"
    bash hack/slurm-ec2/collect.sh
  else
    s3put "/tmp/stopped-$ROLE" "stopped-$ROLE"
  fi
  exit 1
}

# late REASON: the bring-up missed its deadline. The registration makes every check NOTRUN then, not the session VOID:
# nothing about the system under test was shown to be wrong, only slow.
late() {
  log "NOTRUN: $*"
  phase "NOTRUN: $*"
  [ "$ROLE" = head ] || diag_ship final
  if [ "$ROLE" = head ]; then
    mkdir -p "$EVID" && echo "$*" >"$EVID/NOTRUN_ALL"
    bash hack/slurm-ec2/collect.sh
  else
    # Head reads the LATE prefix and makes the session NOTRUN rather than VOID.
    echo "LATE: $*" >"/tmp/stopped-$ROLE"
    s3put "/tmp/stopped-$ROLE" "stopped-$ROLE"
  fi
  exit 1
}

# worker_stopped: whether either worker reported a stop.
worker_stopped() {
  local n
  for n in gpu1 gpu2; do
    awsb s3api head-object --bucket "$BUCKET" --key "$PREFIX/stopped-$n" >/dev/null 2>>/var/log/slurmec2-probe.log && return 0
  done
  return 1
}

# head_wait END CMD...: until_true with an early stop when a worker has given up.
head_wait() {
  local end=$1
  shift
  while :; do
    # Each probe gets at most the time left, so a hung sinfo cannot carry the wait past its deadline.
    timeout --kill-after=2 "$(left "$end")" "$@" && [ "$(date +%s)" -le "$end" ] && return 0
    [ "$(date +%s)" -lt "$end" ] || return 1
    if CALL_BOUND=$(( end - $(date +%s) )) worker_stopped; then
      local why
      why=$(for n in gpu1 gpu2; do CALL_BOUND=30 s3get "stopped-$n" - 2>>/var/log/slurmec2-probe.log; done | paste -sd';')
      case "$why" in LATE:*) late "a worker missed the bring-up deadline: $why" ;; *) die "a worker stopped: $why" ;; esac
    fi
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep "$(CALL_BOUND=$(( end - $(date +%s) )) bound 5)"
  done
}

# ------------------------------------------------------------- the cluster's addresses and T0, from the runner
until_true $(( BOOT + 600 )) 5 s3get cluster.env /tmp/cluster.env || die "cluster.env never arrived"
why=$(cenv_check /tmp/cluster.env) || die "$why"
# shellcheck disable=SC1091
. /tmp/cluster.env
: "${T0:?}" "${HEAD_IP:?}" "${GPU1_IP:?}" "${GPU2_IP:?}"
# Exported, because procedure.sh and collect.sh are child processes and read T0 from their environment.
export T0 HEAD_IP GPU1_IP GPU2_IP
# The t3 real-NFS rehearsal shortens the clock; whatever cluster.env sets must be numbers in the registered order.
for v in BRINGUP_END_S CHECKS_END_S EVIDENCE_S; do [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v is '${!v}'"; done
{ [ "$BRINGUP_END_S" -lt "$CHECKS_END_S" ] && [ "$CHECKS_END_S" -lt "$EVIDENCE_S" ] && [ "$EVIDENCE_S" -lt "$STOP_S" ]; } ||
  die "the clock is out of order: bring-up $BRINGUP_END_S, checks $CHECKS_END_S, evidence $EVIDENCE_S, stop $STOP_S"
export BRINGUP_END_S CHECKS_END_S EVIDENCE_S
# Only the t3 rehearsal narrows the checks and B4's admission; anything else is refused rather than read.
[[ "${SLURMEC2_CHECKS:-}" =~ ^(b[1-4](,b[1-4])*)?$ ]] && [[ "${B4_ADMIT_S:-1700}" =~ ^[0-9]+$ ]] && [[ "${B4_MEM_MB:-4096}" =~ ^[0-9]+$ ]] ||
  die "SLURMEC2_CHECKS, B4_ADMIT_S or B4_MEM_MB is malformed"
export SLURMEC2_CHECKS="${SLURMEC2_CHECKS:-}" B4_ADMIT_S="${B4_ADMIT_S:-1700}" B4_MEM_MB="${B4_MEM_MB:-4096}"
phase "T0 read"
now=$(date +%s)
{ [[ "$T0" =~ ^[0-9]+$ ]] && [ "$T0" -le $(( now + 60 )) ]; } || die "T0 is '$T0' at $now"
# A slow bootstrap (snap seeding, the CLI, the source) is only late once the registered bring-up window has passed,
# and late is NOTRUN, not VOID.
[ $(( now - T0 )) -le "$BRINGUP_END_S" ] || late "the bootstrap reached T0 only $(( now - T0 )) s after it, past the bring-up window"
# The precise backstop: T0 is no later than this instance's LaunchTime plus a few seconds, so this always fires
# before the boot-relative one the user-data armed.
( sleep "$(left $(( T0 + STOP_S )))"; [ "$SLURMEC2_NO_SHUTDOWN" = 1 ] || shutdown -h now ) &
# This host's diagnostics go to S3 every minute on their own, so a host whose Slurm or NFS never worked still reports.
( while sleep 60; do diag_ship periodic; done ) &
BRINGUP_END=$(( T0 + BRINGUP_END_S ))
log "T0=$T0 head=$HEAD_IP gpu1=$GPU1_IP gpu2=$GPU2_IP bring-up ends $BRINGUP_END"

# The node names Slurm uses are the roles, and every node resolves every other by them.
hostnamectl set-hostname "$ROLE" || [ "$SLURMEC2_SHARED_VOLUME" = 1 ] || die "hostnamectl"
printf '%s head\n%s gpu1\n%s gpu2\n' "$HEAD_IP" "$GPU1_IP" "$GPU2_IP" >>/etc/hosts

case "$ROLE" in
  head) pkgs="slurmctld=$SLURM_PKG_VERSION slurmdbd=$SLURM_PKG_VERSION slurm-client=$SLURM_PKG_VERSION munge=$MUNGE_PKG_VERSION mariadb-server=$MARIADB_PKG_VERSION nfs-kernel-server python3-venv tcpdump" ;;
  *) pkgs="slurmd=$SLURM_PKG_VERSION slurm-client=$SLURM_PKG_VERSION munge=$MUNGE_PKG_VERSION nfs-common tcpdump" ;;
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
  >/var/log/slurmec2-apt.log 2>&1
apt_rc=$?
# Out of time is a missed bring-up deadline, which the registration makes NOTRUN; any other failure is VOID.
if [ "$apt_rc" = 124 ]; then late "the package install ran out of the bring-up time"
elif [ "$apt_rc" != 0 ]; then die "apt install failed ($apt_rc); see /var/log/slurmec2-apt.log"; fi
phase "packages installed"
# NFS traffic during the bring-up, the probe's included, in two rotating 8 MB files: what a client asked and what the
# server answered.
if [ "$SLURMEC2_SHARED_VOLUME" != 1 ]; then
  ( timeout "$(left "$BRINGUP_END")" tcpdump -ni any -s 256 -C 8 -W 2 -w "$DIAG/nfs.pcap" 'tcp port 2049' >>"$DIAG/tcpdump.log" 2>&1 ) &
fi
# The munge key is in S3 before any instance is bought, so it is fetched before the probe can spend the bring-up time;
# running out of that time is a missed deadline, NOTRUN.
until_true "$BRINGUP_END" 5 s3get munge.key /etc/munge/munge.key || late "munge.key was not fetched by the bring-up deadline"
# The old barrier, on its own, as a reproduction attempt; only the t3 rehearsal sets this.
if [ "${SLURMEC2_NFS_PROBE:-0}" = 1 ]; then
  probe_left=$(left "$BRINGUP_END"); [ "$probe_left" -le 600 ] || probe_left=600
  timeout --kill-after=5 "$probe_left" bash hack/slurm-ec2/nfs-probe.sh
  phase "nfs probe exited $?"
fi

chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key
systemctl restart munge || die "munge"
id "$TENANT" >>/var/log/slurmec2-setup.log 2>&1 || useradd -u "$TENANT_UID" -m -s /bin/bash "$TENANT" || die "useradd $TENANT"
mkdir -p /var/log/slurm && chown slurm:slurm /var/log/slurm

head_bringup() {
  # Every directory exists before the export, and every write is checked: the first paid run could not tell a marker
  # never written from one never seen.
  mkdir -p "$SHARED" "$EVID" "$SHARED/gpuhc" "$SHARED/nodeinfo" "$SHARED/ckpt" "$SHARED/jobs" "$SHARED/nfscheck" ||
    die "mkdir under $SHARED"
  chmod 1777 "$SHARED/ckpt" "$SHARED/jobs" "$EVID" || die "chmod under $SHARED"
  echo requeue >"$SHARED/gpuhc/policy" || die "write the gpuhc policy"
  # A token head writes on NFS and names in CONF_READY over S3: a worker that reads it back has shown head-to-worker
  # visibility through the mount, which nothing else in the bring-up does.
  NFS_TOKEN=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
  echo "$NFS_TOKEN" >"$SHARED/nfscheck/head.tmp" && mv "$SHARED/nfscheck/head.tmp" "$SHARED/nfscheck/head" || die "write the NFS token"
  if [ "$SLURMEC2_SHARED_VOLUME" != 1 ]; then
    # Exported to the two workers by address, and nowhere else.
    printf '%s %s(rw,sync,no_root_squash,no_subtree_check) %s(rw,sync,no_root_squash,no_subtree_check)\n' \
      "$SHARED" "$GPU1_IP" "$GPU2_IP" >/etc/exports || die "write /etc/exports"
    systemctl restart nfs-kernel-server && exportfs -ra || die "nfs export"
    run_logged exportfs exportfs -v
    run_logged head-stat stat "$SHARED" "$SHARED/nfscheck/head" "$SHARED/gpuhc/policy"
    run_logged head-df bash -c "df -h $SHARED; df -i $SHARED"
  fi
  phase "shared tree ready"

  # The trainer's PyTorch, once, into the shared volume, while the rest comes up.
    # Without a GPU the CPU wheel is enough and a tenth of the download.
  local idx=()
  [ "$SLURMEC2_FAKE_GPU" = 1 ] && idx=(--index-url https://download.pytorch.org/whl/cpu)
  ( python3 -m venv "$SHARED/venv" && "$SHARED/venv/bin/pip" install -q ${idx[@]+"${idx[@]}"} "torch==$TORCH_VERSION" ) \
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
    late "a worker never reported its hardware by the bring-up deadline"
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
  until_true $(( $(date +%s) + 60 )) 2 scontrol ping >>/var/log/slurmec2-setup.log 2>&1 || die "slurmctld does not answer scontrol ping"
  sig_put CONF_READY ready "$NFS_TOKEN" || die "CONF_READY could not be put to S3"
  head_wait "$BRINGUP_END" bash -c '[ "$(sinfo -h -N -o "%N %t" | grep -cE "^gpu[12] (idle|mix)")" = 2 ]' ||
    late "both workers did not register idle by the bring-up deadline: $(timeout -k 2 10 sinfo -h -N -o '%N %t %E' | paste -sd';')"
  local venv_left
  venv_left=$(left "$BRINGUP_END")
  timeout "$venv_left" tail --pid="$venv_pid" -f /dev/null || late "the venv was not ready by the bring-up deadline"
  wait "$venv_pid" || die "the venv install failed; see /var/log/slurmec2-venv.log"
  local n2
  for n2 in gpu1 gpu2; do
    sig_get "CONF_ACK-$n2" "$n2" acked; echo "$n2 ack=$?" >>"$DIAG/acks.txt"
    # Each worker wrote the token back through its mount before slurmd started; head reads it from its own disk.
    [ "$(cat "$SHARED/nfscheck/$n2" 2>>"$DIAG/cmd.err")" = "$NFS_TOKEN" ] || die "$n2's NFS token did not reach head"
  done
  log "bring-up complete"
  phase "bring-up complete"
  printf 'T0=%s\nbringup_done=%s\n' "$T0" "$(date +%s)" >"$EVID/bringup.env"
  # Finished, but late: the registration admits no check after the bring-up deadline.
  [ "$(date +%s)" -le "$BRINGUP_END" ] || late "the bring-up finished after its deadline"
}

worker_bringup() {
  if [ "$SLURMEC2_FAKE_GPU" = 1 ]; then
    # No GPU in a rehearsal: a device node with no driver behind it and an nvidia-smi that names one A10G.
    [ -e /dev/nvidia0 ] || mknod -m 666 /dev/nvidia0 c 195 0 || die "mknod /dev/nvidia0"
    install -m 755 hack/slurm-ec2/rehearsal-nvidia-smi /usr/local/bin/nvidia-smi || die "install the nvidia-smi stand-in"
  fi
  if [ "$SLURMEC2_SHARED_VOLUME" != 1 ]; then
    # The Deep Learning AMI has no /shared; a mount onto a missing directory fails every time.
    mkdir -p "$SHARED" || die "mkdir $SHARED"
    until_true "$BRINGUP_END" 5 mount -t nfs -o "$NFS_OPTS" head:"$SHARED" "$SHARED" || late "/shared did not mount by the bring-up deadline"
    # The options the kernel actually uses, which can differ from the ones asked for (/etc/nfsmount.conf).
    run_logged findmnt findmnt -T "$SHARED" -o TARGET,SOURCE,FSTYPE,OPTIONS
    run_logged nfsstat-m nfsstat -m
    cp /proc/self/mountinfo "$DIAG/mountinfo" 2>>"$DIAG/cmd.err"
    cp /etc/nfsmount.conf "$DIAG/nfsmount.conf" 2>>"$DIAG/cmd.err"
  fi
  phase "shared mounted"
  local cards
  cards=$(nvidia-smi -L) || die "nvidia-smi failed"
  [ "$(grep -c 'A10G' <<<"$cards")" = 1 ] && [ "$(wc -l <<<"$cards")" = 1 ] || die "not one A10G: $cards"
  # Every write to /shared from here is made locally and copied under timeout with a forced kill: a hard mount blocks a
  # write to an unreachable server until the process is killed.
  nfs_do() { timeout --kill-after=5 30 "$@"; }
  nfs_do mkdir -p "$SHARED/nodeinfo" || die "mkdir $SHARED/nodeinfo"
  # The worker's own write, read back, is the shared-volume check the registration asks for before any job.
  nfs_do bash -c 'echo "$1 $(date +%s)" >"$2" && grep -q "^$1 " "$2"' _ "$ROLE" "$SHARED/nodeinfo/$ROLE.rw" || die "/shared write"
  {
    echo "cards=$cards"
    echo "driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
    echo "slurmd=$(dpkg-query -W -f '${Version}' slurmd)"
    echo "kernel=$(uname -r)"
    echo "slurm_uid=$(id -u slurm)"
    echo "nvml_plugin=$(test -e /usr/lib/x86_64-linux-gnu/slurm-wlm/gpu_nvml.so && echo present || echo absent)"
  } >"/tmp/nodeinfo-$ROLE.env"
  nfs_do cp "/tmp/nodeinfo-$ROLE.env" "$SHARED/nodeinfo/$ROLE.env" || die "copy the node info to $SHARED"
  slurmd -C >"/tmp/nodeinfo-$ROLE.conf" || die "slurmd -C"
  nfs_do bash -c 'cp "$1" "$2.tmp" && mv "$2.tmp" "$2"' _ "/tmp/nodeinfo-$ROLE.conf" "$SHARED/nodeinfo/$ROLE.conf" || die "copy slurmd -C to $SHARED"

  # The GPU fault signal gpuhc.py reads: this card's UUID, healthy, until the procedure writes a fault into it.
  local uuid
  uuid=$(nvidia-smi --query-gpu=uuid --format=csv,noheader | head -1)
  [ -n "$uuid" ] || die "no GPU UUID"
  # Made here too: head may not have made it yet, and a missing signal makes gpuhc drain the node at slurmd's start.
  nfs_do mkdir -p "$SHARED/gpuhc" || die "mkdir $SHARED/gpuhc"
  printf '# generation 0\nDCGM_FI_DEV_XID_ERRORS{gpu="0",UUID="%s"} 0\nDCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu="0",UUID="%s"} 0\n' "$uuid" "$uuid" \
    >"/tmp/gpuhc-$ROLE.prom" && nfs_do cp "/tmp/gpuhc-$ROLE.prom" "$SHARED/gpuhc/$ROLE.prom" || die "write the GPU signal"
  mkdir -p /opt/slurm-ec2 /var/lib/gpuhc
  cp experiments/slurm-lab/etc/gpuhc.py /opt/slurm-ec2/gpuhc.py
  sed "s|@ROLE@|$ROLE|g" hack/slurm-ec2/gpuhc-ec2.sh >/etc/slurm/gpuhc-ec2.sh
  chmod 755 /etc/slurm/gpuhc-ec2.sh /opt/slurm-ec2/gpuhc.py
  echo 'SLURMD_OPTIONS="--conf-server head:6817"' >/etc/default/slurmd || die "write /etc/default/slurmd"
  # Configless slurmd retries its first fetch on its own, but nothing documents that it does for ever; systemd starts
  # it again if it gives up.
  mkdir -p /etc/systemd/system/slurmd.service.d &&
    printf '[Service]\nRestart=on-failure\nRestartSec=5\n[Unit]\nStartLimitIntervalSec=0\n' >/etc/systemd/system/slurmd.service.d/restart.conf &&
    systemctl daemon-reload || die "the slurmd restart policy"
  # Signal B4's watcher: every change this host sees in its own GPU signal, with when and what, so a drain's delay can be
  # split into the signal's delivery and Slurm's reaction (the registered B4 clock is unchanged).
  ( prev=""; while sleep 1; do
      h=$(sha256sum "$SHARED/gpuhc/$ROLE.prom" 2>&1 | cut -c1-16)
      [ "$h" = "$prev" ] && continue
      g=$(sed -n 's/^# generation \([0-9]*\)$/\1/p' "$SHARED/gpuhc/$ROLE.prom" 2>>"$DIAG/watch.err")
      printf '%s %s generation=%s sha=%s\n' "$(date +%s.%N | cut -c1-14)" "$(cut -d' ' -f1 /proc/uptime)" "${g:-?}" "$h" >>"$DIAG/signal-observed.log"
      prev=$h
    done ) &

  sig_wait "$BRINGUP_END" CONF_READY head ready
  case $? in
    0) ;;
    1) late "head did not put CONF_READY by the bring-up deadline" ;;
    *) die "CONF_READY could not be read from S3 (see the s3 log in the diagnostics)" ;;
  esac
  # Head-to-worker visibility through the mount, shown rather than assumed: the token head wrote on NFS, read here.
  local token seen
  token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$CTRL/CONF_READY.download") ||
    die "CONF_READY carries no NFS token"
  [[ "$token" =~ ^[0-9a-f]{24}$ ]] || die "CONF_READY's NFS token is '$token', not 24 hex digits"
  if [ "$SLURMEC2_SHARED_VOLUME" != 1 ]; then
    # The read runs under until_true's timeout, because a hard mount blocks a read on an unreachable server forever.
    until_true $(( $(date +%s) + 60 )) 2 grep -qx "$token" "$SHARED/nfscheck/head"
    seen=$?
    run_logged nfscheck-stat timeout --kill-after=5 20 python3 -c 'import os,sys
for p in sys.argv[1:]:
    try:
        s = os.stat(p); print(p, "OK", s.st_ino, s.st_size, s.st_mtime_ns)
    except OSError as e:
        print(p, "ERROR", e.errno, e.strerror)' "$SHARED" "$SHARED/nfscheck" "$SHARED/nfscheck/head"
    # NOTRUN, as the registration says: the bring-up did not complete, and the stat above says how far it got.
    [ "$seen" = 0 ] || late "head's NFS token is not visible here through the mount after 60 s"
  fi
  # Worker-to-head visibility: head reads this back before admitting jobs (it already reads nodeinfo the same way).
  nfs_do bash -c 'echo "$1" >"$2.tmp" && mv "$2.tmp" "$2"' _ "$token" "$SHARED/nfscheck/$ROLE" || die "write the NFS token back"
  sig_put "CONF_ACK-$ROLE" acked "$token" || die "CONF_ACK could not be put to S3"
  systemctl enable slurmd >>/var/log/slurmec2-setup.log 2>&1
  systemctl restart slurmd || die "slurmd"
  log "slurmd started"
  phase "slurmd started"
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
    # Workers serve jobs until head says the evidence is in, or the session's end; then their own diagnostics go out.
    # Read errors are reported and the worker keeps serving: only a valid END or the deadline ends it, so an S3 outage
    # cannot take a node out of a running check.
    while :; do
      sig_wait $(( T0 + STOP_S - 120 )) END head end
      rc=$?
      phase "END wait returned $rc"
      [ "$rc" = 2 ] || break
      diag_ship periodic
      sleep 10
    done
    diag_ship final
    ;;
  *) die "unknown role $ROLE" ;;
esac
