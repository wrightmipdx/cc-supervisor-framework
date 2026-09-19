#!/usr/bin/env bash
# Supervisor hook — PostToolUse on Agent|Task, and SubagentStop.
#
# Records the two facts a hook can actually know about a dispatched worker:
# that it launched, and that it stopped. It injects nothing and it never blocks.
#
# WHY THIS IS NOT ONE EVENT ANY MORE (0.4.0). Through 0.3.3 both wirings wrote a
# single `dispatch_end` carrying the worker's report — its verdict, its finding
# counts, whether it had an Evidence section. Measured on the first real
# consumer, every one of those fields was empty on every dispatch, because
#
#   AGENTS ON THIS CLAUDE CODE VERSION LAUNCH ASYNCHRONOUSLY.
#
# `Task` returns immediately with a receipt — "Async agent launched
# successfully… agentId: <id>" — and `PostToolUse` fires against THAT, one to
# two seconds after the dispatch, while the worker is still starting up. The
# report arrives much later through `SubagentHandback`, which no hook sees.
#
# The evidence, from 24 paired dispatches: the gap from `dispatch` to the old
# `dispatch_end` was 1.0s twenty times and 2.0s four times, and `report_bytes`
# minus `brief_bytes` fell between +353 and +428 on all 24. The "report size"
# was a function of the BRIEF. It never contained a worker's output, so the
# verdict parsed out of it was `none` 27 times out of 27 while the transcripts
# showed critics returning FIX FIRST over real blockers.
#
# `docs/METRICS.md` used to say "PostToolUse is the better source when it fires:
# its payload carries the worker's report". That was true of a synchronous Task
# tool. Wiring two sources did not save it, because BOTH fire at launch.
#
# So the report fields are gone from this hook. They are not recoverable here at
# any effort, and a field that reports a confident zero it cannot populate is
# worse than a missing one. `.claude/scripts/session-tokens.sh` reads the
# verdict and the finding counts out of the session transcript, where the
# handback actually lands, and joins them back to this log on `agent_id`.
#
# What each wiring now writes:
#
#   PostToolUse  -> dispatch_launched   agent, agent_id        (the join key)
#   SubagentStop -> dispatch_end        duration_s, inflight-1 (real completion)
#
# SubagentStop is the only decrementer now. Through 0.3.3 the decrement happened
# at launch, so the in-flight count returned to zero about a second after every
# dispatch while every worker was still running: `origin` read `ambiguous` zero
# times in 111 logged events, across sessions running eight concurrent builders.
# The safeguard that exists to stop this framework guessing at attribution was
# answering `main` to every question.
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

  # --- launch -------------------------------------------------------------
  # Fires ~1s after the dispatch. Carries no report and never will. Its one
  # piece of real information is the agentId in the launch receipt, and that id
  # is what lets the cost reader say WHICH opus rather than only how much.
  PostToolUse)
    AGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || printf '')

    # The receipt, wherever this version puts it. Matched by shape, not by a
    # fixed path: an id is an id whether tool_response is a string, an object or
    # an array of content blocks.
    #
    # NEVER RENDERED. The harness marks this id internal metadata and forbids
    # quoting it into a user-facing reply. It is a local join handle, it goes to
    # a gitignored log, and nothing reads it but session-tokens.sh.
    AGENT_ID=$(printf '%s' "$INPUT" \
      | jq -r '.tool_response // ""
               | if type == "string" then . else tostring end' 2>/dev/null \
      | grep -oE 'agentId[": ]+[a-f0-9]{8,}' \
      | grep -oE '[a-f0-9]{8,}' \
      | head -1 || true)

    # Written with or without the id. A dispatch that launched is a fact worth
    # recording even on a version that stops printing the receipt; the join
    # degrades to "unjoined runs: N" in the report, which is visible, rather
    # than to a missing event, which is not.
    METRICS_ORIGIN=main metrics_event dispatch_launched "$(jq -cn \
      --arg agent "${AGENT:-unknown}" --arg id "${AGENT_ID:-}" \
      '{agent:$agent, agent_id:(if $id == "" then null else $id end)}' \
      2>/dev/null || printf '{}')"
    exit 0
    ;;

  # --- completion ---------------------------------------------------------
  SubagentStop) ;;

  *) exit 0 ;;
esac

# ATTRIBUTE OR DO NOT LOG — kept verbatim from 0.3.2, and still correct.
#
# Measured on this Claude Code version: SubagentStop fires even when nothing was
# dispatched — four times in a session with zero Agent calls, each carrying no
# agent and no report. Logged blindly, those become phantom completions, and a
# metric with a target turns into noise at exactly the moment it is supposed to
# mean something.
#
# A SubagentStop with no worker in flight did not end a dispatch, whatever the
# harness calls it. What changed in 0.4.0 is only that the counter it consults
# is now truthful: it is decremented HERE, at real completion, instead of at
# launch.
if [ "$(metrics_inflight)" -eq 0 ]; then
  exit 0
fi

# How long the worker ran, from the oldest dispatch still unmatched. Seconds,
# not a report: duration is the one thing this event knows that the transcript
# would otherwise have to infer.
DURATION=$(metrics_dispatch_age)

# One worker fewer in flight. Before logging, so the origin of any later event
# is judged against the corrected count.
metrics_inflight_dec

METRICS_ORIGIN=main metrics_event dispatch_end "$(jq -cn \
  --argjson d "${DURATION:-0}" \
  '{source:"subagent_stop", duration_s:$d}' 2>/dev/null || printf '{}')"

exit 0
