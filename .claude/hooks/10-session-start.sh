#!/usr/bin/env bash
# Supervisor hook — SessionStart
# Injects the durable state that a conversation cannot carry: lessons, open
# ledger items, and the active plan. Files survive compaction. Chat does not.
#
# Portable to BSD grep (macOS) and GNU grep. Fails open.

set -uo pipefail

DOCS="${DOCS:-docs}"
ROOT="${CLAUDE_PROJECT_DIR:-.}"
cd "$ROOT" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

SP='[[:space:]]'
CTX=""

# --- lessons -----------------------------------------------------------------
if [ -f "$DOCS/LESSONS.md" ]; then
  # Only bullet lines count as lessons. Header prose is instructions, not data.
  LESSONS=$(grep "^-${SP}" "$DOCS/LESSONS.md" | grep -v '(seed) none yet' | head -12 || true)
  if [ -n "$LESSONS" ]; then
    CTX="${CTX}## Lessons from prior sessions
${LESSONS}

"
  fi
fi

# --- ledger ------------------------------------------------------------------
for LEDGER in "$DOCS"/LEDGER.md "$DOCS"/LEDGER-*.md; do
  [ -f "$LEDGER" ] || continue
  case "$LEDGER" in *-archive.md) continue ;; esac
  OPEN=$(grep -c "^${SP}*-${SP}\[ \]" "$LEDGER" 2>/dev/null || true)
  DONE=$(grep -c "^${SP}*-${SP}\[x\]" "$LEDGER" 2>/dev/null || true)
  OPEN=${OPEN:-0}; DONE=${DONE:-0}
  if [ "$OPEN" -gt 0 ]; then
    ITEMS=$(grep "^${SP}*-${SP}\[ \]" "$LEDGER" | head -10 || true)
    CTX="${CTX}## Open ledger — ${LEDGER} (${OPEN} open, ${DONE} verified)
${ITEMS}

"
  fi
done

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
