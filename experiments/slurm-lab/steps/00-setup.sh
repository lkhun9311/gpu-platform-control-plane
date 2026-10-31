#!/usr/bin/env bash
# Records what was built and what the cluster declares, then creates the accounts, users and QoS the later steps use.
# Run after `docker compose up -d --build` once every node reports idle.
source "$(dirname "$0")/lib.sh"

out 00-cluster.txt
host "docker compose images"
host "docker image inspect slurmlab:24.11.5-torch251--format '{{.Id}} {{.Created}}'"
at slurmctld "dpkg-query -W slurmctld slurmd slurmdbd slurm-client munge"
at slurmctld "scontrol --version"
at mariadb "mariadb --version"
at slurmctld "cat /etc/slurm/gres.conf"
at c1 "ls -l /dev/labgpu*"
at slurmctld "sinfo -N -o '%N %T %c %m %G'"
at slurmctld "scontrol show node c1"
note "A job given one declared GPU: Slurm binds and exports it, and the device behind it cannot be opened."
at slurmctld "srun -w c1 --gres=gpu:1 bash -c 'echo host=\$(hostname) CUDA_VISIBLE_DEVICES=\$CUDA_VISIBLE_DEVICES; cat /dev/labgpu0'"

out 00-accounting.txt
note "Two tenants as two accounts, one user each; two QoS levels, high preempting normal."
at slurmctld "sacctmgr -i add account teama Description=tenant-a Organization=lab"
at slurmctld "sacctmgr -i add account teamb Description=tenant-b Organization=lab"
at slurmctld "sacctmgr -i add user alice Account=teama"
at slurmctld "sacctmgr -i add user bob Account=teamb"
at slurmctld "sacctmgr -i add qos high Priority=100 Preempt=normal"
at slurmctld "sacctmgr -i modify user where name=alice,bob set QOS=normal,high DefaultQOS=normal"
at slurmctld "sacctmgr show assoc format=Cluster,Account,User,GrpTRES,QOS,DefaultQOS"
at slurmctld "sacctmgr show qos format=Name,Priority,Preempt,PreemptMode,GrpTRES"
