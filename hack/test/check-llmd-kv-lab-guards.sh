#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written literally; they expand when the stubs run
# Checks the llm-d KV routing lab's isolation guards with docker, kubectl, curl and git stubbed, so no cluster is needed:
#   1. lab_init refuses a cluster without the lab's owner marker before it arms any cleanup, so nothing is deleted there;
#   2. cleanup removes this run's tagged firewall rules and nothing else, exits 0 when none is left, and fails when one
#      stays or the chain cannot be read;
#   3. up refuses a dirty router checkout before building anything from it;
#   4. lab_init refuses a kubectl proxy that does not start, or one that never says it serves on the port;
#   5. the PID cleanup stops is the proxy's own;
#   6. a reused STAMP is refused before any of its recorded files is written, and a reused arm before anything restarts.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

mkdir -p "$TMP/bin"
# The docker stub logs every call and keeps the node's FORWARD chain in a file: -S lists it, -D removes the matching
# line unless STUCK=1 (a deletion that does not take), and UNREADABLE=1 makes -S fail.
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "docker $*" >>"$CALLS"' \
  'args="$*"' \
  'case "$args" in' \
  '  *"iptables -w -S FORWARD"*) [ "${UNREADABLE:-0}" = 1 ] && exit 4; cat "$CHAIN" ;;' \
  '  *"iptables -w -D "*) [ "${STUCK:-0}" = 1 ] && exit 0; rule="-A ${args#*iptables -w -D }"; grep -vxF -- "$rule" "$CHAIN" >"$CHAIN.new" || true; mv "$CHAIN.new" "$CHAIN" ;;' \
  '  *"crictl images"*) echo "IMAGE TAG IMAGE-ID SIZE"; echo "${NODE_IMAGE_LINE:-}" ;;' \
  'esac' >"$TMP/bin/docker"
