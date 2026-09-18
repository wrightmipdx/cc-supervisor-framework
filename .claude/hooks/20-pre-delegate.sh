#!/usr/bin/env bash
# Supervisor hook — PreToolUse on Agent/Task
# Measured failure mode #1: delegating without a ledger. This does not block.
# It reminds, once per session, and only when the ledger is genuinely absent.
#
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
FLAG="${TMPDIR:-/tmp}/ledger-warned-${SESSION}"

# Already warned this session. Stay quiet.
[ -f "$FLAG" ] && exit 0

HAS_ITEMS=0
while IFS= read -r LEDGER; do
  [ -n "$LEDGER" ] || continue
  if ledger_has_items "$LEDGER"; then HAS_ITEMS=1; break; fi
done <<EOF
$(ledger_files)
EOF

[ "$HAS_ITEMS" -eq 1 ] && exit 0

touch "$FLAG" 2>/dev/null

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: "SUPERVISOR: you are delegating and no requirements ledger exists in docs/. If this is a single trivial task, proceed. If this is multi-task work, stop and run the plan skill first — a conversation does not survive compaction, and a ledger does. This reminder fires once per session."
  }
}'
exit 0
