#!/usr/bin/env bash
#
# Checks hack/net-diag/check.py against the scored run and against copies of it with one thing changed, without a
# cluster.
#
#   bash hack/test/check-net-diag.sh
#
# Each perturbation is a way the instrument could fail or the network behave otherwise, and each must change the
# checker's answer for the case it touches, and only that case.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

RUN=hack/net-diag-20261107T004649Z
CASES="b n1a n1b n2a n2b n3a n3b"
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

copy() {
  rm -rf "$work/run"
  cp -r "$RUN" "$work/run"
  rm -f "$work/run/verdict.json"
}

score() {
  python3 hack/net-diag/check.py "$work/run" > "$work/summary" 2>&1 || {
    echo "checker exited $?" >> "$work/summary"
  }
}

# expect NAME LINE: the checker's output holds LINE exactly.
expect() {
  if grep -qxF -- "$2" "$work/summary"; then ok "$1"; else
    bad "$1: no line '$2' in:"
    sed 's/^/    /' "$work/summary"
  fi
}

# unchanged_except CASE: every other case still held in 3 of 3.
unchanged_except() {
  local c
  for c in $CASES; do
    [ "$c" = "$1" ] && continue
    grep -qxF "$c: held in 3 of 3 (0 invalid)" "$work/summary" || bad "a change to $1 moved $c: $(grep "^$c:" "$work/summary")"
  done
}

# edit FILE PYTHON: rewrite FILE in place with a python expression over its text s.
edit() {
  python3 - "$1" "$2" <<'EOF'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
t = eval(expr)
if t == s:
    sys.exit(f"the edit changed nothing in {p}")
open(p, "w").write(t)
EOF
}

copy
score
for c in $CASES; do expect "the scored run: $c" "$c: held in 3 of 3 (0 invalid)"; done
if cmp -s <(jq -S . "$RUN/verdict.json") <(jq -S . "$work/run/verdict.json"); then ok "the committed verdict is reproduced"; else
  bad "the committed verdict differs from the checker's"
fi

copy
edit "$work/run/n1a-r1/probe.txt" 's.replace("capture_ready=1", "capture_ready=0")'
score
expect "a capture that started late invalidates" "  n1a r1: INVALID: tcpdump was not listening when the request started"
unchanged_except n1a

copy
edit "$work/run/n2a-r2/probe.txt" 's.replace("kernel_dropped=0", "kernel_dropped=3")'
score
expect "a capture with kernel drops invalidates" "  n2a r2: INVALID: the capture dropped 3 packets in the kernel"
unchanged_except n2a

copy
edit "$work/run/n1b-r1/fault.txt" 's.replace("policy_enforced=1", "policy_enforced=0")'
score
if grep -q '^  n1b r1: INVALID: the NetworkPolicy was not shown enforced' "$work/summary"; then ok "a policy not shown enforced invalidates"; else
  bad "an unenforced policy was scored: $(grep 'n1b r1' "$work/summary")"
fi
unchanged_except n1b

copy
edit "$work/run/n1a-r2/fault.txt" 's.replace("reject_rules=1", "reject_rules=0")'
score
if grep -q '^  n1a r2: INVALID: CoreDNS still had endpoints or Pods, or kube-proxy had no REJECT rule' "$work/summary"; then
  ok "a DNS fault without kube-proxy's REJECT rule invalidates"
else
  bad "n1a without the REJECT rule: $(grep 'n1a r2' "$work/summary")"
fi
unchanged_except n1a

copy
edit "$work/run/n3a-r3/removal.txt" 's.replace("reject_rules=0", "reject_rules=1")'
score
expect "a recovery probed before the REJECT rule left invalidates" "  n3a r3: INVALID: kube-proxy's REJECT rule was still there when the recovery was probed"
unchanged_except n3a

copy
printf 'qdisc netem 8001: root refcnt 2 limit 1000 loss 100%%\n' > "$work/run/n2a-r1/removal.txt"
score
if grep -q '^  n2a r1: INVALID: the loss was still on the server' "$work/summary"; then ok "loss left on after removal invalidates"; else
  bad "loss left on: $(grep 'n2a r1' "$work/summary")"
fi
unchanged_except n2a

copy
# The silent DNS case answered: a resolver that is not dropped is not N1b.
edit "$work/run/n1b-r2/probe.txt" 's.replace("--- end", "00:00:00.000000 IP 10.96.0.10.53 > 10.244.0.6.1: 1*- 1/0/1 A 10.96.0.1 (121)\n--- end")'
score
expect "an answered query in the silent-DNS case" "  n1b r2: did not hold: two or more queries, no answer, no ICMP"
unchanged_except n1b

