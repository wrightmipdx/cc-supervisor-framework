#!/usr/bin/env bash
# List worktrees left open by an isolated dispatch, so status and
# install-check.sh can see what a `git status` in the main worktree cannot.
#
#   .claude/scripts/worktrees.sh              # open worktree dispatches
#   .claude/scripts/worktrees.sh --self-test  # hermetic self-test
#
# UNLIKE A HOOK, THIS FAILS LOUDLY. This runs because a human (or `status`)
# asked it to, and a silent empty report is worse than an error — it reads as
# "nothing open" when it means "I could not tell".
#
# THE CONVENTION THIS SCRIPT DEPENDS ON (dispatch/SKILL.md "Merging a worktree
# dispatch back"): the Supervisor never works from a secondary worktree — only
# an `isolation: "worktree"` dispatch creates one. So `git worktree list`'s
# first entry is always the primary worktree this repo runs from, and every
# entry after it IS an open dispatch, by construction. There is no branch- or
# path-naming scheme to key on instead, because the Agent tool that creates
# these worktrees, not this framework, names them.
#
# A CLEAN WORKTREE WITH NO COMMITS AHEAD OF HEAD IS GENUINELY AMBIGUOUS: git
# cannot tell "this was merged --ff-only and never removed" from "this was
# just created and the worker hasn't done anything yet" — a fast-forward
# leaves no trace that distinguishes them. Reporting the first case as a
# confident "MERGED, safe to remove" would, in the second case, tell the
# Supervisor to delete a live worker's workspace out from under it. So this
# never claims more than the data supports: both read as "nothing to merge",
# advisory, not a verdict — never a claim this script cannot stand behind.
#
# Detection only. This never runs `git merge`, `git worktree remove`, or
# `git branch -d` — dispatch/SKILL.md's merge-back steps do that by hand, on
# purpose, so a merge is never unattended.
#
# Dependency: git. No jq — this parses `git worktree list --porcelain` only.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

die() { printf 'worktrees: %s\n' "$1" >&2; exit 1; }

