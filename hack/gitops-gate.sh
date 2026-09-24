#!/usr/bin/env bash
# Rehearse, for free, the GitOps path a paid EKS session would take.
#
# Two pre-spend reviews (gpt-5.6-sol, gpt-6-astra) independently found the same hole: `infra/aws/argo-bootstrap`
# installs the Argo CD Helm chart and nothing applies `config/argocd/root.yaml`, so Terraform can finish
# green with **zero** Applications deployed. They also found that `gateway-api-keys` -- the Secret the
# gateway reads to authenticate a tenant -- is created nowhere outside unit tests.
#
# The second half of that was WRONG, and this gate is what found it: five scripts create the Secret with
# `k create secret generic gateway-api-keys` (hack/m5b-*.sh, hack/m5c-matrix.sh, hack/test/rehearse-m5c-deploy.sh).
# The earlier search had restricted itself to yaml/tf/go and never looked at shell. What remains genuinely
# missing is the apply of root.yaml -- gate 1.
#
# This script closes both on kind before either is paid for on EKS. It is the gate, not the experiment: it
# answers "would the paid run have produced anything?" and nothing about GPUs.
#
# Usage:
#   hack/gitops-gate.sh check     # run every gate, leaving the cluster as it found it
#   hack/gitops-gate.sh teardown  # remove what `check` created
#
# Environment:
#   CONTEXT  kube context                (default kind-platform)
#   REPO     repository root             (default: this script's parent)
#   EXDIR    evidence directory          (default ex/gitops-gate-<UTC timestamp>)

set -euo pipefail
set -m

CONTEXT="${CONTEXT:-kind-platform}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-$ROOT}"
if [[ ! -d "$REPO/config/argocd" ]]; then
  echo "REPO=$REPO does not contain config/argocd; set REPO to the repository root" >&2
  exit 1
fi

NS=gitops-gate
LOCKDIR="${LOCKDIR:-/tmp/gitops-gate.lock}"

k() { kubectl --context "$CONTEXT" "$@"; }
say() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$*" | tee -a "$EXDIR/run.log"; }

failures=0
ok() { printf '   ok   %s\n' "$*" | tee -a "$EXDIR/run.log"; }
bad() {
  printf '   FAIL %s\n' "$*" | tee -a "$EXDIR/run.log" >&2
  failures=$((failures + 1))
}

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo $$ >"$LOCKDIR/pid"
    LOCK_HELD=1
    return 0
  fi
  local owner
  owner="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    echo "another run (pid $owner) holds $LOCKDIR" >&2
    exit 1
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" && echo $$ >"$LOCKDIR/pid" && LOCK_HELD=1
}
release_lock() {
  [[ "${LOCK_HELD:-0}" == "1" ]] || return 0
  rm -rf "$LOCKDIR"
  LOCK_HELD=0
}

# Gate 1: is there anything in the repository that applies the root Application?
#
# A paid session that relies on Terraform alone gets Argo CD and no Applications. This asks the question the
# way a reader would -- by searching for a command, not by trusting a memory of one.
gate_root_is_applied() {
  say "gate 1: does any automation apply config/argocd/root.yaml?"
  # An APPLY, not a mention.
  #
  # The first version of this gate counted every line containing "root.yaml" under infra/, .github/ and
  # hack/ -- including the comments in this very file, which talk about root.yaml at length. It reported
  # "4 references, ok" against a tree where the real answer is zero. Two things fix it: exclude this script,
  # and require the grep to match a command that actually applies something.
  # `|| true` on the whole pipeline, because zero matches is the ANSWER, not an error.
  #
  # Under `set -euo pipefail` a grep that finds nothing exits 1 and takes the function with it. The gate then
  # printed its heading and died before any verdict -- and the script's exit 1 read exactly like "the gate
  # failed as intended". It had not run. Both gates below had the same shape.
  local hits
  hits="$( { grep -rnE '(kubectl|kubectl_manifest|k) +apply[^|]*root\.yaml' \
    "$REPO"/infra "$REPO"/.github "$REPO"/hack 2>/dev/null |
    grep -v "gitops-gate.sh" | wc -l; } || true)"
  if [[ "${hits:-0}" -gt 0 ]]; then
    ok "an apply path exists ($hits command(s))"
  else
    bad "nothing applies root.yaml: Terraform installs Argo CD and no Application is ever created. A paid EKS session would end with Terraform green and zero deployed apps."
  fi
}

