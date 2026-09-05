#!/usr/bin/env bash
#
# The session pre-registered in docs/superpowers/specs/2026-09-05-the-device-was-never-observed.md.
#
# It exists to remove one banner. `queuelabrun -compare` prints this on every comparison the lab has ever
# produced:
#
#     device: NOT OBSERVED -- every GPU-second below is a second of RESERVATION
#
# The code that removes it is written and has never run: -require-device invalidates a run with no device
# evidence, hack/gpu-session.sh routes the exporter per worker and takes the termination canary,
# internal/queuelab/submit.go carries a PTX kernel loaded through the CUDA driver, and
# cmd/queuelabrun/device_preflight.go gates the spend. What none of it can produce is a driver and a card.
#
# WHY THIS IS NOT hack/m6-kind-e2e.sh WITH A GPU
#
# That script builds a kind cluster with the FAKE device plugin -- config/device-plugin, the gpu-simulator
# that advertises nvidia.com/gpu on nodes with no cards. This one installs the REAL plugin
# (config/nvidia-device-plugin) plus the DCGM exporter, on a machine that has four, and the difference is
# the entire point: a fake plugin makes every GPU-second a reservation, which is the banner.
#
# WHY g6.12xlarge AND NOT THE CHEAPER ONE
#
# The reclaim protocol needs two devices held concurrently on the worker under test, and AWS has no
# two-GPU G instance, so the floor is four. g4dn.12xlarge is cheaper and scores 1 out of 10 on Spot
# placement in this region, which is AWS saying the request will probably not be filled. The g6 scores 3
# and its L4 is sm_89, one of the four targets hack/verify-ptx.sh already compiles the kernel for.
#
# THREE IS STILL A LOW SCORE
#
# So this expects interruption rather than merely tolerating it. A watcher ships every record within
# seconds of it being written, so an interruption after six of eight runs costs the seventh and the eighth
# rather than all of them. gpu-session.sh already knows how to resume from a partial set with START_AT.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

REGION="${AWS_REGION:-ap-northeast-2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g6.12xlarge}"
# Above the observed Spot price of about $2.56 with room for a rise, and far below the $5.66 on-demand
# price the pre-registration deliberately does not authorise.
MAX_SPOT_PRICE="${MAX_SPOT_PRICE:-3.20}"
# The pre-registration's hard stop is 120 minutes. The backstop inside the instance is that plus a margin,
# so the timer this script keeps is the one that fires first.
BACKSTOP_SECONDS="${BACKSTOP_SECONDS:-8400}"
HARD_STOP_SECONDS="${HARD_STOP_SECONDS:-7200}"
REPS="${REPS:-4}"
# Both arms always run: the study IS the contrast between them, and gpu-session.sh interleaves them.
# The dose is narrowed, because the pre-registration buys grace-bounded only.
DOSES="${DOSES:-grace-bounded}"
OUT="${OUT:-hack/qlgpu-$(date -u +%Y%m%d-%H%M%S)}"
STACK="queuelab-gpu"