if [ "${1:-}" = "--self-test" ]; then
  T=$(mktemp -d) || die "cannot make a temp dir"
  trap 'rm -rf "$T"' EXIT

  # --- fixture: a real repo, real linked worktrees ----------------------------
  git init -q "$T/repo"
  git -C "$T/repo" config user.email test@example.com
  git -C "$T/repo" config user.name test
  echo one > "$T/repo/a.txt"
  git -C "$T/repo" add a.txt
  git -C "$T/repo" commit -qm 'first commit'

  fail() { printf 'self-test FAIL: %s\n' "$1" >&2; printf '%s\n' "${OUT:-}" >&2; exit 1; }

  # Case 1 — no dispatch open: only the primary worktree exists.
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" 2>&1) || fail "run exited non-zero on a clean repo"
  printf '%s' "$OUT" | grep -qi 'none' || fail "a repo with only the primary worktree should report none open"

  # Case 2 — one open dispatch: committed on its own branch, not yet merged.
  git -C "$T/repo" worktree add -q -b dispatch-a "$T/wt-a" >/dev/null
  echo two > "$T/wt-a/b.txt"
  git -C "$T/wt-a" add b.txt
  git -C "$T/wt-a" commit -qm 'worker change'
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" 2>&1) || fail "run exited non-zero with one open worktree"
  printf '%s' "$OUT" | grep -q "$T/wt-a" || fail "the open worktree's path was not listed"
  printf '%s' "$OUT" | grep -q 'dispatch-a' || fail "the open worktree's branch was not listed"
  printf '%s' "$OUT" | grep -qi 'not yet merged' || fail "an unmerged, committed worktree should report as not yet merged"

  # Case 3 — THE BLOCKER A CRITIC PASS CAUGHT: a worktree whose branch has no
  # commits of its own yet is trivially "an ancestor of HEAD", the same signal
  # a genuinely merged branch gives. Reporting this as a confident "MERGED,
  # safe to remove" would tell the Supervisor to delete a worker that simply
  # has not started — never a dirty check away from being wrongly torn down.
  git -C "$T/repo" worktree add -q -b dispatch-fresh "$T/wt-fresh" >/dev/null
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" 2>&1) || fail "run exited non-zero with a fresh, commit-less worktree"
  printf '%s' "$OUT" | grep -q 'dispatch-fresh' || fail "the fresh worktree's branch was not listed"
  printf '%s' "$OUT" | grep -qi 'no commits ahead of HEAD' || fail "a fresh, commit-less worktree must not be reported as MERGED — it may just not have started"
  printf '%s' "$OUT" | grep -q 'MERGED —' && fail "a fresh, commit-less worktree was reported as a confident MERGED leftover — this is the exact false positive a critic pass found"

  # Case 4 — a real leftover: the branch WAS merged, but the worktree and
  # branch were never removed. Git cannot tell this apart from case 3 after a
  # fast-forward (see header) — same wording, same "confirm before removing"
  # framing, on purpose. That is the honest answer, not a weaker one.
  git -C "$T/repo" merge -q --ff-only dispatch-a
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" 2>&1) || fail "run exited non-zero on a merged-but-not-removed worktree"
  printf '%s' "$OUT" | grep -qi 'no commits ahead of HEAD' || fail "a merged, un-removed worktree should report nothing-to-merge, same as case 3"

  # Case 5 — dirty: uncommitted changes, distinct from "nothing to merge".
  # Dirty must win even though this branch is also commit-less-ahead, for the
  # same reason as case 3 — an in-progress worker is never a removal target.
  git -C "$T/repo" worktree add -q -b dispatch-b "$T/wt-b" >/dev/null
  echo three > "$T/wt-b/c.txt"
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" 2>&1) || fail "run exited non-zero with a dirty worktree"
  printf '%s' "$OUT" | grep -q 'dispatch-b' || fail "the dirty worktree's branch was not listed"
  printf '%s' "$OUT" | grep -qi 'uncommitted' || fail "a dirty worktree should report uncommitted changes, not just unmerged"

  # Case 6 — THE SECOND BLOCKER: a worktree whose directory is gone (removed
  # by hand, or the process that made it died) but git has not pruned it yet.
  # `git worktree list` still lists it; `git -C <gone path>` fails loudly.
  # Before the fix this leaked a raw `fatal:` line and printed a phantom
  # "committed, not yet merged" entry — exactly the report AC-4 forbids.
  git -C "$T/repo" worktree add -q -b dispatch-c "$T/wt-c" >/dev/null
  rm -rf "$T/wt-c"
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" 2>&1) || fail "run exited non-zero with a stale (directory-gone) worktree"
  printf '%s' "$OUT" | grep -qi 'stale' || fail "a worktree whose directory is gone should be reported as stale, not silently skipped"
  printf '%s' "$OUT" | grep -q 'fatal:' && fail "git's raw stderr leaked into the report for a stale worktree"
  printf '%s' "$OUT" | grep -qi 'not yet merged.*wt-c\|wt-c.*not yet merged' && fail "a stale worktree must not be reported as a real open dispatch"

  # Case 7 — detached HEAD, ahead of nothing: before the fix, a detached
  # worktree always read as "not yet merged" regardless of whether it had
  # actually diverged, because the merged check only ran for named branches.
  git -C "$T/repo" worktree add -q --detach "$T/wt-d" >/dev/null
  OUT=$(CLAUDE_PROJECT_DIR="$T/repo" "$0" 2>&1) || fail "run exited non-zero with a detached-HEAD worktree"
  printf '%s' "$OUT" | grep -q "$T/wt-d" || fail "the detached worktree's path was not listed"
  printf '%s' "$OUT" | grep -qi 'no commits ahead of HEAD' || fail "a detached worktree with nothing ahead of HEAD must not default to 'not yet merged'"

  # Totals: 4 genuinely open (wt-a, wt-fresh, wt-b, wt-d) plus 1 stale
  # (wt-c) — stale must not inflate "total open".
  printf '%s' "$OUT" | grep -qE '^   total open: 4$' \
    || fail "total open should count the 4 real entries and exclude the 1 stale one"
  printf '%s' "$OUT" | grep -qi 'stale.*: 1' || fail "the stale count should be reported separately, not folded into total open"

  printf 'self-test OK — none, unmerged, fresh-no-commits, merged-leftover, uncommitted, stale, detached\n'
  exit 0
