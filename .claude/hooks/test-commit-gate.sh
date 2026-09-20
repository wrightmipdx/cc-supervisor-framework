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
run ALLOW 'git commit -m "fix: tighten the gate"'
run ALLOW 'git commit --amend --no-edit'
run ALLOW 'git commit --allow-empty -m "ci: trigger"'

echo
echo "--- text that merely mentions the phrase must be allowed"
run ALLOW 'git commit -m "docs: explain why git add -A is blocked"'
run ALLOW 'grep -rn "git add -A" .claude/'
run ALLOW 'rg "git commit -a" docs/'
run ALLOW 'cat > notes.md <<EOF
git add -A
EOF'
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
