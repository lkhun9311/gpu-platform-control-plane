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
#   hack/eks-gitops-runbook.sh seed-key # create the api-key Secret the GitOps bundle does not own
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

  # The declared set has to still be there in the SAME snapshot that says everything converged.
  #
  # Existence was checked in one loop and convergence in another, minutes apart, so an Application that
  # disappeared in between -- pruned, renamed, deleted by hand -- left a table whose remaining automated rows
  # were all Synced/Healthy, and that read as success.
  #
  # An EMPTY table read that way too, and the guard that skipped the comparison whenever the table was empty
  # is exactly what let it: `pending` counts failures among the rows present, no rows means no failures, and
  # the comparison that would have named every declared Application as missing never ran. A successful read
  # returning zero Applications is the strongest possible failure, not the absence of one. So the unreadable
  # case is answered first, and every case after it compares against the table whatever the table holds.
  if ((pending < 0)); then
    bad "could not read Application status at all; this is an unmeasured run, not a pass"
  else
    local gone
    gone="$(comm -23 <(printf '%s\n' "$expected") \
      <(printf '%s\n' "$table" | awk 'NF {print $1}' | sort) | grep -v '^$' || true)"
    if [[ -n "$gone" ]]; then
      bad "$(printf '%s\n' "$gone" | wc -l) of the $(printf '%s\n' "$expected" | wc -l) declared Application(s) are absent from the snapshot that judged convergence: $(printf '%s\n' "$gone" | tr '\n' ' ')"
    elif ((pending == 0)); then
      ok "every automated Application is Synced/Healthy, and every declared Application is still present"
    else
      bad "$pending automated Application(s) never reached Synced/Healthy; see applications.txt"
    fi
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
# Create the credential the GitOps path does not own.
#
# `config/gateway/deployment.yaml` names the Secret in GATEWAY_API_KEY_SECRET and nothing in the bundle
# creates it: the five scripts that do are experiment harnesses no EKS run invokes. So a fresh cluster gets a
# gateway that is Ready, Healthy, and refuses every request -- and a paid session would spend its money
# discovering a fact this repository already knows.
#
# No restart follows. The gateway watches Secrets in its own namespace through a scoped cache
# (internal/gateway/server.go:654), so a Secret created after the Deployment is picked up in place.
#
# An existing Secret is left alone. Overwriting one would destroy whatever credentials a cluster already
# serves, and on this machine's long-lived kind cluster that Secret was made by hand.
seed_key() {
  say "context: $CONTEXT"
  if k -n "$GW_NS" get secret gateway-api-keys >/dev/null 2>&1; then
    ok "gateway-api-keys already exists in $GW_NS; leaving it untouched"
    return 0
  fi
  local key
  key="runbook-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  if ! k -n "$GW_NS" create secret generic gateway-api-keys \
    --from-literal="$key=tenant-a" >>"$EXDIR/run.log" 2>&1; then
    bad "could not create gateway-api-keys in $GW_NS; verify cannot exercise the key store without it"
    return 0
  fi
  printf '%s\n' "$key" >"$EXDIR/seeded-key.txt"
  ok "created gateway-api-keys with one key for tenant-a (recorded in seeded-key.txt)"
}

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
    403) bad "a key that is not in the Secret was answered 403, not 401. resolveTenant returns not-authenticated for an unknown key (internal/gateway/tenant.go:56), so a 403 here means the request got past authentication -- a misclassification, not a pass" ;;
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

# --- Serving one request: config/serving, docs/superpowers/specs/2026-10-12-serve-one-request-on-eks-design.md ---
#
# The subcommands below take the serving bundle from synced to answered. None of them touches AWS: the GPU node
# group is scaled by the session, so each of these can be rehearsed on kind, where the engine's Pod is created and
# can never schedule.

SERVE_NS="${SERVE_NS:-serve-a}"
SERVE_APP="${SERVE_APP:-gpu-platform-serving}"
SERVE_INFD="${SERVE_INFD:-qwen25-3b-holdcap}"
SERVE_MODEL="${SERVE_MODEL:-Qwen/Qwen2.5-3B-Instruct}"
SERVE_TENANT="${SERVE_TENANT:-serve-a}"
WAIT_SERVE_SYNC="${WAIT_SERVE_SYNC:-300}"
# 25 minutes: the startup probe allows 900 s, and the conformance engine took 9 min 31 s from creation to HoldCap
# on a host that pulled nothing through a NAT.
WAIT_SERVE_READY="${WAIT_SERVE_READY:-1500}"
WAIT_SERVE_RECOVER="${WAIT_SERVE_RECOVER:-1500}"

