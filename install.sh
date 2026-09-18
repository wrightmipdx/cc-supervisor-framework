#!/usr/bin/env bash
# Install or upgrade the Supervisor framework in a project repo.
#
#   ./install.sh /path/to/repo [--stack node|python|rust-go|none]
#                              [--adopt] [--force] [--dry-run]
#
# INSTALL writes the framework and records a manifest at
# .claude/.framework-manifest: the version, the stack, and a hash per file.
#
# UPGRADE reads that manifest, which is what lets it tell your edits from the
# previous version's files:
#
#   unchanged since install  -> overwritten with the new version
#   you edited it            -> left alone, new version written as .new
#   removed upstream         -> deleted (or kept, if you had edited it)
#   CLAUDE.md                -> only the marked framework block is replaced
#
# The promise is "nothing YOU wrote is overwritten", not "nothing is
# overwritten" — otherwise an upgrade cannot land.
#
# --adopt   One-time migration for a repo installed before manifests existed.
#           Declares the framework files currently in the target to be
#           unmodified, writes a manifest, then upgrades. If you had customized
#           a framework file, that customization is lost — commit first and read
#           `git diff` afterwards. Also rewrites an unmarked constitution in
#           CLAUDE.md so future upgrades replace it cleanly.
# --force   Overwrite locally modified framework files too.
# --dry-run Print the plan. Write nothing.

set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$KIT/VERSION" 2>/dev/null || echo unknown)"
MANIFEST_REL=".claude/.framework-manifest"
SET_REL=".claude/settings.json"   # tracked in the manifest, but managed separately below
BEGIN_MARK='<!-- BEGIN SUPERVISOR FRAMEWORK -->'
END_MARK='<!-- END SUPERVISOR FRAMEWORK -->'

TARGET=""; STACK=""; DRY=0; ADOPT=0; FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --stack) STACK="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --adopt) ADOPT=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || { echo "usage: ./install.sh /path/to/repo [--stack S] [--adopt] [--force] [--dry-run]" >&2; exit 2; }
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || { echo "no such directory: $TARGET" >&2; exit 1; }
[ "$TARGET" = "$KIT" ] && { echo "refusing to install the kit into itself" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
        else sha256sum "$1" | awk '{print $1}'; fi; }

# Every path the framework owns. Anything not listed here is yours.
framework_paths() {
  { (cd "$KIT" && find .claude/agents .claude/skills .claude/hooks .claude/scripts \
        .claude/settings.examples -type f 2>/dev/null)
    echo ".claude/install-check.sh"
    echo "docs/ROUTING.md"
    echo "docs/plans/000-template.md"
  } | sort -u
}

MF="$TARGET/$MANIFEST_REL"
manifest_hash() { [ -f "$MF" ] && awk -v p="$1" '$2==p {print $1; exit}' "$MF"; }
manifest_paths() { [ -f "$MF" ] && awk 'NF==2 && $1 ~ /^[0-9a-f]{64}$/ {print $2}' "$MF"; }
manifest_field() { [ -f "$MF" ] && awk -v k="$1" '$1==k {print $2; exit}' "$MF"; }

# --- mode ---------------------------------------------------------------------
HAS_FRAMEWORK=0
while IFS= read -r p; do
  [ -e "$TARGET/$p" ] && { HAS_FRAMEWORK=1; break; }
done < <(framework_paths)

if [ -f "$MF" ]; then MODE=upgrade
elif [ "$HAS_FRAMEWORK" -eq 1 ]; then MODE=adopt
else MODE=install; fi

if [ "$MODE" = adopt ] && [ "$ADOPT" -eq 0 ]; then
  cat >&2 <<MSG
This repo already has framework files but no manifest ($MANIFEST_REL),
so it was installed before manifests existed. Without one the installer cannot
tell your edits from the previous version's files, and refusing is safer than
guessing.

Re-run with --adopt to migrate it. That declares every framework file currently
in the target to be unmodified, writes a manifest, and upgrades. Commit your
work first: if you customized a framework file, --adopt will overwrite it.

  ./install.sh "$TARGET" --adopt --dry-run   # see the plan first
MSG
  exit 3
fi
[ "$MODE" = adopt ] && MODE=upgrade-adopt

# --- stack --------------------------------------------------------------------
if [ -z "$STACK" ]; then
  STACK="$(manifest_field stack)"
  if [ -n "$STACK" ]; then :
  elif [ -f "$TARGET/package.json" ]; then STACK=node
  elif [ -f "$TARGET/pyproject.toml" ] || [ -f "$TARGET/setup.py" ] || [ -f "$TARGET/requirements.txt" ]; then STACK=python
  elif [ -f "$TARGET/Cargo.toml" ] || [ -f "$TARGET/go.mod" ]; then STACK=rust-go
  else STACK=none; fi