# Gate 2: is the Secret the gateway authenticates against created anywhere?
#
# Without it the Deployment is Available, /readyz passes, Argo is Healthy -- and every authenticated request
# is 503. That combination is exactly what a session would record as success.
gate_api_key_secret_has_a_source() {
  say "gate 2: is gateway-api-keys created anywhere in the repository?"
  # Count FILES, and count them correctly.
  #
  # `grep -rln` prints one filename per line and `grep -vc` then counted lines of that list -- but the -c
  # was applied to the wrong stream in the first version and returned 47 for a tree whose real answer is
  # zero. The question is also narrower than "does the name appear": a Secret referenced by a Deployment is
  # not a Secret anyone creates.
  local files
  files="$( { grep -rl -- "gateway-api-keys" "$REPO"/config "$REPO"/infra "$REPO"/hack 2>/dev/null |
    grep -v "_test.go" | grep -v "gitops-gate.sh"; } || true)"
  # A manifest that CREATES it says `kind: Secret`; one that merely consumes it names it under a volume or
  # an env reference.
  local creators=""
  local f
  for f in $files; do
    grep -qE '^kind: Secret|create secret|kubernetes_secret|kubectl create secret' "$f" 2>/dev/null && creators="$creators $f"
  done
  if [[ -n "${creators// /}" ]]; then
    ok "a creation path exists:$creators"
  else
    bad "gateway-api-keys is referenced but never created in this repository (checked $(printf '%s' "$files" | wc -w) file(s)). On a fresh EKS the gateway would report ready while authenticated requests fail on the unreadable Secret."
  fi
}

