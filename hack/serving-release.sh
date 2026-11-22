#!/usr/bin/env bash
# Deploys InferenceDeployment candidates on the CPU benchharness stub in kind, smokes each through the gateway,
# and restores the last known good CR spec when one fails.
#
# What it proves and what it does not is hack/serving-release.md.
# The cluster setup follows hack/gateway-replica-limit.sh: Kueue CRDs, the operator, the gateway, one tenant.
#
#   MODE=self-test (default)  runs the three fixed candidates; green only if the healthy one passes and both bad
#                             ones fail and are restored.
#   MODE=gate CANDIDATE=file  runs one candidate; red when it fails, even if the restore succeeds.
#   CORRUPT_LKG=1             corrupts the saved spec after it is saved, so the self-test must turn red.
#   OUT=dir                   where logs, CRs and raw smoke output go; KEEP=1 leaves the cluster up.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MODE=${MODE:-self-test}
CLUSTER=${CLUSTER:-serving-release}
KCTX=kind-$CLUSTER
NS=gpu-platform-control-plane-system
SERVING_NS=serving
NAME=stub
TAG=serving-release
STUB_IMG=benchharness:$TAG
# Apart from gateway-replica-limit.sh's 31080 and kind-config-gateway-path.yaml's 3008x, so the runs can coexist.
GW_PORT=31090
URL="http://127.0.0.1:$GW_PORT/v1/chat/completions"
TTFT_BOUND_MS=${TTFT_BOUND_MS:-1000}
# The controller sets ProgressDeadlineSeconds to 600, so a wait that long would let Kubernetes, not this job,
# decide; three minutes is ample for a stub image that is already loaded on the node.
WAIT_S=${WAIT_S:-180}
SRC=hack/serving-release
OUT=${OUT:-${RUNNER_TEMP:-/tmp}/serving-release-$(date -u +%Y%m%dT%H%M%SZ)}
LOG=$OUT/log.txt
WORK=$(mktemp -d)
mkdir -p "$OUT"

log()  { echo -e "$*" | tee -a "$LOG"; }
run()  { echo "+ $*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }
k()    { kubectl --context "$KCTX" "$@"; }
teardown() {
  rm -rf "$WORK"
  if [ "${KEEP:-0}" != 1 ] && grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")"; then
    kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || echo "teardown: kind delete failed" >>"$LOG"
  fi
}
# A setup failure exits 2, apart from a verdict's 1, so a must-fail check cannot mistake a broken cluster for a
# caught regression.
die() {
  log "SETUP FAILED at: $*"
  jq -n --arg mode "$MODE" --arg step "$*" '{mode: $mode, verdict: "setup-failed", step: $step}' >"$OUT/summary.json"
  tail -20 "$LOG" >&2
  teardown
  exit 2
}
trap 'teardown; exit 130' INT
trap 'teardown; exit 143' TERM

case "$MODE" in
  self-test) CANDIDATES=(healthy:pass ttft-regression:fail never-ready:fail) ;;
  gate)
    [ -n "${CANDIDATE:-}" ] && [ -f "$CANDIDATE" ] || die "MODE=gate needs CANDIDATE set to a spec file, got '${CANDIDATE:-}'"
    CANDIDATES=("gate:any") ;;
  *) die "MODE=$MODE is neither self-test nor gate" ;;
esac
# A corrupted spec is only meaningful as a self-test of the restore; in a gate it would just fake a failure.
[ "${CORRUPT_LKG:-0}" = 1 ] && [ "$MODE" != self-test ] && die "CORRUPT_LKG=1 is only for MODE=self-test"

export PATH="$PWD/bin:$PATH"
command -v kustomize >/dev/null || make kustomize >>"$LOG" 2>&1 || die "make kustomize"
for tool in docker kind kubectl kustomize jq curl python3; do
  command -v "$tool" >/dev/null || die "missing tool $tool"
done
log "commit $(git rev-parse HEAD), dirty files: $(git status --porcelain | wc -l), mode $MODE, corrupt_lkg ${CORRUPT_LKG:-0}"

log "== build"
run make docker-build IMG=controller:$TAG || die "operator image"
run make docker-build-gateway GATEWAY_IMG=gateway:$TAG || die "gateway image"
run make docker-build-benchharness BENCHHARNESS_IMG="$STUB_IMG" || die "stub image"

