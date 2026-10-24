#!/usr/bin/env bash
# Pins the MPS overlay's wiring to the device plugin's own contract at the pinned tag, v0.16.2, read from its source.
#
# Run 1 of 2026-10-24 bought a card for an overlay that passed every check and could not work: the plugin's
# --mps-root was /mps, the plugin takes that flag as a HOST path (internal/plugin/server.go:89-90), and so both engines
# were handed the node's empty /mps/nvidia.com/gpu/pipe. Nothing read the rendered overlay against that contract.
# This renders it and checks, without a cluster:
#   - the plugin's --mps-root equals the hostPath both DaemonSets mount at /mps;
#   - the daemon runs `mps-control-daemon mount-shm` first, privileged, with /mps propagated Bidirectionally;
#   - the daemon and the plugin both mount <root>/shm at /dev/shm, as the chart at the same tag does.
# With a directory argument it checks that overlay instead, which is how a mutation is shown to fail.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${1:-$ROOT/config/nvidia-device-plugin-mps}"

if [ -n "${KUSTOMIZE:-}" ]; then render=("$KUSTOMIZE" build)
elif [ -x "$ROOT/bin/kustomize" ]; then render=("$ROOT/bin/kustomize" build)
elif command -v kubectl >/dev/null; then render=(kubectl kustomize)
else echo "check-mps-overlay: no kustomize and no kubectl, so nothing was checked" >&2; exit 1
fi
out="$(mktemp)"; trap 'rm -f "$out" "$out.err"' EXIT
"${render[@]}" "$DIR" >"$out" 2>"$out.err" || { echo "check-mps-overlay: rendering $DIR failed: $(tail -5 "$out.err")" >&2; exit 1; }

python3 - "$out" <<'PY'
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
fails, oks = [], []
def check(cond, what):
    (oks if cond else fails).append(what)

def daemonset(component):
    for d in docs:
        if d.get("kind") == "DaemonSet" and d["spec"]["template"]["metadata"]["labels"].get("app.kubernetes.io/component") == component:
            return d["spec"]["template"]["spec"]
    return None

def host_path(spec, volume):
    for v in spec.get("volumes", []):
        if v["name"] == volume:
            return (v.get("hostPath") or {}).get("path")
    return None

def mount_at(container, spec, path):
    # The hostPath of the volume this container mounts at path, or None.
    for m in container.get("volumeMounts", []):
        if m["mountPath"] == path:
            return host_path(spec, m["name"]), m
    return None, None

daemon = daemonset("nvidia-mps-control-daemon")
plugin = daemonset("nvidia-device-plugin-mps-plugin")
check(daemon is not None, "the control daemon's DaemonSet is rendered")
check(plugin is not None, "the plugin's DaemonSet is rendered")
if daemon is None or plugin is None:
    print("\n".join("FAIL: " + f for f in fails)); sys.exit(1)

d_main = next(c for c in daemon["containers"] if c["name"] == "mps-control-daemon")
p_main = next(c for c in plugin["containers"] if c["name"] == "nvidia-device-plugin")
d_root, _ = mount_at(d_main, daemon, "/mps")
p_root, _ = mount_at(p_main, plugin, "/mps")
check(d_root is not None and d_root == p_root, f"the daemon and the plugin mount one host root at /mps ({d_root}, {p_root})")

flags = [a.split("=", 1)[1] for a in p_main.get("args", []) if a.startswith("--mps-root=")]
for e in p_main.get("env", []):
    if e["name"] == "MPS_ROOT":
        flags.append(e.get("value"))
check(len(flags) == 1, f"the plugin is given its MPS root exactly once ({flags})")
check(flags == [p_root], f"the plugin's MPS root is the host path it mounts at /mps, as server.go:90 uses it ({flags} against {p_root})")

inits = [c for c in daemon.get("initContainers", []) if c.get("command") == ["mps-control-daemon", "mount-shm"]]
check(len(inits) == 1, "the daemon runs mps-control-daemon mount-shm before it starts")
if inits:
    init = inits[0]
    i_root, m = mount_at(init, daemon, "/mps")
    check(i_root == d_root and m and m.get("mountPropagation") == "Bidirectional",
          "mount-shm sees the same root at /mps with Bidirectional propagation, so its tmpfs reaches the node")
    check((init.get("securityContext") or {}).get("privileged") is True, "mount-shm runs privileged, as Bidirectional requires")
    check(daemon["initContainers"][0] is init, "mount-shm is the first init container")

for name, c, spec in (("daemon", d_main, daemon), ("plugin", p_main, plugin)):
    shm, _ = mount_at(c, spec, "/dev/shm")
    check(d_root is not None and shm == d_root.rstrip("/") + "/shm",
          f"the {name} mounts <root>/shm at /dev/shm, the directory server.go hands every client ({shm})")

for o in oks:
    print("ok: " + o)
for f in fails:
    print("FAIL: " + f)
sys.exit(1 if fails else 0)
PY
rc=$?
[ "$rc" = 0 ] && echo "check-mps-overlay: all checks passed" || echo "check-mps-overlay: FAILED" >&2
exit "$rc"
