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

Newest first, one line each, maximum 5 per session:

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
- `LESSONS.md` over roughly 40 lines: prune it now.

## 5. Cost check

Per-agent token attribution is not exposed to you. Do not estimate a split —
a guessed number in a governance loop is worse than no number. Report what is
countable:

- opus dispatches this session, by agent, and whether each was warranted:
  `architect` on genuinely hard work, `critic` on a mandatory risk category
- routine closes that went to `critic` when `reviewer` would have done
- any task where you typed a long implementation instead of briefing it

Session totals come from `/cost`. If you want a real split, export OTel metrics
— otherwise the counts above are the honest instrument.

Anything the counts surface becomes next session's first lesson.
