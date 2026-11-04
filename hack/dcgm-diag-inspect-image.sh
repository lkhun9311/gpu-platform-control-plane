#!/usr/bin/env bash
# The free step of the DCGM diagnostic registration (docs/superpowers/specs/2026-11-04-dcgm-diag-runbook-design.md):
# read the candidate diagnostic images on a machine with no GPU, and archive what they show.
#
#   bash hack/dcgm-diag-inspect-image.sh            # writes hack/dcgm-diag/<UTC date>-image-inspection/
#
# Everything here runs with --network none and no GPU, so it can settle only what the image's own files and its
# behaviour without a device show; what a card's real output would show is left to the paid session.
# Every command's stdout and stderr are kept apart, because which stream a message lands on is itself a finding.
# It exits non-zero if any inspection step fails, so a partial archive is never mistaken for a complete one.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# version, tag, and the index digest the registration pins for that tag.
# EXPECT_<version> overrides one, which is how the digest check is shown to fail.
IMAGES=(
  "3.3.9 nvcr.io/nvidia/cloud-native/dcgm:3.3.9-1-ubuntu22.04 ${EXPECT_339:-sha256:9cce4b88361d634bfff830b68b4f24a0a39b3c7004447e917bf85fa01804b24f}"
  "4.4.2 nvcr.io/nvidia/cloud-native/dcgm:4.4.2-1-ubuntu22.04 ${EXPECT_442:-sha256:becae9b24707d2bdfce87cb72626e24b2fbfbca812329ca52540ad0e0d955717}"
)
OUT=${OUT:-hack/dcgm-diag/$(date -u +%Y-%m-%d)-image-inspection}
# A fresh directory only: files left from an earlier run would otherwise sit beside this run's as if it wrote them.
if [ -e "$OUT" ]; then
  echo "INSPECTION REFUSED: $OUT already exists; move it aside or set OUT"
  exit 2
fi
mkdir -p "$OUT"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() {
  echo "INSPECTION STEP FAILED: $*"
  failed=1
}

