#!/usr/bin/env bash
# Session event log, written by hooks and read by .claude/scripts/metrics.sh.
#
# WHAT THIS IS FOR. CLAUDE.md prime rule 2 orders the Supervisor to govern the
# combined opus share, and the retro skill forbade it from estimating that
# share. The rule had no instrument. This is the instrument: hooks append facts,
# nothing else writes, and one script reads the file at retro.
#
# THREE RULES, all of them learned the hard way.
#
# 1. NEVER BREAK A HOOK. Every write is append-only and swallowed. A missing
#    directory, a read-only disk, a missing jq: the hook carries on and emits
#    exactly what it emitted before. Logging is worth nothing next to the
#    context injection the hooks exist for.
#
# 2. NEVER LOG CONTENT. Sizes, counts, verdicts and types. Never a brief, never
#    a report, never a diff. The log lives in the repo and must be boring.
#
# 3. ATTRIBUTE OR SAY YOU CANNOT. Hooks fire inside subagents too — an earlier
#    edit-budget hook was removed because a builder tripped it unaided. Some
#    events are provably from the main session; some are not, and those say so
#    rather than guessing. See metrics_origin.

METRICS_DIR="${METRICS_DIR:-.metrics}"
METRICS_SESSION="${METRICS_SESSION:-nosession}"

metrics_init() {   # metrics_init <session_id>
  METRICS_SESSION="${1:-nosession}"
  mkdir -p "$METRICS_DIR" 2>/dev/null || true
}

_metrics_log()      { printf '%s/session-%s.jsonl' "$METRICS_DIR" "$METRICS_SESSION"; }
_metrics_inflight() { printf '%s/.inflight-%s'     "$METRICS_DIR" "$METRICS_SESSION"; }
_metrics_head()     { printf '%s/.head-%s'         "$METRICS_DIR" "$METRICS_SESSION"; }

# How many dispatched workers are believed to be running right now. This is the
# only handle we have on attribution: a Bash call with none in flight is the
# Supervisor's; with one or more in flight it could be anyone's.
metrics_inflight() {
  local n; n=$(cat "$(_metrics_inflight)" 2>/dev/null || printf 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}
metrics_inflight_inc() {
  printf '%s' "$(( $(metrics_inflight) + 1 ))" > "$(_metrics_inflight)" 2>/dev/null || true
}
metrics_inflight_dec() {
  local n; n=$(metrics_inflight)
  if [ "$n" -gt 0 ]; then n=$((n - 1)); fi
  printf '%s' "$n" > "$(_metrics_inflight)" 2>/dev/null || true
}

# main       — provably the main session: either this event source does not fire
#              in a subagent, or no worker was in flight when it did.
# ambiguous  — a worker was in flight, so this could be the Supervisor or the
#              worker. Recorded as ambiguous rather than attributed by guess.
# repo       — a fact about the repository, not about any agent: HEAD moved.
#              Who ran the command is neither known nor interesting.
metrics_origin() {
  if [ -n "${METRICS_ORIGIN:-}" ]; then printf '%s' "$METRICS_ORIGIN"; return 0; fi
  if [ "$(metrics_inflight)" -gt 0 ]; then printf 'ambiguous'; else printf 'main'; fi
}

# metrics_event <type> [json-object]
# Appends one line. Failure of any kind is silent and never propagates.
metrics_event() {
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "$METRICS_DIR" ] || return 0
  # The whole group is wrapped, not just jq: when the APPEND itself fails —
  # a read-only log file — bash writes "Permission denied" to stderr before jq
  # ever runs, and a hook that chatters on stderr is a hook that broke.
  { jq -cn \
      --arg e "$1" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg s "$METRICS_SESSION" \
      --arg o "$(metrics_origin)" \
      --argjson x "${2:-{\}}" \
      '{event:$e, ts:$ts, session:$s, origin:$o} + $x' \
      >> "$(_metrics_log)"
  } 2>/dev/null || true
}

# File mtime in epoch seconds, or 0 if it cannot be read.
#
# GNU stat is probed FIRST, and the order is the whole point. On Linux `stat -f`
# means --file-system, so the BSD-first spelling does not fail there — it
# SUCCEEDS and returns something that is not an mtime, which is worse. BSD stat
# has no -c and fails cleanly, so trying -c first is safe on both.
metrics_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=''
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

# --- helpers the hooks share -------------------------------------------------

# The ledger and lesson shape of the repo right now. Needs lib/ledger.sh and
# lib/lessons.sh sourced; prints an empty object when they are not.
metrics_state_json() {
  command -v jq >/dev/null 2>&1 || { printf '{}'; return 0; }
  local open=0 verified=0 defer=0 lessons=0 f
  if command -v ledger_files >/dev/null 2>&1; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      open=$((open + $(ledger_count_open "$f")))
      verified=$((verified + $(ledger_count_done "$f")))
      defer=$((defer + $(ledger_count_deferred "$f")))
    done <<EOF
$(ledger_files)
EOF
  fi
  if command -v lessons_count >/dev/null 2>&1; then
    lessons=$(lessons_count "${DOCS:-docs}/LESSONS.md")
  fi
  jq -cn --argjson o "$open" --argjson d "$verified" --argjson f "$defer" --argjson l "$lessons" \
     '{ledger_open:$o, ledger_verified:$d, ledger_deferred:$f, lessons:$l}' 2>/dev/null || printf '{}'
}

# Conventional-commit type of a message, or "none".
metrics_commit_type() {
  local t
  t=$(printf '%s' "$1" | sed -n '1s/^\([a-z][a-z]*\)[(!:].*/\1/p')
  case "$t" in
    feat|fix|refactor|test|docs|chore|perf|ci|build|style|revert) printf '%s' "$t" ;;
    *) printf 'none' ;;
  esac
}

# git numstat -> {files, insertions, deletions}. Takes the git args to run.
metrics_numstat_json() {
  git "$@" 2>/dev/null | awk '
    $1 ~ /^[0-9]+$/ { ins += $1 }
    $2 ~ /^[0-9]+$/ { del += $2 }
                    { n++ }
    END { printf "{\"files\":%d,\"insertions\":%d,\"deletions\":%d}", n+0, ins+0, del+0 }
  ' 2>/dev/null || printf '{"files":0,"insertions":0,"deletions":0}'
}

# Has HEAD moved since we last looked in this session? Prints the new sha and
# returns 0, or returns 1 and prints nothing. Recording the sha is what stops a
# second hook invocation counting the same commit twice.
metrics_head_moved() {
  local now last
  # A repo with no commits yet prints the sentinel rather than failing. Without
  # it, the baseline is never recorded in an empty repo and the FIRST commit
  # made in that session goes unlogged — every call keeps looking like the
  # first one.
  # --verify --quiet, NOT a bare rev-parse: in a repo with no commits `git
  # rev-parse HEAD` prints the literal string "HEAD" on stdout and then fails,
  # so the obvious `|| printf none` yields "HEADnone" and the sentinel silently
  # stops working.
  now=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || now=''
  [ -n "$now" ] || now=none
  last=$(cat "$(_metrics_head)" 2>/dev/null || printf '')
  [ "$now" = "$last" ] && return 1
  printf '%s' "$now" > "$(_metrics_head)" 2>/dev/null || true
  printf '%s' "$now"
}
