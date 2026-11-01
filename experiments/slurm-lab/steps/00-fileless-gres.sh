#!/usr/bin/env bash
# Why gres.conf names device nodes: the same image given a file-less GPU line drops it, and with gres.conf's File= line it keeps both.
# Runs slurmd -G (print the GRES this node would report, then exit) in a throwaway container, so the running cluster is not touched.
source "$(dirname "$0")/lib.sh"

out 00-fileless-gres.txt
fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
echo 'NodeName=c[1-3] Name=gpu Count=2' >"$fixture"
note "gres.conf replaced by one line with no File=:"
host "cat $fixture"
host "docker run --rm --hostname c1 --entrypoint bash -v $fixture:/etc/slurm/gres.conf:ro slurmlab:24.11.5-torch251 -c 'mkdir -p /run/munge; chown munge:munge /run/munge; runuser -u munge -- /usr/sbin/munged; slurmd -G 2>&1 | grep -iE \"gres|gpu\"'"
note "The committed gres.conf, with the device nodes the entrypoint would create made by hand:"
host "docker run --rm --hostname c1 --entrypoint bash slurmlab:24.11.5-torch251 -c 'mknod /dev/labgpu0 c 240 0; mknod /dev/labgpu1 c 240 1; mkdir -p /run/munge; chown munge:munge /run/munge; runuser -u munge -- /usr/sbin/munged; slurmd -G 2>&1 | grep -iE \"gres|gpu\"'"
