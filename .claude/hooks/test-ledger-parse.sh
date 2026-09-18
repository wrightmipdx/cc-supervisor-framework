#!/usr/bin/env bash
# Behavioral test for .claude/hooks/lib/ledger.sh.
# Run: .claude/hooks/test-ledger-parse.sh
#
# The bug this library was written to end: every hook required the checkbox to
# be the first token after the dash, so a real ledger using ID prefixes counted
# zero open items and every hook stayed silent about it.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. .claude/hooks/lib/ledger.sh || { echo "cannot source the library"; exit 1; }

PASS=0; FAIL=0
eq() {  # eq <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok   %-46s %s\n' "$1" "$3"
  else FAIL=$((FAIL+1)); printf 'FAIL %-46s want=%s got=%s\n' "$1" "$2" "$3"; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs"

# The form the framework's own ledger and every real consumer plan uses.
cat > "$TMP/docs/LEDGER-ids.md" <<'EOF'
# Ledger
- E1 [ ] open with an ID
- E2 [x] verified with an ID
- I10 [ ] two-digit ID
- X3 [~] deferred with an ID
EOF

# The form the template ships.
cat > "$TMP/docs/LEDGER-plain.md" <<'EOF'
- [ ] open, checkbox first
- [x] verified, checkbox first
- [~] deferred, checkbox first
EOF

# Both in one file. opanalyst does exactly this.
cat > "$TMP/docs/LEDGER-mixed.md" <<'EOF'
- E1 [ ] ID form
- [ ] plain form
  - E2 [ ] indented, still a requirement
- I1 [x] done
EOF

# Prose that must never be counted.
cat > "$TMP/docs/LEDGER-prose.md" <<'EOF'
# Ledger
Some prose about [ ] brackets in a sentence.
- an ordinary bulleted list item
- another one mentioning [x] in passing
- a bullet with [ ] mid-sentence is prose, not a requirement
* [ ] a star bullet is not our format
EOF

cat > "$TMP/docs/LEDGER-closed-archive.md" <<'EOF'
- E1 [ ] archived work that must not be counted
EOF

echo "--- the ID-prefixed form"
eq "ids: open"        2 "$(ledger_count_open     "$TMP/docs/LEDGER-ids.md")"
eq "ids: verified"    1 "$(ledger_count_done     "$TMP/docs/LEDGER-ids.md")"
eq "ids: deferred"    1 "$(ledger_count_deferred "$TMP/docs/LEDGER-ids.md")"

echo
echo "--- the checkbox-first form still works"
eq "plain: open"      1 "$(ledger_count_open     "$TMP/docs/LEDGER-plain.md")"
eq "plain: verified"  1 "$(ledger_count_done     "$TMP/docs/LEDGER-plain.md")"
eq "plain: deferred"  1 "$(ledger_count_deferred "$TMP/docs/LEDGER-plain.md")"

echo
echo "--- both forms in one file"
eq "mixed: open"      3 "$(ledger_count_open "$TMP/docs/LEDGER-mixed.md")"
eq "mixed: verified"  1 "$(ledger_count_done "$TMP/docs/LEDGER-mixed.md")"

echo
echo "--- prose is not a requirement"
eq "prose: open"      0 "$(ledger_count_open "$TMP/docs/LEDGER-prose.md")"
eq "prose: verified"  0 "$(ledger_count_done "$TMP/docs/LEDGER-prose.md")"

echo
echo "--- file selection"
eq "archives excluded" "" "$(DOCS=$TMP/docs ledger_files | grep archive || true)"
eq "live ledgers found" 4 "$(DOCS=$TMP/docs ledger_files | wc -l | tr -d ' ')"
eq "total open across files" 6 "$(DOCS=$TMP/docs ledger_total_open)"

echo
echo "--- absence is zero, never an error"
eq "missing file: open"  0 "$(ledger_count_open "$TMP/docs/nope.md")"
eq "no ledger at all"    "" "$(DOCS=$TMP/empty ledger_files)"
eq "no ledger: total"    0 "$(DOCS=$TMP/empty ledger_total_open)"

echo
echo "--- has_items: a ledger of only deferred work is still a ledger"
has() { ledger_has_items "$1" && printf yes || printf no; }
printf -- '- [~] only deferred\n' > "$TMP/docs/LEDGER-defer.md"
eq "has_items: ID form"       yes "$(has "$TMP/docs/LEDGER-ids.md")"
eq "has_items: prose only"    no  "$(has "$TMP/docs/LEDGER-prose.md")"
eq "has_items: deferred only" yes "$(has "$TMP/docs/LEDGER-defer.md")"
eq "has_items: missing file"  no  "$(has "$TMP/docs/nope.md")"

echo
echo "--- open items are returned whole and capped"
eq "open_items: count" 3 "$(ledger_open_items "$TMP/docs/LEDGER-mixed.md" | wc -l | tr -d ' ')"
eq "open_items: cap"   2 "$(ledger_open_items "$TMP/docs/LEDGER-mixed.md" 2 | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
