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
echo "--- PostToolUse writes a launch, not a report"
# Agents launch asynchronously: Task returns this receipt and PostToolUse fires
# against it, seconds before the worker has done anything. Through 0.3.3 the
# hook parsed a verdict out of it and got `none` 27 times out of 27 on real
# sessions. The receipt's one real datum is the agentId, and that is what the
# cost report joins on.
RECEIPT='Async agent launched successfully. (This tool result is internal metadata.)
agentId: a5596596b88ba7d9d (internal ID - do not mention to user.)'
P=$(jq -cn --arg r "$RECEIPT" '{session_id:"testsess", hook_event_name:"PostToolUse",
      tool_input:{subagent_type:"critic"}, tool_response:$r}')
hook 60-dispatch-end.sh "$P" >/dev/null
eq "dispatch_launched logged"  1 "$(ev_count dispatch_launched)"
eq "agent recorded"      critic "$(events | jq -r 'select(.event=="dispatch_launched") | .agent' | head -1)"
eq "agent_id extracted"  a5596596b88ba7d9d \
   "$(events | jq -r 'select(.event=="dispatch_launched") | .agent_id' | head -1)"
eq "PostToolUse writes no completion" 0 "$(ev_count dispatch_end)"

# The fields that could never be populated are gone. A field reporting a
# confident zero it cannot fill is worse than a missing one.
eq "no verdict field"       0 "$(events | grep -c '"verdict"' || true)"
eq "no has_evidence field"  0 "$(events | grep -c 'has_evidence' || true)"
eq "no findings field"      0 "$(events | grep -c '"findings"' || true)"

# An id-less receipt still records the launch: the join degrades visibly to
# "unjoined runs: N" in the report, never to a missing event.
P=$(jq -cn '{session_id:"testsess", hook_event_name:"PostToolUse",
      tool_input:{subagent_type:"builder"}, tool_response:"launched, no id here"}')
hook 60-dispatch-end.sh "$P" >/dev/null
eq "a receipt with no id still logs" 2 "$(ev_count dispatch_launched)"
eq "and its agent_id is null" null \
   "$(events | jq -r 'select(.event=="dispatch_launched") | .agent_id' | tail -1)"
eq "no receipt text stored" 0 "$(events | grep -c 'internal metadata' || true)"

echo
echo "--- SubagentStop is the completion, and the only decrementer"
# Kept verbatim from 0.3.2: SubagentStop fires on this version even when nothing
# was dispatched. With no worker in flight it did not end a dispatch.
# A SEPARATE session, because the one above still has workers outstanding.
P2='{"session_id":"phantom"'
BEFORE=$(ev_count dispatch_end)
hook 60-dispatch-end.sh "$P2,\"hook_event_name\":\"SubagentStop\"}" >/dev/null
eq "a SubagentStop with nothing in flight is not logged" "$BEFORE" "$(ev_count dispatch_end)"

hook 20-pre-delegate.sh "$P2,\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"T9 — go\"}}" >/dev/null
eq "in flight after dispatch" 1 "$(cat "$LOGDIR/.inflight-phantom" 2>/dev/null)"
hook 60-dispatch-end.sh "$P2,\"hook_event_name\":\"SubagentStop\"}" >/dev/null
eq "with a worker in flight it is logged" "$((BEFORE + 1))" "$(ev_count dispatch_end)"
eq "in flight back to zero" 0 "$(cat "$LOGDIR/.inflight-phantom" 2>/dev/null)"
# Scoped to the phantom session: events() concatenates every log in glob order,
# so a bare tail -1 reads whichever session sorts last, not the latest event.
eq "subagent_stop source recorded" subagent_stop \
   "$(events | jq -r 'select(.event=="dispatch_end" and .session=="phantom") | .source' | tail -1)"
eq "a duration is carried" 0 \
   "$(events | jq -r 'select(.event=="dispatch_end" and .session=="phantom") | .duration_s' | tail -1)"

# THE 0.3.3 DEFECT, ASSERTED AGAINST DIRECTLY. The decrement used to happen at
# launch, so the counter returned to zero about a second after every dispatch
# while every worker was still running: `ambiguous` fired zero times in 111 real
# events. Two dispatched, one launched, and the count must still read 2.
P3='{"session_id":"twoflight"'
hook 20-pre-delegate.sh "$P3,\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"T1\"}}" >/dev/null
hook 20-pre-delegate.sh "$P3,\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"T2\"}}" >/dev/null
hook 60-dispatch-end.sh "$P3,\"hook_event_name\":\"PostToolUse\",\"tool_input\":{\"subagent_type\":\"builder\"},\"tool_response\":\"agentId: abcdef0123456789\"}" >/dev/null
eq "a launch does not decrement" 2 "$(cat "$LOGDIR/.inflight-twoflight" 2>/dev/null)"
hook 60-dispatch-end.sh "$P3,\"hook_event_name\":\"SubagentStop\"}" >/dev/null
eq "one stop leaves one in flight" 1 "$(cat "$LOGDIR/.inflight-twoflight" 2>/dev/null)"
hook 60-dispatch-end.sh "$P3,\"hook_event_name\":\"SubagentStop\"}" >/dev/null
eq "two stops clear it" 0 "$(cat "$LOGDIR/.inflight-twoflight" 2>/dev/null)"

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
echo "--- mtime reads as a real epoch on this platform"
# This is the case that was missing when the retro nudge's rate limiter passed
# on macOS and failed on Linux: the BSD-first stat spelling does not fail on
# GNU, it succeeds with the wrong number.
touch "$TMP/stamp"
MT=$(metrics_mtime_probe() { . "$KIT/.claude/hooks/lib/metrics.sh"; metrics_mtime "$1"; }; metrics_mtime_probe "$TMP/stamp")
NOWS=$(date +%s)
if [ "$MT" -gt 0 ] && [ $((NOWS - MT)) -ge 0 ] && [ $((NOWS - MT)) -lt 120 ]; then
  PASS=$((PASS+1)); printf 'ok   %-50s %s\n' "metrics_mtime returns a current epoch" "$MT"
else
  FAIL=$((FAIL+1)); printf 'FAIL %-50s got=%s now=%s\n' "metrics_mtime returns a current epoch" "$MT" "$NOWS"
fi
eq "and 0 for a file that is not there" 0 \
   "$(. "$KIT/.claude/hooks/lib/metrics.sh"; metrics_mtime "$TMP/no-such-file")"

echo
echo "--- the whole log is valid JSON, every line"
eq "jq -s parses it" 0 "$(events | jq -s '.' >/dev/null 2>&1; printf %s $?)"
eq "every event has a type"    0 "$(events | jq -r 'select(.event == null)' | wc -l | tr -d ' ')"
eq "every event has an origin" 0 "$(events | jq -r 'select(.origin == null)' | wc -l | tr -d ' ')"
eq "every event has a session" 0 "$(events | jq -r 'select(.session == null)' | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
