#!/usr/bin/env bash
# The campaign manifest exists, is written before the first run, and every exit from a run records itself.
#
# 2026-09-22-the-retry-rule-had-nothing-counting-it.md registers that a campaign must leave an attempt
# history. Deleting the whole manifest block left `bash -n` green, `make shell-check` green and
# `make session-refusals` green -- so nothing guarded it, which is the same gap the refusals had.
#
# WHAT THIS CANNOT DO, stated so the green is not read as more than it is:
#
# The manifest is written after prepare(), which needs a cluster and a rented card, so this file cannot run
# the script and read the file it produces. It asserts the STRUCTURE instead: that the block is there, that
# it precedes the run loop, and that each way out of a run calls the recorder. A manifest that is written
# but whose contents are wrong would pass here. The only thing that settles that is a paid session, and the
# manifest is the artifact that will show it.
set -uo pipefail

SCRIPT="$(dirname "$0")/gpu-session.sh"
failures=0

fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}

line_of() {
  grep -n -- "$1" "$SCRIPT" | head -1 | cut -d: -f1
}

# The file has to be created, not just named. A variable assignment with no redirection would satisfy a
# grep for MANIFEST and produce nothing.
if grep -q '} > "\$MANIFEST"' "$SCRIPT"; then
  echo "ok   the manifest is written to a file"
else
  fail "nothing redirects into \$MANIFEST; the manifest is named but never created"
fi

# What a reader needs in order to judge a campaign: which study, which attempt, and the planned order. The
# attempt is the one that distinguishes a re-entry's records from the ones it resumed over.
for field in "study " "attempt " "planned order:" "outcomes:"; do
  if grep -q "echo \"$field" "$SCRIPT" || grep -q "echo \"  \$i" "$SCRIPT"; then
    echo "ok   the manifest header carries '$field'"
  else
    fail "the manifest header does not carry '$field'"
  fi
done

# Written BEFORE the first run start, which is the half that matters: a manifest assembled at the end
# documents only the campaigns that reached the end.
#
# The anchor is `deadline_check`, not the `for SPEC` line. There are THREE loops over SEQUENCE -- the DOSES
# filter, the manifest's own planned-order listing, and the run loop -- and the first draft of this check
# anchored on the first of them and reported the script broken when it was not. `deadline_check` runs once
# per run and nowhere else, so it marks where spending begins.
manifest_line="$(line_of 'MANIFEST="$EXDIR/campaign.txt"')"
loop_line="$(line_of 'deadline_check || exit 1')"
if [[ -z "$manifest_line" || -z "$loop_line" ]]; then
  fail "cannot locate the manifest block or the first run start"
elif (( manifest_line < loop_line )); then
  echo "ok   the manifest is written before the first run start"
else
  fail "the manifest is written at or after the first run start (manifest $manifest_line, run $loop_line)"
fi

# Every way out of a run has to leave a line. A history that records only successes cannot tell "not
# attempted" from "attempted and refused", which is the distinction the page registered.
want_outcomes=3
got_outcomes="$(grep -c 'manifest_outcome "' "$SCRIPT" || true)"
if (( got_outcomes >= want_outcomes )); then
  echo "ok   $got_outcomes run outcomes are recorded (skipped, failed, ok)"
else
  fail "only $got_outcomes manifest_outcome call(s); a run can end without recording itself"
fi

for kind in skipped FAILED ok; do
  if grep -q "manifest_outcome \"\$N\" \"$kind\"" "$SCRIPT"; then
    echo "ok   a '$kind' run records itself"
  else
    fail "a '$kind' run does not record itself in the manifest"
  fi
done

# The recorder must not be able to kill the session it is documenting.
if grep -q 'printf .* >> "\$MANIFEST" || true' "$SCRIPT"; then
  echo "ok   a failed manifest append does not end the run"
else
  fail "manifest_outcome can fail the session under set -e; a bookkeeping error would discard a paid run"
fi

if [[ $failures -ne 0 ]]; then
  echo "$failures manifest property/properties did not hold" >&2
  exit 1
fi
echo "the campaign manifest is written before the runs, and every run exit records itself"
