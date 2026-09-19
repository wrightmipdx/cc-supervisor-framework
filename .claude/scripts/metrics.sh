#!/usr/bin/env bash
# Read one session's event log and print what the retro and status skills need.
#
#   .claude/scripts/metrics.sh [log]     # newest session log if omitted
#   .claude/scripts/metrics.sh --cost    # the token cost block on its own
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
  # 0.3.3 and earlier printed a refusal here: three routes existed for token
  # cost and none had been verified, and docs/METRICS.md held that a guessed
  # split inside a governance loop is worse than no split at all.
  #
  # Route 3 — the local session transcript — was verified on 2026-09-19 and
  # built. This now prints real numbers, and session-tokens.sh says UNAVAILABLE
  # with a reason wherever it cannot.
  exec "$(dirname "$0")/session-tokens.sh" "${2:-}"
fi

LOG="${1:-}"
# THE NEWEST LOG IS OFTEN THE WRONG ONE. Every `/clear` starts a new session,
# which fires SessionStart and writes a log holding exactly one `session_start`
# and nothing else. That log is newer than the session you actually worked in,
# so a bare `ls -t | head -1` reports on an empty session and says "none
# logged" about work that happened minutes earlier — a report that is not wrong,
# just answering about the wrong session.
#
# So: newest log that recorded something BESIDES starting up. Skipped logs are
# counted and named, because silently reading a different file than the obvious
# one is its own way to mislead.
SKIPPED=0
if [ -z "$LOG" ]; then
  # Ordering is by mtime, which a glob cannot express portably, and the names
  # are session-<uuid>.jsonl — no spaces to split on.
  # shellcheck disable=SC2012,SC2045
  for CAND in $(ls -t "$METRICS_DIR"/session-*.jsonl 2>/dev/null); do
    if [ "$(jq -r -c 'select(.event != "session_start") | .event' "$CAND" 2>/dev/null | head -1)" != "" ]; then
      LOG="$CAND"; break
    fi
    SKIPPED=$((SKIPPED + 1))
  done
  # Every log is a bare start-up. Report on the newest rather than dying: an
  # empty session is a fact about the session, and "nothing happened" is a
  # legitimate answer when nothing did.
  if [ -z "$LOG" ]; then
    # shellcheck disable=SC2012
    LOG=$(ls -t "$METRICS_DIR"/session-*.jsonl 2>/dev/null | head -1)
    SKIPPED=0
  fi
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
if [ "${SKIPPED:-0}" -gt 0 ]; then
  printf '   skipped %s newer log(s) holding only a session_start — a /clear writes\n' "$SKIPPED"
  printf '   one of those per invocation, and reporting on it would say "none logged"\n'
  printf '   about work that did happen. Name a log explicitly to override.\n'
fi

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

# --- completions ------------------------------------------------------------
# 0.4.0 SPLIT THIS EVENT IN TWO, and dropped the fields it could never fill.
#
# Agents launch asynchronously: `Task` returns a receipt and PostToolUse fires
# against it, so through 0.3.3 the "report" this block read was the brief echoed
# back. Measured over 24 paired dispatches, report_bytes minus brief_bytes was
# +353..+428 every time and the verdict came out `none` on 27 of 27 while the
# transcripts showed critics returning FIX FIRST over real blockers.
#
# So verdict, findings and Evidence are no longer read here. They are read from
# the session transcript by session-tokens.sh, below, where the handback lands —
# next to what each run cost, which is the pairing that decides a tier.
printf '\n## Completions\n'
# A pre-0.4.0 log is recognisable and must not be read as if it were current:
# its dispatch_end events were written at LAUNCH, so counting them as
# completions overstates them and any duration read off them is meaningless.
LEGACY=0
if [ "$N_END" -gt 0 ] && \
   [ "$(printf '%s' "$EV" | jq '[.[] | select(.event == "dispatch_end" and .duration_s != null)] | length')" -eq 0 ]; then
  LEGACY=1
fi
if [ "$LEGACY" -eq 1 ]; then
  printf '   UNAVAILABLE — this log predates 0.4.0. Its %s dispatch_end events were\n' "$N_END"
  printf '   written when each worker LAUNCHED, not when it finished, and they carry\n'
  printf '   no duration. They are not completions and are not counted as any.\n'
  printf '   Token cost below is read from the transcript and is unaffected.\n'
