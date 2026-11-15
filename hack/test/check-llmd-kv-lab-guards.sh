#!/usr/bin/env bash
# Checks the llm-d KV routing lab's two isolation guards with docker, kubectl and git stubbed, so no cluster is needed:
#   1. lab_init refuses a cluster without the lab's owner marker before it arms any cleanup, so nothing is deleted there;
#   2. lab_cleanup removes only the firewall rules the run inserted, one deletion per insertion;
#   3. up refuses a dirty router checkout before building anything from it.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$CALLS"
EOF
cat >"$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
[ "${OWNED:-0}" = 1 ] || exit 1
EOF
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

# 2. Cleanup deletes exactly what was inserted.
for inserted in 0 2; do
  : >"$CALLS"
  bash -c "source '$REPO/hack/llmd-kv-lab/lib.sh'; PROXY_PID= FW_INSERTED=$inserted lab_cleanup" 2>/dev/null
  got=$(grep -c "iptables -D" "$CALLS" || true)
  if [ "$got" = $((inserted * 2)) ]; then
    ok "cleanup after $inserted insertion(s) deleted $got rule(s)"
  else
    bad "cleanup after $inserted insertion(s) deleted $got rule(s), want $((inserted * 2))"
  fi
done

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

[ "$fail" = 0 ] && echo "check-llmd-kv-lab-guards: all checks passed"
exit "$fail"
