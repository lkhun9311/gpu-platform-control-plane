#!/usr/bin/env bash
# Builds the lab from scratch, runs every step in order into evidence/<UTC date>/, and removes the containers and volumes afterwards.
# Set KEEP=1 to leave the cluster running for inspection.
set -euo pipefail
cd "$(dirname "$0")"

docker compose down -v --remove-orphans
docker compose build slurmctld
docker compose up -d --no-build

# Every node must report idle before any step runs, or step 1's placement would be decided by which slurmd registered first.
for _ in $(seq 90); do
	n=$(docker compose exec -T slurmctld sinfo -h -N -o %T 2>/dev/null | grep -c '^idle$' || true)
	[ "$n" = 3 ] && break
	sleep 2
done
docker compose exec -T slurmctld sinfo -N
if [ "$n" != 3 ]; then
	echo "only $n of 3 nodes idle after 180 s; not running the steps" >&2
	exit 1
fi

for s in steps/00-fileless-gres.sh steps/00-setup.sh steps/01-gres.sh steps/02-quota-preempt.sh steps/03-node-failure.sh steps/04-multinode.sh; do
	echo "== $s"
	bash "$s"
done

if [ "${KEEP:-0}" != 1 ]; then
	docker compose down -v --remove-orphans
fi
