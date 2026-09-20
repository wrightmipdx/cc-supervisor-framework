#!/usr/bin/env bash
# Mechanizes worktree merge-back — the half of "direct lane" that carries no
# judgment: stage the named files, commit, rebase onto the main worktree's
# current branch, fast-forward-only merge, remove the worktree, delete the
# branch. One invocation instead of six commands narrated by the chair.
#
#   .claude/scripts/integrate-worktree.sh <worktree-path> <message> <file>...
#   .claude/scripts/integrate-worktree.sh --self-test
#
# UNLIKE A HOOK, THIS FAILS LOUDLY (docs/INTENT.md). This runs because the
# chair asked it to merge a specific, finished worktree — a silent no-op or a
# silent force-past-a-conflict is worse than an error that stops and explains
# itself. This never falls back from a rebase conflict to a three-way merge,
# and never commits an empty tree just to have something to merge.
#
# SCOPED STAGING (I6) — ENFORCED, not just discipline: only the files named
# on the command line are ever staged. `.`/`:`/`:/`/`-A`/`--all`/`*` as a
# named file are rejected outright (a critic pass caught these passing
# straight through to `git add`, which is the exact blind-add I6 forbids).
# Before staging anything, the worktree is checked for changes OUTSIDE the
# named files — tracked or untracked — and refused if found, rather than
# staging only the named ones and leaving the rest to silently break the
# rebase a few lines later with a misleading "conflict".
#
# BRANCH SOURCE (I7) — do not copy worktrees.sh's detached-HEAD handling here.
# worktrees.sh treats a detached HEAD on the *worktree it is inspecting* as a
# valid, reportable state (correct there — it only reads and reports). Here
# the branch to rebase onto is read from the MAIN worktree, via
# `git -C "$REPO" symbolic-ref --short -q HEAD` — never the worktree being
# merged, and never defaulted to main/development if that main-worktree read
# fails. That silent default is the exact bug class named in opanalyst plan
# 007's own next steps (worktrees provisioned from a hardcoded `main`).
#
# "$REPO" IS VERIFIED TO BE THE MAIN WORKTREE, not just any git repo — a
# critic pass demonstrated that with CLAUDE_PROJECT_DIR pointing at a linked
# worktree, the un-guarded version merged into that worktree's own branch,
# deleted it, and reported success while the real main worktree sat
# untouched. Only the main worktree's git-dir equals the shared repository's
# git-common-dir (a linked worktree's git-dir is a subdirectory of it) — that
# equality is the check, not a path heuristic. The merge target is also
# checked against the main worktree's own path: passing the main worktree
# itself as the thing to merge back is a plausible chair typo, refused
# up front rather than committing onto main directly and failing later with
# a misleading "worktree remove" error.
#
# Dependency: git only.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

die() { printf 'integrate-worktree: %s\n' "$1" >&2; exit 1; }