say()  { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

spot_say()  { say "$@"; }
spot_fail() { fail "$@"; }
# shellcheck source=hack/lib/spot-run.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/spot-run.sh"

ACCOUNT=$(spot_account) || fail "not authenticated"
BUCKET="${BUCKET:-$STACK-$ACCOUNT}"
RUN_ID="$(basename "$OUT")"

mkdir -p "$OUT"
say "study  queuelab reclaim, with the device observed"
say "doses  $DOSES   reps $REPS   (both arms, interleaved by gpu-session.sh)"
say "output $OUT"

# ---------------------------------------------------------------- the source the instance builds from
#
# git archive rather than a tarball of the working tree: the instance must build the operator image from a
# committed state, so that the record it produces names a commit somebody can check out. A dirty tree would
# produce evidence about a build that exists nowhere.
# REQUIRE_CLEAN_TREE exists so the characterization harness can drive the rest of this script, and it is
# deliberately loud rather than silent. An override that leaves no trace is an override somebody uses on a
# paid run and forgets, so the line below goes into the run log and into every golden that records one.
REQUIRE_CLEAN_TREE="${REQUIRE_CLEAN_TREE:-1}"
COMMIT=$(git rev-parse HEAD)
# --porcelain rather than `git diff`, because git diff does not see UNTRACKED files and git archive does not
# include them either. A tree carrying a new script somebody is about to add passed this guard and shipped
# an archive without it, which is precisely the mismatch the guard exists to refuse. Found because the
# characterization scenario that asserts this refusal could not make it fire.
if [ -z "$(git status --porcelain)" ]; then
  say "source $COMMIT, working tree clean"
elif [ "$REQUIRE_CLEAN_TREE" = "1" ]; then
  fail "the working tree is dirty. This session records a commit as the provenance of its numbers, and a build from uncommitted changes is provenance that names nothing. Commit, or set REQUIRE_CLEAN_TREE=0 and accept that the archive will not match the tree you are looking at"
else
  say "source $COMMIT, TREE IS DIRTY and REQUIRE_CLEAN_TREE=0 -- this archive does NOT match the working tree"
fi
git archive --format=tar.gz -o "$OUT/source.tgz" HEAD || fail "git archive"
SOURCE_SHA=$(sha256sum "$OUT/source.tgz" | cut -d' ' -f1)

# ---------------------------------------------------------------- AWS scaffolding
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"

# This instance reads as well as writes: it downloads the source archive it was sent.
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"

say "uploading the source archive"
aws s3 cp "$OUT/source.tgz" "s3://$BUCKET/$RUN_ID/src/source.tgz" >/dev/null \
  || fail "could not upload the source archive"

AMI=$(spot_resolve_ami "$REGION" \
  /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id) \
  || fail "could not resolve a GPU AMI"

ZONES=$(spot_zones_offering "$REGION" "$INSTANCE_TYPE")
[ -n "$ZONES" ] || fail "$INSTANCE_TYPE is offered in no availability zone of $REGION"
say "$INSTANCE_TYPE is offered in: $ZONES"

# ---------------------------------------------------------------- what the instance runs
RUNSCRIPT=$(mktemp)
cat > "$RUNSCRIPT" <<'USERDATA'
#!/bin/bash
exec > >(tee /var/log/qlgpu.log) 2>&1
set -x
( sleep BACKSTOP_SECONDS_PLACEHOLDER; shutdown -h now ) &

BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
SOURCE_SHA="SOURCE_SHA_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
REPS="REPS_PLACEHOLDER"
DOSES="DOSES_PLACEHOLDER"

upload() { aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/qlgpu.log log.txt; shutdown -h now' EXIT

# The source is verified before it is trusted, for the reason the harness binary is in the other runner: a
# truncated download that still extracts produces a build, and a build produces numbers.
aws s3 cp "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
got=$(sha256sum /tmp/source.tgz | cut -d' ' -f1)
if [ "$got" != "$SOURCE_SHA" ]; then
  echo "source checksum mismatch: expected $SOURCE_SHA, got $got"
  exit 1
fi
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src
cd /src

# ---------------------------------------------------------------- the cards, before anything else
#
# Preflight check 1 of 4. A machine that does not report four cards is not the machine this session was
# costed for, and finding that out after twenty minutes of cluster bring-up is finding it out too late.
nvidia-smi --query-gpu=index,name,memory.total --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
cards=$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)
if [ "$cards" -lt 4 ]; then
  echo "PREFLIGHT FAILED: $cards cards, the protocol needs 4 (2 for the trace, 2 held by the occupier)"
  exit 1
fi

# ---------------------------------------------------------------- kind, with the host's cards visible
#
# kind nodes are containers, so the GPUs reach them only if the container runtime passes them through by
# default. The toolkit is on the deep-learning AMI already; what it needs is to be the DEFAULT runtime and
# to accept the visible-devices variable as a volume mount, which is how the device plugin inside kind
# claims a card.
# Installed rather than assumed. The deep-learning AMI has shipped the toolkit for a while, and a session
# that discovers otherwise twenty minutes in has paid for the discovery.
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit || exit 1
fi
nvidia-ctk runtime configure --runtime=docker --set-as-default
sed -i 's/^#accept-nvidia-visible-devices-as-volume-mounts.*/accept-nvidia-visible-devices-as-volume-mounts = true/' \
  /etc/nvidia-container-runtime/config.toml || true
grep -q 'accept-nvidia-visible-devices-as-volume-mounts = true' /etc/nvidia-container-runtime/config.toml \
  || echo 'accept-nvidia-visible-devices-as-volume-mounts = true' >> /etc/nvidia-container-runtime/config.toml
systemctl restart docker
sleep 5

curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x /usr/local/bin/kind
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# One worker, because the protocol measures one worker and a second would only add a factor this session is
# not buying. The control plane stays separate so stopping anything on the worker cannot take the apiserver.
cat > /tmp/kind.yaml <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: qlgpu
nodes:
  - role: control-plane
  - role: worker
KINDEOF
kind create cluster --config /tmp/kind.yaml --wait 300s || exit 1
export KUBECONFIG=/root/.kube/config
kubectl cluster-info

# ---------------------------------------------------------------- the platform under test
kubectl apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml
kubectl -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s || exit 1

# docker build inside a container, so no Go is needed on this host.
make docker-build IMG=controller:latest || exit 1
kind load docker-image controller:latest --name qlgpu || exit 1

# The CRDs are applied from the committed files rather than through `make install`.
#
# That target depends on manifests, which depends on controller-gen, which the Makefile installs with Go --
# absent from this AMI -- and which would REGENERATE the CRDs before applying them. Regenerating on a rented
# box means the cluster gets whatever this machine's controller-gen produces rather than what the commit
# says, which is the opposite of the provenance this session is trying to record. `make manifests` is a
# no-op on this tree, so the committed files already are the generated ones.
kubectl apply --server-side -f config/crd/bases/ || exit 1
kubectl kustomize config/operator | kubectl apply --server-side -f - || exit 1

# The node label both DaemonSets select on, which nothing in this repository applies.
#
# config/nvidia-device-plugin and config/dcgm-exporter both carry
# `nodeSelector: platform.lkhun9311.github.io/gpu: "true"`, and every other reference to that label in the
# tree READS it -- m5b-arms.sh and m5b-gpu-session.sh look up the node group by it. In production it comes
# from the EKS node group. On a kind cluster nobody applies it, so both DaemonSets would sit Pending, the
# node would advertise nothing, and preflight check 2 would fail after the instance, the driver, the
# cluster and the operator had all been paid for.
#
# The plugin's own comment explains why this label and not nvidia.com/gpu.present: GPU Feature Discovery is
# not deployed here, and selecting on that one would leave the plugin unschedulable while the node reads
# downstream as "no GPU nodes" rather than as "the plugin never ran".
kubectl label node qlgpu-worker platform.lkhun9311.github.io/gpu=true --overwrite || exit 1

# The worker is deliberately NOT tainted nvidia.com/gpu=present:NoSchedule the way the production node
# group is. This cluster has one worker and kind's control plane carries its own NoSchedule taint, so
# tainting it would leave Kueue and the operator with nowhere to run.

# The REAL device plugin, not config/device-plugin, which is the fake one that makes every GPU-second a
# reservation. This is the line the whole session is about.
kubectl kustomize config/nvidia-device-plugin | kubectl apply -f - || exit 1
kubectl kustomize config/dcgm-exporter | kubectl apply -f - || exit 1

# ---------------------------------------------------------------- preflight, checks 2 to 4
#
# Charged before any measurement because it is the failure that wastes the session, and it costs minutes.
# Check 4 is the one that matters: the first three can all pass on a machine where attribution is still
# impossible, and attribution is the deliverable.
for _ in $(seq 1 60); do
  adv=$(kubectl get node qlgpu-worker -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0)
  [ "${adv:-0}" -ge 4 ] && break
  sleep 5
done
echo "worker advertises ${adv:-0} nvidia.com/gpu"
kubectl get nodes -o wide > /tmp/preflight-nodes.txt
upload /tmp/preflight-nodes.txt preflight-nodes.txt
if [ "${adv:-0}" -lt 4 ]; then
  echo "PREFLIGHT FAILED: the real device plugin advertises ${adv:-0} of 4 cards"
  exit 1
fi

# Preflight checks 3 and 4 are NOT written here. hack/gpu-session.sh takes the termination canary and then
# runs `queuelabrun -device-preflight`, which applies a GPU-holding Pod with the same template, placement,
# toleration and finalizer a real run gets, and reports which of the driver calls answered. A second
# preflight written into this file would be a probe invented for the occasion, which is the thing that mode
# exists to avoid being.

# ---------------------------------------------------------------- the study, shipping records as they land
#
# gpu-session.sh runs the whole study itself -- surplus occupancy, canary, per-worker exporter route,
# preflight, then the runs -- so this does not reimplement its loop. What it adds is the one thing a
# low placement score demands: an uploader watching the session directory, so a record reaches S3 within
# seconds of being written rather than at the end. An interruption after six of eight runs must cost the
# seventh and the eighth, not all of them.
export EXDIR=/tmp/session
mkdir -p "$EXDIR"

(
  # Ships anything new every ten seconds, and keeps shipping until the study exits. Records are small and
  # S3 puts are idempotent by key, so re-uploading an unchanged file costs nothing worth optimising.
  while :; do
    for f in "$EXDIR"/*.json; do
      [ -e "$f" ] && aws s3 cp "$f" "s3://$BUCKET/$PREFIX/runs/$(basename "$f")" >/dev/null 2>&1
    done
    sleep 10
  done
) &
UPLOADER=$!

rc=0
# The worker is a POSITIONAL argument. gpu-session.sh takes WORKERS=("$@"), and calling it with none used
# to reach `WORKERS[0]: unbound variable` after everything above had already been paid for.
REPS="$REPS" EXDIR="$EXDIR" DOSES="$DOSES" \
  bash hack/gpu-session.sh qlgpu-worker >/tmp/study.log 2>&1 || rc=$?
kill "$UPLOADER" 2>/dev/null || true

upload /tmp/study.log study.log
tar -czf /tmp/session.tgz -C /tmp session
upload /tmp/session.tgz session.tgz
echo "$COMMIT" > /tmp/commit.txt && upload /tmp/commit.txt commit.txt
# A final sweep, because the watcher may have been killed between a write and its tick.
for f in "$EXDIR"/*.json; do
  [ -e "$f" ] && upload "$f" "runs/$(basename "$f")"
done

# DONE means records exist, not that the study exited zero. A study that produced six good records and
# then failed is worth collecting -- and a study that exited zero having written none is not.
#
# Counted with a glob into an array rather than `ls ... | wc -l`. Under errexit and pipefail, ls exits 2
# when its glob matches nothing, the pipeline inherits it, and the script dies at the count -- taking with
# it the message that was about to explain the empty case. The characterization suite caught exactly that
# on the host side of this script, where the operator was left with no refusal at all in the one run that
# most needed one.
shopt -s nullglob
records=("$EXDIR"/*.json)
accepted=${#records[@]}
shopt -u nullglob
echo "records written: $accepted, study rc=$rc"
if [ "$accepted" -gt 0 ]; then
  touch /tmp/DONE && upload /tmp/DONE DONE
else
  echo "no record was written; DONE withheld"
fi
USERDATA

UD=$(mktemp)
{
  echo "#!/bin/bash"
  sed -e "s|BACKSTOP_SECONDS_PLACEHOLDER|$BACKSTOP_SECONDS|" \
      -e "s|BUCKET_PLACEHOLDER|$BUCKET|" \
      -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" \
      -e "s|SOURCE_SHA_PLACEHOLDER|$SOURCE_SHA|" \
      -e "s|COMMIT_PLACEHOLDER|$COMMIT|" \
      -e "s|REPS_PLACEHOLDER|$REPS|" \
      -e "s|DOSES_PLACEHOLDER|$DOSES|" "$RUNSCRIPT" | tail -n +2
} > "$UD"
cp "$UD" "$OUT/user-data.sh"

# ---------------------------------------------------------------- launch
say "launching $INSTANCE_TYPE spot (max \$$MAX_SPOT_PRICE/h)"
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=queuelab-device-observation}]"
IID=""
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  say "trying $z ($SUBNET)"
  IID=$(spot_launch "$REGION" "$AMI" "$INSTANCE_TYPE" "$SUBNET" "$STACK" \
        "$MAX_SPOT_PRICE" 300 "$UD" "$TAGS" 2>>"$OUT/launch-errors.txt") \
    && [ -n "$IID" ] && [ "$IID" != "None" ] && break
  IID=""
done
[ -n "$IID" ] || fail "no zone would launch $INSTANCE_TYPE; see $OUT/launch-errors.txt. A placement score of 3 means this is a normal answer rather than a fault"
echo "$IID" > "$OUT/instance-id"
say "instance $IID"

cleanup() { spot_terminate "$REGION" "$IID"; }
trap cleanup EXIT INT TERM

say "waiting for results (driver, cluster, operator and four preflight checks come first)"
done_seen=0
ended_early=""
marker_rc=0
ended_early=$(spot_wait_for_marker "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" \
              "$((HARD_STOP_SECONDS / 30))" 30) || marker_rc=$?
case "$marker_rc" in
  0) say "records are up"; done_seen=1 ;;
  2) say "instance ended before writing DONE" ;;
esac

for k in session.tgz commit.txt log.txt preflight.txt preflight-nodes.txt preflight-nvidia-smi.csv; do
  aws s3 cp "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" >/dev/null 2>&1 || true
done
aws s3 cp --recursive "s3://$BUCKET/$RUN_ID/runs" "$OUT/runs" >/dev/null 2>&1 || true

if [ "$done_seen" -eq 0 ]; then
  # Partial evidence is the point of uploading per run, so it is reported rather than discarded.
  shopt -s nullglob
  recovered=("$OUT/runs"/*.json)
  partial=${#recovered[@]}
  shopt -u nullglob
  say "records recovered before the end: $partial"
  if [ -n "$ended_early" ]; then
    fail "the instance was $ended_early before it wrote its completion marker; $partial record(s) were recovered and $OUT/log.txt is whatever it managed to upload"
  fi
  fail "no completion marker within the hard stop; $partial record(s) were recovered and $IID has been terminated"
fi

[ -s "$OUT/session.tgz" ] || fail "no session archive was written; $OUT/log.txt may say why"
tar -xzf "$OUT/session.tgz" -C "$OUT" && say "records unpacked to $OUT/session"

say "the comparison is NOT run here: it belongs to whoever reads the records"
say "when they are complete:  queuelabrun -compare '$OUT/session/gpu-grace-bounded-*.json'"
say "reading 1 is whether that command prints its comparison WITHOUT the device: NOT OBSERVED line"
