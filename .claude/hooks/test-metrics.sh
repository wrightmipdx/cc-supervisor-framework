#!/usr/bin/env bash
# Behavioral test for the session event log.
# Run: .claude/hooks/test-metrics.sh
#
# Two things are under test and the first matters more than the second:
#
#   1. Logging NEVER breaks a hook. Absent metrics directory, read-only metrics
#      directory, no jq: every hook still exits 0 and still emits exactly the
#      output it emitted before logging existed.
#   2. The events that do get written are complete and attributed — including on
#      the early-exit paths, which is where an appended logging call would have
#      recorded nothing at all.

set -uo pipefail
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$KIT" || exit 1

PASS=0; FAIL=0
eq()  { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok   %-50s %s\n' "$1" "$3"
        else FAIL=$((FAIL+1)); printf 'FAIL %-50s want=%s got=%s\n' "$1" "$2" "$3"; fi; }
yes() { if [ -n "$2" ]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
        else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; fi; }

TMP=$(mktemp -d); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
LOGDIR="$TMP/metrics"

# A fixture project, not this repo. The hooks emit nothing when there is no
# ledger, no lessons and no plan — which is exactly the state of a freshly
# installed consumer — so a suite that leans on whatever this repo happens to
# contain passes here and fails there.
PROJ="$TMP/proj"; mkdir -p "$PROJ/docs"
git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" config user.email t@t 2>/dev/null; git -C "$PROJ" config user.name t 2>/dev/null
cp -R "$KIT/.claude" "$PROJ/.claude" 2>/dev/null || true
printf -- '- E1 [ ] an open requirement\n- E2 [x] a verified one\n' > "$PROJ/docs/LEDGER.md"
printf -- '# Lessons\n\n- 2026-09-18 — a lesson that wraps\n  onto a second line.\n' > "$PROJ/docs/LESSONS.md"

# Run a hook with a payload. Its exit status is the function's, so callers read
# it with RC=$? straight after the command substitution.
hook() {  # hook <script> <payload-json> [project-dir]
  METRICS_DIR="$LOGDIR" CLAUDE_PROJECT_DIR="${3:-$PROJ}" \
    bash "$KIT/.claude/hooks/$1" <<EOF
$2
EOF
}
RC=0
events() { cat "$LOGDIR"/session-*.jsonl 2>/dev/null; }
ev_count() { events | jq -r "select(.event==\"$1\")" 2>/dev/null | jq -s 'length' 2>/dev/null || printf 0; }

SID='{"session_id":"testsess"'

echo "--- a hook is never broken by logging"
# The metrics directory cannot even be created: its parent is read-only. This
# is the real "no log" case, because metrics_init would otherwise create it.
RO="$TMP/readonly"; mkdir -p "$RO"; chmod a-w "$RO"
LOGDIR="$RO/metrics"

OUT=$(hook 10-session-start.sh "$SID}"); RC=$?
eq "session-start exits 0 when the log cannot be created" 0 "$RC"
yes "session-start still injects its context"  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
BASELINE="$OUT"

OUT=$(hook 30-commit-gate.sh "$SID,\"tool_input\":{\"command\":\"git add -A\"}}"); RC=$?
eq "commit-gate still denies with no log" deny \
   "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
eq "commit-gate exits 0" 0 "$RC"
eq "nothing was written" 0 "$(events | wc -l | tr -d ' ')"
chmod u+w "$RO"

LOGDIR="$TMP/metrics"

echo
echo "--- events are written, well formed and attributed"
hook 10-session-start.sh "$SID}" >/dev/null
eq "session_start logged" 1 "$(ev_count session_start)"
yes "it carries the ledger counts" "$(events | jq -r 'select(.event=="session_start") | .ledger_open' | head -1)"
eq "origin is the main session" main "$(events | jq -r 'select(.event=="session_start") | .origin' | head -1)"

echo
echo "--- LOG FIRST, DECIDE SECOND: the early-exit paths still record"
# 20-pre-delegate returns early once its flag exists AND whenever a ledger has
# items — which is nearly every dispatch in a healthy repo.
D="$SID,\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"T5 — build the thing\"}}"
hook 20-pre-delegate.sh "$D" >/dev/null
hook 20-pre-delegate.sh "$D" >/dev/null
hook 20-pre-delegate.sh "$D" >/dev/null
eq "three dispatches, three events" 3 "$(ev_count dispatch)"
eq "the tier is resolved from the agent file" sonnet \
   "$(events | jq -r 'select(.event=="dispatch") | .tier' | head -1)"
eq "the task id is extracted" T5 "$(events | jq -r 'select(.event=="dispatch") | .task' | head -1)"
yes "the brief is measured, not stored" \
   "$(events | jq -r 'select(.event=="dispatch") | select(.brief_bytes > 0) | .brief_bytes' | head -1)"
eq "no brief text is stored anywhere" 0 "$(events | grep -c 'build the thing' || true)"

# 30-commit-gate returns early when the ledger is clean; the kit's is not, so
# both paths are exercised by the repo itself.
hook 30-commit-gate.sh "$SID,\"tool_input\":{\"command\":\"git commit -m \\\"fix(x): y\\\"\"}}" >/dev/null
eq "commit_attempt logged" 1 "$(ev_count commit_attempt)"
eq "its conventional type is read" fix \
   "$(events | jq -r 'select(.event=="commit_attempt") | .commit_type' | head -1)"
hook 30-commit-gate.sh "$SID,\"tool_input\":{\"command\":\"git add -A\"}}" >/dev/null
eq "a blocked stage is recorded" 1 "$(ev_count gate_block)"
eq "with the reason it was blocked" blind_add \
   "$(events | jq -r 'select(.event=="gate_block") | .kind' | head -1)"