if [ "${1:-}" = "--self-test" ]; then
  T=$(mktemp -d) || die "cannot make a temp dir"
  trap 'rm -rf "$T"' EXIT

  # --- fixture: a real repo, real linked worktrees ----------------------------
  git init -q -b main "$T/repo"
  git -C "$T/repo" config user.email test@example.com
  git -C "$T/repo" config user.name test
  echo one > "$T/repo/a.txt"
  git -C "$T/repo" add a.txt
  git -C "$T/repo" commit -qm 'first commit'

  fail() { printf 'self-test FAIL: %s\n' "$1" >&2; printf '%s\n' "${OUT:-}" >&2; exit 1; }

  # Case 1 — blind-add file arguments are rejected outright (I6). This check
  # runs before any repo/worktree validation, so a garbage path is fine here.
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/whatever" "msg" . 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "'.' as a named file was not refused"
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/whatever" "msg" -A 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "'-A' as a named file was not refused"

  # Case 2 — CLAUDE_PROJECT_DIR pointing at a LINKED worktree, not the main
  # one (the bug a critic pass reproduced: it silently merged into the linked
  # worktree's own branch and reported success while main sat untouched).
  git -C "$T/repo" worktree add -q -b dispatch-notmain "$T/wt-notmain" >/dev/null
  OUT=$(CLAUDE_PROJECT_DIR="$T/wt-notmain" "$0" "$T/wt-notmain" "msg" a.txt 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "CLAUDE_PROJECT_DIR pointing at a linked worktree was not refused"
  printf '%s' "$OUT" | grep -qi 'main worktree' || fail "expected a 'not the main worktree' message"
  git -C "$T/repo" rev-parse --verify dispatch-notmain >/dev/null 2>&1 \
    || fail "the linked worktree's own branch must not have been touched by the misdirected run"
  git -C "$T/repo" worktree list | grep -q wt-notmain \
    || fail "the linked worktree must not have been removed by the misdirected run"

  # Case 3 — the main worktree itself passed as the merge target (a plausible
  # chair typo): refused up front, never committed onto main directly.
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/repo" "msg" a.txt 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "merging the main worktree into itself was not refused"
  printf '%s' "$OUT" | grep -qi 'itself\|main worktree' || fail "expected a 'refusing to merge into itself' message"

  # Case 4 — missing/unregistered worktree (X3): a path that does not even
  # exist, and a real directory that git never registered as a worktree.
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/nope" "msg" a.txt 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "a nonexistent worktree path was not refused"
  printf '%s' "$OUT" | grep -qi 'does not exist' || fail "expected a 'does not exist' message for a nonexistent path"

  mkdir -p "$T/not-a-worktree"
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/not-a-worktree" "msg" a.txt 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "a real directory that is not a registered worktree was not refused"
  printf '%s' "$OUT" | grep -qi 'registered worktree' || fail "expected a 'not a registered worktree' message"

  # Case 5 — empty-diff refusal (X1): stage a file with no actual change.
  # Must not create a commit, not just print an error.
  git -C "$T/repo" worktree add -q -b dispatch-empty "$T/wt-empty" >/dev/null
  BEFORE=$(git -C "$T/wt-empty" rev-parse HEAD)
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/wt-empty" "no-op" a.txt 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "an empty diff was not refused"
  printf '%s' "$OUT" | grep -qi 'empty diff' || fail "expected an empty-diff refusal message"
  git -C "$T/repo" worktree list | grep -q wt-empty || fail "an empty-diff refusal must leave the worktree in place, not clean it up"
  AFTER=$(git -C "$T/wt-empty" rev-parse HEAD)
  [ "$BEFORE" = "$AFTER" ] || fail "an empty-diff refusal must not create a commit"

  # Case 6 — I6's central claim, proven by refusal: a named file and an
  # UNNAMED dirty tracked file are both present. Before the fix this staged
  # only the named file, then let the unnamed leftover break the rebase a few
  # lines later with a misleading "conflict". Now it refuses up front, before
  # any commit, naming the leftover.
  git -C "$T/repo" worktree add -q -b dispatch-leftover "$T/wt-leftover" >/dev/null
  echo "named change" > "$T/wt-leftover/named.txt"
  echo "unnamed change" >> "$T/wt-leftover/a.txt"
  BEFORE=$(git -C "$T/wt-leftover" rev-parse HEAD)
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/wt-leftover" "msg" named.txt 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "an unnamed dirty tracked file was not refused"
  printf '%s' "$OUT" | grep -q 'a.txt' || fail "expected the leftover file's name in the refusal message"
  AFTER=$(git -C "$T/wt-leftover" rev-parse HEAD)
  [ "$BEFORE" = "$AFTER" ] || fail "a leftover-file refusal must not create a commit"

  # Case 7 — non-fast-forward refusal (X2): the worktree and the main branch
  # diverge on the same line of the same file, so the rebase itself reports a
  # conflict. The script must stop and die() — never fall back to a
  # three-way merge, never force.
  echo base > "$T/repo/conflict.txt"
  git -C "$T/repo" add conflict.txt
  git -C "$T/repo" commit -qm 'add conflict.txt'
  git -C "$T/repo" worktree add -q -b dispatch-conflict "$T/wt-conflict" >/dev/null
  echo "worker version" > "$T/wt-conflict/conflict.txt"
  echo "main version" > "$T/repo/conflict.txt"
  git -C "$T/repo" commit -qam 'main diverges on conflict.txt'
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/wt-conflict" "worker change" conflict.txt 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "a rebase conflict was not refused"
  printf '%s' "$OUT" | grep -qi 'conflict' || fail "expected a conflict message"
  git -C "$T/wt-conflict" rev-parse --verify -q REBASE_HEAD >/dev/null 2>&1 \
    && fail "the rebase was not aborted — a conflict was left in progress instead of refused cleanly"
  git -C "$T/repo" worktree list | grep -q wt-conflict || fail "a rebase-conflict refusal must leave the worktree in place"
  git -C "$T/repo" rev-parse --verify dispatch-conflict >/dev/null 2>&1 \
    || fail "a rebase-conflict refusal must leave the branch in place"

  # Case 8 — detached HEAD on the MAIN worktree (I7): the target branch read
  # must die(), never default to main/development, and never commit either.
  git -C "$T/repo" worktree add -q -b dispatch-detached-main "$T/wt-detached-main" >/dev/null
  echo change > "$T/wt-detached-main/work2.txt"
  BEFORE=$(git -C "$T/wt-detached-main" rev-parse HEAD)
  git -C "$T/repo" checkout -q --detach HEAD
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/wt-detached-main" "msg" work2.txt 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "a detached-HEAD main worktree was not refused"
  printf '%s' "$OUT" | grep -qi 'detached HEAD' || fail "expected a detached-HEAD message"
  git -C "$T/repo" worktree list | grep -q wt-detached-main \
    || fail "a detached-main refusal must leave the worktree in place, not merge it against a defaulted branch"
  AFTER=$(git -C "$T/wt-detached-main" rev-parse HEAD)
  [ "$BEFORE" = "$AFTER" ] || fail "a detached-main refusal must not create a commit"
  git -C "$T/repo" checkout -q main

  # Case 9 — happy path: stage, commit, rebase, ff-merge, remove worktree,
  # delete branch. Verified by real git state after, not just exit code —
  # including that the merge commit contains ONLY the named file (I6), even
  # though other tracked files exist untouched in the same worktree.
  git -C "$T/repo" worktree add -q -b dispatch-happy "$T/wt-happy" >/dev/null
  echo "worker change" > "$T/wt-happy/work.txt"
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/wt-happy" "merge dispatch-happy" work.txt 2>&1)
  RC=$?
  [ "$RC" -eq 0 ] || fail "the happy-path merge-back exited non-zero"
  [ -f "$T/repo/work.txt" ] || fail "work.txt is not present in the main worktree after the merge"
  [ "$(cat "$T/repo/work.txt")" = "worker change" ] || fail "work.txt's content did not survive the merge"
  git -C "$T/repo" worktree list | grep -q wt-happy && fail "the worktree was not removed"
  git -C "$T/repo" rev-parse --verify dispatch-happy >/dev/null 2>&1 && fail "the branch was not deleted"
  [ -d "$T/wt-happy" ] && fail "the worktree directory was not removed from disk"
  NEWEST="$(git -C "$T/repo" rev-parse HEAD)"
  COMMIT_FILES="$(git -C "$T/repo" diff-tree --no-commit-id --name-only -r "$NEWEST")"
  [ "$COMMIT_FILES" = "work.txt" ] \
    || fail "the merge commit should contain exactly the named file, got: $COMMIT_FILES"

  # Case 10 — a named file with a space in it merges successfully (regression:
  # the leftover check used to read git's default porcelain format, which
  # quotes such paths, so they never matched the caller's unquoted argument
  # and a legitimately-named file was refused as if it were a leftover).
  git -C "$T/repo" worktree add -q -b dispatch-space "$T/wt-space" >/dev/null
  echo "spaced" > "$T/wt-space/my notes.txt"
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" "$T/wt-space" "add spaced file" "my notes.txt" 2>&1)
  RC=$?
  [ "$RC" -eq 0 ] || fail "a named file with a space in it was refused instead of merged"
  [ -f "$T/repo/my notes.txt" ] || fail "the space-named file did not land in the main worktree"

  # Case 11 — CLAUDE_PROJECT_DIR pointing at a bare repo (no working tree)
  # dies with a clear message (regression: this used to leak raw git stderr
  # and silently skip the main-worktree guard instead of refusing cleanly).
  git init -q --bare "$T/bare.git"
  OUT=$(CLAUDE_PROJECT_DIR="$T/bare.git" "$0" "$T/wt-space" "msg" "my notes.txt" 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "a bare-repo CLAUDE_PROJECT_DIR was not refused"
  printf '%s' "$OUT" | grep -qi 'working tree' || fail "expected a 'no working tree' message for a bare repo"

  printf 'self-test OK — blind-add-rejected, not-main-worktree, main-as-target, missing-worktree, empty-diff, leftover-file, non-fast-forward, detached-main-HEAD, happy-path, space-in-filename, bare-repo\n'
  exit 0
fi

# --- normal invocation ---------------------------------------------------
WTPATH="${1:-}"
MESSAGE="${2:-}"
[ -n "$WTPATH" ] && [ -n "$MESSAGE" ] \
  || die "usage: integrate-worktree.sh <worktree-path> <commit-message> <file>..."
shift 2
FILES=("$@")
[ "${#FILES[@]}" -gt 0 ] || die "no files named — refusing to stage nothing (never git add -A/./:)"

# Reject blind-add forms outright (I6) — never let one of these reach
# `git add` even if a caller passes it as a "file".
for f in "${FILES[@]}"; do
  case "$f" in
    .|:|:/|-A|--all|'*')
      die "refusing to stage '$f' — named files must be explicit paths, never a blind-add form (never git add -A/./:)" ;;
  esac
done

REPO="${CLAUDE_PROJECT_DIR:-$ROOT}"
GITDIR="$(git -C "$REPO" rev-parse --path-format=absolute --git-dir 2>/dev/null)" \
  || die "$REPO is not a git repository"
COMMONDIR="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || die "$REPO is not a git repository"
[ "$GITDIR" = "$COMMONDIR" ] \
  || die "$REPO is not the main worktree — its git-dir is a linked worktree's, not the shared repository's common git-dir. Run this from the main worktree, or point CLAUDE_PROJECT_DIR at it"
REPO_ABS="$(git -C "$REPO" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" \
  || die "$REPO has no working tree (bare repo?) — point CLAUDE_PROJECT_DIR at the main worktree"

# Resolve against what git actually has registered — never trust a path from
# an argument alone (X3).
ABS_WT="$(cd "$WTPATH" 2>/dev/null && pwd -P)" || die "worktree path does not exist: $WTPATH"
[ "$ABS_WT" != "$REPO_ABS" ] \
  || die "refusing to merge $ABS_WT into itself — it is the main worktree, not a linked worktree to merge back"
REGISTERED="$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')"
printf '%s\n' "$REGISTERED" | grep -qxF "$ABS_WT" \
  || die "not a registered worktree: $ABS_WT (looked in \`git worktree list\` for $REPO)"

# The branch to rebase onto is read from the MAIN worktree ($REPO), never the
# worktree being merged (I7) — see header note.
MAIN_BRANCH="$(git -C "$REPO" symbolic-ref --short -q HEAD)" \
  || die "main worktree ($REPO) is in detached HEAD — refusing to guess a branch to rebase onto"

WT_BRANCH="$(git -C "$ABS_WT" symbolic-ref --short -q HEAD)" \
  || die "worktree $ABS_WT is in detached HEAD — nothing to name as a branch to merge or delete"

# --- refuse if the worktree has changes OUTSIDE the named files (I6) ------
# Staging only the named files and leaving an unnamed leftover dirty would
# make the rebase below fail with "you have unstaged changes" — indistin-
# guishable, from the outside, from a real conflict. Catch it here instead,
# before any commit exists to half-finish a merge around.
#
# -z, NOT the default porcelain format: git quotes a path containing a space
# or non-ASCII byte (`"my notes.txt"`) in the default format, which then never
# matches the caller's unquoted argument and the check wrongly names an
# actually-named file as the leftover (found by critic review). -z gives raw,
# unquoted paths, NUL-terminated. A rename/copy record (status code R or C)
# carries an EXTRA NUL-terminated field — the new path — read explicitly below
# rather than left to bleed into the next record's status-code parse.
LEFTOVER=""
while IFS= read -r -d '' rec; do
  code="${rec:0:2}"
  p="${rec:3}"
  case "$code" in
    R?|C?) IFS= read -r -d '' p || true ;;
  esac
  [ -n "$p" ] || continue
  MATCH=0
  for f in "${FILES[@]}"; do
    [ "$f" = "$p" ] && MATCH=1 && break
  done
  [ "$MATCH" -eq 0 ] && LEFTOVER="${LEFTOVER}${LEFTOVER:+, }$p"
