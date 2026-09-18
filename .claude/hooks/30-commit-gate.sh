#!/usr/bin/env bash
# Fable hook — PreToolUse on Bash
# Two jobs:
#   1. BLOCK blind staging (git add -A / git add . / git commit -a). The chair
#      stages this increment's files, deliberately.
#   2. WARN when committing with open ledger items (failure mode #2: closing
#      with open requirements). A warning, not a block — partial commits are
#      legitimate mid-plan.
#
# Fails open.

set -uo pipefail

DOCS="${FABLE_DOCS:-docs/fable}"
ROOT="${CLAUDE_PROJECT_DIR:-.}"
cd "$ROOT" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && exit 0

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# --- 1. blind staging --------------------------------------------------------
case "$CMD" in
  *"git add -A"*|*"git add --all"*|*"git add ."*|*"git add :/"*)
    deny "FABLE: blind staging is blocked. Stage only this increment's files by path (git add path/to/file). See the fable-commit skill." ;;
  *"git commit -a"*|*"git commit --all"*)
    deny "FABLE: 'git commit -a' stages everything tracked. Stage this increment's files by path, then commit. See the fable-commit skill." ;;
esac

# --- 2. open ledger on commit ------------------------------------------------
case "$CMD" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

OPEN=0
for LEDGER in "$DOCS"/LEDGER.md "$DOCS"/LEDGER-*.md; do
  [ -f "$LEDGER" ] || continue
  case "$LEDGER" in *-archive.md) continue ;; esac
  N=$(grep -c "^[[:space:]]*-[[:space:]]\[ \]" "$LEDGER" 2>/dev/null || true); N=${N:-0}
  OPEN=$((OPEN + N))
done

[ "$OPEN" -eq 0 ] && exit 0

jq -n --arg n "$OPEN" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: ("FABLE: " + $n + " ledger item(s) are still open. Committing a verified increment mid-plan is fine. Closing the session with these open is not — run fable-retro before you finish.")
  }
}'
exit 0
