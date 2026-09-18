#!/usr/bin/env bash
# Behavioral test for .claude/hooks/lib/lessons.sh.
# Run: .claude/hooks/test-lessons-parse.sh

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. .claude/hooks/lib/lessons.sh || { echo "cannot source the library"; exit 1; }

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok   %-44s %s\n' "$1" "$3"
       else FAIL=$((FAIL+1)); printf 'FAIL %-44s want=%s got=%s\n' "$1" "$2" "$3"; fi; }
has() { if printf '%s' "$2" | grep -q "$3"; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL %s\n  in: %s\n' "$1" "$2"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/wrapped.md" <<'EOF'
# Lessons

Prose in the header is instructions, not data.

- 2026-09-18 (003) — Every builder hit its turn budget in one session. The
  budgets were set for briefs half the size the plan skill now produces, and
  a truncated report is worse than a partial one.
- 2026-09-17 (002) — One line, no wrap.
EOF

echo "--- a wrapped lesson arrives whole"
OUT=$(lessons_render "$TMP/wrapped.md" 12 4000)
eq  "lines out"        2 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
has "three physical lines joined into one" "$OUT" 'a truncated report is worse'
has "header prose excluded"                "$OUT" '^- 2026-09-18'
eq  "count is logical, not physical" 2 "$(lessons_count "$TMP/wrapped.md")"

echo
echo "--- an over-cap file says what it left out"
: > "$TMP/many.md"
i=20; while [ "$i" -gt 0 ]; do printf -- '- lesson number %02d\n' "$i" >> "$TMP/many.md"; i=$((i-1)); done
OUT=$(lessons_render "$TMP/many.md" 12 4000)
eq  "entries kept"  12 "$(printf '%s\n' "$OUT" | grep -c '^- lesson')"
has "overflow reported"  "$OUT" '8 older lesson(s) not shown'
has "newest kept first"  "$OUT" 'lesson number 20'

echo
echo "--- the character cap also reports"
OUT=$(lessons_render "$TMP/many.md" 12 60)
has "char cap reports overflow" "$OUT" 'older lesson(s) not shown'

echo
echo "--- edge cases"
printf -- '- (seed) none yet\n' > "$TMP/seed.md"
eq "seed placeholder is not a lesson" "" "$(lessons_render "$TMP/seed.md")"
eq "seed placeholder is not counted"  0  "$(lessons_count "$TMP/seed.md")"
printf '# Lessons\n\nNo bullets at all.\n' > "$TMP/empty.md"
eq "no lessons yields nothing" "" "$(lessons_render "$TMP/empty.md")"
eq "missing file yields nothing" "" "$(lessons_render "$TMP/nope.md")"
eq "missing file counts zero"   0  "$(lessons_count "$TMP/nope.md")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
