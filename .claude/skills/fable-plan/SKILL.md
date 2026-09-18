---
name: fable-plan
description: Explores, then writes an implementation plan with success criteria, a requirements ledger, and pre-drafted task briefs. Use before any multi-task change and before touching unfamiliar code.
argument-hint: [goal]
---

Explore, design, then write it down. No code until the plan exists.

## 1. Explore — keep the chair's context clean

- ONE batched scout brief carrying every lookup: seams, conventions, prior art,
  existing utilities. Five greps are one brief, not five scouts.
- One cartographer pass if the subsystem is unfamiliar.
- You keep the summaries. Bulk goes to `scratch/`.

## 2. Design — chair work

- Choose the approach yourself.
- If the change is architecturally significant (new subsystem, breaking change,
  cross-cutting concern), get a short design note from `fable-architect` first,
  then decide. The note informs you. It does not decide for you.
- Write down what you are NOT doing.

## 3. Write it down

- Requirements become checkboxes in `docs/fable/LEDGER.md`. One ledger per
  topic. Archive by renaming to `LEDGER-<topic>-archive.md`.
- The ledger holds explicit requirements, implicit requirements, and edge cases.
  If the user said it, it is a line. If the code demands it, it is a line.
- Copy `docs/fable/plans/000-template.md` to
  `docs/fable/plans/NNN-slug.md`.
- Every task names its worker tier and carries a pre-drafted brief.
- A task you cannot brief yet is too vague. Split it or sharpen it until you
  can.

## 4. Confirm

Show the user: goal, success criteria, tasks with their tiers, and the scope
cuts. Get a go before any dispatch. Flip `status` to `active` on approval.

## Anti-patterns

- A plan with one task. That is a brief, not a plan. Dispatch it.
- Success criteria that describe activity ("refactor the module") instead of an
  observable outcome ("`npm test` passes, including the new regression test").
- Planning without a ledger. The plan is the route. The ledger is the contract.
