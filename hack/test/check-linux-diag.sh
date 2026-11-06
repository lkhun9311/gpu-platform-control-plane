#!/usr/bin/env bash
#
# Checks hack/linux-diag/check.py against the scored run and against copies of it with one thing changed, without a
# cluster.
#
#   bash hack/test/check-linux-diag.sh
#
# Each perturbation is a way the instrument could fail or the system could behave otherwise, and each must change the
# checker's answer for the case it touches, and only that case.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

RUN=hack/linux-diag-20261106T230435Z
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# copy: a fresh copy of the scored run, without its verdict.
copy() {
  rm -rf "$work/run"
  cp -r "$RUN" "$work/run"
  rm -f "$work/run/verdict.json"
}

# summary_of DIR: the checker's per-case summary lines and its per-repetition reasons, one per line.
summary_of() {
  python3 hack/linux-diag/check.py "$1" > "$work/out.txt" 2>&1 || {
    echo "checker exited $?"
    cat "$work/out.txt"
    return
  }
  cat "$work/out.txt"
}

# expect NAME LINE: the checker's output on $work/run holds LINE exactly.
expect() {
  if grep -qxF -- "$2" "$work/summary"; then ok "$1"; else
    bad "$1: no line '$2' in:"
    sed 's/^/    /' "$work/summary"
  fi
}

# unchanged_except CASE: every case other than CASE still held in 3 of 3.
unchanged_except() {
  local c
  for c in c1 c2a c2b c3 c4; do
    [ "$c" = "$1" ] && continue
    grep -qxF "$c: held in 3 of 3 (0 invalid)" "$work/summary" || bad "a change to $1 moved $c: $(grep "^$c:" "$work/summary")"
  done
}

copy
summary_of "$work/run" > "$work/summary"
for c in c1 c2a c2b c3 c4; do expect "the scored run: $c" "$c: held in 3 of 3 (0 invalid)"; done
# The committed verdict is the one this checker writes: a checker changed after the run would show here.
if cmp -s <(jq -S . "$RUN/verdict.json") <(jq -S . "$work/run/verdict.json"); then ok "the committed verdict is reproduced"; else
  bad "the committed verdict differs from the checker's"
fi

copy
jq '.journal_exit = 1' "$work/run/c4-r2/case.json" > "$work/x" && mv "$work/x" "$work/run/c4-r2/case.json"
summary_of "$work/run" > "$work/summary"
expect "an unread journal invalidates even the case that expects no report" "  c4 r2: INVALID: journalctl exited 1"
unchanged_except c4

copy
jq '.single_process_oom_kill_effective = "false"' "$work/run/c2b-r1/case.json" > "$work/x" && mv "$work/x" "$work/run/c2b-r1/case.json"
summary_of "$work/run" > "$work/summary"
expect "a cluster without the setting invalidates the case" "  c2b r1: INVALID: the cluster's singleProcessOOMKill was false, not true"
unchanged_except c2b

copy
grep -v 'parent-done' "$work/run/c2b-r3/log.txt" > "$work/x" && mv "$work/x" "$work/run/c2b-r3/log.txt"
summary_of "$work/run" > "$work/summary"
expect "a parent that did not survive the child's OOM" "  c2b r3: did not hold: log has child-exit=137 and parent-done"
unchanged_except c2b

copy
grep -v 'going to be killed due to memory.oom.group set' "$work/run/c2a-r1/journal.txt" > "$work/x" && mv "$work/x" "$work/run/c2a-r1/journal.txt"
summary_of "$work/run" > "$work/summary"
expect "a whole-container kill without the kernel's group line" "  c2a r1: did not hold: the record has the memory.oom.group line"
unchanged_except c2a

copy
sed -E 's/kernel: shmem [0-9]+$/kernel: shmem 1048576/' "$work/run/c3-r2/journal.txt" > "$work/x" && mv "$work/x" "$work/run/c3-r2/journal.txt"
summary_of "$work/run" > "$work/summary"
expect "an OOM whose statistics hold no tmpfs" "  c3 r2: did not hold: statistics block shmem at least 96 MiB"
unchanged_except c3

copy
# The c3 report's lines, given the c4 container's ID: a kernel OOM report the case says must not exist.
id=$(jq -r '.status.containerStatuses[0].containerID' "$(ls "$work"/run/c4-r1/status-*.json | tail -1)" | sed 's|.*://||')
old=$(grep -o 'cri-containerd-[0-9a-f]*\.scope' "$work/run/c3-r1/journal.txt" | head -1)
sed "s|$old|cri-containerd-$id.scope|g" "$work/run/c3-r1/journal.txt" >> "$work/run/c4-r1/journal.txt"
summary_of "$work/run" > "$work/summary"
expect "a page-cache case that did meet an OOM" "  c4 r1: did not hold: no matching journal record"
unchanged_except c4

copy
head -n 2 "$work/run/c4-r3/summary.jsonl" > "$work/x" && mv "$work/x" "$work/run/c4-r3/summary.jsonl"
summary_of "$work/run" > "$work/summary"
if grep -qE '^  c4 r3: INVALID: [0-2] kubelet samples with distinct times after the read finished, need 3$' "$work/summary"; then
  ok "too few fresh kubelet samples invalidate the working-set reading"
else
  bad "two kubelet samples were read as a working set: $(grep 'c4 r3' "$work/summary")"
fi
unchanged_except c4

copy
sed -i 's/Killed process \([0-9]*\) (python3)/Killed process \1 (python3x)/' "$work/run/c1-r1/journal.txt"
sed -i 's/task=python3,/task=sh,/' "$work/run/c1-r1/journal.txt"
summary_of "$work/run" > "$work/summary"
expect "a report that names another task" "  c1 r1: did not hold: one OOM record with task=python3"
unchanged_except c1

copy
sed -i 's/512+0 records out/511+0 records out/' "$work/run/c4-r2/log.txt"
summary_of "$work/run" > "$work/summary"
expect "an incomplete write leaves the page-cache case unexercised" "  c4 r2: INVALID: dd did not write and read 512 records"
unchanged_except c4

# The trim keeps a report whole and drops what is not one.
printf '%s\n' '[1.0] genesis kernel: wifi noise' \
  '[2.0] genesis kernel: x invoked oom-killer: gfp_mask=0' '[2.1] genesis kernel: Hardware name: BOARD' \
  '[2.2] genesis kernel: memory: usage 1kB, limit 1kB, failcnt 1' \
  '[2.3] genesis kernel: Memory cgroup out of memory: Killed process 7 (x) total-vm:1kB, anon-rss:1kB, file-rss:1kB, shmem-rss:0kB, UID:0' \
  '[3.0] genesis kernel: wifi noise again' > "$work/j.raw"
python3 hack/linux-diag/trim-journal.py "$work/j.raw" "$work/j.txt" > /dev/null
if [ "$(wc -l < "$work/j.txt")" -eq 3 ] && ! grep -q 'genesis\|BOARD\|wifi' "$work/j.txt" && grep -q 'Killed process 7' "$work/j.txt"; then
  ok "the trim keeps the report, drops the host's name, its board and other drivers"
else
  bad "the trim kept: $(cat "$work/j.txt")"
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
