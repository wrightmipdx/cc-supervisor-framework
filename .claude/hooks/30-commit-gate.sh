#!/usr/bin/env bash
# Supervisor hook — PreToolUse on Bash
# Two jobs:
#   1. BLOCK blind staging. The Supervisor stages this increment's files by
#      path, deliberately.
#   2. WARN when committing with open ledger items (failure mode #2: closing
#      with open requirements). A warning, not a block — partial commits are
#      legitimate mid-plan.
#
# Matching is TOKEN-based, not substring-based. An earlier version matched the
# raw command string and denied any command that merely contained the phrase:
# explicit dotfile paths, commit messages quoting it, even a grep for it. This
# version:
#   - ignores everything after the first heredoc operator (document bodies)
#   - strips quoted spans, so message text and search patterns cannot trip it
#   - inspects only segments that actually invoke git
#   - requires an exact token to count a staging target as blind
#
# Fails open.

set -uo pipefail

DOCS="${DOCS:-docs}"
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

DENY_ADD="SUPERVISOR: blind staging is blocked. Stage only this increment's files by path (git add path/to/file). See the commit skill."
DENY_COMMIT="SUPERVISOR: that commit stages everything tracked. Stage this increment's files by path, then commit without it. See the commit skill."

# --- normalize ---------------------------------------------------------------
# Everything from the first heredoc operator on is document body, not commands.
CMD="${CMD%%<<*}"

# Drop quoted spans so their contents can never match.
SCRUBBED=$(printf '%s' "$CMD" | sed -e "s/'[^']*'/ /g" -e 's/"[^"]*"/ /g')

# One shell command per line.
SEGMENTS=$(printf '%s' "$SCRUBBED" \
  | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/|/\n/g' -e 's/;/\n/g' -e 's/&/\n/g')

# --- classify one segment ----------------------------------------------------
# Echoes: DENY_ADD | DENY_COMMIT | COMMIT | (nothing)
classify() (
  set -f            # no globbing while we word-split
  # shellcheck disable=SC2086
  set -- $1
  [ $# -eq 0 ] && return 0

  # Skip leading VAR=value assignments.
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      *) break ;;
    esac
  done
  [ $# -eq 0 ] && return 0

  # Must actually invoke git.
  case "$1" in
    git|*/git) shift ;;
    *) return 0 ;;
  esac

  # Skip git's global options to reach the subcommand.
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--namespace|--git-dir|--work-tree|--exec-path) shift 2 || return 0 ;;
      --*=*) shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -eq 0 ] && return 0

  SUB="$1"; shift

  case "$SUB" in
    add)
      for t in "$@"; do
        case "$t" in
          --) ;;
          --all) echo DENY_ADD; return 0 ;;
          --*) ;;
          -*[AuU]*) echo DENY_ADD; return 0 ;;
          .|:|:/) echo DENY_ADD; return 0 ;;
        esac
      done
      ;;
    commit)
      for t in "$@"; do
        case "$t" in
          --) ;;
          --all) echo DENY_COMMIT; return 0 ;;
          --*) ;;
          -*a*) echo DENY_COMMIT; return 0 ;;
        esac
      done
      echo COMMIT
      ;;
  esac
  return 0
)

IS_COMMIT=0
while IFS= read -r seg; do
  [ -z "${seg// /}" ] && continue
  case "$(classify "$seg")" in
    DENY_ADD) deny "$DENY_ADD" ;;
    DENY_COMMIT) deny "$DENY_COMMIT" ;;
    COMMIT) IS_COMMIT=1 ;;
  esac
done <<EOF
$SEGMENTS
EOF

# --- open ledger on commit ---------------------------------------------------
[ "$IS_COMMIT" -eq 1 ] || exit 0

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
    additionalContext: ("SUPERVISOR: " + $n + " ledger item(s) are still open. Committing a verified increment mid-plan is fine. Closing the session with these open is not — run retro before you finish.")
  }
}'
exit 0
