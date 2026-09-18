#!/usr/bin/env bash
# Install the Supervisor framework into a project repo.
#
#   ./install.sh /path/to/your/repo [--stack node|python|rust-go|none] [--dry-run]
#
# Safe to re-run: this is also the upgrade path. Nothing you have written is
# ever clobbered. Three things collide on a real repo, and each is handled
# rather than hoped about:
#
#   CLAUDE.md      — most repos have one. The constitution goes in between
#                    markers, appended if the file exists, replaced in place on
#                    re-run. Your own instructions are untouched.
#   settings.json  — if you already have one, yours stays and the merged
#                    version is written alongside as .new for you to diff.
#   check commands — the base settings are stack-neutral. A stack fragment is
#                    merged in, detected from your repo or named with --stack.
#
# Any other file that exists and differs is written as <file>.new and listed at
# the end. The installer never overwrites and never deletes.

set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
TARGET=""; STACK=""; DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --stack) STACK="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || { echo "usage: ./install.sh /path/to/your/repo [--stack S] [--dry-run]" >&2; exit 2; }
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || { echo "no such directory: $TARGET" >&2; exit 1; }
[ "$TARGET" = "$KIT" ] && { echo "refusing to install the kit into itself" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 \
  || echo "  note: $TARGET is not a git repo yet. The commit gate and review skills assume one."

NEW=(); WROTE=(); KEPT=0
say()  { [ "$DRY" -eq 1 ] && printf '  would %s\n' "$1" || printf '  %s\n' "$1"; }
put()  { # put <src> <dst-relative>
  local src="$1" dst="$TARGET/$2"
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then KEPT=$((KEPT+1)); return; fi
    [ "$DRY" -eq 0 ] && { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst.new"; }
    NEW+=("$2.new"); say "differs, wrote $2.new"
  else
    [ "$DRY" -eq 0 ] && { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; }
    WROTE+=("$2"); say "wrote $2"
  fi
}
seed() { # seed <src> <dst> — only if absent; never .new, these are yours to fill
  if [ -e "$TARGET/$2" ]; then KEPT=$((KEPT+1)); return; fi
  [ "$DRY" -eq 0 ] && { mkdir -p "$(dirname "$TARGET/$2")"; cp "$1" "$TARGET/$2"; }
  WROTE+=("$2"); say "seeded $2"
}

echo "installing into $TARGET"
[ "$DRY" -eq 1 ] && echo "  (dry run — nothing will be written)"

# --- 1. stack ----------------------------------------------------------------
if [ -z "$STACK" ]; then
  if   [ -f "$TARGET/package.json" ];   then STACK=node
  elif [ -f "$TARGET/pyproject.toml" ] || [ -f "$TARGET/setup.py" ] || [ -f "$TARGET/requirements.txt" ]; then STACK=python
  elif [ -f "$TARGET/Cargo.toml" ] || [ -f "$TARGET/go.mod" ]; then STACK=rust-go
  else STACK=none; fi
  echo "  stack: $STACK (detected)"
else
  echo "  stack: $STACK"
fi
FRAG="$KIT/.claude/settings.examples/$STACK.json"
[ "$STACK" = none ] || [ -f "$FRAG" ] || { echo "no such stack: $STACK" >&2; exit 2; }

# --- 2. the kit itself -------------------------------------------------------
echo
echo "agents, skills, hooks, scripts"
while IFS= read -r f; do
  put "$KIT/$f" "$f"
done < <(cd "$KIT" && find .claude/agents .claude/skills .claude/hooks .claude/scripts .claude/settings.examples -type f 2>/dev/null | sort)
put "$KIT/.claude/install-check.sh" ".claude/install-check.sh"
[ "$DRY" -eq 0 ] && chmod +x "$TARGET"/.claude/hooks/*.sh "$TARGET/.claude/install-check.sh" 2>/dev/null

# --- 3. settings.json --------------------------------------------------------
echo
echo "settings"
MERGED="$(mktemp)"; LAYER="$(mktemp)"
# Canonical form from the start: both lists uniqued and sorted on every path.
# Otherwise the second run normalizes what the first wrote, the bytes differ,
# and the upgrade path produces a spurious .new. (CI checks exactly this.)
if [ "$STACK" = none ]; then
  jq '.permissions.allow = (.permissions.allow // [] | unique)
      | .permissions.deny = (.permissions.deny // [] | unique)' \
     "$KIT/.claude/settings.json" > "$LAYER"
else
  jq -s '.[0] as $base | .[1] as $frag
         | $base
         | .permissions.allow = (($base.permissions.allow // []) + ($frag.permissions.allow // []) | unique)
         | .permissions.deny  = ($base.permissions.deny // [] | unique)' \
     "$KIT/.claude/settings.json" "$FRAG" > "$LAYER"
fi

# If they already have settings, the .new must be adoptable as-is: ours layered
# over theirs, with both allow and deny lists unioned rather than replaced.
if [ -f "$TARGET/.claude/settings.json" ]; then
  jq -s '.[0] as $yours | .[1] as $ours
         | ($yours * $ours)
         | .permissions.allow = ((($yours.permissions.allow // []) + ($ours.permissions.allow // [])) | unique)
         | .permissions.deny  = ((($yours.permissions.deny  // []) + ($ours.permissions.deny  // [])) | unique)' \
     "$TARGET/.claude/settings.json" "$LAYER" > "$MERGED" 2>/dev/null \
     || cp "$LAYER" "$MERGED"
else
  cp "$LAYER" "$MERGED"
fi
put "$MERGED" ".claude/settings.json"
rm -f "$MERGED" "$LAYER"

# --- 4. docs -----------------------------------------------------------------
echo
echo "docs"
put  "$KIT/docs/ROUTING.md"           "docs/ROUTING.md"
seed "$KIT/docs/LEDGER.md"            "docs/LEDGER.md"
seed "$KIT/docs/LESSONS.md"           "docs/LESSONS.md"
seed "$KIT/.claude/templates/INTENT.md" "docs/INTENT.md"
put  "$KIT/docs/plans/000-template.md" "docs/plans/000-template.md"

# --- 5. scratch + gitignore --------------------------------------------------
echo
echo "workspace"
if [ ! -e "$TARGET/scratch/.gitkeep" ]; then
  [ "$DRY" -eq 0 ] && { mkdir -p "$TARGET/scratch"; : > "$TARGET/scratch/.gitkeep"; }
  say "created scratch/"
else KEPT=$((KEPT+1)); fi

if grep -qs 'scratch/\*' "$TARGET/.gitignore"; then
  KEPT=$((KEPT+1))
else
  if [ "$DRY" -eq 0 ]; then
    printf '\n# Supervisor framework: shared Supervisor/worker workspace, never committed.\nscratch/*\n!scratch/.gitkeep\n' >> "$TARGET/.gitignore"
  fi
  say "appended scratch rules to .gitignore"
fi

# --- 6. CLAUDE.md ------------------------------------------------------------
echo
echo "CLAUDE.md"
BEGIN='<!-- BEGIN SUPERVISOR FRAMEWORK -->'
END='<!-- END SUPERVISOR FRAMEWORK -->'
CM="$TARGET/CLAUDE.md"
BLOCK="$(mktemp)"
{ printf '%s\n' "$BEGIN"; cat "$KIT/CLAUDE.md"; printf '%s\n' "$END"; } > "$BLOCK"

if [ ! -e "$CM" ]; then
  [ "$DRY" -eq 0 ] && cp "$BLOCK" "$CM"
  WROTE+=("CLAUDE.md"); say "wrote CLAUDE.md"
elif grep -qF "$BEGIN" "$CM"; then
  if [ "$DRY" -eq 0 ]; then
    awk -v b="$BEGIN" -v e="$END" -v f="$BLOCK" '
      index($0,b){ while ((getline l < f) > 0) print l; close(f); skip=1; next }
      index($0,e){ skip=0; next }
      !skip' "$CM" > "$CM.tmp" && mv "$CM.tmp" "$CM"
  fi
  say "refreshed the framework block in CLAUDE.md (your own sections untouched)"
else
  if [ "$DRY" -eq 0 ]; then printf '\n' >> "$CM"; cat "$BLOCK" >> "$CM"; fi
  say "appended the framework block to your existing CLAUDE.md"
fi
rm -f "$BLOCK"

# --- 7. report ---------------------------------------------------------------
echo
echo "----------------------------------------------------------------"
printf 'installed: %d file(s), unchanged: %d\n' "${#WROTE[@]}" "$KEPT"
if [ "${#NEW[@]}" -gt 0 ]; then
  echo
  echo "These differed from yours. Nothing was overwritten — diff and adopt:"
  printf '  %s\n' "${NEW[@]}"
  case " ${NEW[*]} " in *" .claude/settings.json.new "*)
    echo
    echo "  settings.json.new is yours with ours layered on top: both allow and"
    echo "  deny lists are unioned, so it is adoptable as-is. One exception — if"
    echo "  you had your own hooks, the framework's replaced them in that file."
    echo "  Check the hooks key before you move it into place." ;;
  esac
fi

if [ "$DRY" -eq 1 ]; then echo; echo "dry run: nothing written."; exit 0; fi

echo
echo "Next:"
echo "  1. Fill in docs/INTENT.md — what this project is. CLAUDE.md points there."
echo "  2. Check permissions.allow in .claude/settings.json against your real"
echo "     check commands. The skills run these; wrong entries mean prompts."
echo "  3. Run the probe once and record the answer in docs/LESSONS.md:"
echo "       .claude/install-check.sh --probe"
echo
cd "$TARGET" && .claude/install-check.sh --static
