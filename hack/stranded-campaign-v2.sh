#!/usr/bin/env bash
#
# Runs the second stranded-GPU campaign: every cell in the registered order, each on its own fresh cluster.
#
# The registration is docs/superpowers/specs/2026-10-22-stranding-where-packing-should-lose-design.md and the
# machine copy is hack/stranded-protocol-v2.yaml, whose conditions name their own protocol files. This builds
# and deletes the clusters; hack/stranded-cell.sh performs each cell and does not configure its cluster, and
# cmd/strandedrun judges, so the three stay apart as in the first campaign.
#
#   hack/stranded-campaign-v2.sh            # the 72 cells, in the registered twelve blocks
#   REHEARSE=1 hack/stranded-campaign-v2.sh  # block 1 only, into a rehearsal directory, never counted
#
# Evidence goes to ex/stranded-v2-<UTC>/ (or ex/stranded-v2-rehearsal-<UTC>/): one directory per attempt, and the
# record of each under records/<condition>/, which is what check-campaign-v2 reads.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CAMPAIGN=hack/stranded-protocol-v2.yaml
BIN=bin/strandedrun
TAG=$([ "${REHEARSE:-0}" = 1 ] && echo stranded-v2-rehearsal || echo stranded-v2)
OUT=ex/$TAG-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/campaign.log
mkdir -p "$OUT/records"

# To stderr as well as the log, because run_attempt's stdout is its verdict and a log line there would read as one.
log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG" >&2; }
die() {
  log "STOP: $*"
  exit 1
}

# A tree that differs from its commit is not the commit the registration froze.
dirty=$(git status --porcelain)
[ -z "$dirty" ] || die "uncommitted or untracked changes: $dirty"
for tool in kind kubectl docker go python3; do command -v "$tool" >/dev/null || die "missing tool $tool"; done
go build -o "$BIN" ./cmd/strandedrun >>"$LOG" 2>&1 || die "go build strandedrun"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:latest >>"$LOG" 2>&1 || die "simulator image"
bash hack/test/check-stranded-v2-order.sh >>"$LOG" 2>&1 || die "the order is not the seed's draw"

# Each condition's protocol file, layout and node image, read once from the campaign.
eval "$(python3 - "$CAMPAIGN" "${REHEARSE:-0}" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
for cond in c["conditions"]:
    p = yaml.safe_load(open(cond["protocol"]))
    n = cond["name"]
    print(f'PROTO_{n}={cond["protocol"]}')
    print(f'LAYOUT_{n}={",".join(str(w) for w in p["node_layout"]["workers"])}')
    print(f'IMAGE_{n}={p["images"]["node"]}')
# The quoted heredoc expands nothing, so the rehearsal flag arrives as an argument.
blocks = c["order"]["blocks"][:1] if sys.argv[2] == "1" else c["order"]["blocks"]
print("CELLS=(" + " ".join(f"{i + 1}:{cell}" for i, b in enumerate(blocks) for cell in b) + ")")
PY
)" || die "the campaign could not be read"

{
  echo "commit=$(git rev-parse HEAD)"
  echo "kind=$(kind version)"
  echo "simulator_image=$(docker image inspect gpu-simulator:latest --format '{{.Id}}')"
  for n in C1 C2 C3; do
    img=IMAGE_$n
    echo "node_image_$n=${!img} $(docker image inspect "${!img}" --format '{{.Id}}' 2>&1)"
  done
  echo "rehearsal=${REHEARSE:-0} cells=${#CELLS[@]}"
} >"$OUT/provenance.txt"
log "provenance: $(tr '\n' ' ' <"$OUT/provenance.txt")"

