#!/usr/bin/env bash
# Behavioral test for 30-commit-gate.sh.
# Run: .claude/hooks/test-commit-gate.sh
#
# Each case is: expectation<TAB>command. DENY means the hook must emit a
# permissionDecision of "deny". ALLOW means it must not.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
HOOK=.claude/hooks/30-commit-gate.sh

# The gate writes to the event log, and a test run is not a session. Without
# this, every invocation appends fixture events to the REPO'S OWN .metrics/ —
# and install.sh runs install-check, which runs this suite, so installing the
# framework used to dump about a hundred fake gate_block and commit_attempt
# events straight into the consumer's live log.
METRICS_TMP="$(mktemp -d)"
METRICS_DIR="$METRICS_TMP/metrics"
export METRICS_DIR
trap 'rm -rf "$METRICS_TMP"' EXIT

# Fingerprint of the repo's own log before the run. The check below compares
# against this rather than asserting absence, because a consumer upgrading from
# a version that HAD this bug still has the stale file, and failing their
# install over history they cannot change would be its own defect.
repo_log_state() { wc -c < .metrics/session-test.jsonl 2>/dev/null || printf 'absent'; }
REPO_LOG_BEFORE="$(repo_log_state)"

PASS=0; FAIL=0

run() {
  local want="$1" cmd="$2" out
  out=$(jq -n --arg c "$cmd" '{session_id:"test",tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK")
  local got=ALLOW
  printf '%s' "$out" | grep -q '"permissionDecision": *"deny"' && got=DENY
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); printf 'ok   %-5s %s\n' "$got" "$cmd"
  else
    FAIL=$((FAIL+1)); printf 'FAIL want=%s got=%s  %s\n' "$want" "$got" "$cmd"
  fi
}

# Appends one fixture event straight to the shared session log, the same log
# `run`'s hook invocations read and write. The commit gate now denies any
# commit with no dispatch/reasoned-direct_lane event since the last
# commit_landed (or session start) — every case below that expects ALLOW on
# an actual `git commit` needs one of these first, since `run()` shares one
# log across the whole file with no reset between cases (see METRICS_TMP
# above).
seed() {
  local event="$1"
  mkdir -p "$METRICS_DIR"
  # Whether `reason` is written at all is decided by ARGUMENT COUNT, not by
  # whether the string happens to be empty — production (25-direct-lane.sh)
  # always writes a `reason` key, even an empty one, so `seed direct_lane ""`
  # must produce {reason:""} on disk, not silently omit the key the way a
  # string-emptiness check would.
  if [ "$#" -ge 2 ]; then
    jq -cn --arg e "$event" --arg r "$2" \
      '{event:$e, ts:"1970-01-01T00:00:00Z", session:"test", reason:$r}' \
      >> "$METRICS_DIR/session-test.jsonl"
  else
    jq -cn --arg e "$event" \
      '{event:$e, ts:"1970-01-01T00:00:00Z", session:"test"}' \
      >> "$METRICS_DIR/session-test.jsonl"
  fi
}

# Appends a raw, non-JSON (or otherwise malformed) line straight to the log,
# to prove the gate skips it rather than choking on it.
seed_raw() {
  mkdir -p "$METRICS_DIR"
  printf '%s\n' "$1" >> "$METRICS_DIR/session-test.jsonl"
}

echo "--- blind staging must be blocked"
run DENY  'git add -A'
run DENY  'git add --all'
run DENY  'git add .'
run DENY  'git add :/'
run DENY  'git add -Av'
run DENY  'git add -u'
run DENY  'git commit -a'
run DENY  'git commit -am "wip"'
run DENY  'git commit --all -m "wip"'
run DENY  'git status && git add -A'
run DENY  'git -C sub add -A'

echo
echo "--- explicit paths must be allowed (regression: substring match)"
run ALLOW 'git add .gitignore'
run ALLOW 'git add ./src/foo.ts'
run ALLOW 'git add .claude/hooks/30-commit-gate.sh'
run ALLOW 'git add docs/kit/LEDGER.md docs/kit/LESSONS.md'
seed dispatch
run ALLOW 'git commit -m "fix: tighten the gate"'
seed dispatch
run ALLOW 'git commit --amend --no-edit'
seed dispatch
run ALLOW 'git commit --allow-empty -m "ci: trigger"'

echo
echo "--- text that merely mentions the phrase must be allowed"
seed dispatch
run ALLOW 'git commit -m "docs: explain why git add -A is blocked"'
run ALLOW 'grep -rn "git add -A" .claude/'
run ALLOW 'rg "git commit -a" docs/'
run ALLOW 'cat > notes.md <<EOF
git add -A
EOF'
seed dispatch
run ALLOW 'git commit -m "$(cat <<'"'"'EOF'"'"'
fix: thing

why-line mentioning git add -A
EOF
)"'

echo
echo "--- a heredoc must not hide the commands that FOLLOW it"
run DENY  'cat > notes.md <<EOF
body
EOF
git add -A'
run DENY  'cat > notes.md <<-EOF
	body
	EOF
git commit -am "wip"'
run DENY  'git add -A <<EOF
body
EOF'

echo
echo "--- the reason gate: a direct-lane commit needs a stated reason first"
seed commit_landed
run DENY  'git commit -m "no dispatch, no direct_lane, nothing precedes this"'

seed commit_landed
seed direct_lane
run DENY  'git commit -m "a direct_lane event exists but has no reason key at all"'

seed commit_landed
seed direct_lane ""
run DENY  'git commit -m "a direct_lane event has reason explicitly set to empty string"'

seed commit_landed
seed direct_lane "   "
run DENY  'git commit -m "a direct_lane event has a whitespace-only reason"'

seed commit_landed
seed direct_lane "single-line config tweak, tests exist"
run ALLOW 'git commit -m "a direct_lane event with a real reason precedes it"'

seed commit_landed
seed dispatch
run ALLOW 'git commit -m "a dispatch precedes this commit"'

echo
echo "--- commit_landed resets the window: each commit needs its own event (X4)"
seed commit_landed
seed dispatch
run ALLOW 'git commit -m "first commit in the pair, dispatch precedes it"'
seed commit_landed
run DENY  'git commit -m "second commit, nothing precedes it since the reset"'

echo
echo "--- a malformed line in the log must not wedge the gate for the rest of the session"
seed commit_landed
seed_raw 'not json'
seed dispatch
run ALLOW 'git commit -m "a junk non-JSON line before a valid dispatch must not break the gate"'

seed commit_landed
seed_raw '5'
seed dispatch
run ALLOW 'git commit -m "a bare non-object JSON line must not break the gate either"'

echo
# This run must leave the repo's own log exactly as it found it, and must have
# logged somewhere — otherwise the isolation is untested rather than working.
echo
if [ "$(repo_log_state)" != "$REPO_LOG_BEFORE" ]; then
  FAIL=$((FAIL+1)); printf 'FAIL %s\n' "the suite wrote fixture events into the repo's .metrics/"
elif [ ! -s "$METRICS_DIR/session-test.jsonl" ]; then
  FAIL=$((FAIL+1)); printf 'FAIL %s\n' "nothing was logged at all — isolation is untested"
else
  PASS=$((PASS+1)); printf 'ok   %s\n' "fixture events went to the temp log, not the repo's"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
