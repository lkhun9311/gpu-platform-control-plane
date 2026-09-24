#!/usr/bin/env bash
# Apply the GitOps root on a live cluster, and prove a real credential reaches the gateway it deploys.
#
# It does NOT prove serving. Serving needs a backend, and this runbook deploys none: a key from the Secret
# that comes back 404 on model resolution has passed authentication and reached routing, which is where the
# evidence stops. Saying more than that was this script's own first claim, and it was wrong.
#
# This exists because nothing did it. `infra/aws/argo-bootstrap` installs the Argo CD Helm chart and says so
# in its first line -- "This root installs Argo CD once and owns nothing else" -- and no Terraform, workflow
# or script ever applies `config/argocd/root.yaml`. Two independent pre-spend reviews found the same hole:
# a paid EKS session could finish with Terraform green, Argo CD running, and **zero** Applications deployed.
#
# It is deliberately NOT in Terraform. The bootstrap root's own comment draws the ownership boundary -- after
# install, Argo CD owns in-cluster resources and the release is left alone -- and a `kubernetes_manifest` for
# the root Application would put Terraform back inside it.
#
# It is deliberately not m5a-ephemeral-runbook.sh either: that one destroys the bootstrap and never touches
# the GitOps path, so reusing it would answer a different question and cost the same money.
#
# Usage:
#   hack/eks-gitops-runbook.sh apply    # apply the root Application and wait for the children
#   hack/eks-gitops-runbook.sh verify   # prove a real credential reaches the key store, not merely Ready
#   hack/eks-gitops-runbook.sh status   # print what is deployed, without changing anything
#
# Environment:
#   CONTEXT   kube context                     (REQUIRED -- this runbook refuses to guess a cluster)
#   REPO      repository root                  (default: this script's parent)
#   EXDIR     evidence directory               (default ex/eks-gitops-<UTC timestamp>)
#   GW_NS     gateway namespace                (default gpu-platform-control-plane-system)
#   WAIT_CHILDREN  seconds to wait for the root to create children   (default 300)
#   WAIT_SYNC      seconds to wait for Synced/Healthy                (default 600)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-$ROOT}"
if [[ ! -f "$REPO/config/argocd/root.yaml" ]]; then
  echo "REPO=$REPO does not contain config/argocd/root.yaml; set REPO to the repository root" >&2
  exit 1
fi

# CONTEXT must be named. Inheriting the current one is how this runbook first pointed at kind-ckad.
#
# "No default" was the intent and `current-context` was the implementation, which is not the same thing: this
# machine's current context is an unrelated practice cluster, and a runbook whose whole job is to apply the
# GitOps root would have applied it there. The repository already records that the default context is not to
# be trusted.
if [[ -z "${CONTEXT:-}" ]]; then
  echo "CONTEXT is not set. Name the cluster explicitly -- this runbook applies the GitOps root and will not" >&2
  echo "guess. Current context is '$(kubectl config current-context 2>/dev/null || echo none)'." >&2
  exit 1
fi
if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx -- "$CONTEXT"; then
  echo "CONTEXT='$CONTEXT' is not a context on this machine" >&2
  exit 1
fi
GW_NS="${GW_NS:-gpu-platform-control-plane-system}"

# The two deadlines are settings, not literals, so the failure verdicts can be rehearsed against a stub in
# seconds rather than a quarter of an hour. A failure branch nobody has ever run is how a false green
# survives: the healthy path was the only one this runbook had exercised, and it was the one that was wrong.
WAIT_CHILDREN="${WAIT_CHILDREN:-300}"
WAIT_SYNC="${WAIT_SYNC:-600}"

# Every call carries a request timeout.
#
# The loops below are bounded by WAIT_CHILDREN and WAIT_SYNC, but a deadline in the loop does not bound a
# single call that never returns: one hung kubectl and the run sits there while the cluster bills.
k() { kubectl --context "$CONTEXT" --request-timeout=20s "$@"; }
say() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$*" | tee -a "$EXDIR/run.log"; }

failures=0
ok() { printf '   ok   %s\n' "$*" | tee -a "$EXDIR/run.log"; }
bad() {
  printf '   FAIL %s\n' "$*" | tee -a "$EXDIR/run.log" >&2
  failures=$((failures + 1))
}

# Application status as a table: name, automated|manual, sync, health.
#
# jsonpath cannot report whether `spec.syncPolicy.automated` is present, and that distinction decides what may
# be waited on at all: `device-plugin` and `samples` deliberately carry no automated policy, so a wait for
# "every Application Synced/Healthy" would spend ten minutes and then fail on a perfectly healthy cluster.
#
# It exits 3 rather than printing nothing when the status cannot be read, because "no rows" and "nothing
# pending" must not look alike -- reading an unreadable cluster as zero pending is the false green this
# runbook is for.
app_table() {
  k -n argocd get applications.argoproj.io -o json 2>/dev/null | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for item in doc.get("items", []):
    policy = item.get("spec", {}).get("syncPolicy") or {}
    status = item.get("status", {}) or {}
    print(item["metadata"]["name"],
          "automated" if policy.get("automated") is not None else "manual",
          (status.get("sync") or {}).get("status", "-"),
          (status.get("health") or {}).get("status", "-"))
'
}

