#!/usr/bin/env bash
#
# Runs hack/m5b-arms.sh -- the real script, unmodified -- as far as a local kind cluster can take it.
#
# WHY THIS EXISTS
#
# hack/m5b-arms.sh had no rehearsal of any kind. hack/m5c-matrix.sh has three; this one had none, so every
# change to it first executed on a rented card. That is not a hypothetical cost: the script's own comments
# record a paid run where gen-trace's --model default asked a real Qwen engine for llama-3-8b, the router
# answered ErrNoRoute to 907 of 999 requests, and three hours of card time recorded zero completions.
#
# It was found the way these things are found. A guard was added to this script on 2026-09-30, `make
# infra-validate` came back green, and the green was read as "the change is verified". It was not: no target
# and no workflow runs any rehearsal, and this script had none to run. Three attempts to trip that guard
# deliberately all stopped on an EARLIER refusal, which is what revealed the guard sat after go build, docker
# build, the ECR login and the image push -- after the spending it existed to prevent.
#
# WHAT IS SUBSTITUTED, AND WHY THAT IS HONEST
#
# One thing, in a THROWAWAY COPY of the tree and never in the tracked one: the ECR push. The real script
# refuses without REGISTRY, and it is right to -- "a kind cluster can side-load an image; EKS cannot". A
# rehearsal cannot reach ECR, so the copy replaces that block with a kind side-load and resolves GW_IMAGE to
# the local image id. Everything else is the real script: the pre-spend refusals, the tenant list, the API
# key secret, the policies, the gateway rollout, gen-trace, prepare-traces and the manifests they write.
#
# The cluster's preconditions are met rather than faked: a namespace, an InferenceDeployment carrying the
# engine name and the served model, and a Deployment of that name running a digest-pinned stub that answers
# /metrics. Those are what the script reads, and it reads them through the same API a real session would.
#
# WHAT THIS CANNOT SAY
#
# Every number, and whether a card can hold any of this. A stub answers in milliseconds. It answers one
# question: does the real runner get from its first refusal to the manifests it writes, on inputs a person
# can supply -- which is the question a paid run was answering at $0.68 an hour.
#
# It also does not reach the replay or the report. Those need the gateway serving and the engine streaming,
# which hack/test/rehearse-m5c-matrix.sh covers for the matrix. What is covered here is the span that had
# never run anywhere: the pre-spend block and the manifest-writing calls.
#
# NOT IN A CI GATE, deliberately. Makefile's harness-check says why for the three existing rehearsals: they
# build a real kind cluster and do not belong in one. This is run by hand, and the defect record says so.
set -euo pipefail

cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)

CLUSTER="${CLUSTER:-m5b-arms-rehearse}"
KCTX="kind-$CLUSTER"
NS="${NS:-m5b}"
ENGINE_NAME="vllm-qwen25-3b"
SERVED_MODEL="Qwen/Qwen2.5-3B-Instruct"
MODEL_REV="aa8e72537993ba99e69dfaafa59ed015b17504d1"
STUB_IMAGE="${STUB_IMAGE:-benchstub:m5b-rehearse}"
KEEP="${KEEP:-0}"
WORK="$(mktemp -d)"
SRC="$WORK/src"