# The tier serve-a's policy resolves to: no tier annotation is standard, and standard binds priority 1
# (internal/gateway/priority.go). The gateway writes it only under HoldCap or -bind-priority, and config/gateway
# sets no flags, so its presence on the response is the per-request trace of HoldCap admission.
SERVE_EXPECTED_PRIORITY="${SERVE_EXPECTED_PRIORITY:-1}"

# gw_forward starts a port-forward to the gateway's API port and sets GW_API_PORT and GW_PF_PID; gw_unforward ends
# it. The same rules as verify's: a kernel-chosen port, its own process group, and a cleanup that checks.
gw_forward() {
  GW_API_PORT="" GW_PF_PID=""
  local pod pf_log="$EXDIR/port-forward-serve.log"
  pod="$( { k -n "$GW_NS" get pod -o name 2>/dev/null | grep gateway | head -1 | cut -d/ -f2; } || true)"
  [[ -n "$pod" ]] || return 1
  set -m
  kubectl --context "$CONTEXT" -n "$GW_NS" port-forward "pod/$pod" :8080 >"$pf_log" 2>&1 &
  GW_PF_PID=$!
  set +m
  trap 'gw_unforward' EXIT INT TERM
  local waited=0
  while ((waited < 100)); do
    GW_API_PORT="$(sed -n 's|^Forwarding from 127\.0\.0\.1:\([0-9]\{1,\}\) -> 8080$|\1|p' "$pf_log" | head -1)"
    [[ -n "$GW_API_PORT" ]] && return 0
    kill -0 "$GW_PF_PID" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

gw_unforward() {
  [[ -n "${GW_PF_PID:-}" ]] || return 0
  kill -- -"$GW_PF_PID" 2>/dev/null || kill "$GW_PF_PID" 2>/dev/null || true
  wait "$GW_PF_PID" 2>/dev/null || true
  if kill -0 "$GW_PF_PID" 2>/dev/null; then
    sleep 0.5
    kill -9 -- -"$GW_PF_PID" 2>/dev/null || kill -9 "$GW_PF_PID" 2>/dev/null || true
  fi
  GW_PF_PID=""
  trap - EXIT INT TERM
}

# serve_key prints the serve-a key this run saved, and nothing when there is none.
#
# The key is read from the run's own file rather than from the Secret, because the Secret also holds seed-key's
# tenant-a key and verify takes the first one it finds: a request sent with that key is answered 403 no_policy,
# which would read as the serving chain failing.
serve_key() { cat "$EXDIR/serve-key.txt" 2>/dev/null || true; }

serve_sync() {
  say "context: $CONTEXT"
  local key
  key="$(serve_key)"
  if [[ -z "$key" ]]; then
    key="serve-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    # Added to the Secret seed-key made, never replacing it: a merge patch adds one data key and leaves the rest.
    if ! k -n "$GW_NS" patch secret gateway-api-keys --type merge \
      -p "{\"stringData\":{\"$key\":\"$SERVE_TENANT\"}}" >>"$EXDIR/run.log" 2>&1; then
      bad "could not add a $SERVE_TENANT key to gateway-api-keys in $GW_NS (run seed-key first)"
      return 0
    fi
    printf '%s\n' "$key" >"$EXDIR/serve-key.txt"
    ok "added a key for $SERVE_TENANT to gateway-api-keys (recorded in serve-key.txt)"
  fi

  # A manual Application syncs when its operation is set; there is no argocd CLI on the path this runs from.
  if ! k -n argocd patch application "$SERVE_APP" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"eks-gitops-runbook"},"sync":{"revision":"main"}}}' >>"$EXDIR/run.log" 2>&1; then
    bad "could not request a sync of $SERVE_APP; is it declared in config/argocd and created by the root?"
    return 0
  fi
  local deadline=$((SECONDS + WAIT_SERVE_SYNC)) sync="" phase=""
  while ((SECONDS < deadline)); do
    sync="$(k -n argocd get application "$SERVE_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    phase="$(k -n argocd get application "$SERVE_APP" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    [[ "$sync" == Synced && "$phase" == Succeeded ]] && break
    [[ "$phase" == Failed || "$phase" == Error ]] && break
    sleep 5
  done
  k -n argocd get application "$SERVE_APP" -o json >"$EXDIR/serving-application.json" 2>/dev/null || true
  if [[ "$sync" != Synced || "$phase" != Succeeded ]]; then
    bad "$SERVE_APP did not sync within ${WAIT_SERVE_SYNC}s (sync=${sync:-?} operation=${phase:-?}); see serving-application.json"
    return 0
  fi
  ok "$SERVE_APP synced at $(k -n argocd get application "$SERVE_APP" -o jsonpath='{.status.sync.revision}' 2>/dev/null)"
}

