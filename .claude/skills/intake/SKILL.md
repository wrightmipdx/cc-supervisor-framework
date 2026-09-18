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

## 5. Pick the lane

| The request is | Lane |
|---|---|
| Trivial, a one-sentence diff | Do it inline, then `commit` |
| A single well-specified task | Light scout pass → brief → dispatch |
| A feature or multi-step change | `plan` |
| A failure with an unknown cause | `debug` |
| UI work with a mockup involved | `ui` |

## Hard rule

No code during intake. None.
