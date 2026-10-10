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
# THE PAYLOAD'S SHAPE FOR BASH IS NOW MEASURED, and the answer is not a different field name: there is no
# exit-status field at all. `tool_response` for a Bash call carries exactly interrupted, isImage,
# noOutputExpected, stderr and stdout. This hook fired 66 times on 2026-09-30 -- every Bash call in the
# session, including a deliberate `ls` of a path that does not exist -- and every one of them landed in the
# `unknown` branch and recorded nothing. So the recorder was installed, armed, running, and blind.
#
# It said so, 66 times, in its own log. That is the only reason the diagnosis took minutes: this file does not
# end in `|| true` and does not send stderr to /dev/null, and the line it wrote names the keys it did find.
#
# The key NAMES do not separate failure from success -- a failing call and a succeeding one produce the same
# set. The difference must be in the values, so the values are being measured too rather than guessed at; see
# the capture block below. Until that is settled this hook records nothing for Bash, which is the honest
# behaviour: `rc=unknown` is not evidence of failure and must not be written as one.
#
# `tool_input` was never in doubt -- mirror-to-storage.sh reads `.tool_input.file_path` and works.
set -uo pipefail

# storage/gpu-platform-control-plane/defects, beside the project's own copy in storage.
#
# `defects` not `issues`: the two were split on 2026-09-30, where a defect is something that is wrong and an
# issue is something that is blocked. A command that failed belongs with defects.
#
# This path moved four times on 2026-09-30 -- storage/issues, storage/defects, storage/gpuaas/defects, and
# finally here, into the project folder storage already had. Every move needed this line changed with it, and
# a recorder left pointing at a stale path silently recreates the old directory and splits the record across
# two trees. So each move is verified by writing one line and reading it back, not by editing this string and
# trusting it.
#
# One thing to know about this destination: it is also where hack/../.claude/hooks/mirror-to-storage.sh
# copies edited project files. That hook only writes paths that exist in the project, and the project has no
# `defects/`, so nothing collides today. If one is ever added there, these records are in its way.
LOG_DIR="/home/lkhun9311/workspace/storage/gpu-platform-control-plane/defects/hook-log"
LOG="$LOG_DIR/$(date -u +%Y-%m).jsonl"
SELF_LOG="/home/lkhun9311/workspace/gpu-platform-control-plane/.claude/hooks/record-defect.log"

# A one-off measurement of the payload shape, armed by creating CAPTURE_FLAG and disarmed by deleting it.
#
# Gated on a file rather than an environment variable because a PostToolUse hook runs in its own process and
# inherits nothing from the session that triggered it -- an env var set in a session's own shell would never
# reach here, and a gate that can never open reads exactly like one that opened and found nothing.
#
# Both paths are under `.claude/`, which is gitignored: a raw payload carries command text and output, and
# that belongs in a local diagnosis file, not in a records tree that gets committed.
CAPTURE_FLAG="/home/lkhun9311/workspace/gpu-platform-control-plane/.claude/hooks/record-defect-capture.on"
CAPTURE_LOG="/home/lkhun9311/workspace/gpu-platform-control-plane/.claude/hooks/record-defect-payloads.jsonl"

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

# The capture sits HERE, ahead of every branch, and not inside one of them.
#
# Its first version was inside the `unknown` arm, so it could only ever see payloads that reached that arm. A
# deliberately failing command produced no sample at all, and that silence is indistinguishable from "the hook
# did not fire" -- the same defect class this whole file exists to catch, committed by the instrument built to
# diagnose it. A probe that can observe one outcome cannot tell you which outcome happened.
#
# The computed rc travels with the sample, so the record says which branch the payload would take.
#
# Each field is truncated by jq rather than by `cut -c` or `head -c`, both of which cut bytes and split a
# multi-byte character in half. A broken UTF-8 log has cost this repository a diagnosis before: a Korean
# document sliced at a byte offset made codex refuse its own arguments, and the hook that did it was silent.
if [ -f "$CAPTURE_FLAG" ]; then
  printf '%s' "$payload" | jq -c --arg rc "$rc" '
    {
      at: (now | todate),
      computed_rc: $rc,
      tool_name,
      top_level_keys: keys,
      tool_input: (.tool_input // {} | if type == "object" then with_entries(.value |= (tostring | .[0:300])) else tostring | .[0:300] end),
      tool_response_type: (.tool_response | type),
      tool_response: (.tool_response // null | if type == "object" then with_entries(.value |= (tostring | .[0:300])) else tostring | .[0:300] end)
    }' >>"$CAPTURE_LOG" \
    || echo "$(date -u +%FT%TZ) record-defect: payload capture failed" >&2
fi

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
