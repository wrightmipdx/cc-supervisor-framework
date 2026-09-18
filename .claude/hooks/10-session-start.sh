#!/usr/bin/env bash
# Supervisor hook — SessionStart
# Injects the durable state that a conversation cannot carry: lessons, open
# ledger items, and the active plan. Files survive compaction. Chat does not.
#
# Portable to BSD grep (macOS) and GNU grep. Fails open.

set -uo pipefail

DOCS="${DOCS:-docs}"
ROOT="${CLAUDE_PROJECT_DIR:-.}"
# Resolve the library before cd, so it is found however we were invoked.
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
cd "$ROOT" 2>/dev/null || exit 0
# Fail open: a missing library leaves the hook silent, never broken.
. "$LIB/ledger.sh" 2>/dev/null || exit 0
. "$LIB/lessons.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

SP='[[:space:]]'
CTX=""

# --- lessons -----------------------------------------------------------------
if [ -f "$DOCS/LESSONS.md" ]; then
  # A lesson is one bullet at column 0, however many lines it wraps across.
  # lessons_render reassembles it and reports anything the cap left out.
  LESSONS=$(lessons_render "$DOCS/LESSONS.md" 12 4000)
  if [ -n "$LESSONS" ]; then
    CTX="${CTX}## Lessons from prior sessions
${LESSONS}

"
  fi
fi

# --- ledger ------------------------------------------------------------------
while IFS= read -r LEDGER; do
  [ -n "$LEDGER" ] || continue
  OPEN=$(ledger_count_open "$LEDGER")
  DONE=$(ledger_count_done "$LEDGER")
  if [ "$OPEN" -gt 0 ]; then
    ITEMS=$(ledger_open_items "$LEDGER" 10)
    CTX="${CTX}## Open ledger — ${LEDGER} (${OPEN} open, ${DONE} verified)
${ITEMS}

"
  fi
done <<EOF
$(ledger_files)
EOF

# --- active plan -------------------------------------------------------------
if [ -d "$DOCS/plans" ]; then
  ACTIVE=$(grep -l "^status:${SP}*active" "$DOCS"/plans/*.md 2>/dev/null | head -3 || true)
  if [ -n "$ACTIVE" ]; then
    CTX="${CTX}## Active plans
${ACTIVE}

"
  fi
fi

# --- stale scratch -----------------------------------------------------------
if [ -d scratch ]; then
  N=$(find scratch -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
  N=${N:-0}
  if [ "$N" -gt 0 ]; then
    CTX="${CTX}## Scratch
${N} file(s) left in scratch/ — a previous task did not close cleanly.

"
  fi
fi

[ -z "$CTX" ] && exit 0

CTX="${CTX}Run the intake skill before acting on any request."

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
exit 0
