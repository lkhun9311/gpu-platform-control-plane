#!/usr/bin/env bash
#
# Kernel semantics of memory.swap.max below memory.swap.current, in a bare cgroup v2 group with no kubelet involved.
# K1: the write itself, then whether usage drains while the pages stay cold.
# K2: the same, then the process touches every page again.
# K2c: K2 without lowering memory.swap.max, so an OOM in K2 can be put down to the lowered limit.
# K3: the same, then the process frees most of its memory.
# K4 (only with --swapoff, and last, since it removes the node's swap): swapoff while a group holds swap above its memory.max.
#
#   sudo bash kernel-swapmax.sh <out-dir> [--swapoff]
set -uo pipefail
OUT="$1"; SWAPOFF="${2:-}"
mkdir -p "$OUT"
G=/sys/fs/cgroup/k142885
ALLOC=/tmp/k142885-alloc.py
cat > "$ALLOC" <<'PY'
import signal, sys, time
# 1 MiB chunks, so that freeing a prefix releases the oldest, coldest pages.
chunks = [bytearray(1 << 20) for _ in range(int(sys.argv[1]))]
def touch(lst):
    for c in lst:
        for i in range(0, len(c), 4096):
            c[i] = (c[i] + 1) & 0xff
touch(chunks)
def retouch(*_):
    touch(chunks)
    print("RETOUCHED", flush=True)
def free(*_):
    del chunks[: len(chunks) * 3 // 4]
    print("FREED", flush=True)
signal.signal(signal.SIGUSR1, retouch)
signal.signal(signal.SIGUSR2, free)
print("READY", flush=True)
while True:
    time.sleep(1)
PY

snap() {
  printf '%s swap.max=%s swap.current=%s memory.max=%s memory.current=%s %s alive=%s\n' "$1" \
    "$(cat $G/memory.swap.max)" "$(cat $G/memory.swap.current)" "$(cat $G/memory.max)" "$(cat $G/memory.current)" \
    "$(grep -E '^oom_kill ' $G/memory.events | tr ' ' '=')" "$(kill -0 "$PID" 2>/dev/null && echo yes || echo no)"
}

start_group() {
  [ -d $G ] && { cat $G/cgroup.procs | xargs -r kill -9; sleep 1; rmdir $G; }
  mkdir $G
  echo 64M > $G/memory.max
  echo max > $G/memory.swap.max
  # 192 MiB under a 64 MiB limit puts about 128 MiB in swap.
  bash -c "echo \$\$ > $G/cgroup.procs; exec python3 -u $ALLOC 192" > "$OUT/$1.proc.log" 2>&1 &
  PID=$!
  until grep -q READY "$OUT/$1.proc.log" 2>/dev/null; do sleep 1; kill -0 $PID 2>/dev/null || break; done
  sleep 5
}

lower() {
  # The write's own exit status is the question: EBUSY, or success.
  echo 32M > $G/memory.swap.max
  echo "write 32M to memory.swap.max: rc=$?"
}

for k in ${KCASES:-K1 K2 K2c K3}; do
  {
    echo "== $k $(date -u +%FT%TZ) kernel $(uname -r)"
    start_group "$k"
    snap before
    # K2c is K2's control: the same retouch with memory.swap.max left at max.
    [ "$k" = K2c ] || lower
    snap "+0s"
    sleep 30
    snap "+30s"
    case $k in
      K1) sleep 30; snap "+60s" ;;
      K2|K2c) kill -USR1 $PID; sleep 20; snap "+20s after retouch"; cat "$OUT/$k.proc.log" ;;
      K3) kill -USR2 $PID; sleep 10; snap "+10s after freeing 3/4"; cat "$OUT/$k.proc.log" ;;
    esac
    kill -9 $PID 2>/dev/null
  } 2>&1 | tee "$OUT/$k.txt"
done

if [ "$SWAPOFF" = --swapoff ]; then
  {
    echo "== K4 $(date -u +%FT%TZ)"
    start_group K4
    snap before
    swapoff -a
    echo "swapoff rc=$?"
    snap "after swapoff"
    grep -i swap /proc/meminfo | head -2
    kill -9 $PID 2>/dev/null
  } 2>&1 | tee "$OUT/K4.txt"
fi
sleep 1; cat $G/cgroup.procs 2>/dev/null | xargs -r kill -9; sleep 1; rmdir $G 2>/dev/null
