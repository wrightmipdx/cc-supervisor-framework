#!/usr/bin/env bash
# Read one session's event log and print what the retro and status skills need.
#
#   .claude/scripts/metrics.sh [log]     # newest session log if omitted
#   .claude/scripts/metrics.sh --cost    # says why token cost is not here yet
#
# UNLIKE A HOOK, THIS FAILS LOUDLY. A hook that breaks costs you a session; a
# hook that fails open costs you nothing. This runs because a human asked it to,
# and a silent empty report is worse than an error — it reads as "nothing
# happened" when it means "I could not tell".
#
# Where an event type is missing from the log, every line that depends on it
# says UNAVAILABLE and why. It never prints a zero it cannot stand behind.
#
# Dependencies: jq and git, the same as the hooks. docs/METRICS.md documents the
# event schema this reads.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/.claude/hooks/lib"
METRICS_DIR="${METRICS_DIR:-$ROOT/.metrics}"

die() { printf 'metrics: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

if [ "${1:-}" = "--cost" ]; then
  cat >&2 <<'MSG'
metrics: token cost per tier is NOT IMPLEMENTED, deliberately.

  Three routes exist and each needs verifying before anything depends on it.
  docs/METRICS.md states what each yields and what to check first. Guessing a
  split would be worse than having none: a fabricated number in a governance
  loop is how a budget rule stops meaning anything.

  What IS countable today is in the report this script prints without --cost:
  dispatches by tier, opus dispatches by agent, and what each one found.
MSG
  exit 2
fi

LOG="${1:-}"
if [ -z "$LOG" ]; then
  # shellcheck disable=SC2012
  LOG=$(ls -t "$METRICS_DIR"/session-*.jsonl 2>/dev/null | head -1)
fi
[ -n "$LOG" ]  || die "no session log found in $METRICS_DIR — has a session run since the hooks were installed?"
[ -f "$LOG" ]  || die "no such log: $LOG"
jq -se 'length >= 0' "$LOG" >/dev/null 2>&1 || die "$LOG is not valid JSONL"

EV=$(jq -s '.' "$LOG") || die "cannot parse $LOG"
n_of() { printf '%s' "$EV" | jq --arg e "$1" '[.[] | select(.event == $e)] | length'; }

N_START=$(n_of session_start)
N_DISP=$(n_of dispatch)
N_END=$(n_of dispatch_end)
N_ATT=$(n_of commit_attempt)
N_LAND=$(n_of commit_landed)
N_BLOCK=$(n_of gate_block)

printf '## Session %s\n' "$(printf '%s' "$EV" | jq -r '.[0].session // "unknown"')"
printf '   log: %s\n' "$LOG"

# --- observed span ----------------------------------------------------------
# NOT a session duration. There is no session-end event: the Stop hook fires at
# the end of every assistant turn, so anything it wrote would be stamped at the
# end of turn one. This is first event to last, and it is labelled as such.
if [ "$(printf '%s' "$EV" | jq 'length')" -gt 1 ]; then
  printf '   observed span: %s -> %s\n' \
    "$(printf '%s' "$EV" | jq -r '.[0].ts')" "$(printf '%s' "$EV" | jq -r '.[-1].ts')"
fi

# --- dispatches -------------------------------------------------------------
printf '\n## Dispatches\n'
if [ "$N_DISP" -eq 0 ]; then
  printf '   none logged — every commit this session was direct-lane work\n'
else
  printf '%s' "$EV" | jq -r '
    [.[] | select(.event == "dispatch")] as $d
    | ($d | group_by(.tier) | map("   \(.[0].tier // "unknown"): \(length)") | .[])
    , "   total: \($d | length)   opus: \([$d[] | select(.tier == "opus")] | length)"'
fi

# --- reports ----------------------------------------------------------------
printf '\n## Reports\n'
if [ "$N_END" -eq 0 ]; then
  printf '   UNAVAILABLE — no dispatch_end events in this log.\n'
  printf '   This version fires neither SubagentStop nor PostToolUse on Agent, or no\n'
  printf '   worker finished. Run .claude/install-check.sh --probe. The ratio and the\n'
  printf '   value report below need this event and are not computed without it.\n'
else
  # Count ONE source. 60-dispatch-end.sh is wired to two events on purpose, and
  # preferring the richer one is what stops that double counting.
  SRC=$(printf '%s' "$EV" | jq -r '
    [.[] | select(.event == "dispatch_end") | .source] as $s
    | if ($s | index("post_tool_use")) then "post_tool_use"
      elif ($s | index("subagent_stop")) then "subagent_stop"
      else ($s[0] // "unknown") end')
  printf '   source in use: %s\n' "$SRC"
  printf '%s' "$EV" | jq -r --arg src "$SRC" '
    [.[] | select(.event == "dispatch_end" and .source == $src)] as $e
    | "   reports: \($e | length)"
    , "   missing an Evidence section: \([$e[] | select(.has_evidence == false)] | length)   (target 0)"'

  printf '\n## Dispatch-to-report ratio — the resume signal\n'
  printf '%s' "$EV" | jq -r --arg src "$SRC" '
    ([.[] | select(.event == "dispatch")] | group_by(.agent)
     | map({key: (.[0].agent // "unknown"), value: length}) | from_entries) as $sent
    | ([.[] | select(.event == "dispatch_end" and .source == $src)] | group_by(.agent)
     | map({key: (.[0].agent // "unknown"), value: length}) | from_entries) as $back
    | $sent | to_entries[]
    | "   \(.key): \(.value) sent, \($back[.key] // 0) returned"'
  printf '   A worker sent more often than it returned was resumed. Budget one\n'
  printf '   resume per dispatch; a second means the brief was too large.\n'

  # --- the value report ----------------------------------------------------
  printf '\n## Opus value — what the expensive lanes actually found\n'
  printf '   The ~25%% opus ceiling is a goal, not a gate. Judge it here, against\n'
  printf '   what the spend bought, not against the percentage alone.\n\n'
  # Dispatches and their reports are paired by order within the opus lanes,
  # which is what the log supports: a dispatch_end carries the agent but not the
  # task id. Out-of-order completion of two concurrent opus workers would swap a
  # pair of task labels and nothing else.
  printf '%s' "$EV" | jq -r --arg src "$SRC" '
    ([.[] | select(.event == "dispatch" and .tier == "opus")]) as $od
    | ([.[] | select(.event == "dispatch_end" and .source == $src
                     and (.agent == "critic" or .agent == "architect"))]) as $oe
    | if ($od | length) == 0 then "   no opus dispatches this session"
      else
        [range(0; ($od | length))]
        | map(. as $i | ($od[$i]) as $d | ($oe[$i] // null) as $r
              | "   \($d.agent) \($d.task // "-"): "
                + (if $r == null then "no report logged"
                   else "verdict \($r.verdict), \($r.findings.blocker // 0) blocker(s), "
                        + "\($r.findings.should_fix // 0) should-fix" end))
        | .[]
      end'
  printf '%s' "$EV" | jq -r --arg src "$SRC" '
    [.[] | select(.event == "dispatch_end" and .source == $src
                  and (.agent == "critic" or .agent == "architect"))] as $oe
    | if ($oe | length) == 0 then "   (no opus reports carrying a verdict)"
      else
        "   " + ((($oe | map(select(.agent == "critic" and .verdict == "ship"
                                    and ((.findings.blocker // 0) == 0)))) | length) | tostring)
        + " critic dispatch(es) returned SHIP with no blockers — downgrade candidates"
        , "   " + ((($oe | map(select(.verdict == "block" or .verdict == "fix_first"))) | length) | tostring)
        + " returned BLOCK or FIX FIRST — these paid for themselves"
      end'
fi

# --- commits ----------------------------------------------------------------
printf '\n## Commits\n'
if [ "$N_LAND" -eq 0 ]; then
  printf '   none landed this session'
  [ "$N_ATT" -gt 0 ] && printf ' (%s attempt(s) logged)' "$N_ATT"
  printf '\n'
else
  printf '%s' "$EV" | jq -r '
    [.[] | select(.event == "commit_landed")] as $c
    | "   landed: \($c | length)"
    , "   insertions: min \([$c[].insertions] | min), median \([$c[].insertions] | sort | .[length/2|floor]), max \([$c[].insertions] | max)"
    , "   over the commit skill'"'"'s ~400 line advisory bound: \([$c[] | select(.insertions > 400)] | length)"
    , "   by type: \($c | group_by(.commit_type) | map("\(.[0].commit_type)=\(length)") | join(" "))"'
  printf '   The bound is advisory. Exceeding it is not a failure; it is a thing to\n'
  printf '   say a reason for at retro.\n'
fi
if [ "$N_ATT" -gt 0 ] && [ "$N_LAND" -gt 0 ] && [ "$N_ATT" -gt "$N_LAND" ]; then
  printf '   attempted but not landed: %s — denied by the gate, declined, or failed\n' \
    "$((N_ATT - N_LAND))"
fi
[ "$N_BLOCK" -gt 0 ] && printf '   blind staging blocked by the gate: %s\n' "$N_BLOCK"

# Direct lane: a commit with no dispatch since the previous one.
if [ "$N_LAND" -gt 0 ]; then
  printf '   direct-lane commits (no dispatch preceding them): %s\n' \
    "$(printf '%s' "$EV" | jq '
        [.[] | select(.event == "dispatch" or .event == "commit_landed")]
        | reduce .[] as $e ({seen: false, n: 0};
            if $e.event == "dispatch" then .seen = true
            else {seen: false, n: (.n + (if .seen then 0 else 1 end))} end)
        | .n')"
fi

# --- ledger -----------------------------------------------------------------
printf '\n## Ledger\n'
if [ "$N_START" -eq 0 ]; then
  printf '   UNAVAILABLE — no session_start event, so there is no opening count to\n'
  printf '   compare against.\n'
else
  OPEN0=$(printf '%s' "$EV" | jq -r '[.[] | select(.event == "session_start")][0].ledger_open // "?"')
  NOW="?"
  if [ -f "$LIB/ledger.sh" ]; then
    # shellcheck disable=SC1091
    . "$LIB/ledger.sh" && cd "$ROOT" && NOW=$(ledger_total_open)
  fi
  printf '   open at session start: %s\n' "$OPEN0"
  printf '   open now (this repo): %s\n' "$NOW"
fi

printf '\n## Token cost\n'
printf '   NOT IMPLEMENTED — see docs/METRICS.md. Run with --cost for why.\n'
