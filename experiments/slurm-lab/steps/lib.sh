# Shared by every step: records each command exactly as run, its UTC time, its output and its exit status.
# Sourced, not executed.
set -uo pipefail

LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$LAB"
EVID=${EVID:-$LAB/evidence/$(date -u +%F)}
mkdir -p "$EVID"

# out NAME starts a new transcript; every later call appends to it.
out() {
	OUT=$EVID/$1
	: >"$OUT"
	echo "# transcript $1, slurm-lab, written by steps/$(basename "$0")" >>"$OUT"
}

note() { echo "# $*" >>"$OUT"; }

# now prints UTC with milliseconds through Python, because this host's date (uutils 0.8.0) ignores %3N and drops the leading zeros of %N.
now() { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")'; }

# at WHERE [-u USER] CMD... runs CMD inside the container for service WHERE, printing the prompt as USER@WHERE.
# The exit status is printed rather than acted on, because a refused command is often the observation itself.
at() {
	local where=$1 user=root
	shift
	if [ "${1:-}" = -u ]; then
		user=$2
		shift 2
	fi
	{
		echo
		echo "$user@$where\$ $*"
		echo "# at $(now)"
	} >>"$OUT"
	# The user's home is the working directory, because a batch job writes its output where sbatch ran, and / is not writable for alice.
	local home=/home/$user
	[ "$user" = root ] && home=/root
	docker compose exec -T -u "$user" -w "$home" "$where" bash -c "$*" >>"$OUT" 2>&1
	local rc=$?
	echo "# exit $rc" >>"$OUT"
	return 0
}

# host CMD... runs CMD on the host in this directory, recorded the same way.
host() {
	{
		echo
		echo "host\$ $*"
		echo "# at $(now)"
	} >>"$OUT"
	bash -c "$*" >>"$OUT" 2>&1
	echo "# exit $?" >>"$OUT"
	return 0
}

# jobid_of NAME prints the id of the newest job with that name, so later commands can refer to it.
jobid_of() {
	docker compose exec -T slurmctld squeue -h -n "$1" -o %i | tail -1
}

# trace SECONDS COND PROBE runs PROBE inside slurmctld about once a second and records its output each time it changes, until COND succeeds.
# Only changes are kept, so the transcript shows when each transition was first seen, to within one poll; SECONDS counts polls, each a little over a second.
trace() {
	local limit=$1 cond=$2 probe=$3 t=0 last="" cur
	echo >>"$OUT"
	echo "# trace: probe [$probe] until [$cond], at most ${limit}s" >>"$OUT"
	while :; do
		cur=$(docker compose exec -T slurmctld bash -c "$probe" 2>&1)
		if [ "$cur" != "$last" ]; then
			echo "## seen at $(now)" >>"$OUT"
			echo "$cur" >>"$OUT"
			last=$cur
		fi
		if docker compose exec -T slurmctld bash -c "$cond" >/dev/null 2>&1; then
			note "trace ended: condition met after ${t}s"
			return 0
		fi
		t=$((t + 1))
		if [ "$t" -ge "$limit" ]; then
			note "TIMEOUT after ${limit}s; condition never met: $cond"
			return 1
		fi
		sleep 1
	done
}

# wait_until SECONDS CMD... polls CMD inside slurmctld once a second until it succeeds or the time runs out.
# A timeout is written into the transcript, so a step that did not reach its state cannot read as one that did.
wait_until() {
	local limit=$1
	shift
	local t=0
	until docker compose exec -T slurmctld bash -c "$*" >/dev/null 2>&1; do
		t=$((t + 1))
		if [ "$t" -ge "$limit" ]; then
			note "TIMEOUT after ${limit}s waiting for: $*"
			return 1
		fi
		sleep 1
	done
	note "waited ${t}s for: $*"
}
