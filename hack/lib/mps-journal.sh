# shellcheck shell=bash
# The MPS capability session's bar journal, written as the session works.
#
# docs/superpowers/specs/2026-09-25-can-mps-engage-on-this-card-at-all.md requires B0 to B5 "written to a structured
# file as they are decided, so a session cut short still says how far it got". This file is the only writer of that
# file, and `benchharness mps-capability-verdict` (internal/bench/mps_capability.go) is its only reader.
#
# A bar is started before its instrument runs and decided once the answer is read, so a bar whose instrument was
# killed reads as interrupted rather than as never attempted.
# Each line is built by python's json module, because a reason quoting a Pod's event can carry quotes and newlines
# that printf would turn into a line the reader refuses.
#
# MPS_JOURNAL names the file. MPS_JOURNAL_ON_APPEND, when set, is run after every line, so the session can upload
# the journal as it grows rather than once at the end.

# mj_append TYPE KEY=VALUE...: one journal line; VALUE true or false is written as a JSON boolean for key "value".
mj_append() {
  [ -n "${MPS_JOURNAL:-}" ] || { echo "mps journal: MPS_JOURNAL is not set" >&2; return 1; }
  python3 - "$MPS_JOURNAL" "$@" <<'PY' || return 1
import datetime, json, sys
path, kind, *pairs = sys.argv[1:]
rec = {"type": kind}
for p in pairs:
    k, _, v = p.partition("=")
    if k == "value":
        rec[k] = {"true": True, "false": False}[v]
    elif v:
        rec[k] = v
rec["at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
with open(path, "a") as f:
    f.write(json.dumps(rec, separators=(",", ":")) + "\n")
PY
  if [ -n "${MPS_JOURNAL_ON_APPEND:-}" ]; then ${MPS_JOURNAL_ON_APPEND} || echo "mps journal: the upload after this line failed" >&2; fi
  return 0
}

mj_known_bar() { case "$1" in B0|B1|B2|B3|B4|B5) return 0 ;; *) echo "mps journal: no bar $1" >&2; return 1 ;; esac; }

# mj_start BAR: the instrument for BAR is about to run.
mj_start() { mj_known_bar "$1" && mj_append bar "bar=$1" state=started; }

# mj_decide BAR RESULT DETAIL: what the instrument read, as pass, fail or unmeasured.
mj_decide() {
  mj_known_bar "$1" || return 1
  case "$2" in pass|fail|unmeasured) ;; *) echo "mps journal: $1 cannot be decided as '$2'" >&2; return 1 ;; esac
  mj_append bar "bar=$1" state=decided "result=$2" "detail=${3:-}"
}

# mj_fact NAME true|false DETAIL: a fact the classification reads, recorded once.
mj_fact() {
  case "$2" in true|false) ;; *) echo "mps journal: fact $1 cannot be '$2'" >&2; return 1 ;; esac
  if mj_has_fact "$1"; then echo "mps journal: fact $1 is already recorded" >&2; return 1; fi
  mj_append fact "name=$1" "value=$2" "detail=${3:-}"
}

# mj_has_fact NAME: whether the journal already records NAME, so a later step can fill a fact only an earlier one
# could have missed without recording it twice.
mj_has_fact() {
  [ -s "${MPS_JOURNAL:-}" ] || return 1
  python3 - "$MPS_JOURNAL" "$1" <<'PY'
import json, sys
path, name = sys.argv[1:]
for line in open(path):
    line = line.strip()
    if line and json.loads(line).get("type") == "fact" and json.loads(line).get("name") == name:
        sys.exit(0)
sys.exit(1)
PY
}

# mj_result BAR: the bar's decided result, or nothing when it has none yet.
mj_result() {
  [ -s "${MPS_JOURNAL:-}" ] || return 0
  python3 - "$MPS_JOURNAL" "$1" <<'PY'
import json, sys
path, bar = sys.argv[1:]
for line in open(path):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    if r.get("type") == "bar" and r.get("bar") == bar and r.get("state") == "decided":
        print(r.get("result", ""))
PY
}