elif [ "$N_END" -eq 0 ]; then
  if [ "$N_DISP" -eq 0 ]; then
    printf '   none — nothing was dispatched\n'
  else
    printf '   UNAVAILABLE — %s dispatch(es) logged, no dispatch_end.\n' "$N_DISP"
    printf '   This version fires no SubagentStop, or every worker is still running.\n'
    printf '   Token cost below does not depend on this event.\n'
  fi
else
  printf '%s' "$EV" | jq -r '
    [.[] | select(.event == "dispatch_end")] as $e
    | "   completed: \($e | length) of '"$N_DISP"' dispatched"
    , (if ([$e[] | select(.duration_s != null)] | length) > 0 then
        "   queue age at completion: min \([$e[].duration_s // 0] | min)s, max \([$e[].duration_s // 0] | max)s"
       else empty end)'
  printf '   Queue age, not a per-worker runtime: workers finish out of order and a\n'
  printf '   hook cannot tell which one stopped. Per-run turn counts are below.\n'
fi

# --- the join ---------------------------------------------------------------
printf '\n## Dispatch join\n'
N_LAUNCH=$(n_of dispatch_launched)
if [ "$N_DISP" -eq 0 ]; then
  printf '   no dispatches this session — every commit was direct-lane work\n'
elif [ "$N_LAUNCH" -eq 0 ]; then
  printf '   UNAVAILABLE — no dispatch_launched events. Worker costs below will\n'
  printf '   report as unjoined: real numbers, unknown roles. Logs written before\n'
  printf '   0.4.0 have none.\n'
else
  printf '%s' "$EV" | jq -r '
    [.[] | select(.event == "dispatch_launched")] as $l
    | "   launched: \($l | length), carrying an agent_id: \([$l[] | select(.agent_id != null)] | length)"'
  printf '   agent_id is what lets the cost report say WHICH opus, not only how much.\n'
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

# Direct lane: a commit with no dispatch since the previous one. This
# establishes only that NO WORKER PRECEDED THE COMMIT — never who wrote the
# code, and never which task it closed. Workers never commit (dispatch rule
# 6), so every commit is chair-TYPED; what this distinguishes is whether a
# worker authored the code that landed. 005/metrics.sh:195-205.
if [ "$N_LAND" -gt 0 ]; then
  DIRECT_ROWS=$(printf '%s' "$EV" | jq -r '
      [.[] | select(.event == "dispatch" or .event == "commit_landed")]
      | reduce .[] as $e ({seen: false, out: []};
          if $e.event == "dispatch" then {seen: true, out: .out}
          elif .seen then {seen: false, out: .out}
          else {seen: false, out: (.out + [$e])} end)
      | .out[]
      | [(.head[0:8]), .commit_type, (.files|tostring), (.insertions|tostring),
         (if (.files > 2 or .insertions > 50) then "1" else "0" end)]
      | @tsv')
  DIRECT_N=0; OVER_N=0
  if [ -n "$DIRECT_ROWS" ]; then
    DIRECT_N=$(printf '%s\n' "$DIRECT_ROWS" | grep -c .)
    OVER_N=$(printf '%s\n' "$DIRECT_ROWS" | awk -F'\t' '$5 == 1' | grep -c .)
  fi
  printf '   direct-lane commits (no dispatch preceding them): %s\n' "$DIRECT_N"
  if [ "$DIRECT_N" -gt 0 ]; then
    printf '   establishes only that no worker preceded the commit, not who wrote it —\n'
    printf '   workers never commit, so every commit is chair-typed.\n'
    printf '%s\n' "$DIRECT_ROWS" | while IFS="$(printf '\t')" read -r H T F I OVER; do
      FLAG=""
      [ "$OVER" = "1" ] && FLAG="  OVER BOUND (dispatch rule 7: <=2 files, <=~50 lines)"
      printf '     %-8s  %-8s files=%s insertions=%s%s\n' "$H" "$T" "$F" "$I" "$FLAG"
    done
    printf '   past the direct lane'"'"'s own hands-on bound (advisory, never\n'
    printf '   enforced): %s\n' "$OVER_N"
  fi
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

printf '\n## Token cost — what this session actually spent\n'
SESSION_ID=$(printf '%s' "$EV" | jq -r '.[0].session // ""')
TOKENS="$(dirname "$0")/session-tokens.sh"
if [ -x "$TOKENS" ]; then
  "$TOKENS" "$SESSION_ID" || printf '   UNAVAILABLE — session-tokens.sh exited non-zero\n'
else
  printf '   UNAVAILABLE — %s is missing or not executable\n' "$TOKENS"
fi
