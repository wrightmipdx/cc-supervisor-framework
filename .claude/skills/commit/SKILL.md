---
name: commit
description: Pre-commit gate and commit choreography for the Supervisor — checks green, message written from the diff you just read, one verified increment committed. Use after every verified task.
allowed-tools: Read, Bash(git status:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*), Bash(git log:*)
---

One verified increment, one commit. Small diffs review well and revert well.

## Gate — all five

1. `git status` shows nothing in the tree you cannot explain.
2. The done-when checks pass, and you saw them pass (`review`).
3. The review pass is done in the lane `review` requires.
4. The user is not holding commits mid-sequence.
5. Every `AC-n` this increment claims has a PASS in the acceptance record, or
   is named there as not demonstrable by run with its substitute evidence
   (`accept`). **Unless `ACCEPT_GATE=off`** — then there are four gates, not a
   fifth that is permanently waved through. A gate nobody can fail is worse
   than no gate: it reads as an answer.

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

## Size — advisory, never a gate

Roughly **400 source lines**, excluding tests and fixtures. That is a planning
signal, not a limit: the direct lane has a precise bound of two files and fifty
lines, and `commit` had none at all, so increments drifted — six commits in the
reference session ran 1,100 to 1,718 insertions each.

It is not enforced and must not be. A test-heavy commit legitimately runs long,
and blocking on a line count would punish exactly the work this framework wants
more of. The hook logs the real number and `metrics.sh` prints the distribution,
which is the measured route this framework prefers over an asserted constant.

Over the bound: commit anyway, and say why at retro. Twice in a session means
the briefs are too large, which is a `plan` problem rather than a `commit` one.

## Commit

- Stage only this increment's files by path. The commit gate hook blocks blind
  staging; if it fires, you were about to commit someone else's work too.
- Commit. Confirm a clean tree. Update the ledger.

## Never

- Never commit a worker's tree you have not read.
- Never commit with a failing check "to be fixed next commit".
- Never bundle two briefs into one commit.
