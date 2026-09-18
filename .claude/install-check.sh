#!/usr/bin/env bash
# Supervisor install check.
# Run after cloning this framework into a repo, and after any Claude Code
# upgrade: .claude/install-check.sh
#
# Turns the framework's assumptions into facts. Two kinds of check:
#   STATIC  — verified here and now (deps, wiring, dangling references)
#   PROBE   — cannot be verified by a script, because only the harness knows
#             whether it honors a frontmatter key. Printed as a brief you
#             dispatch once, then record the answer in docs/LESSONS.md.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MODE=all
case "${1:-}" in
  --static) MODE=static ;;   # CI: wiring only, no probe to print
  --probe)  MODE=probe  ;;   # just reprint the probe brief
  "")       ;;
  *) echo "usage: install-check.sh [--static|--probe]" >&2; exit 2 ;;
esac

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '  warn  %s\n' "$1"; }

if [ "$MODE" != probe ]; then

echo "== dependencies"
for dep in jq git; do
  if command -v "$dep" >/dev/null 2>&1; then ok "$dep present"
  else bad "$dep missing — hooks fail open and stay silent without it"; fi
done

echo
echo "== hooks"
for h in $(jq -r '.hooks | .. | .command? // empty' .claude/settings.json 2>/dev/null); do
  f="${h/\$\{CLAUDE_PROJECT_DIR\}\//}"
  if [ ! -f "$f" ]; then bad "settings.json references missing hook: $f"
  elif [ ! -x "$f" ]; then bad "hook not executable: $f (chmod +x)"
  else
    bash -n "$f" 2>/dev/null && ok "$f" || bad "$f has a syntax error"
  fi
done
for f in .claude/hooks/*.sh; do
  case "$f" in *test-*) continue ;; esac
  grep -q "$(basename "$f")" .claude/settings.json \
    || warn "$f is not wired into settings.json — it will never fire. If you kept your own settings at install time, adopt .claude/settings.json.new"
done
if [ -x .claude/hooks/test-commit-gate.sh ]; then
  if .claude/hooks/test-commit-gate.sh >/dev/null 2>&1; then ok "commit-gate tests pass"
  else bad "commit-gate tests FAIL — run .claude/hooks/test-commit-gate.sh"; fi
fi

echo
echo "== agents"
for f in .claude/agents/*.md; do
  base=$(basename "$f" .md)
  name=$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)
  model=$(sed -n 's/^model:[[:space:]]*//p' "$f" | head -1)
  desc=$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)
  [ "$name" = "$base" ] || bad "$f: name '$name' does not match filename '$base'"
  [ -n "$model" ] || bad "$f: no model set — it will inherit the Supervisor's, at Supervisor prices"
  [ -n "$desc" ] || bad "$f: no description — the router cannot select it"
  [ -n "$name" ] && [ "$name" = "$base" ] && [ -n "$model" ] && [ -n "$desc" ] && ok "$base ($model)"
done

echo
echo "== references in CLAUDE.md resolve"
for a in $(grep -o '\*\*[a-z]*\*\* (\(haiku\|sonnet\|opus\))' CLAUDE.md | sed 's/\*\*\([a-z]*\)\*\*.*/\1/' | sort -u); do
  [ -f ".claude/agents/$a.md" ] && ok "agent $a" || bad "CLAUDE.md routes to '$a' but .claude/agents/$a.md does not exist"
done
for s in $(sed -n '/Where the detail lives/,$p' CLAUDE.md | grep -o '`[a-z]*`' | tr -d '`' | sort -u); do
  case "$s" in status|intake|plan|dispatch|ui|review|debug|commit|retro) ;; *) continue ;; esac
  [ -f ".claude/skills/$s/SKILL.md" ] && ok "skill $s" || bad "CLAUDE.md points at skill '$s' which does not exist"
done

echo
echo "== paths the skills assume"
for p in docs/LEDGER.md docs/LESSONS.md docs/plans/000-template.md scratch; do
  [ -e "$p" ] && ok "$p" || bad "$p missing — a skill references it"
done
if [ -f docs/INTENT.md ]; then
  grep -q "^One paragraph. What the thing does" docs/INTENT.md \
    && warn "docs/INTENT.md is still the unfilled template — CLAUDE.md sends workers there for product context" \
    || ok "docs/INTENT.md"
else
  warn "docs/INTENT.md missing — CLAUDE.md points at it for product context"
fi
if git check-ignore -q scratch/x 2>/dev/null; then ok "scratch/ is gitignored"
else bad "scratch/ is NOT gitignored, but CLAUDE.md says it is"; fi

echo
fi   # end static section

if [ "$MODE" = static ]; then
  printf '\n%d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
  [ "$FAIL" -eq 0 ]; exit
fi

echo "== PROBE — frontmatter keys this script cannot verify"
KEYS=$(grep -ho '^\(effort\|maxTurns\|omitClaudeMd\|skills\):' .claude/agents/*.md | sort -u | tr -d ':' | tr '\n' ' ')
cat <<PROBE
  These agents declare: ${KEYS:-none}
  An unsupported key is IGNORED SILENTLY. omitClaudeMd is the one that bites:
  if it is not honored, every worker reads the Supervisor constitution.

  Dispatch this once, to builder, and record the answer in docs/LESSONS.md:

    Goal:      Report what is in your context, verbatim, without editing files.
    Done when: You have answered all four:
               1. Do you see a file called CLAUDE.md or a "SUPERVISOR" section
                  in your system prompt or context? Quote its first line if so.
               2. What model are you running as?
               3. List the tool names available to you.
               4. Do you see any skill preloaded into your context? Name it.
    Evidence:  The four answers. Do not infer — report only what you can see.

  Expected: (1) no, (2) sonnet, (3) the tools list in builder.md, (4) whatever
  builder's 'skills:' key names, or none.
  If (1) is yes, omitClaudeMd is not honored in this version — the guard banner
  at the top of CLAUDE.md is doing the work instead. Keep it.
PROBE

echo
[ "$MODE" = probe ] && exit 0
printf '%d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ]
