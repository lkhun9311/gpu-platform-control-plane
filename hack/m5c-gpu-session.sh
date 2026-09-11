#!/usr/bin/env bash
#
# Rents one GPU instance, builds a kind cluster on it, and runs the M5-c sharing matrix inside.
#
# WHY THIS EXISTS RATHER THAN hack/m5c-matrix.sh ON ITS OWN
#
# The matrix drives a Kubernetes cluster. It does not make one. Until now the only cluster it could drive was
# an EKS cluster with a GPU node group -- and the cluster half of the AWS path has never been applied, so the
# matrix had nowhere to run and its pre-registration was costed against a shape it does not have.
#
# hack/queuelab-gpu-session.sh already solved the hard part on a rented card: the NVIDIA container toolkit as
# docker's default runtime, `accept-nvidia-visible-devices-as-volume-mounts`, the /var/run/nvidia-container-devices
# mount that makes a kind node see the cards, the toolkit configured a SECOND time inside the node container
# because Pods run on its containerd and not on the host's docker, and a kubeconfig path passed rather than
# guessed. Every one of those was bought with a paid session. This runs the same recipe for one card.
#
# WHY g5.2xlarge AND NOT g5.xlarge
#
# The same single A10G, twice the host memory: 32 GiB against 16. This session runs a kind node, two vLLM
# engines and the replay harness at once, and 16 GiB is the sort of margin that is discovered at a rollout
# timeout on a card that is already billing. Measured 2026-09-10 in ap-northeast-2: $0.680-0.689/h against
# $0.574-0.596/h. Ten cents an hour is the wrong place to economise.
#
# WHAT THIS SHIPS RATHER THAN BUILDS
#
# The GPU AMI carries a driver, not a toolchain, so `go build` on the instance fails with
# `go: command not found` after the driver, the cluster and the plugin have all been paid for. The gateway
# and the harness are built here and shipped with their digests, exactly as the device session ships its
# runner, and the matrix takes them through GATEWAY_BIN and BENCHHARNESS_BIN.
#
# It does NOT ship an operator image, and that is a finding rather than an omission:
# hack/test/rehearse-m5c-deploy.sh proved on a real cluster that the gateway resolves a backend by reading
# the InferenceDeployment CR and constructing http://<name>.<namespace>.svc:<port> itself. The CRDs and the
# gateway's ClusterRole are what M5-c needs. The controller-manager is not.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

REGION="${AWS_REGION:-ap-northeast-2}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"
# Above the $0.68-0.69 measured across all three zones with room for a rise, and below the on-demand price
# the pre-registration does not authorise.
MAX_SPOT_PRICE="${MAX_SPOT_PRICE:-1.10}"
# The backstop inside the instance, and the one this script waits for. The instance's fires first on purpose:
# a shell that dies here must not leave a card running, and the only timer that survives a dead shell is the
# one on the machine that is billing.
BACKSTOP_SECONDS="${BACKSTOP_SECONDS:-9000}"
HARD_STOP_SECONDS="${HARD_STOP_SECONDS:-8400}"
# The same arms, in the same order, as hack/m5c-matrix.sh's own default.
#
# This value is EXPORTED into the matrix, so when the two disagree this one wins and the matrix's default is
# dead text. It said "shared timeSlicing mps" while the matrix said "R1 shared timeSlicing mps", which would
# have bought a run with no isolated baseline for the second time running. A unit test now fails when they
# drift, because this repository has already paid for exactly this shape once with REPS: two scripts that do
# not read each other, one of them quietly halving what the study was designed around.
ARMS="${ARMS:-R1 shared timeSlicing mps}"
OUT="${OUT:-hack/m5c-$(date -u +%Y%m%d-%H%M%S)}"
STACK="m5c-gpu"

say()  { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# REPS has no default here, and that is deliberate.
#
# A pilot is one repetition and a confirmatory run is three; which one this is decides what it costs and what
# may be concluded from it, and neither is a thing to arrive at by forgetting a variable. The matrix defaults
# to four for its own reasons -- a statistical argument about bootstrap blocks -- and a session script that
# quietly defaulted to something else would be the same defect this repository already recorded, where two
# scripts disagreed about REPS and a re-run silently bought half the repetitions the design was built on.
[ -n "${REPS:-}" ] || fail "REPS is unset. A pilot is REPS=1 and a confirmatory run is REPS=3. Which this is decides both the cost and what may be concluded, so it is not a default."
case "$REPS" in ''|*[!0-9]*) fail "REPS is ${REPS@Q}, which is not a number" ;; esac