# Gate 3: readiness is not service.
#
# The route matters. This gateway serves exactly `POST /v1/chat/completions` and `/readyz`
# (internal/gateway/server.go:601-602). The first version of this gate probed `GET /v1/models`, which does
# not exist, got a 404, and reported it as "the request was refused" -- a gate that could not tell a refusal
# from a missing path, which is the exact confusion it was written to catch.
#
# The refusals worth seeing are 401 (bad key), 403 (no tenant policy) and 503 (Secret unreadable or cache
# unsynced). A 404 from the real route means the model was not resolved, which is a different story again.
#
# Three premises of the first version were measured and all three were wrong. The readiness probe is on
# :8081, not :8080 -- 8080 is the http port and 8081 carries metrics and probes. The image is distroless, so
# `kubectl exec` cannot run wget or even sh in it. And `gateway-api-keys` DOES exist on this long-lived kind
# cluster, created by hand 38 days ago, which is a different fact from the repository having a path that
# creates it. A fresh EKS would have neither.
#
# So the probe runs from here through `kubectl port-forward`, and the verdict separates what the cluster has
# from what the repository can rebuild.
gate_ready_is_not_serving() {
  say "gate 3: does /readyz pass while an authenticated request fails?"
  local pod
  pod="$(k -n gpu-platform-control-plane-system get pod -l app.kubernetes.io/name=gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pod" ]]; then
    pod="$(k -n gpu-platform-control-plane-system get pod 2>/dev/null | awk '/^gateway/{print $1; exit}' || true)"
  fi
  if [[ -z "$pod" ]]; then
    say "   (no gateway pod on this cluster; gate 3 is skipped and reported as unmeasured)"
    bad "gate 3 could not run: no gateway pod. Unmeasured is not a pass."
    return 0
  fi

  # Forwarded rather than exec'd: the image has no shell.
  local pf_pid ready_code authed_code
  k -n gpu-platform-control-plane-system port-forward "pod/$pod" 18080:8080 18081:8081 \
    >"$EXDIR/port-forward.log" 2>&1 &
  pf_pid=$!
  # The forward needs a moment, and a failure to establish must not read as a failing endpoint.
  sleep 3
  if ! kill -0 "$pf_pid" 2>/dev/null; then
    bad "port-forward did not stay up; the probe is broken and proves nothing (see port-forward.log)"
    return 0
  fi

  ready_code="$(curl -s -o "$EXDIR/readyz.out" -w '%{http_code}' --max-time 5 http://127.0.0.1:18081/readyz || echo 000)"
  authed_code="$(curl -s -o "$EXDIR/authed.out" -w '%{http_code}' --max-time 5 \
    -X POST -H 'Content-Type: application/json' -H 'X-API-Key: gate-probe-not-a-real-key' \
    -d '{"model":"gate-probe","messages":[{"role":"user","content":"probe"}]}' \
    http://127.0.0.1:18080/v1/chat/completions || echo 000)"

  kill -- -"$pf_pid" 2>/dev/null || kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true

  {
    echo "readyz  :8081 -> $ready_code"
    echo "request :8080 -> $authed_code"
    echo "--- readyz body ---"; cat "$EXDIR/readyz.out" 2>/dev/null
    echo "--- request body ---"; cat "$EXDIR/authed.out" 2>/dev/null
  } >"$EXDIR/gateway-probe.txt"
  say "   readyz=$ready_code  authenticated-request=$authed_code"

  case "$ready_code:$authed_code" in
    000:*)
      bad "/readyz was unreachable through the forward; the probe is broken and proves nothing" ;;
    *:000)
      bad "the request never reached the gateway; the probe is broken and proves nothing" ;;
  esac
  if [[ "$ready_code" != "200" ]]; then
    bad "/readyz answered $ready_code, so this cluster's gateway is not even ready -- fix that before reading anything into the request"
  else
    case "$authed_code" in
      401 | 403 | 503)
        ok "readiness passes (200) while the request is refused ($authed_code) -- the false-green a paid session must not accept" ;;
      200)
        ok "readiness passes AND the request was served; this cluster has a hand-made Secret a fresh EKS will not inherit" ;;
      404)
        bad "the request returned 404 on the real route, which means the model did not resolve -- not an auth refusal. Do not read this as a refusal." ;;
      *)
        bad "the request returned $authed_code, which this gate does not know how to classify; read $EXDIR/authed.out before drawing any conclusion" ;;
    esac
  fi

  # The cluster having a hand-made Secret says nothing about the repository being able to make one; gate 2
  # is the one that answers that, and this note exists so the two are never read as the same result.
  if k -n gpu-platform-control-plane-system get secret gateway-api-keys >/dev/null 2>&1; then
    say "   note: gateway-api-keys exists on this cluster (created outside the repository); gate 2 governs whether a fresh EKS would get one"
  fi
}

check() {
  gate_root_is_applied
  gate_api_key_secret_has_a_source
  gate_ready_is_not_serving

  say "---"
  if ((failures > 0)); then
    say "$failures gate(s) failed. These are the paid run's failure modes, found for free."
    return 1
  fi
  say "every gate passed; the GitOps path is worth paying for"
}

teardown() {
  say "removing anything this gate created"
  k delete namespace "$NS" --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  say "teardown complete"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    check | teardown) ;;
    *)
      echo "usage: $0 {check|teardown}" >&2
      exit 1
      ;;
  esac
  shift

  acquire_lock
  EXDIR="${EXDIR:-ex/gitops-gate-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$EXDIR"
  trap release_lock EXIT

  "$cmd" "$@"
}

main "$@"
