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
PROJ="$TMP/proj"; mkdir -p "$PROJ/docs/kit"
git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" config user.email t@t 2>/dev/null; git -C "$PROJ" config user.name t 2>/dev/null
cp -R "$KIT/.claude" "$PROJ/.claude" 2>/dev/null || true
printf -- '- E1 [ ] an open requirement\n- E2 [x] a verified one\n' > "$PROJ/docs/kit/LEDGER.md"
printf -- '# Lessons\n\n- 2026-09-18 — a lesson that wraps\n  onto a second line.\n' > "$PROJ/docs/kit/LESSONS.md"

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
# A PLAUSIBLE VALUE, NOT AN EXACT ONE. duration_s is wall-clock seconds, so
# asserting 0 here only holds when the dispatch and the stop land inside the
# same clock second. They usually do, and under install-check — slower, and
# after four other suites — they crossed a boundary about one run in ten. A
# flaky suite is worse than a missing one: it trains you to re-run until green.
D=$(events | jq -r 'select(.event=="dispatch_end" and .session=="phantom") | .duration_s' | tail -1)
case "$D" in
  ''|*[!0-9]*) eq "a duration is carried (non-negative integer)" "an integer" "$D" ;;
  *)           eq "a duration is carried (non-negative integer)" ok ok ;;
esac

# And that the number MEANS something, which presence alone does not show.
METRICS_DIR="$LOGDIR" METRICS_SESSION=timed bash -c '
  . "'"$PWD"'/.claude/hooks/lib/metrics.sh"
  metrics_init timed; metrics_dispatch_push' 2>/dev/null