# The kubectl stub answers ownership as OWNED says; a proxy prints its serving line when SERVE_LINE=1 and stays up.
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "kubectl $*" >>"$CALLS"' \
  'port=; for a in "$@"; do case "$a" in --port=*) port=${a#--port=} ;; esac; done' \
  'case "$*" in *" proxy "*) [ "${SERVE_LINE:-1}" = 1 ] && echo "Starting to serve on 127.0.0.1:${port}"; exec sleep 30 ;; esac' \
  'case "$*" in *"get deployment"*"jsonpath"*) echo "${SPEC_IMAGE:-}"; exit 0 ;; *"get deployment"*"go-template"*) echo "app=x,"; exit 0 ;; *"get pods"*) printf "%s\\n" ${POD_IDS:-}; exit 0 ;; esac' \
  '[ "${OWNED:-0}" = 1 ] || exit 1' >"$TMP/bin/kubectl"
printf '%s\n' '#!/usr/bin/env bash' 'exit "${CURL_EXIT:-7}"' >"$TMP/bin/curl"
chmod +x "$TMP/bin/docker" "$TMP/bin/kubectl" "$TMP/bin/curl"
export PATH=$TMP/bin:$PATH CALLS=$TMP/calls CHAIN=$TMP/chain LAB_HOME=$TMP/home

# chain_with writes a FORWARD chain holding this run's two rules (when given a tag), another run's identical rule and an
# unrelated one.
chain_with() {
  {
    echo "-P FORWARD ACCEPT"
    if [ -n "$1" ]; then
      echo "-A FORWARD -p tcp -m tcp --dport 5557 -m comment --comment $1 -j DROP"
      echo "-A FORWARD -p tcp -m tcp --sport 5557 -m comment --comment $1 -j DROP"
    fi
    echo "-A FORWARD -p tcp -m tcp --dport 5557 -m comment --comment llmd-kv-lab-other-run -j DROP"
    echo "-A FORWARD -j KUBE-FORWARD"
  } >"$CHAIN"
}
cleanup_as() { bash -c "set -euo pipefail; source '$REPO/hack/llmd-kv-lab/lib.sh'; FW_TAG=$1 PROXY_PID= lab_cleanup" 2>/dev/null; }

# 1. No owner marker: lab_init exits, and its exit runs no cleanup against the cluster.
: >"$CALLS"
if (OWNED=0 bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; SAY_AS=test lab_init") 2>/dev/null; then
  bad "lab_init accepted a cluster without the owner marker"
elif grep -q "iptables" "$CALLS"; then
  bad "a refused run still touched the firewall: $(grep iptables "$CALLS")"
else
  ok "lab_init refuses an unowned cluster and touches nothing"
fi

# 2. Cleanup removes this run's tagged rules and nothing else, under the callers' own set -euo pipefail.
chain_with llmd-kv-lab-test-1
: >"$CALLS"
if cleanup_as llmd-kv-lab-test-1 && ! grep -q test-1 "$CHAIN" && grep -q other-run "$CHAIN" && grep -q KUBE "$CHAIN" \
  && [ "$(grep -c 'iptables -w -D' "$CALLS")" = 2 ]; then
  ok "cleanup removed this run's two tagged rules and nothing else"
else
  bad "cleanup left: $(cat "$CHAIN") after: $(grep 'iptables' "$CALLS")"
fi
chain_with ""
: >"$CALLS"
if ! cleanup_as llmd-kv-lab-test-2; then
  bad "cleanup with no tagged rule failed"
elif grep -q "iptables -w -D" "$CALLS"; then
  bad "a run that inserted nothing deleted: $(grep 'iptables -w -D' "$CALLS")"
else
  ok "a run that inserted nothing deletes nothing and exits 0"
fi
chain_with llmd-kv-lab-test-3
if STUCK=1 cleanup_as llmd-kv-lab-test-3; then
  bad "cleanup reported success with its DROP rules still installed"
else
  ok "cleanup fails when a tagged rule stays"
fi
if UNREADABLE=1 cleanup_as llmd-kv-lab-test-3; then
  bad "cleanup reported success without reading the chain"
else
  ok "cleanup fails when the chain cannot be read"
fi

# 3. A dirty checkout is refused before prepare_images builds anything.
CHECKOUT=$TMP/home/llm-d-router
mkdir -p "$CHECKOUT"
git -C "$CHECKOUT" init -q
git -C "$CHECKOUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo dirty >"$CHECKOUT/untracked"
: >"$CALLS"
out=$(bash -c "source '$REPO/hack/llmd-kv-lab.sh'; CHECKOUT='$CHECKOUT'; fetch_checkout() { :; }; cmd_up precise" 2>&1 || true)
if grep -q "docker build" "$CALLS"; then
  bad "an image was built from a dirty checkout"
elif grep -q "nothing was built" <<<"$out"; then
  ok "up refuses a dirty checkout before building"
else
  bad "up did not refuse a dirty checkout: $out"
fi

# 4. A proxy that never answers, and one that never says it serves while something else answers, both end the run.
init_as() { (OWNED=1 STAMP=$1 bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; RUN='$TMP/$1'; SAY_AS=test lab_init") >/dev/null 2>&1; }
if CURL_EXIT=7 init_as guard-a; then
  bad "lab_init returned with a proxy that never reached the cluster"
else
  ok "lab_init refuses a proxy that does not answer"
fi
if CURL_EXIT=0 SERVE_LINE=0 PROXY_PORT=18999 init_as guard-b; then
  bad "lab_init accepted an answer while its own proxy never said it serves on the port"
else
  ok "lab_init refuses an answer from a listener it cannot show is its own"
fi

# 5. The PID cleanup stops is the proxy process itself: the stub proxy stays up until killed.
args=$(OWNED=1 CURL_EXIT=0 STAMP=guard-c bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; RUN='$TMP/guard-c'; SAY_AS=test lab_init >/dev/null 2>&1; ps -o args= -p \"\$PROXY_PID\"; trap - EXIT; kill \"\$PROXY_PID\"" 2>/dev/null || true)
if grep -q "sleep 30" <<<"$args"; then
  ok "PROXY_PID is the proxy process itself"
else
  bad "PROXY_PID is not the proxy process: '$args'"
fi

# 6. A reused STAMP leaves the recorded run untouched; a reused arm is refused before anything restarts.
mkdir -p "$TMP/guard-d"
echo original >"$TMP/guard-d/pins.txt"
if (OWNED=1 CURL_EXIT=0 STAMP=guard-d bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; RUN='$TMP/guard-d'; SAY_AS=test lab_init") >/dev/null 2>&1; then
  bad "lab_init reused an existing run directory"
elif [ "$(cat "$TMP/guard-d/pins.txt")" != original ] || [ -e "$TMP/guard-d/kubectl-proxy.log" ]; then
  bad "a refused run still wrote into the recorded one"
else
  ok "a reused STAMP is refused before anything in it is written"
fi
mkdir -p "$TMP/run3/precise"
: >"$CALLS"
if (bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; RUN='$TMP/run3'; SAY_AS=test fresh_arm precise") >/dev/null 2>&1; then
  bad "fresh_arm reused an existing arm directory"
elif grep -q -e "kubectl" -e "docker" "$CALLS"; then
  bad "a refused arm still touched the cluster: $(cat "$CALLS")"
else
  ok "a reused arm directory is refused before anything restarts"
fi

# 7. A Deployment runs the pinned image only if its template names it and every pod runs the node's image for that tag.
image_ok() { (OWNED=1 bash -c "source '$REPO/hack/llmd-kv-lab.sh'; deploy_image_ok vllm-d ghcr.io/x/sim:v1") >/dev/null 2>&1; }
line="ghcr.io/x/sim v1 sha256:aaa 10MB"
if SPEC_IMAGE=ghcr.io/x/sim:v1 NODE_IMAGE_LINE=$line POD_IDS="sha256:aaa sha256:aaa" image_ok; then
  ok "a deployment on its pinned image passes"
else
  bad "a deployment on its pinned image was refused"
fi
if SPEC_IMAGE=ghcr.io/x/sim:v2 NODE_IMAGE_LINE=$line POD_IDS="sha256:aaa" image_ok; then
  bad "a deployment whose template names another image passed"
else
  ok "a deployment edited to another image is refused"
fi
if SPEC_IMAGE=ghcr.io/x/sim:v1 NODE_IMAGE_LINE=$line POD_IDS="sha256:aaa sha256:bbb" image_ok; then
  bad "a pod running another image passed"
else
  ok "a pod running another image than the node's is refused"
fi

[ "$fail" = 0 ] && echo "check-llmd-kv-lab-guards: all checks passed"
exit "$fail"
