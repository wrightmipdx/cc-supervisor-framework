#!/usr/bin/env bash
# Supervisor hook — PreToolUse on Bash
# Logs a `direct_lane` event {task, reason} the moment the chair runs
# .claude/scripts/direct-lane.sh -- the chair's concrete action for "I am
# choosing not to dispatch, and here is why", mirroring how
# 20-pre-delegate.sh logs `dispatch` for a real delegation. session_id is
# only available inside a hook, never to a plain script, which is why this is
# a hook intercepting a marker command rather than a self-logging script.
#
# Reads tool_input.command UNSCRUBBED. 30-commit-gate.sh's SCRUBBED variable
# blanks quoted spans for its own blind-add check; reused here it would also
# blank the `reason` argument this hook exists to capture.
#
# Never denies the underlying command -- this hook only observes, like
# 20-pre-delegate.sh. Fails open.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
# Resolve the library before cd, so it is found however we were invoked.
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
cd "$ROOT" 2>/dev/null || exit 0
# Fail open: a missing library leaves the hook silent, never broken.
. "$LIB/metrics.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && exit 0
metrics_init "$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')"

# --- normalize -----------------------------------------------------------
# Drop heredoc BODIES only, same as 30-commit-gate.sh. Quoted spans are kept
# intact here -- unlike the commit gate, this hook needs the real text of the
# `reason` argument, not a scrubbed copy.
strip_heredoc_bodies() {
  awk '
    BEGIN { q = sprintf("%c", 39)
            re = "<<-?[ \t]*(\"[^\"]*\"|" q "[^" q "]*" q "|[A-Za-z_][A-Za-z0-9_]*)" }
    skip {
      t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t == delim) skip = 0
      next
    }
    {
      line = $0
      if (match(line, re)) {
        d = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", d)
        gsub("[\"" q "]", "", d)
        delim = d; skip = 1
        line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
      }
      print line
    }
  '
}
CMD=$(printf '%s\n' "$CMD" | strip_heredoc_bodies)

# One shell command per line, same operators 30-commit-gate.sh splits on --
# applied to the UNSCRUBBED text, so a quoted `;` or `&&` inside the reason
# argument can misfire this split. Known limit, same class as the commit
# gate's heredoc-inside-a-quote note: matching only ever finds an extra
# segment to inspect, it never invents a denial, and this hook never denies
# anything regardless.
SEGMENTS=$(printf '%s' "$CMD" \
  | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/|/\n/g' -e 's/;/\n/g' -e 's/&/\n/g')

MARKER='.claude/scripts/direct-lane.sh'

# Token-based classification, mirroring 30-commit-gate.sh's classify(): word-
# split the segment (globbing off) and check that the marker is the actual
# command being invoked -- not merely present somewhere in the text.
# 30-commit-gate.sh's own header documents fixing this exact bug once: raw
# substring matching denied (there, blocked; here, would falsely log) any
# command that merely MENTIONED a phrase -- a grep, a cat, an echo, doc text.
matches_marker() (
  set -f            # no globbing while we word-split
  # shellcheck disable=SC2086
  set -- $1
  [ $# -eq 0 ] && return 1

  # Skip leading VAR=value assignments, same as classify().
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -eq 0 ] && return 1

  # The first real word must BE the marker script (bare, or path-qualified),
  # not just contain its text anywhere in the segment.
  case "$1" in
    "$MARKER"|*"/$MARKER") return 0 ;;
    *) return 1 ;;
  esac
)

while IFS= read -r seg; do
  [ -z "${seg// /}" ] && continue
  matches_marker "$seg" || continue

  # Everything after the marker path is the script's own arguments. Safe to
  # locate by substring here: matches_marker already confirmed the first real
  # word IS (or path-ends-with) $MARKER, so $MARKER is guaranteed to occur in
  # $seg at that word's position.
  rest="${seg#*"$MARKER"}"

  # Quote-aware tokenizing without shell evaluation. `eval` would re-expand
  # any $(...)/backticks in the command text -- text about to run for real
  # anyway -- a second time, here, before the actual tool call. `xargs`
  # splits on quotes and whitespace like a shell does but never expands or
  # executes anything.
  TOKENS=$(printf '%s\n' "$rest" | xargs -n1 2>/dev/null || true)
  TASK=$(printf '%s\n' "$TOKENS" | head -1)
  REASON=$(printf '%s\n' "$TOKENS" | tail -n +2 | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')

  # Log something even with no reason argument at all (task-only, or no
  # arguments) -- T3's gate depends on `reason` being non-empty to allow a
  # commit, so a dropped event here would silently fail differently than a
  # denied one.
  METRICS_ORIGIN=main metrics_event direct_lane "$(jq -cn \
    --arg task "${TASK:-}" --arg reason "${REASON:-}" \
    '{task:(if $task == "" then null else $task end), reason:$reason}' \
    2>/dev/null || printf '{}')"
done <<EOF
$SEGMENTS
EOF

exit 0