spot_say()  { say "$@"; }
spot_fail() { fail "$@"; }
# shellcheck source=hack/lib/spot-run.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/spot-run.sh"

ACCOUNT=$(spot_account) || fail "not authenticated. aws sso login --profile <yours>, and export AWS_PROFILE"
BUCKET="${BUCKET:-$STACK-$ACCOUNT}"
RUN_ID="$(basename "$OUT")"
mkdir -p "$OUT"

say "study  M5-c sharing matrix -- does giving each tenant its own engine on a shared card protect the tail"
# The arm list as it is, not "R1 plus" it. R1 is now IN the list, and the old wording printed it twice.
say "arms   [$ARMS], $REPS repetition(s) each"
say "output $OUT"

# ---------------------------------------------------------------- the load
#
# Every part of it is passed to the matrix, which refuses to start without all five, and the reasons are
# written out at that refusal. The short version: gen-trace's defaults put the 40,000-character contender at
# 45% of arrivals, which is four to five times an A10G's prefill capacity at any rate this study could use,
# and lowering the rate to compensate starves the premium tail below the sample floor. The mix has to move.
#
# These are the price-of-protection run's measured values, which were derived against ONE engine holding the
# WHOLE card. This run gives each engine half of one. They are therefore a starting point that the pilot's
# job is to replace, and the pilot is not finished until its derivation is written down.
RATE="${RATE:-9.85}"
PREMIUM_WEIGHT="${PREMIUM_WEIGHT:-1}"
NOISY_WEIGHT="${NOISY_WEIGHT:-0.054}"
# ZERO, and this is a correction rather than a carried value.
#
# The probe tenants straddle the ADMISSION guard's eligibility threshold. This study runs the gateway with
# -admission-mode=off, so they measure nothing here -- and they cost something: the first paid run sent 41
# probe requests that the gateway turned away on credentials, because the replay carries API keys for the
# premium and contending tenants and the trace generated four. The report said so in as many words, marking
# both probe rows VOID.
#
# hack/lib/spot-run.sh's header records this exact failure happening twice before: "one paid run answered a
# quarter of every replay with 401, the next answered its probe tenants with 403." That was the third. The
# value here was carried from hack/m5b-price-of-protection.sh, which has NO gateway in its path and so needs
# no key for anything.
#
# Zero removes the tenants rather than giving them keys, because a tenant that measures nothing this study
# varies is load wearing a measurement's name. gen-trace omits them entirely at 0.
PROBE_WEIGHT="${PROBE_WEIGHT:-0}"
DURATION_MS="${DURATION_MS:-420000}"
say "load   rate ${RATE}/s, ${DURATION_MS}ms, weights premium=$PREMIUM_WEIGHT noisy=$NOISY_WEIGHT probe=$PROBE_WEIGHT"
say "       (carried from the whole-card run; the pilot's job is to re-derive them for a half-card engine)"

