---
name: commit
description: Pre-commit gate and commit choreography for the Supervisor — checks green, message written from the diff you just read, one verified increment committed. Use after every verified task.
allowed-tools: Read, Bash(git status:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*), Bash(git log:*)
---

One verified increment, one commit. Small diffs review well and revert well.

## Gate — all four

1. `git status` shows nothing in the tree you cannot explain.
2. The done-when checks pass, and you saw them pass (`review`).
3. The review pass is done in the lane `review` requires.
4. The user is not holding commits mid-sequence.

If any gate fails, do not commit. Say which gate failed.

## Message

Write it yourself, inline. You just read the whole diff in `review` — you are
the cheapest source of an accurate message at this point, and delegating it
costs a spawn plus a re-read of a diff you already hold.

- Conventional Commits: `type(scope): summary`, then why-lines.
- Types: `feat` `fix` `refactor` `test` `docs` `chore` `perf`.
- The message claims exactly what the diff does. No salesmanship.
- Debugging closes carry the one-sentence root cause in the body.

Delegate to `scribe` only when the prose is genuinely bulky — a release
changelog spanning many commits, a README sweep. Not a single commit message.

## Commit

- Stage only this increment's files by path. The commit gate hook blocks blind
  staging; if it fires, you were about to commit someone else's work too.
- Commit. Confirm a clean tree. Update the ledger.

## Never

- Never commit a worker's tree you have not read.
- Never commit with a failing check "to be fixed next commit".
- Never bundle two briefs into one commit.
