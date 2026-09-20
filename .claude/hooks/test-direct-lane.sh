#!/usr/bin/env bash
# Behavioral test for 25-direct-lane.sh, the hook that logs a `direct_lane`
# event when the chair runs .claude/scripts/direct-lane.sh.
# Run: .claude/hooks/test-direct-lane.sh
#
# X5: an event with no matching commit must still be captured -- every case
# here asserts the raw jsonl line directly, independent of any commit or
# report, since T3/T4 (which consume this event) are separate tasks.

set -uo pipefail
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$KIT" || exit 1

PASS=0; FAIL=0
eq()  { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok   %-50s %s\n' "$1" "$3"
        else FAIL=$((FAIL+1)); printf 'FAIL %-50s want=%s got=%s\n' "$1" "$2" "$3"; fi; }
yes() { if [ -n "$2" ]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; fi; }

TMP=$(mktemp -d); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
LOGDIR="$TMP/metrics"; mkdir -p "$LOGDIR"

# Run the hook with a raw PreToolUse-shaped payload on stdin. Its exit status
# is the function's, so callers read RC=$? straight after.
hook() {  # hook <payload-json>
  METRICS_DIR="$LOGDIR" bash "$KIT/.claude/hooks/25-direct-lane.sh" <<EOF
$1
EOF
}
events() { cat "$LOGDIR"/session-*.jsonl 2>/dev/null; }
ev_count() { events | jq -r "select(.event==\"$1\")" 2>/dev/null | jq -s 'length' 2>/dev/null || printf 0; }

# jq -n builds the payload so real double quotes inside `reason` survive --
# a hand-escaped heredoc string would round-trip through a shell twice before
# ever reaching the hook and misrepresent what the harness actually sends.
payload() {  # payload <session_id> <command>
  jq -cn --arg s "$1" --arg c "$2" '{session_id:$s, tool_input:{command:$c}}'
}

echo "--- a real invocation logs task and reason, unscrubbed"
CMD='.claude/scripts/direct-lane.sh "T9" "single-line config tweak, tests exist"'
OUT=$(hook "$(payload sessA "$CMD")"); RC=$?
eq "hook exits 0" 0 "$RC"
eq "nothing is emitted to stdout (never denies)" "" "$OUT"
eq "exactly one direct_lane event" 1 "$(ev_count direct_lane)"
eq "task is captured" T9 "$(events | jq -r 'select(.event=="direct_lane") | .task' | head -1)"
eq "reason is captured, unscrubbed, with its comma intact" \
  "single-line config tweak, tests exist" \
  "$(events | jq -r 'select(.event=="direct_lane") | .reason' | head -1)"
eq "origin is the main session" main \
  "$(events | jq -r 'select(.event=="direct_lane") | .origin' | head -1)"
eq "session id is carried" sessA \
  "$(events | jq -r 'select(.event=="direct_lane") | .session' | head -1)"

echo
echo "--- X5: no reason argument still logs, not silently dropped"
hook "$(payload sessB '.claude/scripts/direct-lane.sh T3')" >/dev/null
eq "an event was still written" 1 "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessB")' | jq -s 'length')"
eq "task is captured even with no reason" T3 \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessB") | .task' | head -1)"
eq "reason is the empty string, not missing" "" \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessB") | .reason' | head -1)"

echo
echo "--- no arguments at all still logs, task is null"
hook "$(payload sessC '.claude/scripts/direct-lane.sh')" >/dev/null
eq "an event was still written" 1 \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessC")' | jq -s 'length')"
eq "task is null, not the empty string" null \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessC") | .task' | head -1)"

echo
echo "--- an unrelated command is not mistaken for the marker"
hook "$(payload sessD 'git status')" >/dev/null
eq "no event for an unrelated command" 0 \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessD")' | jq -s 'length')"

echo
echo "--- text that merely MENTIONS the marker must not log an event"
# 30-commit-gate.sh's own header documents fixing this exact bug once: raw
# substring matching fired on any command that merely mentioned a phrase, not
# just one that invoked it. Same class of fixture as test-commit-gate.sh's
# "text that merely mentions the phrase must be allowed" section.
hook "$(payload sessI 'grep -rn "direct-lane.sh" .claude/')" >/dev/null
eq "a grep for the script's name does not log" 0 \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessI")' | jq -s 'length')"

hook "$(payload sessJ 'echo "run .claude/scripts/direct-lane.sh task reason"')" >/dev/null
eq "an echo of instructional text does not log" 0 \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessJ")' | jq -s 'length')"

hook "$(payload sessK 'cat .claude/hooks/25-direct-lane.sh')" >/dev/null
eq "cat-ing the hook's own source does not log" 0 \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessK")' | jq -s 'length')"

# But an actual invocation still logs, chained after a mention in the SAME
# command -- the fix must not overcorrect into missing a real call.
hook "$(payload sessL "echo direct-lane.sh && $CMD")" >/dev/null
eq "a real invocation chained after a mention still logs" 1 \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessL")' | jq -s 'length')"

echo
echo "--- never denies the underlying command"
OUT=$(hook "$(payload sessE "$CMD")")
eq "no permissionDecision is ever emitted" "" \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)"

echo
echo "--- fails open: no jq, no metrics dir, malformed command"
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for c in bash sed grep git find date cat wc tr head sort awk chmod mktemp rm printf xargs; do
  CP=$(command -v "$c" 2>/dev/null) && ln -sf "$CP" "$NOJQ/$c"
done
# Payload built OUTSIDE the PATH-restricted command: a nested $(payload ...)
# inside the same simple command's here-string inherits that command's own
# assignment-prefixed PATH too, which would starve jq's own well-formed-JSON
# construction of the payload, not just the hook under test.
PL_F=$(payload sessF "$CMD")
OUT=$(PATH="$NOJQ" METRICS_DIR="$LOGDIR" bash "$KIT/.claude/hooks/25-direct-lane.sh" \
        <<<"$PL_F" 2>/dev/null); RC=$?
eq "no jq: hook still exits 0" 0 "$RC"
eq "no jq: nothing is emitted" "" "$OUT"

RO="$TMP/readonly-metrics"; mkdir -p "$RO"; chmod a-w "$RO"
PL_G=$(payload sessG "$CMD")
OUT=$(METRICS_DIR="$RO/metrics" bash "$KIT/.claude/hooks/25-direct-lane.sh" \
        <<<"$PL_G" 2>&1); RC=$?
eq "unwritable metrics dir: hook still exits 0" 0 "$RC"
eq "and prints nothing to stderr" "" "$OUT"
chmod u+w "$RO"

OUT=$(hook '{"session_id":"sessH","tool_input":{}}'); RC=$?
eq "no command at all: exits 0" 0 "$RC"
eq "no command at all: nothing logged" 0 \
  "$(events | jq -r 'select(.event=="direct_lane" and .session=="sessH")' | jq -s 'length')"

echo
echo "--- the whole log is valid JSON, every line"
eq "jq -s parses it" 0 "$(events | jq -s '.' >/dev/null 2>&1; printf %s $?)"
eq "every direct_lane event has a task key" 0 \
  "$(events | jq -r 'select(.event=="direct_lane") | select(has("task") | not)' | wc -l | tr -d ' ')"
eq "every direct_lane event has a reason key" 0 \
  "$(events | jq -r 'select(.event=="direct_lane") | select(has("reason") | not)' | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