for entry in "${IMAGES[@]}"; do
  read -r ver tag expect <<<"$entry"
  d="$OUT/$ver"
  mkdir -p "$d"
  repo=${tag%%:*}
  path=${repo#nvcr.io/}

  # The index exactly as the registry serves it: its raw bytes must hash to the pinned digest, and so must the
  # registry's own digest header, before anything is run.
  token=$(curl -fsS "https://nvcr.io/proxy_auth?scope=repository:$path:pull" | python3 -c 'import sys, json; print(json.load(sys.stdin)["token"])') ||
    { fail "$ver: no registry token"; continue; }
  curl -fsS -D "$d/index.headers" -o "$d/index.json" -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://nvcr.io/v2/$path/manifests/${tag##*:}" 2>"$d/index.err"
  echo "exit=$?" >"$d/index.exit"
  got="sha256:$(sha256sum "$d/index.json" | cut -d' ' -f1)"
  header=$(tr -d '\r' <"$d/index.headers" | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
  echo "$got" >"$d/index.sha256"
  if [ "$got" != "$expect" ] || [ "$header" != "$expect" ]; then
    fail "$ver: the tag's index hashes to $got and the registry says $header, not the pinned $expect"
    continue
  fi

  # Everything below runs the pinned index digest, not the tag, so what is inspected is what the digest names.
  ref="$repo@$expect"
  docker pull -q "$ref" >"$d/pull.out" 2>"$d/pull.err"
  echo "exit=$?" >"$d/pull.exit"
  grep -qx 'exit=0' "$d/pull.exit" || { fail "$ver: pull of $ref: $(tail -1 "$d/pull.err")"; continue; }
  docker image inspect "$ref" --format 'ref={{index .RepoDigests 0}} image_id={{.Id}} platform={{.Os}}/{{.Architecture}} size_bytes={{.Size}} created={{.Created}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}}' >"$d/image.txt" 2>"$d/image.err"
  echo "exit=$?" >"$d/image.exit"
  grep -qx 'exit=0' "$d/image.exit" || fail "$ver: image inspect"
  # The platform this machine resolved must be one the index lists, so the archive ties the pin to the bytes run.
  platform=$(sed -n 's/.* platform=\([^ ]*\) .*/\1/p' "$d/image.txt")
  python3 - "$d/index.json" "$platform" >"$d/index-platforms.txt" 2>&1 <<'PY' || fail "$ver: the index does not list the platform run"
import json, sys
index = json.load(open(sys.argv[1]))
want_os, want_arch = sys.argv[2].split("/")
found = False
for m in index["manifests"]:
    p = m.get("platform", {})
    print(m["digest"], p.get("os"), p.get("architecture"))
    found = found or (p.get("os"), p.get("architecture")) == (want_os, want_arch)
sys.exit(0 if found else 1)
PY

  # run NAME SCRIPT: one command in the image, its streams and exit status in three files; it must exit 0.
  run() {
    docker run --rm --network none --entrypoint sh "$ref" -c "$2" >"$d/$1.out" 2>"$d/$1.err"
    local rc=$?
    echo "exit=$rc" >"$d/$1.exit"
    [ "$rc" = 0 ] || fail "$ver: $1 exited $rc"
  }
  # probe NAME SCRIPT: the same, for a command that is expected to fail without a GPU; its exit status is the finding.
  probe() {
    docker run --rm --network none --entrypoint sh "$ref" -c "$2" >"$d/$1.out" 2>"$d/$1.err"
    echo "exit=$?" >"$d/$1.exit"
  }
  run version 'dcgmi --version'
  run diag-help 'dcgmi diag --help'
  run packages 'dpkg -l | grep -iE "datacenter-gpu-manager|dcgm"'
  # The executables and the diagnostic's plugin libraries, each with its path and hash.
  # Each version keeps nvvs in one of two places; the step fails only if neither holds it.
  run executables 'n=0; for f in /usr/bin/dcgmi /usr/bin/nv-hostengine /usr/share/nvidia-validation-suite/nvvs /usr/libexec/datacenter-gpu-manager-4/nvvs; do if [ -e "$f" ]; then sha256sum "$f" || exit 1; n=$((n+1)); fi; done; [ "$n" = 3 ]'
  run plugins 'n=0; for p in /usr/share/nvidia-validation-suite/plugins /usr/libexec/datacenter-gpu-manager-4/plugins; do if [ -d "$p" ]; then find "$p" -maxdepth 2 -name "lib*.so.[0-9]*.[0-9]*.[0-9]*" | sort | xargs sha256sum || exit 1; n=$((n+1)); fi; done; [ "$n" = 1 ]'
  # What a session's commands need from the image itself.
  run tools 'id; for t in tar timeout pgrep ps sha256sum; do printf "%s " "$t"; command -v "$t" || exit 1; done'
  # How dcgmi reaches a host engine with none running, by default and with --host naming a socket that does not
  # exist, with and without an explicit GPU entity; and discovery, which needs an engine.
  probe diag-default 'timeout 60 dcgmi diag -r 1 -j'
  probe diag-badhost 'timeout 60 dcgmi diag --host unix:///tmp/none.sock -r 1 -j'
  probe diag-badhost-gpu0 'timeout 60 dcgmi diag --host unix:///tmp/none.sock -i gpu:0 -r 1 -j'
  probe discovery-badhost 'timeout 30 dcgmi discovery --host unix:///tmp/none.sock -l'
  probe discovery-default 'timeout 30 dcgmi discovery -l'
  # The image's own nvidia-smi, if any: without one, the GPU check in a container depends on the runtime injecting it.
  probe nvidia-smi-in-image 'command -v nvidia-smi'
  # Strings of the binaries, for what their output can carry: the plugin directories nvvs knows, its message for a
  # CUDA version it has no plugins for, and the lower-case keys dcgmi's JSON writer is built from.
  c=$(docker create "$ref") || { fail "$ver: create for copying binaries"; continue; }
  nvvs=/usr/share/nvidia-validation-suite/nvvs
  [ "$ver" = 3.3.9 ] || nvvs=/usr/libexec/datacenter-gpu-manager-4/nvvs
  docker cp "$c:/usr/bin/dcgmi" "$work/dcgmi-$ver" >/dev/null || fail "$ver: copy dcgmi"
  docker cp "$c:$nvvs" "$work/nvvs-$ver" >/dev/null || fail "$ver: copy nvvs"
  docker rm "$c" >/dev/null || fail "$ver: remove the copy container"
  {
    echo "== nvvs: plugin directories and CUDA version messages"
    strings "$work/nvvs-$ver" | grep -E '^/cuda[0-9]+/$|^/cudaless/$|[Uu]nsupported C[Uu][Dd][Aa] version' | sort -u
    echo "== dcgmi: embedded host engine and connection messages"
    strings "$work/dcgmi-$ver" | grep -E 'dcgmStartEmbedded|embedded host engine|unable to establish a connection' | sort -u
    echo "== dcgmi: lower-case key strings that name a device"
    strings "$work/dcgmi-$ver" | grep -E '^(entity_id|entity_groups|serial|serial_num|device_id|uuid|gpu_uuid|results|tests|test_summary|warnings|info|error_id|error_category|runtime_error|metadata|driver_version)$' | sort -u
    echo "== dcgmi: any string containing UUID"
    strings "$work/dcgmi-$ver" | grep -i 'uuid' | grep -v '^_Z' | cut -c1-160 | sort -u
  } >"$d/strings.txt" 2>"$d/strings.err" || fail "$ver: strings"
done
if [ "$failed" = 1 ]; then
  echo "INSPECTION INCOMPLETE: see the failures above; $OUT is not a complete archive"
  exit 1
fi
echo "evidence in $OUT"
