#!/usr/bin/env bash
# Behavior test for install.sh's CLAUDE.md decision matrix, including the
# renamed-fork guard. Run from the kit repo: ./test-install-claudemd.sh
#
# The guard exists because a renamed fork (chair renamed, agents/skills
# prefixed) is invisible to a migration that keys on a literal '# SUPERVISOR'.
# The failure was silent: the new constitution appended below the fork's, two
# contradictory routing tables live at once, install-check all green.
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ANCHOR='## Where the detail lives'

# A CLAUDE.md with the framework's structure under a renamed chair.
fork_md() { printf '# %s — the chair\n\nBody.\n\n%s\n\n| Need | Load |\n' "$1" "$ANCHOR"; }

# $1 label  $2 expected exit  $3 expected stdout pattern ('' = skip)  $4.. args
check() {
  local label="$1" want="$2" pat="$3"; shift 3
  local out rc
  out="$("$KIT/install.sh" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    printf 'FAIL  %s\n      expected exit %s, got %s\n' "$label" "$want" "$rc"; FAIL=$((FAIL+1)); return
  fi
  if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then
    printf 'FAIL  %s\n      expected output to match: %s\n' "$label" "$pat"; FAIL=$((FAIL+1)); return
  fi
  printf 'ok    %s\n' "$label"; PASS=$((PASS+1))
}

# A target that already has a framework file, so mode is adopt, not install.
seeded() {
  local d="$TMP/$1"; mkdir -p "$d/.claude/hooks"
  cp "$KIT/.claude/hooks/10-session-start.sh" "$d/.claude/hooks/"
  printf '%s' "$d"
}

echo "== renamed-fork guard"

d="$(seeded fork)"; fork_md FABLE > "$d/CLAUDE.md"
check "fork refused, names the fork" 4 'FABLE' "$d" --adopt --dry-run

d="$(seeded fork_force)"; fork_md FABLE > "$d/CLAUDE.md"
check "--force bypasses, appends" 0 'append' "$d" --adopt --force --dry-run

# Nothing may be written before the guard: a non-dry-run refusal leaves the
# tree byte-for-byte unchanged.
d="$(seeded fork_nowrite)"; fork_md FABLE > "$d/CLAUDE.md"
before="$(find "$d" -type f -exec shasum {} + | sort)"
"$KIT/install.sh" "$d" --adopt >/dev/null 2>&1
after="$(find "$d" -type f -exec shasum {} + | sort)"
if [ "$before" = "$after" ]; then
  echo "ok    refusal writes nothing"; PASS=$((PASS+1))
else
  echo "FAIL  refusal modified the target tree"; FAIL=$((FAIL+1))
fi

echo
echo "== the guard must not fire on these"

# A first-time install: the anchor is somebody else's heading, not a fork.
d="$TMP/fresh_coincidence"; mkdir -p "$d"
printf '# My Own Project Notes\n\n%s\n' "$ANCHOR" > "$d/CLAUDE.md"
check "fresh install, coincidental anchor" 0 '' "$d" --stack none --dry-run

d="$(seeded unmarked)"; cp "$KIT/CLAUDE.md" "$d/CLAUDE.md"
check "unmarked SUPERVISOR migrates" 0 'migrate' "$d" --adopt --dry-run

d="$(seeded marked)"
{ echo '<!-- BEGIN SUPERVISOR FRAMEWORK -->'; cat "$KIT/CLAUDE.md"
  echo '<!-- END SUPERVISOR FRAMEWORK -->'; } > "$d/CLAUDE.md"
check "marked block updates" 0 'update' "$d" --adopt --dry-run

d="$(seeded plain)"; printf '# My Project\n\nNotes.\n' > "$d/CLAUDE.md"
check "plain CLAUDE.md appends" 0 'append' "$d" --adopt --dry-run

d="$(seeded nocm)"
check "missing CLAUDE.md installs" 0 'install   CLAUDE.md' "$d" --adopt --dry-run

echo
echo "== known limitation (documented, not a bug)"
# A fork that also renamed the anchor is not detected. Asserted so that if a
# future change starts catching it, this test fails and gets updated rather
# than the limitation being quietly assumed to still hold.
d="$(seeded fork_renamed_anchor)"
printf '# FABLE — the chair\n\nBody.\n\n## Where the map lives\n' > "$d/CLAUDE.md"
check "fork w/ renamed anchor slips through" 0 'append' "$d" --adopt --dry-run

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
