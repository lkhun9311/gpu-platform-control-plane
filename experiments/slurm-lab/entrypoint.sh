#!/usr/bin/env bash
# Starts MUNGE and then the one Slurm daemon this container's role names, in the foreground.
set -euo pipefail

role=${1:?usage: entrypoint.sh slurmctld|slurmdbd|slurmd}

# MUNGE must be up before any Slurm daemon, because every Slurm RPC is authenticated through it.
mkdir -p /run/munge && chown munge:munge /run/munge
runuser -u munge -- /usr/sbin/munged

case "$role" in
slurmdbd)
	# Only the port is awaited; if MariaDB is not ready for this user yet, slurmdbd exits and compose restarts it.
	until bash -c '</dev/tcp/mariadb/3306' 2>/dev/null; do sleep 1; done
	exec /usr/sbin/slurmdbd -D -vv
	;;
slurmctld)
	# The controller registers the cluster with slurmdbd on start, so it waits until slurmdbd listens.
	until bash -c '</dev/tcp/slurmdbd/6819' 2>/dev/null; do sleep 1; done
	exec /usr/sbin/slurmctld -D -vv -i
	;;
slurmd)
	# Slurm drops a GPU GRES with no File=, so each declared GPU gets a character device node.
	# Major 240 is in the range Linux reserves for local experimental use, so no driver answers it and the container's device cgroup refuses opening it.
	# These nodes exist only so Slurm can count and bind them; there is no GPU behind them.
	for i in 0 1; do [ -e /dev/labgpu$i ] || mknod /dev/labgpu$i c 240 $i; done
	# A fresh named volume belongs to root, and the training jobs run as alice.
	if [ -d /ckpt ]; then chown alice:alice /ckpt; fi
	until bash -c '</dev/tcp/slurmctld/6817' 2>/dev/null; do sleep 1; done
	exec /usr/sbin/slurmd -D -vv
	;;
*)
	echo "unknown role: $role" >&2
	exit 2
	;;
esac
