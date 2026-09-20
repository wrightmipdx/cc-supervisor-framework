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

KIT_DOCS="${KIT_DOCS:-docs/kit}"
ROOT="${CLAUDE_PROJECT_DIR:-.}"
# Resolve the library before cd, so it is found however we were invoked.
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
cd "$ROOT" 2>/dev/null || exit 0
# Fail open: a missing library leaves the hook silent, never broken.
. "$LIB/ledger.sh" 2>/dev/null || exit 0
. "$LIB/metrics.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && exit 0
metrics_init "$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')"

deny() {
  # A block is a fact worth keeping: it is the gate doing its job.
  metrics_event gate_block "$(jq -cn --arg k "$2" '{kind:$k}' 2>/dev/null || printf '{}')"
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
# Drop heredoc BODIES, not the rest of the command. An earlier version cut
# everything from the first heredoc operator onward, so anything that came after
# a document -- `cat <<EOF > f` ... `EOF` then `git add -A` -- was never seen.
#
# Known limit: a literal '<<' inside a quoted string on a multi-line command is
# read as an operator, and the lines until a matching delimiter are dropped.
# Quoted spans cannot be stripped first, because a heredoc delimiter may itself
# be quoted. Dropping lines only ever loses a deny, never invents one.
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
    DENY_ADD) deny "$DENY_ADD" blind_add ;;
    DENY_COMMIT) deny "$DENY_COMMIT" blind_commit ;;
    COMMIT) IS_COMMIT=1 ;;
  esac
done <<EOF
$SEGMENTS
EOF

# --- open ledger on commit ---------------------------------------------------
[ "$IS_COMMIT" -eq 1 ] || exit 0

OPEN=$(ledger_total_open)

# LOG FIRST, DECIDE SECOND. The `no open items` path below exits, so a logging
# call appended at the bottom would only ever record commits made with an open
# ledger — exactly half the data, and the wrong half.
#
# This is an ATTEMPT, not a commit: the gate can still deny it, the user can
# decline it, and the command can fail. 70-commit-landed.sh records what
# actually landed. The gap between the two is worth reading.
metrics_event commit_attempt "$(jq -cn \
  --arg type "$(metrics_commit_type "$(printf '%s' "$CMD" | sed -n 's/.*-m[[:space:]]*.\{0,1\}\([a-z]\{2,10\}[(:].*\)/\1/p' | head -1)")" \
  --argjson stat "$(metrics_numstat_json diff --cached --numstat)" \
  --argjson open "${OPEN:-0}" \
  '{commit_type:$type, ledger_open:$open} + $stat' 2>/dev/null || printf '{}')"

[ "$OPEN" -eq 0 ] && exit 0

jq -n --arg n "$OPEN" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: ("SUPERVISOR: " + $n + " ledger item(s) are still open. Committing a verified increment mid-plan is fine. Closing the session with these open is not — run retro before you finish.")
  }
}'
exit 0
