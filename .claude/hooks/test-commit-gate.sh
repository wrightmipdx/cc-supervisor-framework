#!/usr/bin/env bash
# Behavioral test for 30-commit-gate.sh.
# Run: .claude/hooks/test-commit-gate.sh
#
# Each case is: expectation<TAB>command. DENY means the hook must emit a
# permissionDecision of "deny". ALLOW means it must not.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
HOOK=.claude/hooks/30-commit-gate.sh

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
run ALLOW 'git add docs/LEDGER.md docs/LESSONS.md'
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
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
