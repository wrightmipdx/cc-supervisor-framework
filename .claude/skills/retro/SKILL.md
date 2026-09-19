---
name: retro
description: Session close for the Supervisor — reconcile the ledger, run the success criteria, write lessons, check the opus spend, archive, and hand off cleanly. Use at the end of a session and when a plan finishes or is abandoned.
---

Close the session like an engineer.

## 1. Reconcile

- Run the plan's success criteria directly. The criteria themselves, not "the
  tests passed".
- Ledger: every item is `[x]` (verified) or `[~]` (deferred, with the user's
  approval noted). Anything still open gets an honest "remaining" note.
- Plan status: `done` when the criteria hold. `abandoned` with a one-line why
  if dropped. Never delete a plan. Future-you wants the map of what failed.

## 2. Lessons → `docs/LESSONS.md`

Newest first, maximum 5 per session. **One lesson is one bullet**, starting at
column 0. It may wrap — indent the continuation lines and the SessionStart hook
reassembles it whole. What it must not be is two bullets, because a lesson split
in half reaches the next session as two half-thoughts.

- surprises — "X depends on Y; touch Y and X breaks"
- process failures — "the brief omitted the migration step; builder blocked"
- corrected beliefs from intake

Prune stale lines. Never hoard. A lesson that no longer applies costs tokens in
every future session.

## 3. Handoff

- Update the active plan: tasks checked, plus a "Next steps" block written as
  the next session's opener.
- Everything verified is committed. The tree is clean, or explicitly WIP with a
  note saying why.
- One paragraph to the user: the goal, what shipped, what is open, the risks.

## 4. Hygiene

- Empty `scratch/`.
- Archive the ledger when the topic closes: rename to
  `LEDGER-<topic>-archive.md`.
- `LESSONS.md` over roughly 12 lessons: prune it now. The hook carries 12 and
  says how many it left behind; a file that always reports overflow has stopped
  being read.

## 5. Session report — run it, do not estimate it

```!
.claude/scripts/metrics.sh
```

The hooks wrote the event log during the session and the transcript wrote
itself; you wrote neither, and bookkeeping in the chair's context costs chair
tokens, which is the thing being measured.

Read the four blocks that carry a decision, and **say which way you land on each
one**. A number nobody judged is a number nobody will act on.

**1. Opus share of cost.** `CLAUDE.md` prime rule 2 governs the combined opus
share — Supervisor **plus** `architect` **plus** `critic`. The ~25% figure is a
goal, not a gate. Judge it against what the spend bought, which the last block
shows you directly.

**2. Worker spend past turn 30.** The largest lever the instrument has found,
and the one nothing else in the framework watches. A worker's context grows
through its run and every turn re-reads all of it, so late turns cost multiples
of early ones. A high number is an argument for a **tighter brief or a lower
`maxTurns`**, not for a cheaper model — a cheap model taking 90 turns is not a
saving. If a run overran its agent's `maxTurns`, say so: that is a brief that
was too large, and it is a lesson.

**3. What each run cost, next to what it returned.** This is the pairing the
framework exists to make. A `critic` that returned SHIP with no blockers on a
routine close is a **downgrade candidate** for next time. One that returned
BLOCK or FIX FIRST paid for its 5x, and you should say so out loud so the lane
does not get cut on cost alone. A run showing `no-handback` never reported: find
out whether it was resumed or lost.

**4. Chair share.** Main thread as a fraction of billable tokens. This is
`ROUTING.md`'s central claim under test — that the saving comes from context
isolation rather than from tiering. A chair share climbing session over session
means work is being done in the chair that should have been briefed out.

Add by hand the one thing the report cannot see: **any task where you typed a
long implementation instead of briefing it.**

Dollars are an estimate from a list-price table dated in the report's header.
Subscription accounting is not list price, so the **shares** are what carry a
decision, not the absolute figures. If that date is far behind you, the table
needs re-checking before any tiering decision rests on it.

`unjoined runs` in the report means the worker costs are real but their roles
are unknown — a log written before 0.4.0, or a version that stopped printing
`agentId` in the launch receipt. Do not guess which run was which.

Anything the report surfaces becomes next session's first lesson.