done < <(git -C "$ABS_WT" status --porcelain -z --untracked-files=all)
[ -z "$LEFTOVER" ] \
  || die "worktree has uncommitted changes outside the named files: $LEFTOVER — resolve by hand first; refusing before any commit rather than letting the rebase misreport this as a conflict"

# --- stage, named files only (I6) -----------------------------------------
git -C "$ABS_WT" add -- "${FILES[@]}" || die "git add failed for: ${FILES[*]}"

if git -C "$ABS_WT" diff --cached --quiet; then
  die "empty diff after staging ${FILES[*]} — nothing to commit, refusing to no-op past it"
fi

git -C "$ABS_WT" commit -q -m "$MESSAGE" || die "commit failed in $ABS_WT"

# --- rebase onto the main worktree's branch (X2) --------------------------
REBASE_OUT="$(git -C "$ABS_WT" rebase "$MAIN_BRANCH" 2>&1)"
REBASE_RC=$?
if [ "$REBASE_RC" -ne 0 ]; then
  git -C "$ABS_WT" rebase --abort >/dev/null 2>&1
  die "rebase of $WT_BRANCH onto $MAIN_BRANCH failed — resolve by hand in $ABS_WT, never falling back to a three-way merge. git said: $REBASE_OUT"
fi

# --- fast-forward-only merge (X2) -----------------------------------------
MERGE_OUT="$(git -C "$REPO" merge --ff-only "$WT_BRANCH" 2>&1)"
MERGE_RC=$?
if [ "$MERGE_RC" -ne 0 ]; then
  if git -C "$REPO" merge-base --is-ancestor "$MAIN_BRANCH" "$WT_BRANCH" 2>/dev/null; then
    die "merge of $WT_BRANCH into $MAIN_BRANCH failed even though it would be a fast-forward (is the main worktree dirty?) — git said: $MERGE_OUT"
  else
    die "merge of $WT_BRANCH into $MAIN_BRANCH would not be a fast-forward — refusing to force it. git said: $MERGE_OUT"
  fi
fi

# --- remove the worktree, delete the branch --------------------------------
git -C "$REPO" worktree remove "$ABS_WT" \
  || die "worktree remove failed for $ABS_WT — resolve any leftover uncommitted changes by hand (scoped staging leaves anything not named)"
git -C "$REPO" branch -d "$WT_BRANCH" || die "branch delete failed for $WT_BRANCH"

printf 'integrate-worktree: merged %s into %s, removed worktree, deleted branch %s\n' \
  "$WT_BRANCH" "$MAIN_BRANCH" "$WT_BRANCH"
exit 0