# ---------------------------------------------------------------- credentials
#
# Checked BEFORE anything is rented, because the alternative was measured: on 2026-09-08 a confirmatory run
# launched with 54 minutes of credential against 100 minutes of work, the credentials expired mid-run, the
# EXIT trap's terminate call was refused, and the line on screen said the instance was being terminated while
# it went on billing until somebody noticed.
#
# The margin is the whole session plus the bring-up plus a tail for the download of the evidence.
require_credential_margin() {
  local need_min="$1" cache newest expiry left
  cache="${AWS_CLI_CACHE_DIR:-$HOME/.aws/cli/cache}"
  [ -d "$cache" ] || { say "no CLI credential cache at $cache; skipping the expiry check"; return 0; }
  # The LATEST live expiry, not the earliest. Taking min() across every file in the cache reads a stale
  # entry from another profile as this session's, which is how a fresh twelve-hour login was once reported
  # as expired.
  newest=""
  for f in "$cache"/*.json; do
    [ -f "$f" ] || continue
    expiry=$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get('Credentials',{}).get('Expiration',''))
except Exception:
    print('')
" "$f" 2>/dev/null)
    [ -n "$expiry" ] || continue
    if [ -z "$newest" ] || [[ "$expiry" > "$newest" ]]; then newest="$expiry"; fi
  done
  [ -n "$newest" ] || { say "no expiry found in $cache; skipping the check"; return 0; }
  left=$(python3 -c "
import datetime,sys
e=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
print(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60))
" "$newest" 2>/dev/null || echo 0)
  # HEADROOM on top of the estimate, because the estimate is a model and the check is about money.
  #
  # This used to be a bare `left >= need`, and on 2026-09-11 it passed a launch with 86 minutes against an
  # estimate of 74 -- twelve minutes of margin on a number nobody had measured. The run had to be killed by
  # hand. A guard that permits a launch it would have refused one minute later is a rounding rule, not a
  # guard.
  #
  # Thirty minutes, flat rather than proportional, because what it covers does not scale with the run: a
  # slow image pull, a Spot interruption and a retry, an arm that hits its rollout timeout instead of its
  # expected time. The evidence download and the terminate call both need credentials AFTER the last cell,
  # and those are the two that cost something when they fail.
  local margin_min="${CREDENTIAL_MARGIN_MIN:-30}"
  say "credentials expire in ${left} min; this session needs about ${need_min} plus ${margin_min} of headroom"
  [ "$left" -ge $(( need_min + margin_min )) ] || fail "credentials expire in ${left} minutes. This session estimates ${need_min} and requires ${margin_min} minutes of headroom on top, because the estimate is a model and the evidence download and the terminate call both come after the last cell. Re-authenticate first -- a run whose credentials die mid-flight cannot terminate its own instance, and the trap that tries will be refused. Type:  aws sso logout; aws sso login --profile <yours>"
}
# The runtime model, refitted on 2026-09-11 against a run that was actually measured.
#
# The first numbers were carried from hack/m5b-price-of-protection.sh, which rents a bare instance and runs
# `docker run`. This one builds a cluster, so the shape is different. What the measured run did, from the
# S3 object timestamps of a session that reached its second arm:
#
#   launch -> user-data executing            63 s
#   -> driver, toolkit, kind, node toolkit    2 min 43 s   (the AMI already ships nvidia-ctk)
#   -> CRDs, RBAC, plugin, first engine ready 8 min        (the 15.6 GB image pull dominates)
#   -> one 420 s replay complete              7 min
#
# So about 11 minutes of bring-up, an 8-minute first engine, and roughly 9 minutes per cell after it. The
# estimate below keeps 25 minutes of fixed cost rather than 11: the measured bring-up had a warm AMI and no
# Spot retry, and a credential check is the wrong place to be optimistic.
# 25 min bring-up + 1.5 min per arm + 7 min per arm-repetition + 15 min for evidence and teardown.
#
# R1 is counted by the loop rather than added afterwards. It used to be a +1 beside it, from when the matrix
# had no R1 arm and the baseline was imagined to come from somewhere else. Now that ARMS carries it, the
# increment would charge the estimate for a fifth arm that does not exist.
arm_count=0; for _a in $ARMS; do arm_count=$(( arm_count + 1 )); done
require_credential_margin $(( 25 + arm_count * 3 / 2 + arm_count * REPS * 7 + 15 ))

# ---------------------------------------------------------------- what the instance builds from
#
# git archive rather than the working tree: the evidence names a commit somebody can check out, and a build
# from uncommitted changes is provenance that names nothing.
REQUIRE_CLEAN_TREE="${REQUIRE_CLEAN_TREE:-1}"
COMMIT=$(git rev-parse HEAD)
if [ -z "$(git status --porcelain)" ]; then
  say "source $COMMIT, working tree clean"
elif [ "$REQUIRE_CLEAN_TREE" = "1" ]; then
  fail "the working tree is dirty. This session records a commit as the provenance of its numbers. Commit, or set REQUIRE_CLEAN_TREE=0 and accept that the archive will not match the tree you are looking at"
else
  say "source $COMMIT, TREE IS DIRTY and REQUIRE_CLEAN_TREE=0 -- this archive does NOT match the working tree"
fi
git archive --format=tar.gz -o "$OUT/source.tgz" HEAD || fail "git archive"
SOURCE_SHA=$(sha256sum "$OUT/source.tgz" | cut -d' ' -f1)

say "building the gateway and the harness for the instance, which has no Go"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/gateway" ./cmd/gateway || fail "build gateway"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/benchharness" ./cmd/benchharness || fail "build benchharness"
GATEWAY_SHA=$(sha256sum "$OUT/gateway" | cut -d' ' -f1)
HARNESS_SHA=$(sha256sum "$OUT/benchharness" | cut -d' ' -f1)
say "  gateway ${GATEWAY_SHA:0:12}, benchharness ${HARNESS_SHA:0:12}"

# ---------------------------------------------------------------- AWS scaffolding
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"

say "uploading the source and the binaries"
aws s3 cp "$OUT/source.tgz" "s3://$BUCKET/$RUN_ID/src/source.tgz" >/dev/null || fail "upload the source archive"
aws s3 cp "$OUT/gateway" "s3://$BUCKET/$RUN_ID/bin/gateway" >/dev/null || fail "upload the gateway"
aws s3 cp "$OUT/benchharness" "s3://$BUCKET/$RUN_ID/bin/benchharness" >/dev/null || fail "upload benchharness"

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
exec > >(tee /var/log/m5c.log) 2>&1
set -x
( sleep BACKSTOP_SECONDS_PLACEHOLDER; shutdown -h now ) &

BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
SOURCE_SHA="SOURCE_SHA_PLACEHOLDER"
GATEWAY_SHA="GATEWAY_SHA_PLACEHOLDER"
HARNESS_SHA="HARNESS_SHA_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
REPS="REPS_PLACEHOLDER"
ARMS="ARMS_PLACEHOLDER"
RATE="RATE_PLACEHOLDER"
PREMIUM_WEIGHT="PREMIUM_WEIGHT_PLACEHOLDER"
NOISY_WEIGHT="NOISY_WEIGHT_PLACEHOLDER"
PROBE_WEIGHT="PROBE_WEIGHT_PLACEHOLDER"
DURATION_MS="DURATION_MS_PLACEHOLDER"
DEADLINE_EPOCH=$(( $(date +%s) + BACKSTOP_SECONDS_PLACEHOLDER ))

upload() { aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/m5c.log log.txt; shutdown -h now' EXIT

# Verified before it is trusted: a truncated download that still extracts produces a build, and a build
# produces numbers.
aws s3 cp "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
got=$(sha256sum /tmp/source.tgz | cut -d' ' -f1)
if [ "$got" != "$SOURCE_SHA" ]; then echo "source checksum mismatch: $SOURCE_SHA vs $got"; exit 1; fi
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src
cd /src
echo "$COMMIT" > /tmp/commit.txt && upload /tmp/commit.txt commit.txt

mkdir -p /src/bin
for b in gateway benchharness; do
  aws s3 cp "s3://$BUCKET/$PREFIX/bin/$b" "/src/bin/$b"
  chmod +x "/src/bin/$b"
done
got=$(sha256sum /src/bin/gateway | cut -d' ' -f1)
if [ "$got" != "$GATEWAY_SHA" ]; then echo "gateway checksum mismatch"; exit 1; fi
got=$(sha256sum /src/bin/benchharness | cut -d' ' -f1)
if [ "$got" != "$HARNESS_SHA" ]; then echo "benchharness checksum mismatch"; exit 1; fi

# Preflight 1: the card. A machine that does not report one A10G is not what this session was costed for,
# and finding that out after twenty minutes of cluster bring-up is finding it out too late.
nvidia-smi --query-gpu=index,name,memory.total --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
cards=$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)
if [ "$cards" -ne 1 ]; then
  echo "PREFLIGHT FAILED: $cards cards; this matrix splits ONE card and two engines on two cards are not sharing"
  exit 1
fi

# The host's docker, configured to hand the card to a container.
#
# This is NOT in the rehearsable span below: it installs packages as root and rewrites
# /etc/nvidia-container-runtime/config.toml, which is the instance's business and nobody's laptop's. The
# span starts where the recipe stops needing a machine with a card in it.
export DEBIAN_FRONTEND=noninteractive
if ! command -v nvidia-ctk >/dev/null; then
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

# >>> REHEARSABLE -- everything to the matching marker needs no GPU and no root.
#
# hack/test/rehearse-bringup.sh extracts exactly this span and runs it on a development machine, driven with
# RUNNER=hack/m5c-gpu-session.sh. It exists because the first thing ever to execute these lines would
# otherwise be a rented instance, which is how a kubeconfig path this repository had asserted without
# checking cost a whole session.
#
# The span begins here rather than at the toolkit install above, which needs root and a card. It ends where
# the recipe starts reaching into the node container for the same toolkit -- the first thing that genuinely
# needs hardware, and the only part the instance should be discovering.
curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x /usr/local/bin/kind
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# One worker, and the cards reach it through the mount rather than through any GPU environment.
#
# accept-nvidia-visible-devices-as-volume-mounts tells the container runtime to read a mount under
# /var/run/nvidia-container-devices/ as if it were NVIDIA_VISIBLE_DEVICES. A kind node is an ordinary
# container that nobody passes that variable to, so the mount is how it ends up with the card. The first
# session to get this far had the setting and not the mount, which is half a recipe: the node saw no devices
# and the plugin advertised zero.
cat > /tmp/kind.yaml <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: m5cgpu
nodes:
  - role: control-plane
  - role: worker
    extraMounts:
      - hostPath: /dev/null
        containerPath: /var/run/nvidia-container-devices/all
KINDEOF
# Told to kind rather than guessed from it: cloud-init runs user-data with HOME unset, and kind with no HOME
# writes .kube/config RELATIVE TO THE WORKING DIRECTORY. A session died three minutes in that way, with kind
# reporting success while the next kubectl talked to localhost:8080.
export KUBECONFIG=/tmp/kubeconfig
kind create cluster --config /tmp/kind.yaml --kubeconfig "$KUBECONFIG" --wait 300s || exit 1
kubectl cluster-info || { echo "PREFLIGHT FAILED: the cluster is up but unreachable through $KUBECONFIG"; exit 1; }

# The CRDs, with kustomize rather than `make install`: that target depends on `manifests`, which runs
# controller-gen and rewrites generated files. The CRDs are committed; building them is all that is needed.
kubectl kustomize config/crd | kubectl apply -f - || exit 1

# The gateway's ClusterRole, through the OVERLAY and not the bare file.
#
# config/gateway/rbac.yaml says `namespace: system`, which is kubebuilder's placeholder; the overlay is what
# rewrites it. Applying the file directly is refused with `namespaces "system" not found`, and
# hack/m5c-matrix.sh refuses to start without the ClusterRole because a binding to a missing one is accepted
# by Kubernetes and then fails authorization on every request, with nothing looking wrong until the first
# replay. Only the RBAC kinds: the overlay also carries a gateway Deployment pinned to an ECR digest, and the
# matrix deploys its own gateway from the binary shipped above.
kubectl create ns gpu-platform-control-plane-system --dry-run=client -o yaml | kubectl apply -f -
kubectl kustomize config/gateway > /tmp/gateway-all.yaml || exit 1
awk 'BEGIN{RS="\n---\n"} /(^|\n)kind: (ClusterRole|ClusterRoleBinding|Role|RoleBinding|ServiceAccount)(\n|$)/ {print "---"; print $0}' \
  /tmp/gateway-all.yaml > /tmp/gateway-rbac.yaml
grep -q "name: gateway-role" /tmp/gateway-rbac.yaml || { echo "PREFLIGHT FAILED: no gateway-role in the rendered overlay"; exit 1; }
kubectl apply -f /tmp/gateway-rbac.yaml || exit 1

# The toolkit is needed INSIDE the node as well, and that is a second configuration rather than the same one.
#
# Everything above configures the HOST's docker, which is what puts the card into the node container. Pods do
# not run on the host's docker; they run on the containerd inside that node, which knows nothing about any of
# it -- so the device plugin starts with no NVML and dies, and DCGM agrees that NVML does not exist. The node
# image ships neither nvidia-ctk nor /sbin/ldconfig.real, so both are put there.
docker exec m5cgpu-worker ln -sf /sbin/ldconfig /sbin/ldconfig.real || exit 1
docker exec m5cgpu-worker bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl gnupg ca-certificates
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=containerd --set-as-default
' || { echo "PREFLIGHT FAILED: could not configure the container runtime inside m5cgpu-worker"; exit 1; }

# Restarting containerd takes the kubelet's runtime out from under it, so the node is waited for rather than
# assumed back. Anything applied before it is Ready would land on a NotReady node.
docker exec m5cgpu-worker systemctl restart containerd || exit 1
kubectl wait --for=condition=Ready node/m5cgpu-worker --timeout=300s \
  || { echo "PREFLIGHT FAILED: m5cgpu-worker did not come back Ready after its containerd was restarted"; exit 1; }
# <<< REHEARSABLE
#
# The span ends HERE and not at the RBAC above, because everything between the two needs no card: installing
# the toolkit inside the node container and pointing its containerd at it are apt-get and a config rewrite,
# and both fail the same way on a laptop as on a rented machine. The first line past this marker asks the
# node for its cards, which is the first thing that genuinely needs one.
docker exec m5cgpu-worker nvidia-smi -L > /tmp/node-cards.txt 2>&1 || echo "(nvidia-smi failed inside the node)" >> /tmp/node-cards.txt
upload /tmp/node-cards.txt preflight-node-cards.txt

# ---------------------------------------------------------------- the matrix
#
# Everything the matrix needs that it refuses to default: the platform, the deadline it measures cell budgets
# against, the shipped binaries, and the whole load.
export KUBECONFIG=/tmp/kubeconfig
export PLATFORM=kind
export KCTX=kind-m5cgpu
export GPU_NODE=m5cgpu-worker
export DEADLINE_EPOCH
export GATEWAY_BIN=/src/bin/gateway
export BENCHHARNESS_BIN=/src/bin/benchharness
export RATE PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT DURATION_MS REPS ARMS
export OUT=/src/m5c-run

bash hack/m5c-matrix.sh; matrix_rc=$?
echo "matrix exited $matrix_rc"

# The evidence goes up whatever happened. A matrix that stopped on a cell boundary still bought every cell
# before it, and those are the cells a partial answer is made of.
if [ -d /src/m5c-run ]; then
  tar -czf /tmp/m5c-evidence.tgz -C /src m5c-run
  upload /tmp/m5c-evidence.tgz evidence.tgz
fi
kubectl get nodes -o wide > /tmp/nodes.txt 2>&1 || true
upload /tmp/nodes.txt nodes.txt

# The marker is written LAST and only on success, because it is what the waiting shell reads as "the records
# are up". A marker written unconditionally would report a matrix that failed as a matrix that finished.
if [ "$matrix_rc" = "0" ]; then
  echo done > /tmp/DONE
  aws s3 cp /tmp/DONE "s3://$BUCKET/$PREFIX/DONE"
fi
USERDATA

UD="$(mktemp)"
{
  # The shebang, re-emitted because the stripping below removes the heredoc's own.
  #
  # `tail -n +2` drops line 1, which is `#!/bin/bash`, and cloud-init runs user-data as a script ONLY when
  # it begins with `#!`. Without this line the instance boots, cloud-init treats the payload as an unknown
  # content type, nothing executes, and the machine sits idle until its backstop -- with no log, because the
  # trap that uploads one is inside the script that never ran.
  #
  # It is not a detail: omitting it cost a g5.2xlarge for 145 minutes on 2026-09-11, about $1.64, and bought
  # nothing. Every other runner in this directory has this line; this file was written from the shape of
  # theirs and dropped it, which is the "second copy written from memory of the first" that hack/lib/spot-run.sh
  # exists to argue against.
  echo "#!/bin/bash"
  sed -e "s|BACKSTOP_SECONDS_PLACEHOLDER|$BACKSTOP_SECONDS|g" \
      -e "s|BUCKET_PLACEHOLDER|$BUCKET|" \
      -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" \
      -e "s|SOURCE_SHA_PLACEHOLDER|$SOURCE_SHA|" \
      -e "s|GATEWAY_SHA_PLACEHOLDER|$GATEWAY_SHA|" \
      -e "s|HARNESS_SHA_PLACEHOLDER|$HARNESS_SHA|" \
      -e "s|COMMIT_PLACEHOLDER|$COMMIT|" \
      -e "s|REPS_PLACEHOLDER|$REPS|" \
      -e "s|ARMS_PLACEHOLDER|$ARMS|" \
      -e "s|RATE_PLACEHOLDER|$RATE|" \
      -e "s|PREMIUM_WEIGHT_PLACEHOLDER|$PREMIUM_WEIGHT|" \
      -e "s|NOISY_WEIGHT_PLACEHOLDER|$NOISY_WEIGHT|" \
      -e "s|PROBE_WEIGHT_PLACEHOLDER|$PROBE_WEIGHT|" \
      -e "s|DURATION_MS_PLACEHOLDER|$DURATION_MS|" "$RUNSCRIPT" | tail -n +2 \
    | sed -e '/^#/d' -e '/^[[:space:]]*$/d'
} > "$UD"

# The comments come off on the way out, and only on the way out.
#
# EC2 caps user-data at 25600 bytes ENCODED, and an earlier session's explanations grew past it: 19,914 raw
# became 26,552 base64 and all three zones returned InvalidParameterValue. The comments are why anything here
# is the way it is and they stay in the tracked file. Only column-0 comments are dropped, because the
# indented ones inside the kind.yaml heredoc are YAML a reader of the launched configuration should still
# see -- and deleting by indentation rather than by content is the rule that cannot cut a line out of a
# string.
cp "$UD" "$OUT/user-data.sh"
# The FIRST thing checked, because it is the one `bash -n` cannot see.
#
# A script with no shebang parses perfectly and does not run. cloud-init needs `#!` on line 1 to execute the
# payload at all, so this check is the difference between a run that fails and a run that silently does
# nothing for two hours on a card that is billing.
head -1 "$UD" | grep -q '^#!' \
  || fail "the generated user-data does not begin with a shebang, so cloud-init would not execute it and the instance would boot, do nothing, and bill until its backstop. See $OUT/user-data.sh"
bash -n "$UD" || fail "the generated user-data does not parse after its comments were stripped; see $OUT/user-data.sh"
grep -q 'containerPath: /var/run/nvidia-container-devices/all' "$UD" \
  || fail "the generated user-data lost the device mount, so the stripping cut something that mattered"
grep -q 'PLACEHOLDER' "$UD" \
  && fail "a placeholder survived substitution; the instance would run a script with a literal PLACEHOLDER in it. See $OUT/user-data.sh"

UD_LIMIT="${UD_LIMIT:-25600}"
UD_ENCODED=$(base64 -w0 "$UD" | wc -c)
if [ "$UD_ENCODED" -gt "$UD_LIMIT" ]; then
  fail "the user-data encodes to $UD_ENCODED bytes and EC2 accepts $UD_LIMIT. Nothing was launched. Move the bulk out of the heredoc rather than trimming prose: see $OUT/user-data.sh"
fi
say "user-data: $UD_ENCODED of $UD_LIMIT encoded bytes"

# ---------------------------------------------------------------- launch
say "launching $INSTANCE_TYPE spot (max \$$MAX_SPOT_PRICE/h)"
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=m5c-sharing-matrix}]"
# The trap is armed BEFORE the launch loop, not after it.
#
# It used to sit below the line that prints the instance id, which left a window in which run-instances had
# returned an id and nothing would terminate it. Under `set -euo pipefail` a failed write of the id file, a
# SIGPIPE, or a Ctrl-C in that window all exit with a GPU instance running and no terminator.
# spot_terminate returns 0 on an empty id, so arming it early costs nothing and closes the window.
cleanup() { spot_terminate "$REGION" "$IID"; }
IID=""
trap cleanup EXIT INT TERM
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  say "trying $z ($SUBNET)"
  IID=$(spot_launch "$REGION" "$AMI" "$INSTANCE_TYPE" "$SUBNET" "$STACK" \
        "$MAX_SPOT_PRICE" 200 "$UD" "$TAGS" 2>>"$OUT/launch-errors.txt") \
    && [ -n "$IID" ] && [ "$IID" != "None" ] && break
  IID=""
done
if [ -z "$IID" ]; then
  # The refusal names the cause the errors actually give. An earlier version attributed every empty result to
  # Spot capacity while all three zones had in fact returned UnauthorizedOperation from a service control
  # policy -- describing a quantity by a cause its own evidence does not support.
  if grep -q "UnauthorizedOperation" "$OUT/launch-errors.txt" 2>/dev/null; then
    scp=$(grep -o 'service_control_policy/[a-z0-9-]*' "$OUT/launch-errors.txt" | head -1)
    fail "every zone refused $INSTANCE_TYPE with UnauthorizedOperation, not for want of capacity. An explicit deny in ${scp:-a service control policy} blocks ec2:RunInstances for this type, and an SCP is not something an account administrator can override. This account's policy allows t3.*, g4dn.* and g5.* only. See $OUT/launch-errors.txt"
  fi
  if grep -qi "InsufficientInstanceCapacity\|capacity-not-available" "$OUT/launch-errors.txt" 2>/dev/null; then
    fail "no zone had Spot capacity for $INSTANCE_TYPE: try again, or raise MAX_SPOT_PRICE. See $OUT/launch-errors.txt"
  fi
  fail "no zone would launch $INSTANCE_TYPE, and the errors name neither an authorization denial nor a capacity shortfall. See $OUT/launch-errors.txt"
fi
echo "$IID" > "$OUT/instance-id"
say "instance $IID"

say "waiting for results (driver, toolkit, cluster and preflight come first; about 25 minutes before the first cell)"
done_seen=0
ended_early=""
marker_rc=0
ended_early=$(spot_wait_for_marker "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" \
              "$((HARD_STOP_SECONDS / 30))" 30) || marker_rc=$?
case "$marker_rc" in
  0) say "records are up"; done_seen=1 ;;
  2) say "instance ended before writing DONE" ;;
esac

for k in evidence.tgz log.txt commit.txt nodes.txt preflight-nvidia-smi.csv preflight-node-cards.txt; do
  aws s3 cp "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" >/dev/null 2>&1 || true
done
# Unpacked, and the unpacking is CHECKED. An `&&` chain that quietly does nothing is how a session ends by
# naming an evidence directory it never created.
if [ -s "$OUT/evidence.tgz" ]; then
  tar -xzf "$OUT/evidence.tgz" -C "$OUT" || fail "the evidence archive came back and could not be unpacked; $OUT/evidence.tgz is whatever arrived"
  say "evidence unpacked to $OUT/m5c-run"
fi

if [ "$done_seen" -eq 0 ]; then
  # Partial evidence is the point of uploading before the marker, so it is reported rather than discarded.
  shopt -s nullglob
  recovered=("$OUT/m5c-run"/raw-*.jsonl)
  partial=${#recovered[@]}
  shopt -u nullglob
  say "raw files recovered before the end: $partial"
  if [ -n "$ended_early" ]; then
    fail "the instance was $ended_early before it wrote its completion marker; $partial raw file(s) were recovered and $OUT/log.txt is whatever it managed to upload"
  fi
  fail "no completion marker within the hard stop; $partial raw file(s) were recovered and $IID has been terminated"
fi

# A completion marker is the instance saying it finished. It is not evidence arriving.
#
# The instance's `upload` helper ends in `|| true`, deliberately, so that one failed upload cannot kill a run
# that still has records to send. The cost of that choice is here: a marker can be written while the archive
# that matters never made it, and without this check the session would print SESSION DONE and name a
# directory that does not exist. hack/queuelab-gpu-session.sh refuses on exactly this and this file did not.
[ -s "$OUT/evidence.tgz" ] \
  || fail "the instance wrote its completion marker and no evidence archive arrived. $OUT/log.txt is whatever it managed to upload, and the run produced nothing this side can read"

# And the archive must contain an arm's worth of evidence for every arm that was asked for.
#
# A tar that unpacks is not a run that measured. The readings need R1 and `shared` at minimum -- R1 is the
# denominator of both bars -- and an arm whose raw file is missing is an arm the report will silently omit
# from its table rather than one it complains about.
missing=""
for arm in $ARMS; do
  compgen -G "$OUT/m5c-run/raw-$arm-"'*.jsonl' >/dev/null || missing="$missing $arm"
done
[ -z "$missing" ] \
  || fail "the run finished and these arms have no raw evidence:$missing. The report would leave them out of its table rather than say they are absent, and any reading that divides by one of them would decline without naming it"
say "every arm in [$ARMS] returned raw evidence"

say "SESSION DONE. Evidence in $OUT/m5c-run"
say "The readings are NOT evaluated here. Run them over the evidence:"
say "  args=; for f in $OUT/m5c-run/raw-*.jsonl; do args=\"\$args --raw \$f\"; done"
say "  go run ./cmd/benchharness report \$args"
say "That prints the pre-registered readings in their registered order and the first that fires."
