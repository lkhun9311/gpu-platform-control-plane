#!/usr/bin/env bash
# Shows hack/dcgm-diag-inspect-image.sh failing where it must, and records how docker top reads a container's
# processes in each state the diagnostic registration's residual check depends on.
#
#   bash hack/test/check-dcgm-diag-inspect.sh <transcript dir>
#
# Each case's command, output and exit status go to the transcript directory, so the demonstrations are evidence
# a reader can check, not a claim that they were run.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
T=${1:?usage: check-dcgm-diag-inspect.sh <transcript dir>}
mkdir -p "$T"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
bad=0
check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then echo "ok: $name (exit $got)"; else echo "FAIL: $name: exit $got, want $want"; bad=1; fi
}

# 1. A wrong pinned digest is refused before anything runs.
OUT=$scratch/wrong-digest EXPECT_442=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
  bash hack/dcgm-diag-inspect-image.sh >"$T/wrong-digest.txt" 2>&1
rc=$?
echo "exit=$rc" >>"$T/wrong-digest.txt"
check "a wrong pinned digest fails the inspection" 1 "$rc"
grep -q 'not the pinned sha256:0000' "$T/wrong-digest.txt" || { echo "FAIL: the wrong-digest refusal does not name the digest"; bad=1; }

# 2. An existing output directory is refused, so old files never sit beside new ones.
mkdir -p "$scratch/existing"
OUT=$scratch/existing bash hack/dcgm-diag-inspect-image.sh >"$T/existing-dir.txt" 2>&1
rc=$?
echo "exit=$rc" >>"$T/existing-dir.txt"
check "an existing output directory is refused" 2 "$rc"

# 3. A probe docker cannot run (exit 125) fails the inspection instead of being archived as a finding.
mkdir -p "$scratch/bin"
real_docker=$(command -v docker)
cat >"$scratch/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in *"dcgmi discovery -l"*) echo "docker: stubbed launch failure" >&2; exit 125 ;; esac
exec "$real_docker" "\$@"
EOF
chmod +x "$scratch/bin/docker"
PATH=$scratch/bin:$PATH OUT=$scratch/probe-125 bash hack/dcgm-diag-inspect-image.sh >"$T/probe-125.txt" 2>&1
rc=$?
echo "exit=$rc" >>"$T/probe-125.txt"
check "a probe docker could not run fails the inspection" 1 "$rc"
grep -q 'discovery-default did not run (exit 125)' "$T/probe-125.txt" || { echo "FAIL: the probe failure is not named"; bad=1; }

# 4. docker top and docker inspect on a container running, stopped and removed: the shapes the residual check reads.
img=nvcr.io/nvidia/cloud-native/dcgm@sha256:becae9b24707d2bdfce87cb72626e24b2fbfbca812329ca52540ad0e0d955717
c=dcgm-diag-top-probe-$$
{
  docker run -d --name "$c" --network none --entrypoint sh "$img" -c 'sleep 300 & sleep 300' >/dev/null
  sleep 2
  echo "== running: docker top $c -eo pid,ppid,comm"
  docker top "$c" -eo pid,ppid,comm 2>&1
  echo "exit=$?"
  echo "== running: docker inspect -f {{.State.Status}}"
  docker inspect -f '{{.State.Status}}' "$c" 2>&1
  echo "exit=$?"
  docker kill "$c" >/dev/null
  sleep 1
  echo "== stopped: docker top"
  docker top "$c" -eo pid,ppid,comm 2>&1
  echo "exit=$?"
  echo "== stopped: docker inspect -f {{.State.Status}}"
  docker inspect -f '{{.State.Status}}' "$c" 2>&1
  echo "exit=$?"
  docker rm "$c" >/dev/null
  echo "== removed: docker top"
  docker top "$c" -eo pid,ppid,comm 2>&1
  echo "exit=$?"
  echo "== removed: docker inspect -f {{.State.Status}}"
  docker inspect -f '{{.State.Status}}' "$c" 2>&1
  echo "exit=$?"
} >"$T/docker-top-states.txt"
head -2 "$T/docker-top-states.txt" | tail -1 | grep -qE '^PID +PPID +COMMAND$' || { echo "FAIL: docker top's header is not PID PPID COMMAND"; bad=1; }

[ "$bad" = 0 ] && echo "check-dcgm-diag-inspect: all checks passed" || exit 1