sleep 1
AGE=$(METRICS_DIR="$LOGDIR" METRICS_SESSION=timed bash -c '
  . "'"$PWD"'/.claude/hooks/lib/metrics.sh"
  metrics_init timed; metrics_dispatch_age' 2>/dev/null)
[ "${AGE:-0}" -ge 1 ] 2>/dev/null \
  && eq "and it measures real elapsed time" ok ok \
  || eq "and it measures real elapsed time" ">=1" "$AGE"

# An empty queue is 0, never a negative and never a guess.
EMPTY=$(METRICS_DIR="$LOGDIR" METRICS_SESSION=timed bash -c '
  . "'"$PWD"'/.claude/hooks/lib/metrics.sh"
  metrics_init timed; metrics_dispatch_age' 2>/dev/null)
eq "an exhausted queue reads 0" 0 "$EMPTY"

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
echo "--- 005: metrics.sh's direct-lane block, real hooks driving real commits"
DLREPO="$TMP/dlane-repo"; mkdir -p "$DLREPO"; git -C "$DLREPO" init -q
git -C "$DLREPO" config user.email t@t; git -C "$DLREPO" config user.name t
SDL='{"session_id":"dlanesess"'
DLB="$SDL,\"tool_input\":{\"command\":\"git status\"}}"

printf 'base\n' > "$DLREPO/a.txt"; git -C "$DLREPO" add a.txt
git -C "$DLREPO" commit -qm "chore: base"
hook 70-commit-landed.sh "$DLB" "$DLREPO" >/dev/null   # baseline only, no event

printf 'one\n' >> "$DLREPO/a.txt"; git -C "$DLREPO" add a.txt
git -C "$DLREPO" commit -qm "fix: small"
hook 70-commit-landed.sh "$DLB" "$DLREPO" >/dev/null   # direct-lane, within bound

hook 20-pre-delegate.sh \
  "$SDL,\"tool_input\":{\"subagent_type\":\"builder\",\"prompt\":\"T9\"}}" "$DLREPO" >/dev/null

printf 'two\n' >> "$DLREPO/a.txt"; git -C "$DLREPO" add a.txt
git -C "$DLREPO" commit -qm "fix: after dispatch"
hook 70-commit-landed.sh "$DLB" "$DLREPO" >/dev/null   # NOT direct-lane

for i in 1 2 3; do printf 'f%s\n' "$i" > "$DLREPO/f$i.txt"; git -C "$DLREPO" add "f$i.txt"; done
seq 1 60 >> "$DLREPO/a.txt"; git -C "$DLREPO" add a.txt
git -C "$DLREPO" commit -qm "fix: big direct edit"
hook 70-commit-landed.sh "$DLB" "$DLREPO" >/dev/null   # direct-lane, OVER BOUND

DLOUT=$(.claude/scripts/metrics.sh "$LOGDIR/session-dlanesess.jsonl")
eq "direct-lane count excludes the post-dispatch commit" 2 \
   "$(printf '%s' "$DLOUT" | grep -oE 'direct-lane commits.*: [0-9]+' | grep -oE '[0-9]+$')"
eq "over-bound count flags only the big one" 1 \
   "$(printf '%s' "$DLOUT" | grep -c 'OVER BOUND')"
eq "the header states what the inference establishes, not who wrote it" 1 \
   "$(printf '%s' "$DLOUT" | grep -c 'no worker preceded the commit, not who wrote it')"

echo
echo "--- 005: a session with no dispatches at all — every landed commit is direct-lane"
NDREPO="$TMP/nodispatch-repo"; mkdir -p "$NDREPO"; git -C "$NDREPO" init -q
git -C "$NDREPO" config user.email t@t; git -C "$NDREPO" config user.name t
SND='{"session_id":"nodispsess"'
NDB="$SND,\"tool_input\":{\"command\":\"git status\"}}"
printf 'base\n' > "$NDREPO/a.txt"; git -C "$NDREPO" add a.txt
git -C "$NDREPO" commit -qm "chore: base"
hook 70-commit-landed.sh "$NDB" "$NDREPO" >/dev/null
printf 'one\n' >> "$NDREPO/a.txt"; git -C "$NDREPO" add a.txt
git -C "$NDREPO" commit -qm "fix: only commit"
hook 70-commit-landed.sh "$NDB" "$NDREPO" >/dev/null
NDOUT=$(.claude/scripts/metrics.sh "$LOGDIR/session-nodispsess.jsonl")
eq "no dispatches logged: the lone commit is still counted direct-lane" 1 \
   "$(printf '%s' "$NDOUT" | grep -oE 'direct-lane commits.*: [0-9]+' | grep -oE '[0-9]+$')"

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
echo "--- the acceptance gate switch (ACCEPT_GATE)"
# The gate is ON unless the value is exactly "off". A typo must not silently
# remove a verification gate, so every near-miss spelling is tested for ON.
#
# The case that matters is the one that FORCES off and asserts the notice
# appears. A test that only checks the hook stays quiet would pass against a
# hook that had lost the feature entirely.
GATEDIR="$TMP/gate"; mkdir -p "$GATEDIR"
gate_ctx() {  # gate_ctx <value|__unset__> -> the injected context, or empty
  ( if [ "$1" = "__unset__" ]; then unset ACCEPT_GATE; else export ACCEPT_GATE="$1"; fi
    METRICS_DIR="$GATEDIR" CLAUDE_PROJECT_DIR="$PROJ" \
      bash "$KIT/.claude/hooks/10-session-start.sh" </dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null )
}
has_gate() { printf '%s' "$1" | grep -c 'Acceptance gate' | tr -d ' '; }

eq "off announces the gate"            1 "$(has_gate "$(gate_ctx off)")"
eq "unset is silent, and the gate is on" 0 "$(has_gate "$(gate_ctx __unset__)")"
eq "on is silent"                      0 "$(has_gate "$(gate_ctx on)")"
eq "OFF is a typo, not a switch"       0 "$(has_gate "$(gate_ctx OFF)")"
eq "Off is a typo, not a switch"       0 "$(has_gate "$(gate_ctx Off)")"
eq "0 is not a switch"                 0 "$(has_gate "$(gate_ctx 0)")"
eq "empty is not a switch"             0 "$(has_gate "$(gate_ctx '')")"
eq "false is not a switch"             0 "$(has_gate "$(gate_ctx false)")"

# The rest of the injected context is unchanged by the switch: the notice is
# added, nothing is displaced.
ON_CTX=$(gate_ctx on); OFF_CTX=$(gate_ctx off)
eq "lessons still reach the session with the gate off" 1 \
   "$(printf '%s' "$OFF_CTX" | grep -c 'Lessons from prior sessions' | tr -d ' ')"
eq "the open ledger still reaches it too" 1 \
   "$(printf '%s' "$OFF_CTX" | grep -c 'Open ledger' | tr -d ' ')"
eq "the gate notice displaces nothing" 0 \
   "$(diff <(printf '%s\n' "$ON_CTX") <(printf '%s\n' "$OFF_CTX") | grep -c '^<' | tr -d ' ')"
eq "and adds only itself" 0 \
   "$(diff <(printf '%s\n' "$ON_CTX") <(printf '%s\n' "$OFF_CTX") | grep '^>' \
      | grep -cv 'Acceptance gate\|ACCEPT_GATE\|^> $' | tr -d ' ')"

# Fail open, and in the safe direction: without jq the hook is silent, so the
# OFF notice never reaches the session and the gate reads ON. Ceremony runs
# when it should not, rather than a gate quietly disappearing.
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for c in bash sed grep git find date cat wc tr head sort awk chmod mktemp rm printf; do
  CP=$(command -v "$c" 2>/dev/null) && ln -sf "$CP" "$NOJQ/$c"
done
OUT=$(PATH="$NOJQ" ACCEPT_GATE=off METRICS_DIR="$GATEDIR" CLAUDE_PROJECT_DIR="$PROJ" \
        bash "$KIT/.claude/hooks/10-session-start.sh" </dev/null 2>/dev/null); RC=$?
eq "no jq: session-start still exits 0"        0 "$RC"
eq "no jq: and emits nothing, so the gate is on" "" "$OUT"

echo
echo "--- the whole log is valid JSON, every line"
eq "jq -s parses it" 0 "$(events | jq -s '.' >/dev/null 2>&1; printf %s $?)"
eq "every event has a type"    0 "$(events | jq -r 'select(.event == null)' | wc -l | tr -d ' ')"
eq "every event has an origin" 0 "$(events | jq -r 'select(.origin == null)' | wc -l | tr -d ' ')"
eq "every event has a session" 0 "$(events | jq -r 'select(.session == null)' | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
