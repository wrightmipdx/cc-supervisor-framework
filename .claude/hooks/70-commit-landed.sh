#!/usr/bin/env bash
# Supervisor hook — PostToolUse on Bash
# Records commits that actually landed, with their real size.
#
# WHY THIS EXISTS SEPARATELY FROM THE GATE. 30-commit-gate.sh runs BEFORE the
# command, so everything it knows is an intention: the gate can still deny the
# commit, the user can decline it, and the command can simply fail. Counting
# those as commits would make every size distribution a fiction.
#
# This hook runs after, and asks the only question that settles it: did HEAD
# move? The answer is a fact about the repository rather than about any agent,
# which is why the event is tagged origin=repo. Who typed the command is not
# knowable here and not interesting: a commit is a commit.
#
# The last seen HEAD is remembered per session, so a second invocation cannot
# count the same commit twice.
#
# This hook injects nothing. It only writes to the event log. Fails open.

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-.}"
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
cd "$ROOT" 2>/dev/null || exit 0
. "$LIB/metrics.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

[ -t 0 ] || INPUT=$(cat)
INPUT="${INPUT:-{\}}"

SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null || printf nosession)
metrics_init "$SESSION"

# On the first Bash call of a session this records the starting HEAD and logs
# nothing, which is correct: nothing was committed yet. In a repo with no
# commits at all the baseline is the sentinel 'none', so the first commit made
# during the session still registers as movement.
FIRST=0
[ -f "$(_metrics_head)" ] || FIRST=1

HEAD_NOW=$(metrics_head_moved) || exit 0
[ "$FIRST" -eq 1 ] && exit 0
[ "$HEAD_NOW" = none ] && exit 0

SUBJECT=$(git log -1 --format=%s 2>/dev/null || printf '')
TYPE=$(metrics_commit_type "$SUBJECT")
STAT=$(metrics_numstat_json show --numstat --format= HEAD)

METRICS_ORIGIN=repo metrics_event commit_landed "$(jq -cn \
  --arg head "$HEAD_NOW" --arg type "$TYPE" --argjson stat "$STAT" \
  '{head:$head, commit_type:$type} + $stat' 2>/dev/null || printf '{}')"

exit 0