fi
FRAG="$KIT/.claude/settings.examples/$STACK.json"
[ "$STACK" = none ] || [ -f "$FRAG" ] || { echo "no such stack: $STACK" >&2; exit 2; }

echo "framework $VERSION -> $TARGET"
echo "  mode: ${MODE}${ADOPT:+}   stack: $STACK"
[ "$MODE" = upgrade ] && echo "  installed version: $(manifest_field version)"
[ "$DRY" -eq 1 ] && echo "  (dry run — nothing will be written)"
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 \
  || echo "  note: not a git repo. The commit gate and review skills assume one."

# --- plan ---------------------------------------------------------------------
PLAN="$(mktemp)"   # lines: <action> <path>
ADOPTED="$(mktemp)"

for p in $(framework_paths); do
  src="$KIT/$p"; dst="$TARGET/$p"
  if [ ! -e "$dst" ]; then
    echo "install $p" >> "$PLAN"; continue
  fi
  if cmp -s "$src" "$dst"; then
    echo "keep $p" >> "$PLAN"; continue
  fi
  if [ "$MODE" = install ]; then
    echo "conflict $p" >> "$PLAN"; continue
  fi
  if [ "$MODE" = upgrade-adopt ]; then
    echo "$(sha "$dst")  $p" >> "$ADOPTED"     # declared unmodified
    echo "update $p" >> "$PLAN"; continue
  fi
  want="$(manifest_hash "$p")"
  have="$(sha "$dst")"
  if [ -n "$want" ] && [ "$want" = "$have" ]; then echo "update $p" >> "$PLAN"
  elif [ "$FORCE" -eq 1 ]; then echo "force $p" >> "$PLAN"
  else echo "conflict $p" >> "$PLAN"; fi
done

# Paths the previous version installed that this one no longer ships.
if [ "$MODE" != install ]; then
  CURRENT="$(framework_paths)"
  if [ "$MODE" = upgrade-adopt ]; then
    # Nothing recorded, so infer: framework-shaped files under the dirs we own.
    OLD_PATHS="$( (cd "$TARGET" && find .claude/agents .claude/skills .claude/hooks \
                     .claude/scripts .claude/settings.examples -type f 2>/dev/null) | sort -u)"
  else
    OLD_PATHS="$(manifest_paths)"
  fi
  for p in $OLD_PATHS; do
    # settings.json is manifest-tracked so upgrades can tell your edits from
    # ours, but it is never a removal candidate: it is merged, not shipped.
    [ "$p" = "$SET_REL" ] && continue
    printf '%s\n' "$CURRENT" | grep -qxF "$p" && continue
    [ -e "$TARGET/$p" ] || continue
    if [ "$MODE" = upgrade-adopt ] || [ "$FORCE" -eq 1 ]; then
      echo "remove $p" >> "$PLAN"
    else
      want="$(manifest_hash "$p")"
      if [ "$want" = "$(sha "$TARGET/$p")" ]; then echo "remove $p" >> "$PLAN"
      else echo "orphan $p" >> "$PLAN"; fi
    fi
  done
fi

show() {
  local act="$1" label="$2"
  local n; n=$(awk -v a="$act" '$1==a' "$PLAN" | wc -l | tr -d ' ')
  [ "$n" -eq 0 ] && return
  [ "$act" = keep ] && { printf '  %-9s %s file(s) already current\n' "$label" "$n"; return; }
  awk -v a="$act" -v l="$label" '$1==a {printf "  %-9s %s\n", l, $2}' "$PLAN"
}
echo
echo "plan"
show install  "install"
show update   "update"
show force    "overwrite"
show remove   "remove"
show conflict "conflict"
show orphan   "orphan"
show keep     "keep"

if awk '$1=="conflict"' "$PLAN" | grep -q .; then
  echo
  if [ "$MODE" = install ]; then
    echo "  conflict = the file exists and differs from this release. Yours is kept;"
    echo "  the new one is written as .new."
  else
    echo "  conflict = you edited this framework file after installing. Yours is kept;"
    echo "  the new one is written as .new. --force overwrites instead."
  fi
fi
awk '$1=="orphan"' "$PLAN" | grep -q . && {
  echo
  echo "  orphan = removed in this release, but you had edited it. Left in place;"
  echo "  delete it yourself once you have salvaged anything you want."
}

