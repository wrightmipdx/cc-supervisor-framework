#!/usr/bin/env bash
# Supervisor hook — Stop
# Reminds the Supervisor to close properly: open ledger items, a dirty tree, or
# leftover scratch all mean the session is not finished.
#
# Never blocks. A blocking Stop hook can loop.
# Fails open.

set -uo pipefail

DOCS="${DOCS:-docs}"
ROOT="${CLAUDE_PROJECT_DIR:-.}"
cd "$ROOT" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')
FLAG="${TMPDIR:-/tmp}/retro-nudged-${SESSION}"
[ -f "$FLAG" ] && exit 0

NOTES=""

OPEN=0
for LEDGER in "$DOCS"/LEDGER.md "$DOCS"/LEDGER-*.md; do
  [ -f "$LEDGER" ] || continue
  case "$LEDGER" in *-archive.md) continue ;; esac
  N=$(grep -c "^[[:space:]]*-[[:space:]]\[ \]" "$LEDGER" 2>/dev/null || true); N=${N:-0}
  OPEN=$((OPEN + N))
done
[ "$OPEN" -gt 0 ] && NOTES="${NOTES}${OPEN} open ledger item(s). "

if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [ "$DIRTY" -gt 0 ] && NOTES="${NOTES}${DIRTY} uncommitted file(s). "
fi

if [ -d scratch ]; then
  S=$(find scratch -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
  [ "$S" -gt 0 ] && NOTES="${NOTES}${S} file(s) left in scratch/. "
fi

[ -z "$NOTES" ] && exit 0

touch "$FLAG" 2>/dev/null

jq -n --arg n "$NOTES" '{
  systemMessage: ("SUPERVISOR retro check — " + $n + "Run /retro to close the session cleanly.")
}'
exit 0