log "== cluster $CLUSTER"
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && run kind delete cluster --name "$CLUSTER"
cat >"$WORK/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - {containerPort: $GW_PORT, hostPort: $GW_PORT, listenAddress: "127.0.0.1", protocol: TCP}
EOF
run kind create cluster --name "$CLUSTER" --config "$WORK/kind.yaml" || die "kind create"
for img in controller:$TAG gateway:$TAG "$STUB_IMG"; do
  run kind load docker-image "$img" --name "$CLUSTER" || die "kind load $img"
done

log "== kueue, CRDs, operator, gateway"
# The operator's controllers watch Kueue kinds and do not start their caches without these CRDs.
run k apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml || die "kueue"
run k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s || die "kueue Available"
# Kueue's Deployment is Available before its webhook Service answers, and that webhook mutates every Deployment,
# so the first operator apply was refused with "connection refused" in one local run out of two.
# Applies are retried for a minute rather than waited on a guessed signal; a real error still fails after that.
apply_kustomization() {
  local dir=$1 i
  for i in $(seq 1 12); do
    kustomize build "$dir" | k apply --server-side -f - >>"$LOG" 2>&1 && return 0
    log "  apply $dir failed (attempt $i), retrying"
    sleep 5
  done
  return 1
}
apply_kustomization config/crd || die "CRDs"
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1
apply_kustomization config/operator || die "operator"
OPDEP=$(k -n "$NS" get deploy -o name | grep controller-manager | head -1)
# Both kustomizations pin an ECR digest a kind node cannot pull, so the local builds are set explicitly.
run k -n "$NS" set image "$OPDEP" "*=controller:$TAG" || die "operator image set"
run k -n "$NS" rollout status "$OPDEP" --timeout=180s || die "operator rollout"
apply_kustomization config/gateway || die "gateway"
k -n "$NS" create secret generic gateway-api-keys --from-literal=key-a=tenant-a >>"$LOG" 2>&1 || die "api keys"
run k -n "$NS" set image deploy/gateway "gateway=gateway:$TAG" || die "gateway image set"
run k -n "$NS" rollout status deploy/gateway --timeout=180s || die "gateway rollout"

log "== tenant"
k create namespace "$SERVING_NS" --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1
# The rate limit is generous on purpose: a smoke refused with 429 would be a failure of this job, not of a release.
cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "tenant policy and gateway Service"
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: tenant-a-quota
spec:
  tenant: tenant-a
  targetNamespace: $SERVING_NS
  gpuClass: l40s
  limits:
    gpuCount: 4
  rateLimit:
    requestsPerMinute: 600
    burst: 50
---
apiVersion: v1
kind: Service
metadata:
  name: gateway-serving-release
  namespace: $NS
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: gpu-platform-control-plane
    app.kubernetes.io/component: gateway
  ports:
    - {name: http, port: 8080, targetPort: http, nodePort: $GW_PORT}
EOF

