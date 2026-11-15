#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written literally; they expand when the stubs run
# Checks the llm-d KV routing lab's isolation guards with docker, kubectl, curl and git stubbed, so no cluster is needed:
#   1. lab_init refuses a cluster without the lab's owner marker before it arms any cleanup, so nothing is deleted there;
#   2. cleanup removes this run's tagged firewall rules and nothing else, however far insertion or removal got;
#   3. up refuses a dirty router checkout before building anything from it;
#   4. lab_init refuses a kubectl proxy that does not start, rather than using whatever listens on its port.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

mkdir -p "$TMP/bin"
# The docker stub logs every call; asked for the FORWARD chain, it lists this run's two rules, another run's identical
# rule, and an unrelated one.
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "docker $*" >>"$CALLS"' \
  'if [[ "$*" == *"iptables -S FORWARD"* ]]; then' \
  '  echo "-P FORWARD ACCEPT"' \
  '  echo "-A FORWARD -p tcp -m tcp --dport 5557 -m comment --comment ${OWN_TAG:-none} -j DROP"' \
  '  echo "-A FORWARD -p tcp -m tcp --sport 5557 -m comment --comment ${OWN_TAG:-none} -j DROP"' \
  '  echo "-A FORWARD -p tcp -m tcp --dport 5557 -m comment --comment llmd-kv-lab-other-run -j DROP"' \
  '  echo "-A FORWARD -j KUBE-FORWARD"' \
  'fi' >"$TMP/bin/docker"
# The kubectl stub answers ownership as OWNED says, and a proxy started through it exits at once.
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "kubectl $*" >>"$CALLS"' \
  '[ "${OWNED:-0}" = 1 ] || exit 1' >"$TMP/bin/kubectl"
chmod +x "$TMP/bin/docker" "$TMP/bin/kubectl"
export PATH=$TMP/bin:$PATH CALLS=$TMP/calls LAB_HOME=$TMP/home

# 1. No owner marker: lab_init exits, and its exit runs no cleanup against the cluster.
: >"$CALLS"
if (OWNED=0 bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; SAY_AS=test lab_init") 2>/dev/null; then
  bad "lab_init accepted a cluster without the owner marker"
elif grep -q "iptables" "$CALLS"; then
  bad "a refused run still touched the firewall: $(grep iptables "$CALLS")"
else
  ok "lab_init refuses an unowned cluster and touches nothing"
fi

# 2. Cleanup deletes this run's tagged rules and nothing else.
: >"$CALLS"
OWN_TAG=llmd-kv-lab-test-1 bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; FW_TAG=llmd-kv-lab-test-1 PROXY_PID= lab_cleanup" 2>/dev/null
deletes=$(grep "iptables -D" "$CALLS" || true)
if [ "$(grep -c . <<<"$deletes")" = 2 ] && ! grep -q -e other-run -e KUBE <<<"$deletes" \
  && [ "$(grep -c 'llmd-kv-lab-test-1' <<<"$deletes")" = 2 ]; then
  ok "cleanup removed this run's two tagged rules and nothing else"
else
  bad "cleanup deleted: ${deletes:-nothing}"
fi
: >"$CALLS"
# Under the callers' own set -euo pipefail, a run with nothing to remove must still exit 0.
if ! OWN_TAG=absent bash -c "set -euo pipefail; source '$REPO/hack/llmd-kv-lab/lib.sh'; FW_TAG=llmd-kv-lab-test-2 PROXY_PID= lab_cleanup" 2>/dev/null; then
  bad "cleanup with no tagged rule failed under pipefail"
elif grep -q "iptables -D" "$CALLS"; then
  bad "a run that inserted nothing deleted: $(grep 'iptables -D' "$CALLS")"
else
  ok "a run that inserted nothing deletes nothing and exits 0"
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

# 4. The proxy dies at once and nothing answers on its port: lab_init must stop, not carry on.
printf '%s\n' '#!/usr/bin/env bash' 'exit 7' >"$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
if (OWNED=1 STAMP=guard PROXY_PORT=1 bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; RUN='$TMP/run'; SAY_AS=test lab_init") >/dev/null 2>&1; then
  bad "lab_init returned with a proxy that never reached the cluster"
else
  ok "lab_init refuses a proxy that does not start"
fi

# 5. The PID cleanup stops is kubectl's own, not a wrapper's: the stub proxy stays up until killed.
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TMP/bin/curl"
printf '%s\n' '#!/usr/bin/env bash' 'echo "kubectl $*" >>"$CALLS"' \
  'case "$*" in *" proxy "*) exec sleep 30 ;; esac' '[ "${OWNED:-0}" = 1 ] || exit 1' >"$TMP/bin/kubectl"
args=$(OWNED=1 STAMP=guard2 bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; RUN='$TMP/run2'; SAY_AS=test lab_init >/dev/null 2>&1; ps -o args= -p \"\$PROXY_PID\"; trap - EXIT; kill \"\$PROXY_PID\"" 2>/dev/null || true)
if grep -q "sleep 30" <<<"$args"; then
  ok "PROXY_PID is the proxy process itself"
else
  bad "PROXY_PID is not the proxy process: '$args'"
fi

[ "$fail" = 0 ] && echo "check-llmd-kv-lab-guards: all checks passed"
exit "$fail"