echo
echo "--- an unwritable log file is survived too"
BEFORE=$(events | wc -l | tr -d ' ')
chmod a-w "$LOGDIR"/session-testsess.jsonl
OUT=$(hook 10-session-start.sh "$SID}"); RC=$?
eq "exit 0 with a read-only log file" 0 "$RC"
eq "output is byte-identical to the baseline" "$BASELINE" "$OUT"
eq "and nothing was appended" "$BEFORE" "$(events | wc -l | tr -d ' ')"
chmod u+w "$LOGDIR"/session-testsess.jsonl

echo
echo "--- attribution: ambiguous while a worker is in flight"
eq "three dispatched, none finished" ambiguous \
   "$(events | jq -r 'select(.event=="commit_attempt") | .origin' | head -1)"

echo
echo "--- dispatch_end carries the value fields"
REPORT='## Verdict: BLOCK
## Findings
- [blocker] a.sh:3 — wrong — fix it
- [should-fix] b.sh:9 — slow — cache it
- [nit] c.sh:1 — typo
## Evidence
ran the tests'
P=$(jq -cn --arg r "$REPORT" '{session_id:"testsess", hook_event_name:"PostToolUse",
      tool_input:{subagent_type:"critic"}, tool_response:$r}')
hook 60-dispatch-end.sh "$P" >/dev/null
eq "dispatch_end logged"  1       "$(ev_count dispatch_end)"
eq "verdict parsed"       block   "$(events | jq -r 'select(.event=="dispatch_end") | .verdict' | head -1)"
eq "blockers counted"     1       "$(events | jq -r 'select(.event=="dispatch_end") | .findings.blocker' | head -1)"
eq "should-fix counted"   1       "$(events | jq -r 'select(.event=="dispatch_end") | .findings.should_fix' | head -1)"
eq "evidence detected"    true    "$(events | jq -r 'select(.event=="dispatch_end") | .has_evidence' | head -1)"
eq "source recorded"      post_tool_use "$(events | jq -r 'select(.event=="dispatch_end") | .source' | head -1)"
eq "no report text stored" 0      "$(events | grep -c 'cache it' || true)"

P=$(jq -cn --arg r "## Verdict: SHIP
No blockers." '{session_id:"testsess", hook_event_name:"PostToolUse",
      tool_input:{subagent_type:"critic"}, tool_response:$r}')
hook 60-dispatch-end.sh "$P" >/dev/null
eq "a clean review reads as ship" ship \
   "$(events | jq -r 'select(.event=="dispatch_end") | .verdict' | tail -1)"

# SubagentStop usually carries no report. It must still record completion.
hook 60-dispatch-end.sh '{"session_id":"testsess","hook_event_name":"SubagentStop"}' >/dev/null
eq "subagent_stop source recorded" subagent_stop \
   "$(events | jq -r 'select(.event=="dispatch_end") | .source' | tail -1)"
eq "no report means no verdict" none \
   "$(events | jq -r 'select(.event=="dispatch_end") | .verdict' | tail -1)"

echo
echo "--- commit_landed records only what actually landed"
R="$TMP/repo"; mkdir -p "$R"; git -C "$R" init -q
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'one\n' > "$R/a.txt"; git -C "$R" add a.txt
git -C "$R" commit -qm "chore: first"
B="$SID,\"tool_input\":{\"command\":\"git status\"}}"
hook 70-commit-landed.sh "$B" "$R" >/dev/null
eq "the first call only records where HEAD was" 0 "$(ev_count commit_landed)"
printf 'two\n' >> "$R/a.txt"; git -C "$R" add a.txt; git -C "$R" commit -qm "feat(x): second"
hook 70-commit-landed.sh "$B" "$R" >/dev/null
eq "a landed commit is recorded" 1 "$(ev_count commit_landed)"
eq "with its real type"    feat "$(events | jq -r 'select(.event=="commit_landed") | .commit_type' | head -1)"
eq "and its real size"     1    "$(events | jq -r 'select(.event=="commit_landed") | .insertions' | head -1)"
eq "origin is the repo"    repo "$(events | jq -r 'select(.event=="commit_landed") | .origin' | head -1)"
hook 70-commit-landed.sh "$B" "$R" >/dev/null
hook 70-commit-landed.sh "$B" "$R" >/dev/null
eq "an unmoved HEAD is never counted twice" 1 "$(ev_count commit_landed)"

# A repo with no commits yet: the baseline is a sentinel, so the very first
# commit of the session still counts. Without it every call looks like the
# first one and that commit is lost.
E="$TMP/empty"; mkdir -p "$E"; git -C "$E" init -q
git -C "$E" config user.email t@t; git -C "$E" config user.name t
BEFORE=$(ev_count commit_landed)
hook 70-commit-landed.sh "$B" "$E" >/dev/null
printf 'first\n' > "$E/a.txt"; git -C "$E" add a.txt; git -C "$E" commit -qm "feat: first ever"
hook 70-commit-landed.sh "$B" "$E" >/dev/null
eq "the first commit in an empty repo is recorded" "$((BEFORE + 1))" "$(ev_count commit_landed)"
eq "and no malformed event was written" 0 \
   "$(events | jq -r 'select(.event=="commit_landed" and .head == null)' | wc -l | tr -d ' ')"

echo
echo "--- the whole log is valid JSON, every line"
eq "jq -s parses it" 0 "$(events | jq -s '.' >/dev/null 2>&1; printf %s $?)"
eq "every event has a type"    0 "$(events | jq -r 'select(.event == null)' | wc -l | tr -d ' ')"
eq "every event has an origin" 0 "$(events | jq -r 'select(.origin == null)' | wc -l | tr -d ' ')"
eq "every event has a session" 0 "$(events | jq -r 'select(.session == null)' | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