pass=0
say()  { printf '== %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
fail() { printf '  FAIL  %s\n' "$*" >&2; exit 1; }
k() { kubectl --context "$KCTX" "$@"; }

cleanup() {
  local rc=$?
  if [ "$KEEP" = 1 ]; then
    printf 'KEEP=1: cluster %s and %s are left in place\n' "$CLUSTER" "$WORK"
  else
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

command -v kind >/dev/null || fail "kind is not installed"
command -v kubectl >/dev/null || fail "kubectl is not installed"
command -v docker >/dev/null || fail "docker is not installed"

# kustomize comes from bin/, not from PATH.
#
# The Makefile uses $(LOCALBIN)/kustomize and this machine has no kustomize on PATH at all, so a bare
# `kustomize build` here would fail at the CRD install -- and that failure reads as "the cluster is not
# ready" rather than "the tool is missing", which is the wrong thing to go looking for.
KUSTOMIZE="$ROOT/bin/kustomize"
[ -x "$KUSTOMIZE" ] || fail "$KUSTOMIZE is missing; run 'make kustomize' first (the Makefile installs it into bin/)"

say "cluster $CLUSTER"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --wait 120s >/dev/null || fail "kind create cluster"
ok "cluster up"

say "CRDs"
# Built and applied in two steps, with the build's status read on its own.
#
# `kustomize build | kubectl apply` hides a failing build behind kubectl's status, and this repository has
# already had a gate report success through a pipe that way. If the build produces nothing, kubectl applies
# nothing and exits 0.
"$KUSTOMIZE" build config/crd > "$WORK/crd.yaml" || fail "kustomize build config/crd"
[ -s "$WORK/crd.yaml" ] || fail "kustomize build config/crd produced nothing to apply"
k apply --server-side -f "$WORK/crd.yaml" >/dev/null \
  || fail "install the CRDs; the script reads an InferenceDeployment through the API"
ok "CRDs installed"

say "build the gateway binary and the engine stub"
mkdir -p "$WORK/bin"
CGO_ENABLED=0 GOOS=linux go build -o "$WORK/bin/benchharness" ./cmd/benchharness || fail "build benchharness"
# The gateway binary too, because the copy has no go.mod and the script now accepts both shipped.
#
# That acceptance is what this rehearsal found on its first run: m5b-arms.sh built unconditionally, so it
# could only run where a Go toolchain happens to be -- not on the GPU AMI, which carries a driver and no
# compiler, and not here.
CGO_ENABLED=0 GOOS=linux go build -o "$WORK/bin/gateway" ./cmd/gateway || fail "build gateway"
printf 'FROM busybox:1.36\nCOPY benchharness /benchharness\nENTRYPOINT ["/benchharness","stub-serve"]\n' \
  > "$WORK/bin/Dockerfile"
docker build -q -t "$STUB_IMAGE" "$WORK/bin" >/dev/null || fail "build the stub image"
kind load docker-image "$STUB_IMAGE" --name "$CLUSTER" >/dev/null || fail "side-load the stub image"
# The digest of the stub, because the real script refuses an engine image that is not digest-pinned.
#
# A locally built image has no RepoDigest until it is pushed, so the Deployment below carries the image ID
# in name@sha256:<id> form. That satisfies the script's *@sha256:* case with a hash that identifies these
# exact bytes on this machine -- which is what the refusal is protecting against, a tag naming whatever was
# built most recently.
STUB_ID="$(docker image inspect --format='{{.Id}}' "$STUB_IMAGE" | sed 's/^sha256://')"
[ -n "$STUB_ID" ] || fail "could not read the stub image id"
ok "stub image $STUB_IMAGE built and loaded"

say "the preconditions the script reads from the cluster"
k create ns "$NS" >/dev/null || fail "create namespace $NS"
cat <<EOF | k apply -f - >/dev/null || fail "create the InferenceDeployment the script reads"
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata:
  name: $ENGINE_NAME
  namespace: $NS
spec:
  model:
    name: $SERVED_MODEL
    storageUri: s3://rehearsal/not-fetched
  image: $STUB_IMAGE
  gpuClass: a10g
  gpuCount: 1
  replicas: 1
  port: 8000
EOF
# The Deployment of that name, whose image digest the provenance step reads.
cat <<EOF | k apply -f - >/dev/null || fail "create the engine Deployment"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $ENGINE_NAME
  namespace: $NS
spec:
  replicas: 1
  selector: {matchLabels: {engine: $ENGINE_NAME}}
  template:
    metadata:
      labels: {engine: $ENGINE_NAME}
    spec:
      containers:
        - name: vllm
          image: $STUB_IMAGE@sha256:$STUB_ID
          imagePullPolicy: IfNotPresent
          args: ["--addr=:8000"]
          ports: [{containerPort: 8000, name: http}]
---
apiVersion: v1
kind: Service
metadata:
  name: $ENGINE_NAME
  namespace: $NS
spec:
  selector: {engine: $ENGINE_NAME}
  ports: [{name: http, port: 8000, targetPort: http}]
EOF
ok "namespace, InferenceDeployment and engine Deployment in place"

say "copy the tree, then substitute the one thing that needs AWS"
mkdir -p "$SRC"
# Old run outputs are excluded, and the reason is not tidiness.
#
# hack/m5b-run-* and hack/m5c-run* are untracked output directories this machine has five of, holding 17
# manifests between them. The first version of this script copied them in and then searched the whole copy
# for manifests -- so it reported 102 files, named arms from other studies, and concluded the tokenizer
# revision was not being written. Every one of those 102 was somebody else's, and the conclusion was about
# nothing. Excluded here AND the search is anchored on this run's own output directory below: two barriers,
# because the first version of that judgment was confident and wrong.
tar -cf - --exclude='m5b-run-*' --exclude='m5c-run*' --exclude='m5c-2026*' hack config \
  | tar -xf - -C "$SRC" || fail "copy the tree"
[ -d "$SRC/hack" ] && [ -d "$SRC/config" ] || fail "the copy is missing hack/ or config/"
if find "$SRC/hack" -maxdepth 1 -name 'm5b-run-*' -o -maxdepth 1 -name 'm5c-run*' | grep -q .; then
  fail "an old run directory reached the copy; the manifest search below would judge its files"
fi
# The ECR push, replaced by a kind side-load.
#
# Bounded by the two lines that open and close the block, so a change to what is inside it makes this
# substitution miss and the rehearsal stop -- rather than silently rehearsing a block that moved.
python3 - "$SRC/hack/m5b-arms.sh" "$CLUSTER" <<'PY'
import sys
p, cluster = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
start = 'if [ -n "${REGISTRY:-}" ]; then'
end = ('  fail "REGISTRY is unset. A kind cluster can side-load an image; EKS cannot, so the gateway image '
       'must be pushed somewhere the nodes can pull from (ECR). Set '
       'REGISTRY=<account>.dkr.ecr.<region>.amazonaws.com"\nfi\n')
i = s.find(start)
j = s.find(end)
if i < 0 or j < 0:
    sys.exit("rehearse-m5b-arms: the REGISTRY block was not found where this substitution expects it; "
             "read hack/m5b-arms.sh and update the anchors rather than widening them")
repl = (
    '# SUBSTITUTED BY hack/test/rehearse-m5b-arms.sh. The real block pushes to ECR and refuses without\n'
    '# REGISTRY; a kind cluster side-loads instead, and GW_IMAGE becomes the local image id so the\n'
    '# digest-pinned form the rest of the script expects still holds.\n'
    'kind load docker-image "$GW_IMAGE" --name ' + cluster + ' >/dev/null || fail "side-load the gateway image"\n'
    'GW_IMAGE="$GW_IMAGE@sha256:$(docker image inspect --format=\'{{.Id}}\' "$GW_IMAGE" | sed \'s/^sha256://\')"\n'
)
open(p, 'w', encoding='utf-8').write(s[:i] + repl + s[j + len(end):])
print("  the ECR push is replaced by a kind side-load")
PY
grep -q 'SUBSTITUTED BY hack/test/rehearse-m5b-arms.sh' "$SRC/hack/m5b-arms.sh" \
  || fail "the substitution did not land, so this would rehearse the ECR path against no registry"
ok "the copy differs from the tracked script in exactly one block"

say "the pre-spend refusals fire before anything is built"
# Each is checked by its own message, and the control that supplies the value must get PAST it. A refusal
# that fires for every input is indistinguishable from one that is always on.
refusal_reaches() {
  local want="$1"; shift
  local out
  out="$(cd "$SRC" && env -u MODEL_REVISION -u RATE "$@" KCTX="$KCTX" NS="$NS" NO_TTL=1 REPS=1 ARMS=off \
    bash hack/m5b-arms.sh 2>&1 || true)"
  printf '%s' "$out" | grep -q "$want" || {
    printf '%s\n' "$out" | tail -3 >&2
    fail "the run did not refuse with $want"
  }
}
refusal_reaches "RATE is unset"
ok "RATE is refused"
refusal_reaches "MODEL_REVISION is unset" RATE=9.4
ok "MODEL_REVISION is refused, and only after RATE is supplied"

# And it is refused BEFORE the build, which is the whole point of where it sits.
out="$(cd "$SRC" && env -u MODEL_REVISION RATE=9.4 KCTX="$KCTX" NS="$NS" NO_TTL=1 REPS=1 ARMS=off \
  bash hack/m5b-arms.sh 2>&1 || true)"
printf '%s' "$out" | grep -q 'build benchharness\|build gateway image' \
  && fail "the MODEL_REVISION refusal came after a build; it belongs in the pre-spend block"
ok "the refusal costs no build"

say "run the REAL hack/m5b-arms.sh as far as the manifests"
LOGF="$WORK/arms.log"
# OUT is named rather than defaulted, so the search below looks only at what THIS run wrote.
#
# The script defaults to hack/m5b-run-<timestamp>, which is inside the copy and indistinguishable from the
# old directories that used to be copied in beside it.
OUT_DIR="$SRC/rehearsal-out"
set +e
( cd "$SRC" && env RATE=9.4 PREMIUM_WEIGHT=1 NOISY_WEIGHT=0.026 PROBE_WEIGHT=0 DURATION_MS=8000 \
    MODEL_REVISION="$MODEL_REV" KCTX="$KCTX" NS="$NS" NO_TTL=1 REPS=1 ARMS=off \
    OUT="rehearsal-out" GW_IMAGE="gpu-platform-gateway:m5b-rehearse" \
    BENCHHARNESS_BIN="$WORK/bin/benchharness" GATEWAY_BIN="$WORK/bin/gateway" \
    bash hack/m5b-arms.sh ) >"$LOGF" 2>&1
arms_rc=$?
set -e
say "  exit $arms_rc"
# The log is shown whenever the run did not succeed, because a rehearsal that hides why the thing it drives
# failed is worse than no rehearsal: it reports a verdict nobody can act on. The trap deletes WORK on exit,
# so the tail has to be printed here or it is gone.
if [ "$arms_rc" -ne 0 ]; then
  say "  the runner did not finish; its last 30 lines:"
  tail -30 "$LOGF" | sed 's/^/    /'
fi

say "check what it wrote"
# The manifests are the artifact this rehearsal exists to reach: they are what --require-provenance judges,
# and the tokenizer revision added on 2026-09-30 had never been written by any execution of this script.
manifests="$(find "$OUT_DIR" -name 'manifest-*.yaml' -o -name 'manifest.yaml' 2>/dev/null | sort)"
[ -n "$manifests" ] || {
  tail -25 "$LOGF" >&2
  fail "no manifest was written, so nothing here exercised the provenance fields"
}
n_manifests=$(printf '%s' "$manifests" | grep -c . || true)
# Zero is a FAILURE, and saying so is the whole point.
#
# An earlier run of this rehearsal printed "0 manifest(s) written" as an ok and then ran two for-loops and a
# replay over an empty list, which checked nothing and printed three more greens. A rehearsal that passes on
# no evidence is the defect class this repository spends most of its time on, committed by the tool built to
# catch it.
#
# The count comes from `grep -c .` rather than `wc -l` because the two disagree about an empty string, and
# the `-gt 0` test is what makes the verdict independent of which. (An earlier version of this comment
# claimed `wc -l` counts an empty string as one line; measured, it returns 0. The real cause of that run was
# simpler and is worth more than the guess: the runner died before writing any manifest at all.)
[ "$n_manifests" -gt 0 ] || {
  say "  the runner's last 30 lines are above; it did not reach a manifest"
  fail "0 manifests were written, so every check below would pass over an empty list"
}
ok "$n_manifests manifest(s) written"

missing=""
for m in $manifests; do
  grep -q "tokenizerRev: $MODEL_REV" "$m" || missing="$missing $(basename "$m")"
done
[ -z "$missing" ] || {
  say "  first manifest:"; sed -n '1,25p' "$(printf '%s' "$manifests" | head -1)" | sed 's/^/    /'
  fail "these manifests carry no tokenizerRev:$missing -- the flag was added and is not reaching the file"
}
ok "every manifest names the tokenizer revision"

for m in $manifests; do
  grep -q 'gatewaySHA:' "$m" || fail "$(basename "$m") carries no gatewaySHA"
done
ok "every manifest names the gateway build"

# And the guard that reads them accepts what was written, which is the end-to-end claim.
"$WORK/bin/benchharness" replay --manifest "$(printf '%s' "$manifests" | head -1)" \
  --require-provenance --target 'http://127.0.0.1:1' --raw-out "$WORK/unused.jsonl" >"$WORK/prov.log" 2>&1 || true
if grep -qE 'no tokenizerRev|not a full 40-character|no gatewaySHA|names no image' "$WORK/prov.log"; then
  sed -n '1,10p' "$WORK/prov.log" | sed 's/^/    /'
  fail "RequireProvenance refused the manifest this run wrote"
fi
ok "RequireProvenance does not refuse the manifest this run wrote"

printf '\nREHEARSAL PASSED: %s checks. The pre-spend refusals fire in order and cost no build, the real\n' "$pass"
printf 'runner reaches its manifests on a kind cluster, and the provenance guard accepts what it wrote.\n'
printf 'NOT covered here: the replay, the report, and every number.\n'
