#!/usr/bin/env bash
# Supervisor hook — PostToolUse on Edit/Write/NotebookEdit
# Measured failure mode #3: the Supervisor silently implements solo. Counts edits
# per session and nudges once past the budget.
#
# NOTE: hooks also fire inside subagents. Worker edits therefore count toward
# the same meter, so the threshold is deliberately loose. Treat the nudge as a
# smoke alarm, not an audit. Set EDIT_BUDGET in settings.json env.
#
# Fails open.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

BUDGET="${EDIT_BUDGET:-12}"
INPUT=$(cat)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')
STATE="${TMPDIR:-/tmp}/edits-${SESSION}"

COUNT=0
[ -f "$STATE" ] && COUNT=$(cat "$STATE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
printf '%s' "$COUNT" > "$STATE" 2>/dev/null

# Nudge exactly once, at the threshold.
[ "$COUNT" -ne "$BUDGET" ] && exit 0

jq -n --arg n "$COUNT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("SUPERVISOR: " + $n + " file edits so far this session (workers included — hooks fire inside subagents, so this number is a smoke alarm, not an audit). Only act on it if most of them are yours AND they belong to one long implementation. Small edits inline are correct: volume decides delegation, not difficulty. See prime rule 1 in CLAUDE.md.")
  }
}'
exit 0
