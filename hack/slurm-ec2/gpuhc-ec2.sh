#!/bin/bash
# slurmd's HealthCheckProgram on worker @ROLE@: the lab's gpuhc.py, unchanged, pointed at this node's signal on /shared,
# its real device files, and the session's policy.
export LABGPU_NODE=@ROLE@
export LABGPU_SIGNAL=/shared/gpuhc/@ROLE@.prom
export LABGPU_POLICY=/shared/gpuhc/policy
export LABGPU_DEVICES='/dev/nvidia[0-9]*'
export LABGPU_LOG=/shared/gpuhc/@ROLE@.log
export LABGPU_TRACE=/shared/gpuhc/trace
export LABGPU_REQUEUED=/var/lib/gpuhc/requeued
exec /usr/bin/python3 /opt/slurm-ec2/gpuhc.py
