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
for t in test-commit-gate test-ledger-parse test-lessons-parse test-metrics test-stop-retro; do
  [ -x ".claude/hooks/$t.sh" ] || continue
  if ".claude/hooks/$t.sh" >/dev/null 2>&1; then ok "$t passes"
  else bad "$t FAILS — run .claude/hooks/$t.sh"; fi
done

echo
echo "== ledger parses"
# The failure this catches: a ledger full of requirements that the hooks count
# as zero. Every hook then stays silent and the mechanism is gone with no
# symptom. It went unnoticed once already; it does not get to happen twice.
if [ -f .claude/hooks/lib/ledger.sh ]; then
  # shellcheck disable=SC1091
  . .claude/hooks/lib/ledger.sh
  FOUND=0
  while IFS= read -r L; do
    [ -n "$L" ] || continue
    FOUND=1
    LOOSE=$(ledger_count_looks_like "$L")
    REAL=$(( $(ledger_count_open "$L") + $(ledger_count_done "$L") + $(ledger_count_deferred "$L") ))
    if [ "$LOOSE" -gt 0 ] && [ "$REAL" -eq 0 ]; then
      bad "$L has $LOOSE checkbox-shaped line(s) the parser counts as 0 — the hooks are blind to this ledger"
    else
      ok "$L ($REAL requirement(s) parsed)"
    fi
  done <<EOF
$(ledger_files)
EOF
  [ "$FOUND" -eq 0 ] && warn "no ledger in ${DOCS:-docs}/ yet — the plan skill writes one"
else
  bad ".claude/hooks/lib/ledger.sh missing — every hook that reads a ledger fails open and stays silent"
fi

echo
echo "== framework version"
MF=.claude/.framework-manifest
if [ -f install.sh ] && [ -f VERSION ] && [ -d .claude/templates ]; then
  ok "kit repo, version $(cat VERSION) — no manifest expected here"
  # A path on the retired list that this release also ships is a contradiction:
  # --adopt would delete a live file. Cheap to check, expensive to discover.
  if [ -f retired-paths.txt ]; then
    RC=0
    while read -r rp _; do
      case "$rp" in ''|\#*) continue ;; esac
      if [ -e "$rp" ]; then
        bad "retired-paths.txt lists $rp but this release still ships it — --adopt would delete it"
        RC=1
      fi
    done < retired-paths.txt
    [ "$RC" -eq 0 ] && ok "retired-paths.txt agrees with what this release ships"
  else
    warn "no retired-paths.txt — --adopt cannot remove anything a past release installed"
  fi
elif [ ! -f "$MF" ]; then
  warn "no $MF — installed before manifests existed, or copied by hand. 'install.sh <repo> --adopt' migrates it so upgrades can land"
else
  ok "version $(awk '$1=="version"{print $2}' "$MF") (stack $(awk '$1=="stack"{print $2}' "$MF"))"
  sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
          else sha256sum "$1" | awk '{print $1}'; fi; }
  DRIFT=0
  while read -r want path; do
    case "$want" in [0-9a-f]*) ;; *) continue ;; esac
    [ "${#want}" -eq 64 ] || continue
    if [ ! -f "$path" ]; then warn "$path is in the manifest but missing — an upgrade will reinstall it"; DRIFT=$((DRIFT+1))
    elif [ "$(sha "$path")" != "$want" ]; then
      warn "$path modified locally — an upgrade will keep yours and write .new"; DRIFT=$((DRIFT+1))
    fi
  done < "$MF"
  [ "$DRIFT" -eq 0 ] && ok "no local drift — every framework file matches the manifest"
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
# The kit ships the seeds; a consumer has the files seeded from them. Asserting
# docs/LEDGER.md in the kit would force it to carry a ledger it must not ship.
if [ -f install.sh ] && [ -f VERSION ] && [ -d .claude/templates ]; then
  ASSUME=".claude/templates/LEDGER.md .claude/templates/LESSONS.md .claude/templates/INTENT.md docs/plans/000-template.md scratch"
else
  ASSUME="docs/LEDGER.md docs/LESSONS.md docs/plans/000-template.md scratch"
fi
for p in $ASSUME; do
  [ -e "$p" ] && ok "$p" || bad "$p missing — a skill references it"
done
if [ -f docs/INTENT.md ]; then
  grep -q "^One paragraph. What the thing does" docs/INTENT.md \
    && warn "docs/INTENT.md is still the unfilled template — CLAUDE.md sends workers there for product context" \
    || ok "docs/INTENT.md"
else
  warn "docs/INTENT.md missing — CLAUDE.md points at it for product context"
fi
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  warn "not a git repo — cannot verify scratch/ is ignored, and the commit gate and review skills assume one"
elif git check-ignore -q scratch/x 2>/dev/null; then ok "scratch/ is gitignored"
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
  If (3) is SHORTER than builder's 'tools:' line, the missing names are ones
  this session cannot grant. Before concluding the 'tools:' key is at fault,
  check whether the Supervisor has those tools either — if it does not, the
  tools are absent from the whole session and the agent definitions are fine.
  Seen this way: Glob and Grep absent everywhere, Read/Edit/Write/Bash arriving
  normally. Do not strip the missing names from the definitions; another
  session will have them. Just make sure briefs say to search with Bash
  'grep'/'find' rather than naming the Grep tool, and note it in
  docs/LESSONS.md. Re-probe after a Claude Code upgrade.
PROBE

echo
[ "$MODE" = probe ] && exit 0
printf '%d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ]
