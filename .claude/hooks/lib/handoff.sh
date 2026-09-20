#!/usr/bin/env bash
# Handoff-brief rendering, for retro step 3's docs/kit/HANDOFF.md.
#
# WHY THIS FILE EXISTS. docs/kit/HANDOFF.md is cross-plan and always
# overwritten, read by the next session's opening turn so it does not have to
# find and open the most recent plan file to get oriented. An unbounded
# "what happened" file is a repeat of the exact failure mode lessons.sh was
# written to end: an entry long enough to wrap arrives cut off mid-sentence,
# and a file with more entries than the cap drops the remainder with no sign
# it had done so.
#
# An entry is one bullet starting at column 0. Continuation lines are
# indented. Reassemble, cap on both count and characters, and SAY what was
# left out — same shape as lessons_render, so the two files behave
# identically to whoever reads either one.
#
# Portable to BSD and GNU awk: no character classes, no GNU extensions.

# handoff_render <file> [max_entries] [max_chars]
#
# Note on the noun: lessons_render says "lesson(s)"; this says "item(s)"
# because a handoff entry is a plan, not a lesson. Intentional divergence,
# not an oversight.
#
# Note on the trim pointer: lessons_render's overflow line names LESSONS.md
# itself, because that file persists every lesson ever written — the pointer
# is trustworthy for as long as anyone might read it. HANDOFF.md has no such
# durable twin: the draft this renders from is deleted by retro's own step 4
# scratch sweep (a standing rule this file does not get to carve an exception
# out of), and HANDOFF.md itself is the capped *output*, not the overflow. So
# on overflow this does not name a file at all — it names where a dropped
# bullet's real state still lives: a handoff bullet is a summary of a plan,
# and if the summary is dropped the plan's actual state persists in its own
# plan file and ledger, which is where the reader needs to go anyway.
handoff_render() {
  [ -f "$1" ] || return 0
  awk -v maxn="${2:-12}" -v maxc="${3:-4000}" -v f="$1" '
    function flush(   L) {
      if (buf == "") return
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
        printf "(%d older item(s) not shown — docs/plans/ and docs/kit/LEDGER*.md hold the full state)\n", n - kept
    }
  ' "$1"
}

# handoff_count <file> — logical entries, not physical lines.
handoff_count() {
  [ -f "$1" ] || { printf '0'; return 0; }
  awk '/^-[ \t]/ {n++} END{printf "%d", n+0}' "$1"
}

# handoff_write <draft> <dest> [max_entries] [max_chars]
#
# Writes the capped brief to <dest> only when <draft> genuinely has content.
# A missing or empty draft means "the drafting step was skipped," not
# "nothing to hand off" — silently blanking <dest> in that case is the same
# failure mode this file exists to end, recurring on the write side. So
# <dest> is left completely untouched and this returns non-zero with a
# message on stderr instead.
#
# Renders to a temp file first and moves it into place, so a failure partway
# through rendering cannot leave a half-written <dest>.
handoff_write() {
  local draft="$1" dest="$2" tmp
  if [ ! -s "$draft" ]; then
    printf 'handoff_write: no draft at %s (missing or empty) — %s left untouched\n' "$draft" "$dest" >&2
    return 1
  fi
  if ! tmp=$(mktemp "${dest}.XXXXXX" 2>/dev/null); then
    printf 'handoff_write: cannot create a temp file next to %s (is its directory missing?) — left untouched\n' "$dest" >&2
    return 1
  fi
  # mktemp creates 0600 and mv carries the mode over, which would silently
  # tighten a readable HANDOFF.md to owner-only on every write. This is a
  # committed doc, not a secret.
  chmod 644 "$tmp" 2>/dev/null
  if handoff_render "$draft" "${3:-12}" "${4:-4000}" > "$tmp"; then
    mv "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}
