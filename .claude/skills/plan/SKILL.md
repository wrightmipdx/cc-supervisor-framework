---
name: plan
description: Explores, then writes an implementation plan with success criteria, a requirements ledger, and pre-drafted task briefs. Use before any multi-task change and before touching unfamiliar code.
argument-hint: [goal]
---

Explore, design, then write it down. No code until the plan exists.

## 0. Enter plan mode

`EnterPlanMode` before you explore. The harness then refuses edits until you
call `ExitPlanMode`, which also puts the plan in front of the user for approval.

This is belt and braces with step 4, and worth it: "no code during planning" is
the rule most easily lost when a fix looks obvious mid-exploration, and
willpower is a weaker mechanism than a tool that refuses. Exploration is
read-only by nature, so the mode costs you nothing until it saves you.

If your version does not offer plan mode, step 4 still gates the dispatch —
you are just enforcing it yourself.

## 1. Explore — keep the Supervisor's context clean

- ONE batched scout brief carrying every lookup: seams, conventions, prior art,
  existing utilities. Five greps are one brief, not five scouts.
- One cartographer pass if the subsystem is unfamiliar.
- You keep the summaries. Bulk goes to `scratch/`.

## 2. Design — Supervisor work

- Choose the approach yourself.
- If the change is architecturally significant (new subsystem, breaking change,
  cross-cutting concern), get a short design note from `architect` first,
  then decide. The note informs you. It does not decide for you.
- Write down what you are NOT doing.

## 3. Write it down

- Requirements become checkboxes in `docs/LEDGER.md`. One ledger per
  topic. Archive by renaming to `LEDGER-<topic>-archive.md`.
- The ledger holds explicit requirements, implicit requirements, and edge cases.
  If the user said it, it is a line. If the code demands it, it is a line.
- Copy `docs/plans/000-template.md` to
  `docs/plans/NNN-slug.md`.
- Every task names its worker tier, its review lane (`direct`, `reviewer`, or
  `critic` — see `review`), and carries a pre-drafted brief. Choosing the review
  lane at plan time, when you can see the risk, stops it being chosen by reflex
  at close time, when opus looks like the safe default.
- A task you cannot brief yet is too vague. Split it or sharpen it until you
  can.

## 4. Confirm

Show the user: goal, success criteria, tasks with their tiers and review lanes,
and the scope cuts. `ExitPlanMode` carries this to them for approval. Get a go
before any dispatch. Flip `status` to `active` on approval.

## Anti-patterns

- A plan with one task. That is a brief, not a plan. Dispatch it.
- Success criteria that describe activity ("refactor the module") instead of an
  observable outcome ("`npm test` passes, including the new regression test").
- Planning without a ledger. The plan is the route. The ledger is the contract.
