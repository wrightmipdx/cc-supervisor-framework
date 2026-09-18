---
name: fable-commit
description: Pre-commit gate and commit choreography for Fable — checks green, message drafted via scribe, one verified increment committed. Use after every verified task.
allowed-tools: Read, Bash(git status:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*), Bash(git log:*)
---

One verified increment, one commit. Small diffs review well and revert well.

## Gate — all four

1. `git status` shows nothing in the tree you cannot explain.
2. The done-when checks pass, and you saw them pass (`fable-review`).
3. The critic pass is done where `fable-review` requires it.
4. The user is not holding commits mid-sequence.

If any gate fails, do not commit. Say which gate failed.

## Message

- `fable-scribe` drafts a Conventional Commit from the diff plus the brief:
  `type(scope): summary`, then why-lines.
- Types: `feat` `fix` `refactor` `test` `docs` `chore` `perf`.
- You check the message against the diff. It claims exactly what the diff does.
  Trim salesmanship.
- Debugging closes carry the one-sentence root cause in the body.

## Commit

- Stage only this increment's files. Never `git add -A` blindly.
- Commit. Confirm a clean tree. Update the ledger.

## Never

- Never commit a worker's tree you have not read.
- Never commit with a failing check "to be fixed next commit".
- Never bundle two briefs into one commit.
