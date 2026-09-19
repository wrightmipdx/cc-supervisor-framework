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
. "$LIB/metrics.sh" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')
FLAG="${TMPDIR:-/tmp}/retro-nudged-${SESSION}"

# Stop fires at the end of EVERY assistant turn, not at the end of a session.
# This hook used to treat its flag file as a kill switch, so the one nudge a
# session got was delivered at the end of turn one — when the tree is naturally
# dirty and the ledger naturally open — and it was silent at the real close,
# which is the only moment it was written for.
#
# The flag is a rate limiter now. Re-arms after RETRO_NUDGE_SECONDS.
if [ -f "$FLAG" ]; then
  NOW=$(date +%s 2>/dev/null || printf 0)
  case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac
  # metrics_mtime returns 0 when it cannot read the time, and 0 means nudge: a
  # hook that fails toward saying nothing is a hook you never notice has broken.
  THEN=$(metrics_mtime "$FLAG")
  if [ "$NOW" -gt 0 ] && [ "$THEN" -gt 0 ] \
     && [ $((NOW - THEN)) -lt "${RETRO_NUDGE_SECONDS:-1800}" ]; then
    exit 0
  fi
fi

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

# The failure mode this hook exists to fence is "closing with open
# requirements", and its signature is not a dirty tree — that is just work in
# progress. It is COMMITS LANDED AND THE LEDGER NOT MOVED: something shipped,
# and nothing was marked verified. Best-effort: no log, no jq, no metrics
# directory leaves the gentler wording in place rather than breaking.
metrics_init "$SESSION"
COMMITS=$(grep -c '"event":"commit_landed"' "$(_metrics_log)" 2>/dev/null || printf 0)
case "$COMMITS" in ''|*[!0-9]*) COMMITS=0 ;; esac

if [ "$COMMITS" -gt 0 ] && [ "$OPEN" -gt 0 ]; then
  MSG="SUPERVISOR retro check — ${NOTES}${COMMITS} commit(s) landed this session and the ledger has not moved. Work shipped without being marked verified, which is the failure this check exists for. Run /retro before you finish."
else
  MSG="SUPERVISOR retro check — ${NOTES}Run /retro to close the session cleanly."
fi

touch "$FLAG" 2>/dev/null

jq -n --arg m "$MSG" '{systemMessage: $m}'
exit 0
