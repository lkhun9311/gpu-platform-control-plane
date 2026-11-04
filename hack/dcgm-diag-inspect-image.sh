#!/usr/bin/env bash
# The free step of the DCGM diagnostic registration (docs/superpowers/specs/2026-11-04-dcgm-diag-runbook-design.md):
# read the candidate diagnostic images on a machine with no GPU, and archive what they show.
#
#   bash hack/dcgm-diag-inspect-image.sh            # writes hack/dcgm-diag/<UTC date>-image-inspection/
#
# Everything here runs with --network none and no GPU, so it can settle only what the image's own files and its
# behaviour without a device show; what a card's real output would show is left to the paid session.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# The exporter's DCGM (config/dcgm-exporter/daemonset.yaml) and the newest 4.x image published, both by digest.
IMAGES=(
  "3.3.9 nvcr.io/nvidia/cloud-native/dcgm@sha256:b40226d395a35f7db3a88ce1a143c6caafadba2315be2b7b7fa9a4f41fa5b41d"
  "4.4.2 nvcr.io/nvidia/cloud-native/dcgm@sha256:30dd30b980ebf2f15a3fe7e629db9b8540f93bed794327dd34a0d4afd8a52c1b"
)
OUT=${OUT:-hack/dcgm-diag/$(date -u +%Y-%m-%d)-image-inspection}
mkdir -p "$OUT"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for entry in "${IMAGES[@]}"; do
  read -r ver img <<<"$entry"
  d="$OUT/$ver"
  mkdir -p "$d"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    docker pull -q "$img" >"$d/pull.txt" 2>&1 || { echo "pull of $img failed: $(tail -1 "$d/pull.txt")"; exit 1; }
  fi
  docker image inspect "$img" --format 'digest={{index .RepoDigests 0}} platform={{.Os}}/{{.Architecture}} created={{.Created}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}} user={{json .Config.User}}' >"$d/image.txt"
  run() { docker run --rm --network none --entrypoint sh "$img" -c "$1" >"$d/$2" 2>&1; echo "exit=$?" >>"$d/$2"; }
  run 'dcgmi --version' version.txt
  run 'dcgmi diag --help' diag-help.txt
  run 'dpkg -l | grep -iE "datacenter-gpu-manager|dcgm"' packages.txt
  # The plugin tree: nvvs picks one directory by the CUDA version the driver reports.
  # Only the fully versioned files are listed, because 4.4.2 ships no unversioned lib<Plugin>.so for a plugin.
  run 'for p in /usr/share/nvidia-validation-suite/plugins /usr/libexec/datacenter-gpu-manager-4/plugins; do [ -d "$p" ] && find "$p" -maxdepth 2 -name "lib*.so.[0-9]*.[0-9]*.[0-9]*" | sort; done' plugins.txt
  # How dcgmi reaches a host engine with none running: the default host, an explicit socket that does not exist,
  # and a diagnostic against each, to see whether a failed connection stops it or it carries on without the engine.
  run 'echo "== diag, default host, no engine"; timeout 60 dcgmi diag -r 1 -j; echo "rc=$?"
       echo "== diag, --host a socket that does not exist"; timeout 60 dcgmi diag --host unix:///tmp/none.sock -r 1 -j; echo "rc=$?"
       echo "== discovery, --host a socket that does not exist"; timeout 30 dcgmi discovery --host unix:///tmp/none.sock -l; echo "rc=$?"
       echo "== discovery, default host, no engine"; timeout 30 dcgmi discovery -l; echo "rc=$?"' engine-probe.txt
  # Strings of the binaries, for what their output can carry: the plugin directories nvvs knows, its message for a
  # CUDA version it has no plugins for, and the lower-case keys dcgmi's JSON writer is built from.
  c=$(docker create "$img")
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
