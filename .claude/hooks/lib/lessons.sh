#!/usr/bin/env bash
# Lessons rendering, for the SessionStart hook.
#
# WHY THIS FILE EXISTS. The hook used to do this:
#
#     grep "^- " docs/LESSONS.md | head -12
#
# which takes one PHYSICAL line per lesson. A lesson long enough to wrap — most
# of them — arrived at the next session cut off mid-sentence:
#
#     - 2026-09-18 (003) — Every builder (7/7) and every critic (5/5) hit its turn
#
# and that was the whole lesson, the point of it amputated. Worse, a file with
# more lessons than the cap dropped the remainder with no sign it had done so.
#
# A lesson is one bullet starting at column 0. Continuation lines are indented.
# Reassemble, cap on both count and characters, and SAY what was left out.
#
# Portable to BSD and GNU awk: no character classes, no GNU extensions.

# lessons_render <file> [max_entries] [max_chars]
lessons_render() {
  [ -f "$1" ] || return 0
  awk -v maxn="${2:-12}" -v maxc="${3:-4000}" -v f="$1" '
    function flush(   L) {
      if (buf == "") return
      # The seed placeholder is not a lesson.
      if (buf ~ /\(seed\) none yet/) { buf = ""; return }
      n++
      L = length(buf)
      if (n <= maxn && chars + L <= maxc) { print buf; chars += L; kept++ }
      buf = ""
    }
    /^-[ \t]/            { flush(); buf = $0; next }
    /^[ \t]+[^ \t]/      { if (buf != "") { line = $0; sub(/^[ \t]+/, "", line); buf = buf " " line } next }
                         { flush() }
    END {
      flush()
      if (n > kept)
        printf "(%d older lesson(s) not shown — %s holds them all)\n", n - kept, f
    }
  ' "$1"
}

# lessons_count <file> — logical lessons, not physical lines.
lessons_count() {
  [ -f "$1" ] || { printf '0'; return 0; }
  awk '/^-[ \t]/ && $0 !~ /\(seed\) none yet/ {n++} END{printf "%d", n+0}' "$1"
}
