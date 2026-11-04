#!/usr/bin/env bash
# The free step of the DCGM diagnostic registration (docs/superpowers/specs/2026-11-04-dcgm-diag-runbook-design.md):
# read the candidate diagnostic images on a machine with no GPU, and archive what they show.
#
#   bash hack/dcgm-diag-inspect-image.sh            # writes hack/dcgm-diag/<UTC date>-image-inspection/
#
# Everything here runs with --network none and no GPU, so it can settle only what the image's own files and its
# behaviour without a device show; what a card's real output would show is left to the paid session.
# Every command's stdout and stderr are kept apart, because which stream a message lands on is itself a finding.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# The exporter's DCGM (config/dcgm-exporter/daemonset.yaml) and the newest 4.x image published.
# Each is named by tag, so the archive can show which index digest the tag resolved to and which amd64 image under it.
IMAGES=(
  "3.3.9 nvcr.io/nvidia/cloud-native/dcgm:3.3.9-1-ubuntu22.04"
  "4.4.2 nvcr.io/nvidia/cloud-native/dcgm:4.4.2-1-ubuntu22.04"
)
OUT=${OUT:-hack/dcgm-diag/$(date -u +%Y-%m-%d)-image-inspection}
mkdir -p "$OUT"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for entry in "${IMAGES[@]}"; do
  read -r ver tag <<<"$entry"
  d="$OUT/$ver"
  mkdir -p "$d"
  # The index exactly as the registry serves it: its raw bytes hash to the index digest a pin names, and the platform
  # manifests listed inside them are what that pin resolves to, so the archive shows the relation and not a claim of it.
  repo=${tag#nvcr.io/}
  repo=${repo%%:*}
  token=$(curl -fsS "https://nvcr.io/proxy_auth?scope=repository:$repo:pull" | python3 -c 'import sys, json; print(json.load(sys.stdin)["token"])')
  curl -fsS -D "$d/index.headers" -o "$d/index.json" -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://nvcr.io/v2/$repo/manifests/${tag##*:}" 2>"$d/index.err"
  echo "exit=$?" >"$d/index.exit"
  sha256sum "$d/index.json" | cut -d' ' -f1 >"$d/index.sha256"
  docker pull -q "$tag" >"$d/pull.out" 2>"$d/pull.err" || { echo "pull of $tag failed: $(tail -1 "$d/pull.err")"; exit 1; }
  # RepoDigests names the index digest the tag resolved to; the platform names the image this machine runs.
  docker image inspect "$tag" --format 'tag={{index .RepoTags 0}} index_digest={{index .RepoDigests 0}} image_id={{.Id}} platform={{.Os}}/{{.Architecture}} created={{.Created}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}}' >"$d/image.txt" 2>"$d/image.err"
  echo "exit=$?" >"$d/image.exit"
  # run NAME SCRIPT: one command in the image, its streams and exit status in three files.
  run() {
    docker run --rm --network none --entrypoint sh "$tag" -c "$2" >"$d/$1.out" 2>"$d/$1.err"
    echo "exit=$?" >"$d/$1.exit"
  }
  run version 'dcgmi --version'
  run diag-help 'dcgmi diag --help'
  run packages 'dpkg -l | grep -iE "datacenter-gpu-manager|dcgm"'
  # The executables and the diagnostic's plugin libraries, each with its path and hash.
  # nvvs picks one plugin directory by the CUDA version the driver reports.
  run executables 'for f in /usr/bin/dcgmi /usr/bin/nv-hostengine /usr/share/nvidia-validation-suite/nvvs /usr/libexec/datacenter-gpu-manager-4/nvvs; do [ -e "$f" ] && sha256sum "$f"; done'
  run plugins 'for p in /usr/share/nvidia-validation-suite/plugins /usr/libexec/datacenter-gpu-manager-4/plugins; do [ -d "$p" ] && find "$p" -maxdepth 2 -name "lib*.so.[0-9]*.[0-9]*.[0-9]*" | sort | xargs sha256sum; done'
  # What a session's commands need from the image itself.
  run tools 'id; for t in tar timeout pgrep ps sha256sum; do printf "%s " "$t"; command -v "$t" || echo ABSENT; done'
  # How dcgmi reaches a host engine with none running, by default and with --host naming a socket that does not
  # exist, with and without an explicit GPU entity; and discovery, which needs an engine.
  run diag-default 'timeout 60 dcgmi diag -r 1 -j'
  run diag-badhost 'timeout 60 dcgmi diag --host unix:///tmp/none.sock -r 1 -j'
  run diag-badhost-gpu0 'timeout 60 dcgmi diag --host unix:///tmp/none.sock -i gpu:0 -r 1 -j'
  run discovery-badhost 'timeout 30 dcgmi discovery --host unix:///tmp/none.sock -l'
  run discovery-default 'timeout 30 dcgmi discovery -l'
  # Strings of the binaries, for what their output can carry: the plugin directories nvvs knows, its message for a
  # CUDA version it has no plugins for, and the lower-case keys dcgmi's JSON writer is built from.
  c=$(docker create "$tag")
  nvvs=/usr/share/nvidia-validation-suite/nvvs
  [ "$ver" = 3.3.9 ] || nvvs=/usr/libexec/datacenter-gpu-manager-4/nvvs
  docker cp "$c:/usr/bin/dcgmi" "$work/dcgmi-$ver" >/dev/null
  docker cp "$c:$nvvs" "$work/nvvs-$ver" >/dev/null
  docker rm "$c" >/dev/null
  {
    echo "== nvvs: plugin directories and CUDA version messages"
    strings "$work/nvvs-$ver" | grep -E '^/cuda[0-9]+/$|^/cudaless/$|[Uu]nsupported C[Uu][Dd][Aa] version' | sort -u
    echo "== dcgmi: embedded host engine and connection messages"
    strings "$work/dcgmi-$ver" | grep -E 'dcgmStartEmbedded|embedded host engine|unable to establish a connection' | sort -u
    echo "== dcgmi: lower-case key strings that name a device"
    strings "$work/dcgmi-$ver" | grep -E '^(entity_id|entity_groups|serial|serial_num|device_id|uuid|gpu_uuid|results|tests|test_summary|warnings|info|error_id|error_category|runtime_error|metadata|driver_version)$' | sort -u
    echo "== dcgmi: any string containing UUID"
    strings "$work/dcgmi-$ver" | grep -i 'uuid' | grep -v '^_Z' | cut -c1-160 | sort -u
  } >"$d/strings.txt" 2>&1
done
echo "evidence in $OUT"
