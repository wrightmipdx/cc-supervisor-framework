#!/usr/bin/env bash
# Ledger parsing, shared by every hook that reads one.
#
# WHY THIS FILE EXISTS. The pattern below used to be copy-pasted into four
# hooks, each requiring the checkbox to be the first token after the dash:
#
#     - [ ] Application accepts manual data entry
#
# Real ledgers grow IDs, because plans cite requirements by name:
#
#     - E1 [x] Application accepts manual data entry
#
# Every hook then counted zero open items against a populated ledger and said
# nothing, which is the worst way for a mechanism to fail. Six copies of a
# pattern is why it was invisible: there was no single place to test it.
#
# The checkbox is still REQUIRED. An ordinary prose bullet is not a requirement
# and must never be counted.
#
# Portable to BSD and GNU userlands: grep -E only, no GNU extensions.

# A requirement line: optional ID prefix, then the checkbox.
LEDGER_RE_OPEN='^[[:space:]]*-[[:space:]]+([A-Za-z]+[0-9]+[[:space:]]+)?\[ \]'
LEDGER_RE_DONE='^[[:space:]]*-[[:space:]]+([A-Za-z]+[0-9]+[[:space:]]+)?\[x\]'
LEDGER_RE_DEFER='^[[:space:]]*-[[:space:]]+([A-Za-z]+[0-9]+[[:space:]]+)?\[~\]'
LEDGER_RE_ANY='^[[:space:]]*-[[:space:]]+([A-Za-z]+[0-9]+[[:space:]]+)?\[[ x~]\]'

# Every live ledger: docs/LEDGER.md plus docs/LEDGER-*.md, archives excluded.
# Prints nothing at all when there is no ledger, which callers treat as zero.
ledger_files() {
  local d="${KIT_DOCS:-docs/kit}" f
  for f in "$d"/LEDGER.md "$d"/LEDGER-*.md; do
    [ -f "$f" ] || continue
    case "$f" in *-archive.md) continue ;; esac
    printf '%s\n' "$f"
  done
}

_ledger_count() {  # _ledger_count <regex> <file>
  local n
  n=$(grep -cE "$1" "$2" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

ledger_count_open()     { _ledger_count "$LEDGER_RE_OPEN"  "$1"; }
ledger_count_done()     { _ledger_count "$LEDGER_RE_DONE"  "$1"; }
ledger_count_deferred() { _ledger_count "$LEDGER_RE_DEFER" "$1"; }

# The open items themselves, newest file order, capped.
ledger_open_items() {
  grep -E "$LEDGER_RE_OPEN" "$1" 2>/dev/null | head -"${2:-10}" || true
}

# Does this file hold any requirement at all, in any state? The pre-delegate
# hook asks this: a ledger with only deferred items is still a ledger.
ledger_has_items() { grep -qE "$LEDGER_RE_ANY" "$1" 2>/dev/null; }

# Open items across every live ledger.
ledger_total_open() {
  local total=0 f n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$(ledger_count_open "$f")
    total=$((total + n))
  done <<EOF
$(ledger_files)
EOF
  printf '%s' "$total"
}

# Lines that LOOK like requirements under a deliberately loose pattern. Only
# install-check uses this: if this finds lines and the real parser finds none,
# the parser has drifted from the format the repo actually writes, which is
# exactly the failure this library was written to end.
ledger_count_looks_like() { _ledger_count '^[[:space:]]*-[[:space:]].*\[[ x~]\]' "$1"; }

# --- 005: id capture and whole-bullet reads, for trace.sh -----------------
#
# The regexes above MATCH an ID prefix but never CAPTURE it, and every
# consumer only ever counts. trace.sh needs the id itself, plus the [~]
# approval date, which is free prose inside the bullet body and can sit on a
# wrapped continuation line the anchored regexes never see. Both are new
# functions; no existing regex or function above this point is touched.

# One TSV row per requirement bullet: id <TAB> state <TAB> text
#   id    the ID prefix (E1, I10, X3...) or "-" when the bullet has none —
#         real ledgers carry both forms in the wild (004's two deferrals)
#   state open | done | deferred
#   text  the WHOLE bullet, continuation lines folded in with a single space,
#         so a [~] date written on a wrapped line is still visible
ledger_items() {  # ledger_items <file>
  local file="$1" line id state text in_item=0 flush
  while IFS= read -r line || [ -n "$line" ]; do
    if printf '%s\n' "$line" | grep -qE "$LEDGER_RE_ANY"; then
      if [ "$in_item" -eq 1 ]; then
        printf '%s\t%s\t%s\n' "${id:--}" "$state" "$text"
      fi
      in_item=1
      id=$(printf '%s\n' "$line" \
           | sed -E 's/^[[:space:]]*-[[:space:]]+([A-Za-z]+[0-9]+)[[:space:]]+\[[ x~]\].*/\1/')
      [ "$id" = "$line" ] && id=""
      case "$line" in
        *'[x]'*) state=done ;;
        *'[~]'*) state=deferred ;;
        *)       state=open ;;
      esac
      text=$(printf '%s\n' "$line" \
             | sed -E 's/^[[:space:]]*-[[:space:]]+([A-Za-z]+[0-9]+[[:space:]]+)?\[[ x~]\][[:space:]]*//')
    elif [ "$in_item" -eq 1 ]; then
      case "$line" in
        '')           flush=1 ;;
        [[:space:]]*) text="$text $(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')" ;;
        *)            flush=1 ;;
      esac
      if [ "${flush:-0}" -eq 1 ]; then
        printf '%s\t%s\t%s\n' "${id:--}" "$state" "$text"
        in_item=0; flush=0
      fi
    fi
  done < "$file"
  if [ "$in_item" -eq 1 ]; then
    printf '%s\t%s\t%s\n' "${id:--}" "$state" "$text"
  fi
}

# The approval date on a deferred bullet's own text — anywhere in it, not just
# the first line, since ledger_items already folded continuation lines in.
# Empty when the bullet carries no ISO date, which trace.sh reports as an
# unapproved deferral (AC-2) rather than silently treating it as approved.
LEDGER_RE_DATE='(19|20)[0-9]{2}-[0-9]{2}-[0-9]{2}'
ledger_deferred_date() {  # ledger_deferred_date <bullet-text>
  printf '%s\n' "$1" | grep -oE "$LEDGER_RE_DATE" | head -1
}
