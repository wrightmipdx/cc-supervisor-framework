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
  local d="${DOCS:-docs}" f
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
