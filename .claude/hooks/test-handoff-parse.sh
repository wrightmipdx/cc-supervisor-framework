#!/usr/bin/env bash
# Behavioral test for .claude/hooks/lib/handoff.sh.
# Run: .claude/hooks/test-handoff-parse.sh

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. .claude/hooks/lib/handoff.sh || { echo "cannot source the library"; exit 1; }

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok   %-44s %s\n' "$1" "$3"
       else FAIL=$((FAIL+1)); printf 'FAIL %-44s want=%s got=%s\n' "$1" "$2" "$3"; fi; }
has() { if printf '%s' "$2" | grep -q "$3"; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL %s\n  in: %s\n' "$1" "$2"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/wrapped.md" <<'EOF'
# Handoff

Prose in the header is instructions, not data.

- 010-chunked-execution: partial — T1 shipped, T2 in review. Sponsor closed
  the session mid-plan; next session should resume at T3, not re-derive scope
  from the ledger.
- 009-docs-reorg: done, archived.
EOF

echo "--- a wrapped entry arrives whole"
OUT=$(handoff_render "$TMP/wrapped.md" 12 4000)
eq  "lines out"        2 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
has "three physical lines joined into one" "$OUT" 'resume at T3, not re-derive scope'
has "header prose excluded"                "$OUT" '^- 010-chunked-execution'
eq  "count is logical, not physical" 2 "$(handoff_count "$TMP/wrapped.md")"

echo
echo "--- an over-cap file says what it left out"
: > "$TMP/many.md"
i=20; while [ "$i" -gt 0 ]; do printf -- '- plan number %02d: open\n' "$i" >> "$TMP/many.md"; i=$((i-1)); done
OUT=$(handoff_render "$TMP/many.md" 12 4000)
eq  "entries kept"  12 "$(printf '%s\n' "$OUT" | grep -c '^- plan')"
has "overflow reported"  "$OUT" '8 older item(s) not shown'
has "newest kept first"  "$OUT" 'plan number 20'

echo
echo "--- the character cap also reports"
OUT=$(handoff_render "$TMP/many.md" 12 60)
has "char cap reports overflow" "$OUT" 'older item(s) not shown'
has "points at durable state, not the deleted draft" "$OUT" 'docs/plans/ and docs/kit/LEDGER\*.md hold the full state'

echo
echo "--- edge cases"
printf '# Handoff\n\nNo plans open, nothing to report.\n' > "$TMP/empty.md"
eq "no entries yields nothing" "" "$(handoff_render "$TMP/empty.md")"
eq "no entries counts zero"    0  "$(handoff_count "$TMP/empty.md")"
eq "missing file yields nothing" "" "$(handoff_render "$TMP/nope.md")"
eq "missing file counts zero"   0  "$(handoff_count "$TMP/nope.md")"

echo
echo "--- handoff_write: missing or empty draft never touches an existing dest"
printf 'previous session content — must survive\n' > "$TMP/dest.md"
before_sum=$(cksum "$TMP/dest.md")
if handoff_write "$TMP/nope.md" "$TMP/dest.md" 2>"$TMP/err1"; then
  FAIL=$((FAIL+1)); printf 'FAIL %s\n' "missing draft: handoff_write should fail"
else
  PASS=$((PASS+1)); printf 'ok   %s\n' "missing draft: handoff_write returns non-zero"
fi
eq "missing draft: dest byte-identical" "$before_sum" "$(cksum "$TMP/dest.md")"
has "missing draft: warns on stderr" "$(cat "$TMP/err1")" 'left untouched'

: > "$TMP/blank.md"
before_sum=$(cksum "$TMP/dest.md")
if handoff_write "$TMP/blank.md" "$TMP/dest.md" 2>"$TMP/err2"; then
  FAIL=$((FAIL+1)); printf 'FAIL %s\n' "empty draft: handoff_write should fail"
else
  PASS=$((PASS+1)); printf 'ok   %s\n' "empty draft: handoff_write returns non-zero"
fi
eq "empty draft: dest byte-identical" "$before_sum" "$(cksum "$TMP/dest.md")"
has "empty draft: warns on stderr" "$(cat "$TMP/err2")" 'left untouched'

echo
echo "--- handoff_write: missing draft with no dest present creates nothing"
rm -f "$TMP/nodest.md"
handoff_write "$TMP/nope.md" "$TMP/nodest.md" >/dev/null 2>&1
eq "no dest created" "no" "$([ -e "$TMP/nodest.md" ] && echo yes || echo no)"

echo
echo "--- handoff_write: the normal path writes correctly"
rm -f "$TMP/out.md"
handoff_write "$TMP/wrapped.md" "$TMP/out.md"
eq "write succeeds and file appears" "yes" "$([ -f "$TMP/out.md" ] && echo yes || echo no)"
has "rendered content lands in dest" "$(cat "$TMP/out.md")" '^- 010-chunked-execution'

echo
echo "--- handoff_write: the written file stays world-readable"
# mktemp creates 0600; without an explicit chmod, mv carries that mode onto
# dest and silently tightens a committed doc to owner-only on every write.
# BSD stat and GNU stat spell this differently; try both.
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
eq "new dest is 644" "644" "$(mode_of "$TMP/out.md")"
printf 'existing\n' > "$TMP/pre.md"; chmod 644 "$TMP/pre.md"
handoff_write "$TMP/wrapped.md" "$TMP/pre.md"
eq "overwritten dest stays 644" "644" "$(mode_of "$TMP/pre.md")"

echo
echo "--- handoff_write: a missing destination directory fails clean"
if handoff_write "$TMP/wrapped.md" "$TMP/no-such-dir/HANDOFF.md" 2>"$TMP/err3"; then
  FAIL=$((FAIL+1)); printf 'FAIL %s\n' "missing dest dir: should fail"
else
  PASS=$((PASS+1)); printf 'ok   %s\n' "missing dest dir: returns non-zero"
fi
has "missing dest dir: names the directory problem" "$(cat "$TMP/err3")" 'directory missing'
eq "missing dest dir: no stray temp file" "0" \
  "$(find "$TMP" -maxdepth 1 -name 'HANDOFF.md.*' | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
