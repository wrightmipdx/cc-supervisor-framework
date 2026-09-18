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

## 5. Cost check

Run it, do not estimate it:

```!
.claude/scripts/metrics.sh
```

The hooks wrote that log during the session; you wrote nothing. Read the two
blocks that carry a decision:

- **Opus value.** Every opus dispatch with its verdict and blocker count. A
  `critic` that returned SHIP with no blockers on a routine close is a
  downgrade candidate for next time. One that returned BLOCK paid for its 5x.
  The ~25% ceiling in `CLAUDE.md` is a goal, not a gate — judge the spend
  against what it bought, and say which way you land.
- **Dispatch-to-report ratio.** A worker sent more often than it returned was
  resumed. One resume is budgeted; a second means the brief was too large.

Add by hand what the log cannot see: any task where you typed a long
implementation instead of briefing it.

Token cost per tier is NOT IMPLEMENTED — `metrics.sh --cost` says why, and
`docs/METRICS.md` holds the three routes and what each needs verified first. Do
not estimate a split. A guessed number in a governance loop is worse than no
number.

Anything the report surfaces becomes next session's first lesson.
