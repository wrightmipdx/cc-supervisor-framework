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

# TOKENIZE THE WHOLE COMMAND FIRST, quote-aware, THEN look for operators --
# not the other way around. An earlier version split on `;`/`&&`/`|`/`&` as
# raw text before any tokenizing, so a semicolon or ampersand INSIDE the
# reason argument's own quotes (ordinary English punctuation -- "did X, then
# Y; verified Z") silently truncated the reason to whatever came before it,
# logging an event this hook itself could not tell was wrong. Reproduced live
# in this very session (2026-09-20): a reason containing "; verified" against
# the previous version logged `reason:""`, which then correctly, but
# needlessly, tripped 30-commit-gate.sh's DENY_NO_REASON.
#
# `xargs -n1` tokenizes the ENTIRE command respecting quotes -- a `;` inside
# a quoted string is just a character to it, never a separator, because xargs
# has no concept of shell operators at all. So: tokenize everything first,
# then walk the token stream ourselves looking for a token that IS (exactly)
# one of the operator strings -- which only happens when that operator
# appeared OUTSIDE any quoting, with whitespace around it, in the original
# command. `eval` is never used: it would re-expand any $(...)/backtick in
# the command text a second time, here, before the real tool call runs it.
#
# Known limits, same shape as 30-commit-gate.sh's own heredoc-inside-a-quote
# note: an operator glued to adjacent text with NO surrounding whitespace
# (`cmd1;cmd2`, no spaces) is not isolated by xargs into its own token, so it
# is not recognized as a boundary here. `xargs` also strips quoting, so a
# task/reason argument whose ENTIRE content is one of the operator strings
# (a reason of literally `";"`, nothing else) is indistinguishable from a
# bare unquoted operator and truncates the reason there -- not realistic
# chair prose, but a real edge. A chair-typed command chaining two commands
# always has spaces around the operator; this hook never denies anything
# regardless, so either miss only ever means one MORE token gets swept into
# a reason, or a reason cut short -- never a false denial.
MARKER='.claude/scripts/direct-lane.sh'
is_operator() {
  case "$1" in
    ';'|'&&'|'||'|'|'|'&') return 0 ;;
    *) return 1 ;;
  esac
}

TOKENS_RAW=$(printf '%s\n' "$CMD" | xargs -n1 2>/dev/null || true)
TOK=()
while IFS= read -r t; do
  TOK+=("$t")
done <<EOF
$TOKENS_RAW
EOF

N=${#TOK[@]}
I=0
SEG_START=1
while [ "$I" -lt "$N" ]; do
  T="${TOK[$I]}"
  if is_operator "$T"; then
    SEG_START=1
    I=$((I + 1))
    continue
  fi
  if [ "$SEG_START" -eq 1 ]; then
    # Skip leading VAR=value assignments, same as 30-commit-gate.sh's
    # classify() does for a segment's own leading words.
    case "$T" in
      [A-Za-z_]*=*) I=$((I + 1)); continue ;;
    esac
    SEG_START=0
  fi
  case "$T" in
    "$MARKER"|*"/$MARKER")
      TASK="${TOK[$((I + 1))]:-}"
      REASON=""
      J=$((I + 2))
      while [ "$J" -lt "$N" ]; do
        RT="${TOK[$J]}"
        is_operator "$RT" && break
        REASON="${REASON}${REASON:+ }${RT}"
        J=$((J + 1))
      done
      # Log something even with no reason argument at all (task-only, or no
      # arguments) -- T3's gate depends on `reason` being non-empty to allow
      # a commit, so a dropped event here would silently fail differently
      # than a denied one.
      METRICS_ORIGIN=main metrics_event direct_lane "$(jq -cn \
        --arg task "${TASK:-}" --arg reason "${REASON:-}" \
        '{task:(if $task == "" then null else $task end), reason:$reason}' \
        2>/dev/null || printf '{}')"
      I="$J"
      SEG_START=1
      continue
      ;;
  esac
  I=$((I + 1))
done

exit 0