# The Applications this repository declares, which is what the root is supposed to produce.
#
# "Some new Application appeared" is not the claim and never was: the root itself appears, and so would an
# Application created by anything else at the same time. The claim is that the set this repository declares
# exists on the cluster.
expected_children() {
  grep -h '^  name:' "$REPO"/config/argocd/*.yaml 2>/dev/null |
    awk '{print $2}' | grep -v '^gpu-platform-root$' | sort -u
}

apply() {
  say "context: $CONTEXT"

  # Names before, so "the root created children" is a difference and not a count of whatever was already here.
  #
  # A baseline that could not be read is refused rather than treated as empty: against an empty baseline every
  # pre-existing Application reads as one the root just produced, which is the claim this whole runbook exists
  # to establish.
  local before after="" new_apps="" readable=0
  if ! before="$(app_table | awk '{print $1}' | sort)"; then
    bad "could not list Applications before applying, so this run cannot tell a new one from a pre-existing one"
    return 0
  fi

  say "applying config/argocd/root.yaml -- the step that was missing"
  if ! k apply -f "$REPO/config/argocd/root.yaml" >>"$EXDIR/run.log" 2>&1; then
    bad "applying config/argocd/root.yaml failed; see run.log. Nothing below this line was measured"
    return 0
  fi

  local deadline=$((SECONDS + WAIT_CHILDREN)) expected missing="unknown"
  expected="$(expected_children)"
  if [[ -z "$expected" ]]; then
    bad "config/argocd declares no child Applications, so there is nothing to check for; REPO is probably wrong"
    return 0
  fi
  while ((SECONDS < deadline)); do
    if after="$(app_table | awk '{print $1}' | sort)"; then
      readable=1
      missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$after") | grep -v '^$' || true)"
      new_apps="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' | grep -v '^gpu-platform-root$' || true)"
    else
      # Unreadable is not "nothing was created". Reporting it as the latter sends the operator after Argo CD
      # while the cluster is billing and the real fault is that nothing here can see the cluster at all.
      readable=0
      missing="unknown"
      new_apps=""
    fi
    [[ -z "$missing" ]] && break
    sleep 5
  done
  if ((readable == 0)); then
    bad "Applications could not be read at all after applying the root; this is an unmeasured run, not a verdict about Argo CD"
    return 0
  fi
  if [[ -n "$missing" ]]; then
    bad "$(printf '%s\n' "$missing" | wc -l) Application(s) this repository declares are absent: $(printf '%s\n' "$missing" | tr '\n' ' ')-- Argo CD is deploying less than the repository says"
    return 0
  fi
  ok "all $(printf '%s\n' "$expected" | wc -l) Applications this repository declares exist, $(printf '%s\n' "$new_apps" | grep -c . || true) of them created by this run"

  # `targetRevision: main` is a moving branch, so the evidence must say which commit was actually deployed.
  k -n argocd get application gpu-platform-root -o jsonpath='{.status.sync.revision}' \
    >"$EXDIR/resolved-revision.txt" 2>/dev/null || true
  say "root resolved revision: $(cat "$EXDIR/resolved-revision.txt" 2>/dev/null || true) (targetRevision is the mutable branch main)"

  say "waiting for the automated Applications to reach Synced/Healthy"
  deadline=$((SECONDS + WAIT_SYNC))
  local table="" pending=-1
  while ((SECONDS < deadline)); do
    # Exit status and output are separate facts. The lister prints the rows it managed before failing, so a
    # partial table is not an empty one, and reading it as complete is how a half-listed cluster reports
    # nothing pending.
    if table="$(app_table)"; then
      pending="$(printf '%s\n' "$table" | awk '$2 == "automated" && !($3 == "Synced" && $4 == "Healthy")' | wc -l)"
    else
      table=""
      pending=-1
    fi
    ((pending == 0)) && break
    sleep 10
  done
  printf '%s\n' "$table" >"$EXDIR/applications.txt"
  if ((pending == 0)); then
    ok "every automated Application is Synced/Healthy"
  elif ((pending < 0)); then
    bad "could not read Application status at all; this is an unmeasured run, not a pass"
  else
    bad "$pending automated Application(s) never reached Synced/Healthy; see applications.txt"
  fi

  local manual
  manual="$(printf '%s\n' "$table" | awk '$2 == "manual" {printf "%s ", $1}')"
  if [[ -n "$manual" ]]; then
    say "not waited on because they carry no automated syncPolicy, by design: $manual"
  fi
}

# Ready is not serving, and Healthy is not serving either.
#
# The gateway's readiness probe checks cache sync and nothing else, so a Deployment can be Available, Argo
# can be Healthy, and every authenticated request can still fail. Only a real request through the real route
# settles it: this gateway serves POST /v1/chat/completions, and a bad key returns 401 rather than 404.
verify() {
  say "context: $CONTEXT"
  local pod
  pod="$( { k -n "$GW_NS" get pod -o name 2>/dev/null | grep gateway | head -1 | cut -d/ -f2; } || true)"
  if [[ -z "$pod" ]]; then
    bad "no gateway pod in $GW_NS; the GitOps path deployed nothing to serve"
    return 0
  fi
  say "probing $pod through a port-forward (the image is distroless, so exec cannot help)"

  # Let the kernel pick the local ports, and kill the forwarder by process group.
  #
  # Both halves are here because the first version got both wrong and produced a false failure on its second
  # run. It forwarded to fixed 18080/18081 and ended with `kill "$pf_pid"` -- but `$!` of a redirected
  # function call is the subshell, not kubectl, so kubectl survived holding both ports, and the next run
  # died with "address already in use" while reporting that the gateway could not be probed. On a paid
  # cluster that is a run that spends money and proves nothing.
  #
  # `:8080` asks kubectl for a free port and it prints which one it chose, so there is nothing to collide
  # with; `set -m` puts it in its own process group so the negative PID reaches the real process.
  local pf_pid pf_log="$EXDIR/port-forward.log" api_port="" ready_port=""
  set -m
  kubectl --context "$CONTEXT" -n "$GW_NS" port-forward "pod/$pod" :8080 :8081 >"$pf_log" 2>&1 &
  pf_pid=$!
  set +m
  # An interrupt must not leave the forwarder behind: a leaked kubectl holds its local ports, and the next
  # run's failure would be this run's litter rather than anything about the cluster.
  trap 'kill -- -"$pf_pid" 2>/dev/null || kill "$pf_pid" 2>/dev/null || true' EXIT INT TERM

  # Wait for the ports it actually chose, not for a fixed time: sleeping is how a slow forward reads as dead.
  local waited=0
  while ((waited < 100)); do
    api_port="$(sed -n 's|^Forwarding from 127\.0\.0\.1:\([0-9]\{1,\}\) -> 8080$|\1|p' "$pf_log" | head -1)"
    ready_port="$(sed -n 's|^Forwarding from 127\.0\.0\.1:\([0-9]\{1,\}\) -> 8081$|\1|p' "$pf_log" | head -1)"
    [[ -n "$api_port" && -n "$ready_port" ]] && break
    kill -0 "$pf_pid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done

  local ready_code=000 bad_key_code=000 real_key="" real_key_code=""
  if [[ -n "$api_port" && -n "$ready_port" ]]; then
    say "   forwarding 127.0.0.1:$api_port -> 8080 and 127.0.0.1:$ready_port -> 8081"
    ready_code="$(curl -s -o "$EXDIR/readyz.out" -w '%{http_code}' --max-time 5 \
      "http://127.0.0.1:$ready_port/readyz" || echo 000)"

    # The credential goes in `Authorization: Bearer`, which is the only header the gateway reads.
    #
    # `resolveTenant` returns not-authenticated before touching the Secret unless the scheme is Bearer
    # (internal/gateway/tenant.go:45), so an `X-API-Key` header -- what this probe sent at first -- is
    # ignored and its 401 means "no credential presented", not "this key was rejected". Worse, it makes the
    # 503 case unreachable: a request that never reaches the key store can never reveal that the key store
    # is unreadable, which is the single failure this runbook exists to catch.
    bad_key_code="$(curl -s -o "$EXDIR/badkey.out" -w '%{http_code}' --max-time 5 \
      -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer runbook-probe-not-a-real-key' \
      -d '{"model":"runbook-probe","messages":[{"role":"user","content":"probe"}]}' \
      "http://127.0.0.1:$api_port/v1/chat/completions" || echo 000)"

    # A key taken from the Secret proves the gateway can read the Secret. A rejected bad key does not.
    #
    # The Secret's data keys are the API keys and the values are tenant names (internal/gateway/tenant.go:57),
    # so any one of its keys is a valid credential. Nothing in the GitOps path creates this Secret, so its
    # absence is a finding rather than a skip.
    real_key="$(k -n "$GW_NS" get secret gateway-api-keys -o jsonpath='{.data}' 2>/dev/null |
      python3 -c 'import json,sys; d=sys.stdin.read().strip(); print(next(iter(json.loads(d))) if d else "")' 2>/dev/null || true)"
    if [[ -n "$real_key" ]]; then
      real_key_code="$(curl -s -o "$EXDIR/realkey.out" -w '%{http_code}' --max-time 5 \
        -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $real_key" \
        -d '{"model":"runbook-probe","messages":[{"role":"user","content":"probe"}]}' \
        "http://127.0.0.1:$api_port/v1/chat/completions" || echo 000)"
    fi
  fi

  # One cleanup site, reached whether or not the probe ran, and it verifies the process is gone.
  kill -- -"$pf_pid" 2>/dev/null || kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true
  if kill -0 "$pf_pid" 2>/dev/null; then
    sleep 0.5
    kill -9 -- -"$pf_pid" 2>/dev/null || kill -9 "$pf_pid" 2>/dev/null || true
  fi
  trap - EXIT INT TERM

  if [[ -z "$api_port" || -z "$ready_port" ]]; then
    bad "port-forward never reported both local ports; the probe is broken and proves nothing (see port-forward.log)"
    return 0
  fi

  say "   readyz=$ready_code  bad-key request=$bad_key_code  real-key request=${real_key_code:-no-secret}"
  {
    echo "readyz   :8081 -> $ready_code"
    echo "bad key  :8080 -> $bad_key_code"
    echo "real key :8080 -> ${real_key_code:-(no gateway-api-keys Secret in this namespace)}"
  } >"$EXDIR/gateway-probe.txt"

  if [[ "$ready_code" != "200" ]]; then
    bad "/readyz answered $ready_code; the gateway is not ready and nothing below means anything"
    return 0
  fi
  case "$bad_key_code" in
    401) ok "a bad key is refused with 401" ;;
    403) ok "a bad key reaches tenant policy and is refused with 403" ;;
    503) bad "503: the gateway cannot read its API-key Secret. Ready, Healthy, and serving nothing -- the exact false green this runbook exists to catch" ;;
    404) bad "404 on the real route means the model did not resolve; this is not an auth result and must not be read as one" ;;
    000) bad "the request never arrived; the probe is broken and proves nothing" ;;
    *) bad "unclassified status $bad_key_code; read $EXDIR/badkey.out before concluding anything" ;;
  esac

  # Only a key that is in the Secret exercises the key store.
  #
  # A refused bad key and an unreadable Secret produce the same 401 through different code -- one returns
  # before the Get, the other after it fails -- so the bad-key result above cannot distinguish a working
  # gateway from one that cannot read its credentials. That is why this second probe exists.
  if [[ -z "$real_key" ]]; then
    bad "no gateway-api-keys Secret in $GW_NS: the GitOps path deploys a gateway and no credential for it, so nothing here can serve a tenant and a fresh cluster inherits none"
    return 0
  fi
  case "$real_key_code" in
    200) ok "a key from the Secret is accepted and the request was served end to end" ;;
    404) ok "a key from the Secret is accepted and the request fails on model resolution (404): authentication reached the key store. Not proof of serving -- no backend is deployed here" ;;
    403) ok "a key from the Secret is accepted and refused by tenant policy (403): authentication reached the key store. Not proof of serving" ;;
    401) bad "a key taken from the Secret was refused with 401: the gateway cannot read its own key store, and the bad-key 401 above was the same answer for a different reason" ;;
    503) bad "503 for a key from the Secret: the key store is unreadable. Ready, Healthy and serving nothing" ;;
    000) bad "the valid-key request never arrived; the probe is broken and proves nothing" ;;
    *) bad "unclassified status $real_key_code for a key from the Secret; read $EXDIR/realkey.out before concluding anything" ;;
  esac
}

status() {
  say "context: $CONTEXT"
  # A listing that failed is not a status report. Without these the command prints an error and exits 0.
  if ! k -n argocd get applications.argoproj.io \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,AUTOMATED:.spec.syncPolicy.automated' \
    2>&1 | tee -a "$EXDIR/run.log"; then
    bad "could not list Applications"
  fi
  if ! k -n "$GW_NS" get deploy 2>&1 | tee -a "$EXDIR/run.log"; then
    bad "could not list Deployments in $GW_NS"
  fi
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    apply | verify | status) ;;
    *)
      echo "usage: $0 {apply|verify|status}" >&2
      exit 1
      ;;
  esac
  shift

  EXDIR="${EXDIR:-ex/eks-gitops-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$EXDIR"

  # `|| true` so a subcommand's own non-zero does not bypass the failure count below.
  #
  # Every branch inside verify() ends in `return 0` -- deliberately, so one bad check does not skip the rest
  # -- which meant `main` returned whatever the last statement produced and the script exited 0 while
  # printing FAIL. That is the defect this whole session has been closing elsewhere, reintroduced here.
  "$cmd" "$@" || true

  if ((failures > 0)); then
    say "$failures check(s) failed"
    exit 1
  fi
  exit 0
}

main "$@"
