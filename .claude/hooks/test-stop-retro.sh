#!/usr/bin/env bash
# Behavioral test for 50-stop-retro.sh.
# Run: .claude/hooks/test-stop-retro.sh
#
# Stop fires at the end of EVERY assistant turn. The hook used to flag-gate
# itself to once per session, so its one nudge landed at the end of turn one and
# it was silent at the real close. These cases hold the fix: a rate limiter
# rather than a kill switch, and a warning raised only on the signature of the
# failure it fences — commits landed with the ledger not moved.

set -uo pipefail
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$KIT" || exit 1

PASS=0; FAIL=0
eq()  { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok   %-48s %s\n' "$1" "$3"
        else FAIL=$((FAIL+1)); printf 'FAIL %-48s want=%s got=%s\n' "$1" "$2" "$3"; fi; }
has() { if printf '%s' "$2" | grep -q "$3"; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL %s\n  in: %s\n' "$1" "$2"; fi; }
no()  { if printf '%s' "$2" | grep -q "$3"; then FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"
        else PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
LOGDIR="$TMP/metrics"; FLAGS="$TMP/flags"; mkdir -p "$LOGDIR" "$FLAGS"

# A repo with an open ledger and a dirty tree: the ordinary mid-session state.
R="$TMP/repo"; mkdir -p "$R/docs/kit"
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf -- '- E1 [ ] something open\n- E2 [x] something done\n' > "$R/docs/kit/LEDGER.md"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm "chore: seed"
printf 'dirty\n' > "$R/scratchfile"

run() {  # run <session-id> [seconds-window]
  TMPDIR="$FLAGS" METRICS_DIR="$LOGDIR" CLAUDE_PROJECT_DIR="$R" \
  RETRO_NUDGE_SECONDS="${2:-1800}" \
  bash "$KIT/.claude/hooks/50-stop-retro.sh" <<EOF
{"session_id":"$1"}
EOF
}
msg() { printf '%s' "$1" | jq -r '.systemMessage // ""' 2>/dev/null; }

echo "--- the ordinary case: work in progress, gentle reminder"
OUT=$(run s1); RC=$?
eq  "exits 0" 0 "$RC"
has "nudges on an open ledger"    "$(msg "$OUT")" 'open ledger item'
has "and on an uncommitted tree"  "$(msg "$OUT")" 'uncommitted file'
no  "does not warn without commits" "$(msg "$OUT")" 'ledger has not moved'

echo
echo "--- the flag is a rate limiter, not a kill switch"
OUT=$(run s1)
eq "silent inside the window" "" "$(msg "$OUT")"
# Re-arm by shrinking the window to zero rather than by sleeping.
OUT=$(run s1 0)
has "nudges again once the window passes" "$(msg "$OUT")" 'open ledger item'

echo
echo "--- commits landed with the ledger unmoved is the real failure"
cat > "$LOGDIR/session-s2.jsonl" <<'EOF'
{"event":"session_start","ts":"2026-09-18T09:00:00Z","session":"s2","origin":"main","ledger_open":1}
{"event":"commit_landed","ts":"2026-09-18T09:30:00Z","session":"s2","origin":"repo","commit_type":"feat","files":2,"insertions":40,"deletions":1}
{"event":"commit_landed","ts":"2026-09-18T09:40:00Z","session":"s2","origin":"repo","commit_type":"fix","files":1,"insertions":3,"deletions":0}
EOF
OUT=$(run s2); RC=$?
eq  "still exits 0" 0 "$RC"
has "counts the commits"        "$(msg "$OUT")" '2 commit(s) landed'
has "names the failure"         "$(msg "$OUT")" 'ledger has not moved'
has "still says run retro"      "$(msg "$OUT")" '/retro'

echo
echo "--- a clean close says nothing at all"
C="$TMP/clean"; mkdir -p "$C/docs/kit"
git -C "$C" init -q; git -C "$C" config user.email t@t; git -C "$C" config user.name t
printf -- '- E1 [x] all verified\n' > "$C/docs/kit/LEDGER.md"
git -C "$C" add -A >/dev/null 2>&1; git -C "$C" commit -qm "chore: seed"
OUT=$(TMPDIR="$FLAGS" METRICS_DIR="$LOGDIR" CLAUDE_PROJECT_DIR="$C" \
      bash "$KIT/.claude/hooks/50-stop-retro.sh" <<< '{"session_id":"s3"}'); RC=$?
eq "exits 0"                 0  "$RC"
eq "and emits nothing"       "" "$(msg "$OUT")"

echo
echo "--- degraded: no metrics directory at all behaves as before"
OUT=$(TMPDIR="$FLAGS" METRICS_DIR="$TMP/nonexistent" CLAUDE_PROJECT_DIR="$R" \
      bash "$KIT/.claude/hooks/50-stop-retro.sh" <<< '{"session_id":"s4"}'); RC=$?
eq  "exits 0 with no log"      0 "$RC"
has "and still reminds"        "$(msg "$OUT")" 'open ledger item'
no  "without claiming commits" "$(msg "$OUT")" 'ledger has not moved'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