# spec_doc reduces an InferenceDeployment to what a release is: its identity and its spec, never its status or
# server-set metadata, so replacing with it is exactly "serve this spec".
spec_doc() {
  jq '{apiVersion, kind,
       metadata: {name: .metadata.name, namespace: .metadata.namespace,
                  labels: (.metadata.labels // {}),
                  annotations: ((.metadata.annotations // {}) | del(."kubectl.kubernetes.io/last-applied-configuration"))},
       spec}'
}

# release_apply puts a spec file in place by replacing the whole object, which is what a restore has to mean:
# a merge would keep any field the candidate added and the saved spec lacks.
# It prints the generation the replace produced, which the wait must see observed.
# A refused replace is retried, because a transient API error is not a verdict on the spec.
# Its caller records a final refusal as apply-failed, never as fail, so a must-fail check cannot credit it.
# Its callers capture stdout as the generation, so every message here goes to stderr, and only a number is printed.
release_apply() {
  local file=$1 doc i gen
  doc=$(k create --dry-run=client -o json -f "$file" 2>>"$LOG") || { log "  $file does not parse as a Kubernetes object" >&2; return 1; }
  if [ "$(jq -r '.kind + "/" + .metadata.namespace + "/" + .metadata.name' <<<"$doc")" != "InferenceDeployment/$SERVING_NS/$NAME" ]; then
    log "  $file is not InferenceDeployment $SERVING_NS/$NAME" >&2
    return 1
  fi
  for i in 1 2 3; do
    if gen=$(spec_doc <<<"$doc" | k replace -o jsonpath='{.metadata.generation}' -f - 2>>"$LOG") && [[ $gen =~ ^[0-9]+$ ]]; then
      echo "$gen"
      return 0
    fi
    log "  replace with $file refused (attempt $i)" >&2
    sleep 5
  done
  return 1
}

# await_release waits until the controller has observed this generation, rendered the spec's model into the
# Deployment, and every replica of that rendering is Ready.
# Degraded alone is not read as the answer: it arrives only at the 600 s ProgressDeadline, after this wait ends.
await_release() {
  local gen=$1 file=$2 out=$3 model uri deadline infd dep ok
  model=$(k create --dry-run=client -o json -f "$file" | jq -r '.spec.model.name')
  uri=$(k create --dry-run=client -o json -f "$file" | jq -r '.spec.model.storageUri')
  deadline=$(( $(date +%s) + WAIT_S ))
  while :; do
    infd=$(k -n "$SERVING_NS" get inferencedeployment "$NAME" -o json 2>>"$LOG")
    dep=$(k -n "$SERVING_NS" get deploy "$NAME" -o json 2>>"$LOG")
    ok=$(jq -n --argjson i "${infd:-null}" --argjson d "${dep:-null}" --argjson gen "$gen" --arg m "$model" --arg u "$uri" '
      $i != null and $d != null
      and ($i.status.observedGeneration // 0) >= $gen
      and $i.status.phase == "Ready"
      and ($i.status.readyReplicas // 0) > 0
      and $d.spec.template.spec.containers[0].args == ["--model", $m, "--model-path", $u]
      and ($d.status.observedGeneration // 0) == $d.metadata.generation
      and ($d.spec.replicas // 0) > 0
      and ($d.status.replicas // 0) == $d.spec.replicas
      and ($d.status.updatedReplicas // 0) == $d.spec.replicas
      and ($d.status.readyReplicas // 0) == $d.spec.replicas' 2>>"$LOG")
    if [ "$ok" = true ]; then
      jq -n --argjson i "$infd" --argjson d "$dep" '{phase: $i.status.phase, observedGeneration: $i.status.observedGeneration,
        readyReplicas: $i.status.readyReplicas, args: $d.spec.template.spec.containers[0].args}' >"$out"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      jq -n --argjson i "${infd:-null}" --argjson d "${dep:-null}" --argjson gen "$gen" --argjson waited "$WAIT_S" '
        {timedOut: true, waitedSeconds: $waited, wantGeneration: $gen, infdStatus: $i.status,
         deploymentStatus: $d.status, renderedArgs: $d.spec.template.spec.containers[0].args}' >"$out" 2>>"$LOG"
      return 1
    fi
    sleep 3
  done
}

# verify is the one judgement a release gets, used alike for v1, a candidate and a restore: Ready at its own
# generation, then the gateway smoke against its own model name.
# The smoke runs even after a failed wait, because what the old Pod answered is the evidence of why it failed.
verify() {
  local gen=$1 file=$2 dir=$3 model ready=pass smoke=pass
  model=$(k create --dry-run=client -o json -f "$file" | jq -r '.spec.model.name')
  await_release "$gen" "$file" "$dir/wait.json" || ready=fail
  python3 -I "$SRC/smoke.py" --url "$URL" --key key-a --model "$model" --ttft-bound-ms "$TTFT_BOUND_MS" \
    --requests 3 --raw "$dir/smoke-raw.txt" >"$dir/smoke.json" 2>>"$LOG" || smoke=fail
  jq -n --arg ready "$ready" --arg smoke "$smoke" --arg model "$model" \
    '{ready: $ready, smoke: $smoke, model: $model, pass: ($ready == "pass" and $smoke == "pass")}' >"$dir/verdict.json"
  log "  ready $ready, smoke $smoke: $(jq -c '[.requests[] | {status, ttft_ms, reasons}]' "$dir/smoke.json" 2>/dev/null)"
  [ "$ready" = pass ] && [ "$smoke" = pass ]
}

snapshot() { k -n "$SERVING_NS" get inferencedeployment "$NAME" -o yaml >"$1" 2>>"$LOG"; }

log "== v1"
mkdir -p "$OUT/v1"
cp "$SRC/v1.yaml" "$OUT/v1/spec.yaml"
run k apply -f "$SRC/v1.yaml" || die "create v1"
gen=$(k -n "$SERVING_NS" get inferencedeployment "$NAME" -o jsonpath='{.metadata.generation}')
# A running v1 is not by that fact a good one, so it is saved only once its own smoke has passed.
verify "$gen" "$SRC/v1.yaml" "$OUT/v1" || die "v1 did not pass its own smoke, so there is no last known good spec"
snapshot "$OUT/v1/cr.yaml"
LKG=$OUT/last-known-good.json
k -n "$SERVING_NS" get inferencedeployment "$NAME" -o json | spec_doc >"$LKG" || die "save last known good"
log "saved last known good: $(jq -c .spec "$LKG")"
if [ "${CORRUPT_LKG:-0}" = 1 ]; then
  # Valid YAML with a slow profile, so the replace itself succeeds and only the restore's smoke can catch it.
  jq '.spec.model.storageUri = "stub://profile?tokens=4&ttft-ms=2500&itl-ms=2"' "$LKG" >"$WORK/lkg" && mv "$WORK/lkg" "$LKG"
  log "CORRUPT_LKG=1: the saved spec now has $(jq -r .spec.model.storageUri "$LKG"); the self-test must turn red"
fi

# restore re-applies the saved spec and holds it to the same verification v1 passed; it counts only if that passes.
restore() {
  local dir=$1 gen
  mkdir -p "$dir"
  gen=$(release_apply "$LKG") || { log "  restore: replace failed"; echo '{"pass": false, "apply": "fail"}' >"$dir/verdict.json"; return 2; }
  verify "$gen" "$LKG" "$dir"
}

# outcome names how a verify ended: pass, fail when the spec applied and its check failed, apply-failed otherwise.
outcome() {
  case $1 in 0) echo pass ;; 2) echo apply-failed ;; *) echo fail ;; esac
}

results=()
for entry in "${CANDIDATES[@]}"; do
  name=${entry%%:*} want=${entry##*:}
  file=$SRC/candidates/$name.yaml
  [ "$MODE" = gate ] && file=$CANDIDATE
  dir=$OUT/$name
  mkdir -p "$dir/candidate"
  log "== candidate $name (expected $want)"
  snapshot "$dir/before.yaml"
  cp "$file" "$dir/candidate.yaml"
  # A candidate the API never accepted was not tested, so it is apply-failed and cannot stand in for an expected fail.
  cand=apply-failed
  if gen=$(release_apply "$file"); then
    verify "$gen" "$file" "$dir/candidate"
    cand=$(outcome $?)
  else
    log "  candidate did not apply"
  fi
  snapshot "$dir/candidate-cr.yaml"
  rest=skipped
  # The self-test starts every candidate from v1, so a healthy one is reset to the saved spec too; in a gate a
  # passing candidate is the new release and stays.
  if [ "$cand" != pass ] || [ "$MODE" = self-test ]; then
    log "  restoring last known good"
    restore "$dir/restore"
    rest=$(outcome $?)
  fi
  snapshot "$dir/after.yaml"
  log "  candidate $cand, restore $rest"
  # The restore's two checks are kept apart, so a reader, and the must-fail job, can see which one failed it.
  results+=("$(jq -n --arg n "$name" --arg w "$want" --arg c "$cand" --arg r "$rest" \
    --argjson rv "$(cat "$dir/restore/verdict.json" 2>/dev/null || echo null)" \
    '{candidate: $n, expected: $w, result: $c, restore: $r, restoreReady: $rv.ready, restoreSmoke: $rv.smoke}')")
done

summary=$(printf '%s\n' "${results[@]}" | jq -s --arg mode "$MODE" --arg corrupt "${CORRUPT_LKG:-0}" '
  {mode: $mode, corruptLastKnownGood: ($corrupt == "1"), candidates: .}
  | .verdict = (if .mode == "self-test" then
      (if all(.candidates[]; .result == .expected and .restore == "pass") then "pass" else "fail" end)
    else
      (if .candidates[0].result == "pass" then "pass"
       elif .candidates[0].restore == "pass" then "candidate-failed-restored"
       else "candidate-failed-restore-failed" end)
    end)')
echo "$summary" >"$OUT/summary.json"
log "== summary\n$(jq . <<<"$summary")"
teardown
[ "$(jq -r .verdict <<<"$summary")" = pass ]
