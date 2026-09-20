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

- Scout briefs carry up to three related lookups each — seams, conventions,
  prior art, existing utilities. Past three, fan out parallel single-topic
  scouts rather than growing one brief; a scout that exhausts its turns returns
  nothing. See `dispatch` rule 1.
- One cartographer pass if the subsystem is unfamiliar.
- You keep the summaries. Bulk goes to `scratch/`.

## 2. Design — Supervisor work

- Choose the approach yourself.
- If the change is architecturally significant (new subsystem, breaking change,
  cross-cutting concern), get a short design note from `architect` first,
  then decide. The note informs you. It does not decide for you.
- Write down what you are NOT doing.

## 3. Write it down

- **Acceptance criteria first, before the ledger.** `AC-n` items in the
  sponsor's language: observable behavior an outsider could check, no commands.
  They are what `accept` demonstrates before commit, and a requirement with no
  acceptance criterion gets one or gets cut — if nobody can say what "working"
  looks like, nobody will be able to tell whether it does. Include the negative
  case wherever one exists.
- Requirements become checkboxes in `docs/kit/LEDGER.md`. One ledger per
  topic. Archive by renaming to `LEDGER-<topic>-archive.md`.
- The ledger holds explicit requirements, implicit requirements, and edge cases.
  If the user said it, it is a line. If the code demands it, it is a line.
- Copy `docs/plans/000-template.md` to
  `docs/plans/NNN-slug.md`.
- Every task names its worker tier, its review lane (`direct`, `reviewer`, or
  `critic` — see `review`), the `AC-n` items it demonstrates, and carries a
  pre-drafted brief. Choosing the review
  lane at plan time, when you can see the risk, stops it being chosen by reflex
  at close time, when opus looks like the safe default.
- **A task with no `Review:` lane is not dispatchable.** Not a convention — a
  gate. Across three real plans the field appeared zero times and every critic
  dispatch was decided at close time, which is how a routine diff ends up on
  opus. `status` reports any active-plan task that is missing one.
- A task you cannot brief yet is too vague. Split it or sharpen it until you
  can.

## 4. Confirm

Show the sponsor their own surface, in this order and contiguously:

1. the goal
2. the acceptance criteria
3. the scope cuts — what you are deliberately not doing
4. the risks, each with its tripwire
5. any decision you need from them before dispatch

Then the engineering, as detail below it: tasks, tiers, review lanes. That
order is the point. Leading with tiers and lanes asks the sponsor to approve
decisions in your column, and what comes back is a rubber stamp rather than a
review — see `CLAUDE.md`, **The chair and the sponsor**.

`ExitPlanMode` carries this to them for approval. Get a go before any dispatch.
Flip `status` to `active` on approval.

## Anti-patterns

- A plan with one task. That is a brief, not a plan. Dispatch it.
- Success criteria that describe activity ("refactor the module") instead of an
  observable outcome ("`npm test` passes, including the new regression test").
- Planning without a ledger. The plan is the route. The ledger is the contract.