# admission_state prints "<mode> <observedGeneration> <generation>" for the serving InferenceDeployment.
admission_state() {
  k -n "$SERVE_NS" get inferencedeployment "$SERVE_INFD" \
    -o jsonpath='{.status.admission.mode} {.status.admission.observedGeneration} {.metadata.generation}' 2>/dev/null
}

holdcap_in_force() {
  local m g gen
  read -r m g gen <<<"$(admission_state)"
  [[ "$m" == HoldCap && -n "$gen" && "$g" == "$gen" ]]
}

serve_ready() {
  say "context: $CONTEXT"
  local deadline=$((SECONDS + WAIT_SERVE_READY)) t0=$SECONDS
  until holdcap_in_force; do
    if ((SECONDS >= deadline)); then
      k -n "$SERVE_NS" get inferencedeployment "$SERVE_INFD" -o yaml >"$EXDIR/infd-not-ready.yaml" 2>&1 || true
      k -n "$SERVE_NS" get pods -o wide >"$EXDIR/pods-not-ready.txt" 2>&1 || true
      k -n "$SERVE_NS" get events --sort-by=.lastTimestamp >"$EXDIR/events-not-ready.txt" 2>&1 || true
      bad "status did not report HoldCap for the current generation within ${WAIT_SERVE_READY}s ($(admission_state)); see infd-not-ready.yaml"
      return 0
    fi
    sleep 10
  done
  ok "HoldCap in force for generation $(admission_state | cut -d' ' -f3), $((SECONDS - t0))s after this step began"

  # The evidence S2 and S3 are judged on: which node, and what the engine says it was started with.
  local pod node
  pod="$(k -n "$SERVE_NS" get pod -l "app.kubernetes.io/instance=$SERVE_INFD" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || pod="$(k -n "$SERVE_NS" get pod -o name 2>/dev/null | head -1 | cut -d/ -f2)"
  node="$(k -n "$SERVE_NS" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  k -n "$SERVE_NS" get inferencedeployment "$SERVE_INFD" -o json >"$EXDIR/holdcap-infd.json" 2>/dev/null || true
  k -n "$SERVE_NS" get pod "$pod" -o json >"$EXDIR/engine-pod.json" 2>/dev/null || true
  k get node "$node" -o json >"$EXDIR/engine-node.json" 2>/dev/null || true
  k -n "$SERVE_NS" logs "$pod" 2>/dev/null | grep -m1 'non-default args' >"$EXDIR/args-holdcap.txt" || true
  k -n argocd get applications.argoproj.io -o custom-columns='NAME:.metadata.name,REVISION:.status.sync.revision,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    >"$EXDIR/application-revisions.txt" 2>&1 || true
  k get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{" "}{end}{"\n"}{end}' 2>/dev/null |
    grep -E 'gateway|controller-manager|'"$SERVE_NS"'/' >"$EXDIR/running-image-digests.txt" || true

  local itype ng
  itype="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["labels"].get("node.kubernetes.io/instance-type",""))' "$EXDIR/engine-node.json" 2>/dev/null || true)"
  ng="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["labels"].get("eks.amazonaws.com/nodegroup",""))' "$EXDIR/engine-node.json" 2>/dev/null || true)"
  say "   engine pod $pod on node $node (instance type ${itype:-?}, node group ${ng:-?})"
  if [[ ! -s "$EXDIR/args-holdcap.txt" ]]; then
    bad "the engine's log carries no 'non-default args' line, so S3 cannot be judged"
  elif python3 "$REPO/hack/holdcap-conformance/check-engine-args.py" "$EXDIR/args-holdcap.txt" 384 "$SERVE_MODEL" \
    >"$EXDIR/args-check.txt" 2>&1; then
    ok "the engine runs the measured arguments with the cap (args-check.txt)"
  else
    bad "the engine's arguments do not match the measured set with the cap; see args-check.txt"
  fi
}