# --- apply --------------------------------------------------------------------
NEWFILES=(); REMOVED=()
if [ "$DRY" -eq 0 ]; then
  while read -r act p; do
    case "$act" in
      install|update|force)
        mkdir -p "$(dirname "$TARGET/$p")"; cp "$KIT/$p" "$TARGET/$p" ;;
      conflict)
        mkdir -p "$(dirname "$TARGET/$p")"; cp "$KIT/$p" "$TARGET/$p.new"; NEWFILES+=("$p.new") ;;
      remove)
        rm -f "$TARGET/$p"; REMOVED+=("$p"); rmdir "$(dirname "$TARGET/$p")" 2>/dev/null ;;
    esac
  done < "$PLAN"
  chmod +x "$TARGET"/.claude/hooks/*.sh "$TARGET/.claude/install-check.sh" 2>/dev/null
fi

# --- settings.json ------------------------------------------------------------
LAYER="$(mktemp)"; MERGED="$(mktemp)"
if [ "$STACK" = none ]; then
  jq '.permissions.allow = (.permissions.allow // [] | unique)
      | .permissions.deny  = (.permissions.deny  // [] | unique)' \
     "$KIT/.claude/settings.json" > "$LAYER"
else
  jq -s '.[0] as $b | .[1] as $f | $b
         | .permissions.allow = (($b.permissions.allow // []) + ($f.permissions.allow // []) | unique)
         | .permissions.deny  = ($b.permissions.deny // [] | unique)' \
     "$KIT/.claude/settings.json" "$FRAG" > "$LAYER"
fi

SET="$TARGET/$SET_REL"
SET_ACTION=""
if [ ! -f "$SET" ]; then
  SET_ACTION=install; cp "$LAYER" "$MERGED"
elif cmp -s "$LAYER" "$SET"; then
  SET_ACTION=keep
else
  want="$(manifest_hash "$SET_REL")"; have="$(sha "$SET")"
  if [ "$MODE" = upgrade-adopt ] || [ "$FORCE" -eq 1 ] || { [ -n "$want" ] && [ "$want" = "$have" ]; }; then
    SET_ACTION=update; cp "$LAYER" "$MERGED"
    [ "$MODE" = upgrade-adopt ] && echo "$have  $SET_REL" >> "$ADOPTED"
  else
    SET_ACTION=conflict
    jq -s '.[0] as $y | .[1] as $o | ($y * $o)
           | .permissions.allow = ((($y.permissions.allow // []) + ($o.permissions.allow // [])) | unique)
           | .permissions.deny  = ((($y.permissions.deny  // []) + ($o.permissions.deny  // [])) | unique)' \
       "$SET" "$LAYER" > "$MERGED" 2>/dev/null || cp "$LAYER" "$MERGED"
  fi
fi
echo
case "$SET_ACTION" in
  install)  echo "settings"; echo "  install   $SET_REL"; [ "$DRY" -eq 0 ] && cp "$MERGED" "$SET" ;;
  update)   echo "settings"; echo "  update    $SET_REL (unmodified since install)"; [ "$DRY" -eq 0 ] && cp "$MERGED" "$SET" ;;
  conflict) echo "settings"; echo "  conflict  $SET_REL — yours kept, merged copy as .new"
            [ "$DRY" -eq 0 ] && { cp "$MERGED" "$SET.new"; NEWFILES+=("$SET_REL.new"); } ;;
  keep)     echo "settings"; echo "  keep      $SET_REL already current" ;;
esac
rm -f "$LAYER" "$MERGED"

# --- docs, workspace ----------------------------------------------------------
seed() { [ -e "$TARGET/$2" ] && return 0
         [ "$DRY" -eq 0 ] && { mkdir -p "$(dirname "$TARGET/$2")"; cp "$1" "$TARGET/$2"; }
         echo "  seed      $2"; }
echo
echo "yours — seeded once, never touched again"
seed "$KIT/docs/LEDGER.md"              "docs/LEDGER.md"
seed "$KIT/docs/LESSONS.md"             "docs/LESSONS.md"
seed "$KIT/.claude/templates/INTENT.md" "docs/INTENT.md"
if [ ! -e "$TARGET/scratch/.gitkeep" ]; then
  [ "$DRY" -eq 0 ] && { mkdir -p "$TARGET/scratch"; : > "$TARGET/scratch/.gitkeep"; }
  echo "  create    scratch/"
fi
if ! grep -qs 'scratch/\*' "$TARGET/.gitignore"; then
  [ "$DRY" -eq 0 ] && printf '\n# Supervisor framework: shared Supervisor/worker workspace, never committed.\nscratch/*\n!scratch/.gitkeep\n' >> "$TARGET/.gitignore"
  echo "  append    .gitignore"
fi

# --- CLAUDE.md ----------------------------------------------------------------
echo
echo "CLAUDE.md"
CM="$TARGET/CLAUDE.md"
BLOCK="$(mktemp)"
{ printf '%s\n' "$BEGIN_MARK"; cat "$KIT/CLAUDE.md"; printf '%s\n' "$END_MARK"; } > "$BLOCK"

replace_marked() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v f="$BLOCK" '
    index($0,b){ while ((getline l < f) > 0) print l; close(f); skip=1; next }
    index($0,e){ skip=0; next } !skip' "$CM" > "$CM.tmp" && mv "$CM.tmp" "$CM"
}

if [ ! -e "$CM" ]; then
  [ "$DRY" -eq 0 ] && cp "$BLOCK" "$CM"
  echo "  install   CLAUDE.md"
elif grep -qF "$BEGIN_MARK" "$CM"; then
  [ "$DRY" -eq 0 ] && replace_marked
  echo "  update    framework block replaced; your own sections untouched"
else
  # No markers. Is an old, unmarked constitution in there?
  START=$(grep -n '^# SUPERVISOR$' "$CM" | head -1 | cut -d: -f1)
  ANCHOR=$(grep -n '^## Where the detail lives$' "$CM" | tail -1 | cut -d: -f1)
  TAILHEAD=0
  [ -n "$START" ] && [ -n "$ANCHOR" ] && [ "$ANCHOR" -gt "$START" ] && \
    TAILHEAD=$(awk -v a="$ANCHOR" 'NR>a && /^# [^ ]/ {c++} END{print c+0}' "$CM")

  if [ "$ADOPT" -eq 1 ] && [ -n "$START" ] && [ -n "$ANCHOR" ] && [ "$TAILHEAD" -eq 0 ]; then
    if [ "$DRY" -eq 0 ]; then
      { awk -v s="$START" 'NR < s' "$CM"; cat "$BLOCK"; } > "$CM.tmp" && mv "$CM.tmp" "$CM"
    fi
    echo "  migrate   replaced the unmarked constitution (from line $START) with a marked block"
    [ "$START" -gt 1 ] && echo "            kept your $((START-1)) line(s) above it"
  elif [ -n "$START" ] && [ -n "$ANCHOR" ]; then
    echo "  SKIPPED   an unmarked constitution is present but content follows it —"
    echo "            not guessing where it ends. Delete it by hand, then re-run."
    [ "$ADOPT" -eq 0 ] && echo "            (or re-run with --adopt if nothing follows it)"
  else
    [ "$DRY" -eq 0 ] && { printf '\n' >> "$CM"; cat "$BLOCK" >> "$CM"; }
    echo "  append    framework block appended below your existing CLAUDE.md"
  fi
fi
rm -f "$BLOCK"

# --- manifest -----------------------------------------------------------------
if [ "$DRY" -eq 0 ]; then
  {
    echo "# Supervisor framework manifest. Written by install.sh — do not edit."
    echo "# Records what the installer owns, so an upgrade can tell your edits"
    echo "# from the previous version's files."
    echo "version $VERSION"
    echo "stack $STACK"
    echo "installed $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for p in $(framework_paths); do
      [ -f "$TARGET/$p" ] && echo "$(sha "$TARGET/$p")  $p"
    done
    [ -f "$SET" ] && echo "$(sha "$SET")  $SET_REL"
  } > "$MF"
fi

# --- report -------------------------------------------------------------------
echo
echo "----------------------------------------------------------------"
[ "$DRY" -eq 1 ] && { echo "dry run: nothing written."; rm -f "$PLAN" "$ADOPTED"; exit 0; }

if [ "${#REMOVED[@]}" -gt 0 ]; then
  for p in "${REMOVED[@]}"; do
    base="$(basename "$p")"
    grep -qs "$base" "$SET" && {
      echo "WARNING: $SET_REL still references $base, which this release removed."
      echo "         Remove that block, or the hook silently never fires."; }
  done
fi
if [ "${#NEWFILES[@]}" -gt 0 ]; then
  echo "Kept yours; new versions written alongside — diff and adopt:"
  printf '  %s\n' "${NEWFILES[@]}"
  case " ${NEWFILES[*]} " in *" $SET_REL.new "*)
    echo "  settings.json.new unions your allow/deny with the framework's, so it is"
    echo "  adoptable as-is — but the framework's hooks replaced yours in it." ;;
  esac
  echo
fi
echo "Next:"
echo "  1. git diff — read what changed before you commit it."
echo "  2. Fill in docs/INTENT.md if you have not. CLAUDE.md points there."
echo "  3. Run the probe once, record it in docs/LESSONS.md:"
echo "       .claude/install-check.sh --probe"
echo
rm -f "$PLAN" "$ADOPTED"
cd "$TARGET" && .claude/install-check.sh --static