copy
edit "$work/run/n1a-r3/probe.txt" 's.replace("udp port 53 unreachable", "udp port 53 unreach")'
score
expect "a DNS failure without the node's ICMP" "  n1a r3: did not hold: a query and a udp port 53 unreachable"
unchanged_except n1a

copy
# Seven SYNs spread over seven client ports are seven connections, not retransmissions of one.
python3 - "$work/run/n2a-r1/probe.txt" <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
n = [0]
def bump(m):
    n[0] += 1
    return f"10.244.0.6.{40000 + n[0]} > "
s2 = re.sub(r"10\.244\.0\.6\.\d+ > (?=\S+\.80: Flags \[S\],)", bump, s)
assert s2 != s
open(p, "w").write(s2)
EOF
score
expect "SYNs from different ports are not retransmissions" "  n2a r1: did not hold: three or more SYNs from one client port, no SYN-ACK, no RST"
unchanged_except n2a

copy
edit "$work/run/n3b-r2/probe.txt" 's.replace(": Flags [R.]", ": Flags [P.]")'
score
expect "a refusal with no RST" "  n3b r2: did not hold: a RST from the server Pod to the port that sent the SYN, and no ICMP"
unchanged_except n3b

copy
edit "$work/run/n3a-r1/probe.txt" 's.replace("tcp port 80 unreachable", "tcp port 80 unreach")'
score
expect "no endpoints without the node's ICMP" "  n3a r1: did not hold: a tcp port 80 unreachable and no RST"
unchanged_except n3a

copy
# A tail that is only failed requests: every slow request made a curl failure, so no completed request is slow.
python3 - "$work/run/n2b-r1/burst.txt" <<'EOF'
import re, sys
p = sys.argv[1]
out = []
for line in open(p).read().splitlines():
    m = re.search(r"t_total=([0-9.]+)", line)
    if line.startswith("req=") and m and float(m.group(1)) >= 0.5:
        line = line.replace(" exit=0", " exit=28")
    out.append(line)
open(p, "w").write("\n".join(out) + "\n")
EOF
score
if grep -q '^  n2b r1: did not hold: completed requests: median under 0.5 s' "$work/summary"; then
  ok "a tail made of failed requests does not count as slow successes"
else
  bad "failed requests counted as the tail: $(grep 'n2b r1' "$work/summary")"
fi
unchanged_except n2b

copy
python3 - "$work/run/b-r2/burst.txt" <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r"(req=1 http=200 t_total=)[0-9.]+", r"\g<1>1.200000", s, count=1)
assert s2 != s
open(p, "w").write(s2)
EOF
score
expect "a slow no-loss batch fails the baseline" "  b r2: did not hold: the no-loss batch: 40 of 40 completed, none at 0.5 s or more"
grep -q '^  n2b r2: did not hold: completed requests' "$work/summary" && ok "and N2b reads its tail against that baseline" ||
  bad "N2b did not read the slow baseline: $(grep 'n2b r2' "$work/summary")"

copy
edit "$work/run/n2b-r3/recovery-burst.txt" 's.replace(" exit=0", " exit=28", 1)'
score
expect "loss still felt after its removal" "  n2b r3: did not hold: after removal: 20 of 20 completed, none at 0.5 s or more"
unchanged_except n2b

# A repetition that left nothing is still scheduled, and counts as INVALID rather than vanishing.
copy
rm "$work/run/n1a-r2/case.json"
score
expect "a scheduled repetition with no case.json" "n1a: held in 2 of 3 (1 invalid)"
unchanged_except n1a

# Unreadable evidence makes one repetition INVALID and the rest are still scored.
copy
rm "$work/run/n3b-r1/probe.txt"
edit "$work/run/n2a-r3/probe.txt" 's.replace("retrans_before=", "retrans_before= x=", 1)'
score
if grep -q '^  n3b r1: INVALID: its evidence could not be read: FileNotFoundError' "$work/summary" &&
  grep -q '^  n2a r3: INVALID: its evidence could not be read: ValueError' "$work/summary"; then
  ok "unreadable evidence invalidates its repetition only"
else
  bad "unreadable evidence: $(cat "$work/summary")"
fi
for c in b n1a n1b n2b n3a; do
  grep -qxF "$c: held in 3 of 3 (0 invalid)" "$work/summary" || bad "unreadable evidence elsewhere moved $c"
done

# A fault read-back with no rule count is no confirmation.
copy
edit "$work/run/n3a-r2/fault.txt" 's.replace("reject_rules=1", "reject_rules=")'
score
if grep -q '^  n3a r2: INVALID: the server Service still had endpoints, or kube-proxy had no REJECT rule' "$work/summary"; then
  ok "a REJECT read-back with no number invalidates"
else
  bad "an empty REJECT read-back was accepted: $(grep 'n3a r2' "$work/summary")"
fi
unchanged_except n3a

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
