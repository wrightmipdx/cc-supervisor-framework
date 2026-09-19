---
name: intake
description: Session-start and new-request ritual for the Supervisor. Restores context (lessons, ledger, active plans), restates the goal, resolves ambiguity, and picks the working lane. Use at the start of a session or whenever a new request arrives.
argument-hint: [the request, optional]
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(git log:*)
---

Run this at session start and whenever a new request arrives.

## 1. Restore context

- Read `docs/LESSONS.md` and any `docs/LEDGER*.md`.
- Open ledger items are unfinished work. Surface them.
- The SessionStart hook may have injected this already. If so, do not re-read.

## 2. Check for an active plan

Look in `docs/plans/` for a file with `status: active`. If one exists,
summarize its progress and ask: continue, or new work?

## 3. Restate the request

Two to five sentences: what is asked, what done looks like, what constraints
were stated. Show this to the user before you do anything else.

## 4. Resolve ambiguity now

Repo, environment, success definition, who the change is for. Ask now. Never
after scouting.

Ask one more, in the sponsor's own words: **how will you know this worked?**
Not "what should it do" — how would you, personally, be able to tell. The
answer is the seed of the `AC-n` acceptance criteria `plan` writes and `accept`
demonstrates, and it is the one thing you cannot derive from the code. Push for
the negative case too: what would tell you it is broken.

## 5. Pick the lane

| The request is | Lane |
|---|---|
| Trivial, a one-sentence diff | Do it inline, then `commit` |
| Small and known — ≤2 files, ≤~50 lines, cause understood, tests already exist | **Direct lane** (below) |
| A single well-specified task, larger than that | Light scout pass → brief → dispatch |
| A feature or multi-step change | `plan` |
| A failure with an unknown cause | `debug` |
| UI work with a mockup involved | `ui` |

## The direct lane

Most real work is small. Briefing a small change costs more than making it, and
it discards the context that made it easy. So: edit inline, run the checks, read
your own diff, commit. No ledger, no brief, no review dispatch.

The lane has a bound, and the bound is the whole point:

- ≤ 2 files and ≤ ~50 lines changed
- you already know the cause — you are not exploring
- the tests that cover it already exist
- it is not in a review risk category (security, auth, money, data loss, public
  API, concurrency, a new module). Those close through `review` no matter how
  small the diff

**If the change grows past the bound mid-flight, stop.** Do not finish it on
momentum. Revert or park what you have, and re-enter through `plan` or a brief.
A direct-lane change that quietly became a feature is the most common way this
framework fails.

## Hard rule

No code during intake, except a change you have already placed in the direct
lane. Exploration is never code.

If the lane you picked is `plan` or `debug`, `EnterPlanMode` now and let the
harness hold that rule for you.
