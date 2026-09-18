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
# Resolve the library before cd, so it is found however we were invoked.
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
cd "$ROOT" 2>/dev/null || exit 0
# Fail open: a missing library leaves the hook silent, never broken.
. "$LIB/ledger.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')
FLAG="${TMPDIR:-/tmp}/retro-nudged-${SESSION}"
[ -f "$FLAG" ] && exit 0

NOTES=""

OPEN=$(ledger_total_open)
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