# build_cluster renders one arm's cluster for one condition's layout and waits for its capacity to read back.
build_cluster() {
  local cond=$1 arm=$2 dir=$3 layout image strategy=()
  layout=LAYOUT_$cond
  image=IMAGE_$cond
  [ "$arm" = S-gpu-most ] && strategy=(-strategy=MostAllocated)
  kind delete cluster --name stranded >>"$LOG" 2>&1
  "$BIN" render-cluster -arm="$arm" "${strategy[@]}" -layout="${!layout}" -dir="$dir/cluster" \
    -node-image="${!image}" >>"$LOG" 2>&1 || return 1
  # From the rendered directory: the configuration mounts ./scheduler-config.yaml, which kind resolves against
  # its working directory rather than the configuration file's.
  (cd "$dir/cluster" && kind create cluster --config kind-config.yaml) >>"$LOG" 2>&1 || return 1
  kind load docker-image gpu-simulator:latest --name stranded >>"$LOG" 2>&1 || return 1
  kubectl --context kind-stranded apply -f "$dir/cluster/device-plugins.yaml" >>"$LOG" 2>&1 || return 1
  local want got=""
  want=$(tr ',' ' ' <<<"${!layout}")
  for _ in $(seq 1 90); do
    got=$(kubectl --context kind-stranded get nodes -l '!node-role.kubernetes.io/control-plane' \
      -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}' 2>>"$LOG")
    [ "$got" = "$want " ] && return 0
    sleep 2
  done
  # Not refused here: the cell's own verify-layout reads it and records the registered invalidation reason.
  log "capacity read back as '$got', registered '$want'; the cell will judge it"
  return 0
}

# run_attempt performs one attempt at one cell and files its record under its condition.
run_attempt() {
  local cond=$1 arm=$2 rep=$3 try=$4 dir proto
  dir=$OUT/attempts/$cond-$arm-rep$(printf %02d "$rep")-try$try
  proto=PROTO_$cond
  mkdir -p "$dir" "$OUT/records/$cond"
  build_cluster "$cond" "$arm" "$dir" || die "the cluster for $cond $arm rep $rep did not build"
  # CONTEXT is set, not inherited: an exported one would point the cell at some other cluster.
  CONTEXT=kind-stranded EXDIR=$dir PROTOCOL=${!proto} bash hack/stranded-cell.sh cell "$arm" "$rep" "$try" >>"$dir/cell.out" 2>&1
  local rc=$?
  kind delete cluster --name stranded >>"$LOG" 2>&1 || log "kind delete failed after $dir"
  [ -f "$dir/record.json" ] || die "$cond $arm rep $rep try $try wrote no record (exit $rc); see $dir/cell.out"
  cp "$dir/record.json" "$OUT/records/$cond/$arm-rep$(printf %02d "$rep")-try$try.json"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("invalidated_because") or "")' "$dir/record.json"
}

for entry in "${CELLS[@]}"; do
  block=${entry%%:*}
  cell=${entry#*:}
  cond=${cell%%/*}
  arm=${cell#*/}
  log "block $block: $cond $arm"
  reason=$(run_attempt "$cond" "$arm" "$block" 1) || exit 1
  if [ -n "$reason" ]; then
    log "  invalid ($reason); one replacement, now"
    reason=$(run_attempt "$cond" "$arm" "$block" 2) || exit 1
    # A second invalidation of one cell ends the campaign, with the history published instead of a comparison.
    [ -z "$reason" ] || die "$cond $arm rep $block invalid twice ($reason)"
  fi
  log "  stands"
done

if [ "${REHEARSE:-0}" = 1 ]; then
  # A rehearsal is one repetition, which check-campaign-v2 would refuse as incomplete; each record is judged alone.
  log "== rehearsal: judging each record alone, never as the campaign"
  rc=0
  for f in "$OUT"/records/*/*.json; do
    cond=$(basename "$(dirname "$f")")
    proto=PROTO_$cond
    "$BIN" check-cell -record="$f" -protocol="${!proto}" 2>&1 | tee -a "$LOG" || rc=1
  done
  exit "$rc"
fi
log "== judging"
"$BIN" check-campaign-v2 -records="$OUT/records" -campaign="$CAMPAIGN" 2>&1 | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