# send_request sends one streaming completion as serve-a and judges it by the bench reader's rules: every frame
# well-formed, non-empty content, no in-band engine error, and a final [DONE]. A 200 with [DONE] alone is not
# enough, because the engine can stream an error object and still end the stream cleanly
# (internal/bench/stream_termination_test.go). Prints nothing; returns 0 only when every rule holds.
send_request() {
  local tag="$1" key
  key="$(serve_key)"
  [[ -n "$key" ]] || { echo "no serve key; run serve-sync" >"$EXDIR/request-$tag.verdict"; return 1; }
  curl -sN --max-time 300 -D "$EXDIR/request-$tag.headers" -o "$EXDIR/request-$tag.body" \
    -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $key" \
    -d "{\"model\":\"$SERVE_MODEL\",\"stream\":true,\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Name three colours.\"}]}" \
    "http://127.0.0.1:$GW_API_PORT/v1/chat/completions" >"$EXDIR/request-$tag.code" 2>/dev/null || true
  python3 - "$EXDIR/request-$tag" "$SERVE_EXPECTED_PRIORITY" >"$EXDIR/request-$tag.verdict" 2>&1 <<'PY'
import json, sys
base, want_priority = sys.argv[1], sys.argv[2]
code = open(base + ".code").read().strip()
if code != "200":
    sys.exit(f"status {code}, not 200")
headers = {}
for line in open(base + ".headers", errors="replace"):
    if ":" in line:
        k, v = line.split(":", 1)
        headers[k.strip().lower()] = v.strip()
got = headers.get("x-engine-priority")
if got != want_priority:
    sys.exit(f"X-Engine-Priority is {got!r}, want {want_priority!r}: the request was not bound as under HoldCap")
frames = [l[len("data:"):].strip() for l in open(base + ".body", errors="replace") if l.startswith("data:")]
if not frames or frames[-1] != "[DONE]":
    sys.exit(f"the stream did not end with [DONE] ({len(frames)} frames)")
content = []
for i, f in enumerate(frames[:-1]):
    try:
        obj = json.loads(f)
    except ValueError:
        sys.exit(f"frame {i} is not JSON: {f[:120]!r}")
    if "error" in obj:
        sys.exit(f"frame {i} carries an in-band engine error: {f[:200]!r}")
    for c in obj.get("choices", []):
        content.append((c.get("delta") or {}).get("content") or "")
if not "".join(content).strip():
    sys.exit("the stream carried no content")
print(f"ok: 200, X-Engine-Priority {got}, {len(frames) - 1} frames, {len(''.join(content))} characters")
PY
}

serve_request() {
  say "context: $CONTEXT"
  if ! gw_forward; then
    gw_unforward
    bad "could not port-forward to the gateway; the request proves nothing either way"
    return 0
  fi
  if send_request first; then
    ok "served: $(cat "$EXDIR/request-first.verdict")"
  else
    bad "the request was not served as S4 requires: $(tail -1 "$EXDIR/request-first.verdict")"
  fi
  gw_unforward
}

serve_recover() {
  say "context: $CONTEXT"
  local pod t_del t_off="" t_back=""
  pod="$(k -n "$SERVE_NS" get pod -o name 2>/dev/null | head -1)"
  [[ -n "$pod" ]] || { bad "no engine Pod in $SERVE_NS to delete"; return 0; }
  holdcap_in_force || { bad "HoldCap is not in force before the deletion, so recovery has nothing to show"; return 0; }
  t_del=$SECONDS
  k -n "$SERVE_NS" delete "$pod" --wait=false >>"$EXDIR/run.log" 2>&1 || { bad "could not delete $pod"; return 0; }
  local deadline=$((SECONDS + WAIT_SERVE_RECOVER))
  while ((SECONDS < deadline)); do
    if [[ -z "$t_off" ]]; then
      holdcap_in_force || t_off=$SECONDS
    elif holdcap_in_force; then
      t_back=$SECONDS
      break
    fi
    sleep 2
  done
  {
    echo "deleted         t=0"
    echo "left HoldCap    t=${t_off:+$((t_off - t_del))}s"
    echo "HoldCap again   t=${t_back:+$((t_back - t_del))}s"
  } >"$EXDIR/recover-timeline.txt"
  [[ -n "$t_off" ]] || { bad "status never left HoldCap after its engine Pod was deleted (recover-timeline.txt)"; return 0; }
  [[ -n "$t_back" ]] || { bad "status did not return to HoldCap within ${WAIT_SERVE_RECOVER}s (recover-timeline.txt)"; return 0; }
  ok "status left HoldCap $((t_off - t_del))s after the deletion and returned $((t_back - t_del))s after it"
  if ! gw_forward; then
    gw_unforward
    bad "could not port-forward to the gateway after recovery"
    return 0
  fi
  if send_request recovered; then
    ok "served after recovery: $(cat "$EXDIR/request-recovered.verdict")"
  else
    bad "the request after recovery was not served: $(tail -1 "$EXDIR/request-recovered.verdict")"
  fi
  gw_unforward
}

# serve_rehearse is the kind rehearsal's verdict: what a cluster with no GPU node can show, and only that.
#
# With no node labelled platform.lkhun9311.github.io/gpu=true the engine's affinity matches nothing. Before PR #338
# the webhook refused the Pod outright (FailedCreate); the point of this check is that the Pod now EXISTS, is
# charged against serve-a's ResourceQuota, and is Pending for the affinity, with status Off and the gateway
# answering 502 bad_gateway for a backend with no endpoint.
serve_rehearse() {
  say "context: $CONTEXT"
  local deadline=$((SECONDS + WAIT_SERVE_SYNC)) pod=""
  while ((SECONDS < deadline)); do
    pod="$(k -n "$SERVE_NS" get pod -o name 2>/dev/null | head -1)"
    [[ -n "$pod" ]] && break
    sleep 3
  done
  k -n "$SERVE_NS" get events --sort-by=.lastTimestamp >"$EXDIR/rehearse-events.txt" 2>&1 || true
  if [[ -z "$pod" ]]; then
    if grep -q 'FailedCreate' "$EXDIR/rehearse-events.txt"; then
      bad "the engine Pod was refused at creation (FailedCreate, rehearse-events.txt): the webhook defect #338 fixes is present"
    else
      bad "no engine Pod appeared in $SERVE_NS within ${WAIT_SERVE_SYNC}s (rehearse-events.txt)"
    fi
    return 0
  fi
  ok "the engine Pod was created: $pod"
  sleep 5
  local phase cond used
  phase="$(k -n "$SERVE_NS" get "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
  cond="$(k -n "$SERVE_NS" get "$pod" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null)"
  used="$(k -n "$SERVE_NS" get resourcequota -o jsonpath='{.items[0].status.used.requests\.nvidia\.com/gpu}' 2>/dev/null)"
  say "   phase=$phase used=$used scheduling: $cond"
  [[ "$phase" == Pending && "$cond" == *affinity* ]] && ok "Pending for node affinity, as a cluster with no GPU node must leave it" ||
    bad "expected Pending for node affinity, got phase=$phase ($cond)"
  [[ "$used" == 1 ]] && ok "charged against serve-a's ResourceQuota (requests.nvidia.com/gpu used=1)" ||
    bad "the Pod is not charged against serve-a's ResourceQuota (used=${used:-unreadable})"
  local m
  m="$(admission_state | cut -d' ' -f1)"
  [[ "$m" == Off ]] && ok "status reports Off while no engine is ready" || bad "status reports '${m:-nothing}' with no engine ready"
  if ! gw_forward; then
    gw_unforward
    bad "could not port-forward to the gateway"
    return 0
  fi
  send_request rehearse || true
  gw_unforward
  local code
  code="$(cat "$EXDIR/request-rehearse.code" 2>/dev/null)"
  if [[ "$code" == 502 ]] && grep -q bad_gateway "$EXDIR/request-rehearse.body"; then
    ok "serve-a's request routed to the backend and found no endpoint: 502 bad_gateway"
  else
    bad "expected 502 bad_gateway for a backend with no endpoint, got ${code:-nothing} (request-rehearse.body)"
  fi
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
    apply | seed-key | verify | status | serve-sync | serve-ready | serve-request | serve-recover | serve-rehearse) ;;
    *)
      echo "usage: $0 {apply|seed-key|verify|status|serve-sync|serve-ready|serve-request|serve-recover|serve-rehearse}" >&2
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
  # `seed-key` reads better as a command than `seed_key` does, and `seed_key` is the only legal function
  # name of the two, so the command name is translated here rather than either one being bent to the other.
  "${cmd//-/_}" "$@" || true

  if ((failures > 0)); then
    say "$failures check(s) failed"
    exit 1
  fi
  exit 0
}

main "$@"
