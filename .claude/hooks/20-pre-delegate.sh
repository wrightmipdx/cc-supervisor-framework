#!/usr/bin/env bash
# Fable hook — PreToolUse on Agent/Task
# Measured failure mode #1: delegating without a ledger. This does not block.
# It reminds, once per session, and only when the ledger is genuinely absent.
#
# Fails open.

set -uo pipefail

DOCS="${FABLE_DOCS:-docs/fable}"
ROOT="${CLAUDE_PROJECT_DIR:-.}"
cd "$ROOT" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')
FLAG="${TMPDIR:-/tmp}/fable-ledger-warned-${SESSION}"

# Already warned this session. Stay quiet.
[ -f "$FLAG" ] && exit 0

HAS_ITEMS=0
for LEDGER in "$DOCS"/LEDGER.md "$DOCS"/LEDGER-*.md; do
  [ -f "$LEDGER" ] || continue
  case "$LEDGER" in *-archive.md) continue ;; esac
  if grep -q "^[[:space:]]*-[[:space:]]\[[ x~]\]" "$LEDGER" 2>/dev/null; then
    HAS_ITEMS=1
    break
  fi
done

[ "$HAS_ITEMS" -eq 1 ] && exit 0

touch "$FLAG" 2>/dev/null

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: "FABLE: you are delegating and no requirements ledger exists in docs/fable/. If this is a single trivial task, proceed. If this is multi-task work, stop and run the fable-plan skill first — a conversation does not survive compaction, and a ledger does. This reminder fires once per session."
  }
}'
exit 0
