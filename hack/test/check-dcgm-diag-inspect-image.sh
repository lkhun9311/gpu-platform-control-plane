#!/usr/bin/env bash
#
# Runs hack/dcgm-diag-inspect-image.sh against stub curl and docker, with no registry, no Docker daemon and no GPU.
#
#   bash hack/test/check-dcgm-diag-inspect-image.sh
#
# What it pins (astra review r3, finding 10): the archived index-platforms.exit carries the platform check's own status,
# so an index that does not list the platform run records exit=1, and one that does records exit=0.
# The stubs make every later step fail too, which is fine: only the platform step's record is asserted here.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# curl: a token for proxy_auth, and for a manifest the index in $STUB_INDEX, with its sha256 as the registry's digest.
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env python3
import hashlib, sys
args = sys.argv[1:]
url = args[-1]
if "proxy_auth" in url:
    print('{"token": "t"}')
    sys.exit(0)
body = open(__import__("os").environ["STUB_INDEX"], "rb").read()
out = args[args.index("-o") + 1]
hdr = args[args.index("-D") + 1]
open(out, "wb").write(body)
open(hdr, "w").write("HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%s\r\n\r\n" % hashlib.sha256(body).hexdigest())
EOF
# docker: the pull and inspect succeed and name linux/amd64; anything else fails, which only later steps read.
cat >"$work/bin/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "pull -q") exit 0 ;;
  "image inspect") echo "ref=x@sha256:0 image_id=sha256:1 platform=linux/amd64 size_bytes=1 created=2026-01-01 entrypoint=null cmd=null"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$work/bin/"*

index() {
  python3 - "$1" "$2" <<'PY'
import json, sys
arch = sys.argv[2]
json.dump({"manifests": [{"digest": "sha256:" + "a" * 64, "platform": {"os": "linux", "architecture": arch}}]}, open(sys.argv[1], "w"))
PY
}

case_run() {
  local name=$1 arch=$2 want=$3 digest
  index "$work/$name.json" "$arch"
  digest="sha256:$(sha256sum "$work/$name.json" | cut -d' ' -f1)"
  env PATH="$work/bin:$PATH" STUB_INDEX="$work/$name.json" OUT="$work/out-$name" EXPECT_339="$digest" EXPECT_442="$digest" \
    bash hack/dcgm-diag-inspect-image.sh >"$work/$name.log" 2>&1
  local rc=$? got
  got=$(cat "$work/out-$name/3.3.9/index-platforms.exit")
  [ "$got" = "exit=$want" ] && ok "$name: index-platforms.exit says $got" || bad "$name: index-platforms.exit says '$got', want exit=$want"
  [ "$rc" != 0 ] && ok "$name: the inspection exits $rc" || bad "$name: the inspection exited 0 with stub images"
}
case_run "an index without the platform run" arm64 1
grep -q "the index does not list the platform run" "$work/an index without the platform run.log" &&
  ok "the mismatch is reported as a failed step" || bad "no failed-step line for the platform mismatch"
case_run "an index listing the platform run" amd64 0

if [[ $fails -ne 0 ]]; then
  echo "check-dcgm-diag-inspect-image: $fails failure(s)"
  exit 1
fi
echo "check-dcgm-diag-inspect-image: all checks passed"
