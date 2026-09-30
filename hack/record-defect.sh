#!/usr/bin/env bash
#
# Append one line to the storage issue log when a tool call failed.
#
# Called from a PostToolUse hook. The logic lives here, tracked and testable, because `.claude/` is gitignored
# and a recorder nobody can review is not one to trust with a defect record -- the same reason
# hack/capture-evidence.sh exists beside its hook caller.
#
# WHAT THIS CAN AND CANNOT KNOW. It sees one tool call and its result. It cannot tell a defect from an
# intended failure: a mutation experiment, a deliberately broken gate, a `grep` that correctly finds nothing.
# So it records failures and says so, and storage/issues/README.md states that the line count is not a defect
# count. Judging is a person's job; this only makes sure the evidence is there to judge.
#
# The payload's shape for Bash was NOT measured. A settings change does not reach a running session, so the
# probe installed on 2026-09-30 never fired and the exit-status field name is unverified. `tool_input` is
# confirmed -- mirror-to-storage.sh reads `.tool_input.file_path` and is demonstrably working -- so only the
# response side is guessed, and it is read defensively across every plausible name. If none matches, the line
# says `rc=unknown` rather than claiming success.
set -uo pipefail

# storage/gpuaas/defects, and every part of that path was chosen rather than defaulted to.
#
# `defects` not `issues`: the two were split on 2026-09-30, where a defect is something that is wrong and an
# issue is something that is blocked. A command that failed belongs with defects.
#
# Under `gpuaas/` because storage holds several projects and records at its top level would mix them. The path
# moved twice in one day -- storage/issues, then storage/defects, then here -- and each move needed this line
# changed with it. A recorder pointed at a stale path silently recreates the old directory and splits the
# record across two trees, which is why the move is verified by writing one line and reading it back rather
# than by editing this string and trusting it.
LOG_DIR="/home/lkhun9311/workspace/storage/gpuaas/defects/hook-log"
LOG="$LOG_DIR/$(date -u +%Y-%m).jsonl"
SELF_LOG="/home/lkhun9311/workspace/gpu-platform-control-plane/.claude/hooks/record-defect.log"

# No 2>/dev/null and no `|| true` at the end: a recorder that discards its own errors cannot be told apart
# from one that never ran, which is this repository's most common defect class.
exec 2>>"$SELF_LOG"

command -v jq >/dev/null || { echo "$(date -u +%FT%TZ) record-defect: jq is missing; nothing recorded" >&2; exit 0; }

payload="$(cat)"
[ -n "$payload" ] || { echo "$(date -u +%FT%TZ) record-defect: empty payload" >&2; exit 0; }

# Every plausible spelling of "this failed", in one pass. The first non-null wins; `unknown` if none is there.
#
# `tool_response` is guarded with `type == "object"` before any field is read. Without that guard jq dies with
# `Cannot index string with string "exit_code"` on a plain-string response, and the first version of this
# script sent that error to /dev/null -- so `rc` came back as the empty string and the `case` below took it
# for a success. A recorder that reads "could not parse" as "passed" is the defect this file exists to catch,
# and it had it. Recorded as storage/issues/closed/2026-09-30-the-recorder-read-unparsable-as-passed.md.
#
# jq's own exit status is checked too, because a guard that only covers the shapes I thought of is still a
# guess about the shapes I did not.
parsed="$(printf '%s' "$payload" | jq -r '
  def first_of(paths): [paths] | map(select(. != null)) | .[0];
  (.tool_response // null) as $r
  | (if ($r | type) == "object" then $r else {} end) as $o
  | [
      (.tool_name // "unknown"),
      (first_of(
          $o.exit_code,
          $o.exitCode,
          $o.returnCode,
          (if ($o.is_error // $o.isError) == true then 1 else null end),
          (if ($o.success == false) then 1 else null end)
        ) // "unknown"),
      (($o.stderr // $o.error // "") | tostring | gsub("[\\n\\t ]+"; " ") | .[0:200])
    ] | @tsv')"
jq_rc=$?
if [ "$jq_rc" -ne 0 ] || [ -z "$parsed" ]; then
  echo "$(date -u +%FT%TZ) record-defect: jq failed (rc=$jq_rc) on this payload; nothing recorded" >&2
  exit 0
fi
IFS=$'\t' read -r tool rc err <<EOF
$parsed
EOF

# Nothing to record for a call that succeeded, and nothing to record when the status is unreadable -- an
# unknown status is not evidence of failure, and writing it as one would fill the log with noise. It goes to
# this hook's own log instead, so a payload shape that never matches is visible rather than silent.
case "$rc" in
  0|"") exit 0 ;;
  unknown)
    echo "$(date -u +%FT%TZ) record-defect: no exit-status field in the ${tool:-?} payload; keys=$(printf '%s' "$payload" | jq -rc '.tool_response | if type == "object" then keys else type end' 2>/dev/null)" >&2
    exit 0
    ;;
esac

mkdir -p "$LOG_DIR" || { echo "$(date -u +%FT%TZ) record-defect: cannot create $LOG_DIR" >&2; exit 0; }

cmd="$(printf '%s' "$payload" | jq -r '(.tool_input.command // .tool_input.file_path // "") | tostring | gsub("[\\n\\t ]+"; " ") | .[0:300]' 2>/dev/null)"

printf '%s\n' "$(jq -nc \
  --arg at "$(date -u +%FT%TZ)" \
  --arg tool "$tool" \
  --arg rc "$rc" \
  --arg cmd "$cmd" \
  --arg err "$err" \
  --arg repo "${CLAUDE_PROJECT_DIR:-/home/lkhun9311/workspace/gpu-platform-control-plane}" \
  '{at:$at, tool:$tool, rc:$rc, repo:$repo, cmd:$cmd, stderr:$err}')" >>"$LOG" \
  || echo "$(date -u +%FT%TZ) record-defect: append to $LOG failed" >&2