fi

# --- report -------------------------------------------------------------------
REPO="${CLAUDE_PROJECT_DIR:-$ROOT}"
[ -d "$REPO" ] || die "not a directory: $REPO"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$REPO is not a git repository"

LIST="$(git -C "$REPO" worktree list --porcelain)"
# The porcelain format is entries separated by a blank line, each a run of
# `key value` lines. The FIRST entry is the primary worktree by construction
# (see header) — every entry after it is an open dispatch.
PATHS="$(printf '%s\n' "$LIST" | awk '/^worktree /{print substr($0,10)}')"
N_TOTAL=$(printf '%s\n' "$PATHS" | grep -c .)

printf '## Open worktree dispatches\n'
if [ "$N_TOTAL" -le 1 ]; then
  printf '   none — only the primary worktree exists\n'
  exit 0
fi

N_OPEN=0
N_STALE=0
FAILED=0
# Process substitution, not a trailing pipe: a pipe runs this loop in a
# subshell, and N_OPEN/N_STALE/FAILED would silently not survive it. This form
# keeps the loop in the current shell so the counts are real.
while IFS= read -r WTPATH; do
  [ -n "$WTPATH" ] || continue

  # A worktree whose directory is gone but not yet pruned: `git -C` on it
  # fails loudly, and treating it as a live entry is exactly the phantom
  # report a critic pass caught. Report it as stale and move on — never run
  # another git command against a path that does not exist.
  if [ ! -d "$WTPATH" ]; then
    printf '   %s\n     stale — directory is gone but not pruned: git worktree prune\n' "$WTPATH"
    N_STALE=$((N_STALE + 1))
    continue
  fi

  BRANCH=$(git -C "$WTPATH" symbolic-ref --short -q HEAD 2>/dev/null) || BRANCH=""
  if [ -n "$BRANCH" ]; then
    LABEL="$BRANCH"
    MERGE_REF="$BRANCH"
  else
    REV=$(git -C "$WTPATH" rev-parse HEAD 2>/dev/null) || REV=""
    if [ -z "$REV" ]; then
      printf '   %s\n     UNAVAILABLE — could not read HEAD\n' "$WTPATH"
      FAILED=1
      continue
    fi
    LABEL="(detached at ${REV:0:8})"
    MERGE_REF="$REV"
  fi

  DIRTY=""
  [ -n "$(git -C "$WTPATH" status --porcelain 2>/dev/null)" ] && DIRTY=1

  # Commits on this ref that HEAD does not have. Zero means "nothing to
  # merge" — either genuinely merged already, or never started; git cannot
  # tell those apart after a fast-forward, and this never claims it can (see
  # header). Run against $REPO, not $WTPATH: worktrees share one object
  # database, and a raw SHA resolves the same from either.
  AHEAD=$(git -C "$REPO" rev-list --count HEAD.."$MERGE_REF" 2>/dev/null) || AHEAD=""

  printf '   %s (branch %s)\n' "$WTPATH" "$LABEL"
  N_OPEN=$((N_OPEN + 1))
  if [ -n "$DIRTY" ]; then
    printf '     uncommitted changes — the worker is still in progress, or stopped early\n'
  elif [ -z "$AHEAD" ]; then
    printf '     UNAVAILABLE — could not compare against HEAD\n'
    FAILED=1
  elif [ "$AHEAD" -gt 0 ]; then
    printf '     committed, not yet merged — review then merge (dispatch/SKILL.md)\n'
  elif [ -n "$BRANCH" ]; then
    printf '     no commits ahead of HEAD — nothing to merge (already merged, or never\n'
    printf '     started); confirm before removing: git worktree remove %s && git branch -d %s\n' \
      "$WTPATH" "$BRANCH"
  else
    printf '     no commits ahead of HEAD — nothing to merge (already merged, or never\n'
    printf '     started); confirm before removing: git worktree remove %s\n' "$WTPATH"
  fi
done < <(printf '%s\n' "$PATHS" | tail -n +2)

printf '   total open: %s\n' "$N_OPEN"
[ "$N_STALE" -gt 0 ] && printf '   stale, not pruned: %s\n' "$N_STALE"
[ "$FAILED" -eq 1 ] && exit 1
exit 0
