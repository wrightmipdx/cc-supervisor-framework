#!/usr/bin/env bash
# Supervisor hook — SubagentStop, and PostToolUse on Agent|Task
# Records that a dispatched worker finished, and what its report was worth.
#
# This hook injects nothing. It only writes to the event log.
#
# WHY IT IS WIRED TO TWO EVENTS. Which of them a given Claude Code version
# actually fires is not knowable from a script, and docs/INTENT.md forbids
# depending on a harness feature that cannot be verified at install time. So
# both are wired and each event records the `source` it came from.
# .claude/scripts/metrics.sh then counts ONE source — preferring the one that
# carries the report — so wiring both can never double count.
#
# PostToolUse is the better source when it fires: its payload carries the
# worker's report, which is where the verdict and the findings counts come from.
# SubagentStop usually does not, and then only the fact of completion is logged.
#
# Fails open. Never blocks.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
cd "$ROOT" 2>/dev/null || exit 0
. "$LIB/metrics.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

[ -t 0 ] || INPUT=$(cat)
INPUT="${INPUT:-{\}}"

SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null || printf nosession)
metrics_init "$SESSION"

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null || printf '')
case "$EVENT" in
  SubagentStop) SOURCE=subagent_stop ;;
  PostToolUse)  SOURCE=post_tool_use ;;
  *)            SOURCE=unknown ;;
esac

AGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || printf '')

# The report, if this event carries one. Never logged — only measured.
REPORT=$(printf '%s' "$INPUT" \
  | jq -r 'if (.tool_response | type) == "string" then .tool_response
           elif (.tool_response | type) == "object" then (.tool_response.content // .tool_response | tostring)
           elif .tool_response then (.tool_response | tostring)
           else "" end' 2>/dev/null || printf '')

BYTES=0
HAS_EVIDENCE=false
VERDICT=none
BLOCKERS=0; SHOULDFIX=0; NITS=0
if [ -n "$REPORT" ]; then
  BYTES=$(printf '%s' "$REPORT" | wc -c | tr -d ' ')
  printf '%s' "$REPORT" | grep -qi '^#\{1,3\}[[:space:]]*Evidence' && HAS_EVIDENCE=true
  # Both review agents already contract for this line. Parsing it is reading a
  # documented format, not guessing at prose.
  case "$(printf '%s' "$REPORT" | grep -i -m1 '^#\{1,3\}[[:space:]]*Verdict:' || true)" in
    *[Bb][Ll][Oo][Cc][Kk]*)      VERDICT=block ;;
    *[Ff][Ii][Xx]*[Ff][Ii][Rr][Ss][Tt]*) VERDICT=fix_first ;;
    *[Ss][Hh][Ii][Pp]*)          VERDICT=ship ;;
  esac
  BLOCKERS=$(printf '%s' "$REPORT"  | grep -c '^[[:space:]]*-[[:space:]]*\[blocker\]'    || true)
  SHOULDFIX=$(printf '%s' "$REPORT" | grep -c '^[[:space:]]*-[[:space:]]*\[should-fix\]' || true)
  NITS=$(printf '%s' "$REPORT"      | grep -c '^[[:space:]]*-[[:space:]]*\[nit\]'        || true)
fi

# ATTRIBUTE OR DO NOT LOG. Measured on this version: SubagentStop fires even
# when nothing was dispatched — four times in a session with zero Agent calls,
# each carrying no agent and no report. Logged blindly, those become phantom
# reports, and "reports missing an Evidence section, target 0" turns into noise
# at exactly the moment it is supposed to mean something.
#
# A SubagentStop with no worker in flight did not end a dispatch, whatever the
# harness calls it. PostToolUse is trusted on its own because it carries the
# subagent_type: it is answering about a specific Agent call.
if [ "$SOURCE" = subagent_stop ] && [ "$(metrics_inflight)" -eq 0 ]; then
  exit 0
fi

# One worker fewer in flight. Do this before logging so the origin of any later
# event is judged against the corrected count.
metrics_inflight_dec

METRICS_ORIGIN=main metrics_event dispatch_end "$(jq -cn \
  --arg agent "${AGENT:-unknown}" --arg source "$SOURCE" --arg verdict "$VERDICT" \
  --argjson bytes "${BYTES:-0}" --argjson evidence "$HAS_EVIDENCE" \
  --argjson b "${BLOCKERS:-0}" --argjson s "${SHOULDFIX:-0}" --argjson n "${NITS:-0}" \
  '{agent:$agent, source:$source, report_bytes:$bytes, has_evidence:$evidence,
    verdict:$verdict, findings:{blocker:$b, should_fix:$s, nit:$n}}' 2>/dev/null || printf '{}')"

exit 0
