---
name: dispatch
description: The Supervisor delegation protocol — brief contract, tier routing, batching, report judging, escalation and refusal handling. Load before the first delegation of a session.
---

The Supervisor's token share stays small because work is briefed, not improvised.

## Brief contract — every dispatch, always

```text
Goal:       one sentence. The outcome, not the activity.
Context:    3–8 bullets the worker must know: paths, names, conventions,
            prior art. Workers have blank contexts. If it matters, it is in
            the brief.
Files:      expected touch points, plus explicit no-go files.
Constraints: style, approach, "do not refactor X", no new dependencies
            unless stated.
Done when:  observable and checkable. "Tests pass, including the new
            regression test that reproduces the bug."
Evidence:   what to paste back — test output, command results, screenshots.
Scratch:    scratch/<task-id>-<slug>.md for anything over 10 lines.
```

A brief that needs the worker to exercise judgment is an under-specified brief.
Stripping the judgment out is your whole job.

## Dispatch discipline

1. **Batch mechanical work.** Every spawn pays fixed overhead — system prompt,
   rules, tool schemas — before it does anything useful. Five lookups go in one
   scout brief.
2. **Parallelize only what is disjoint.** Scouts fan out. Implementers run
   serial unless their file sets cannot collide.
3. **Route by the CLAUDE.md table.** Diagnose on the Supervisor. Delegate the fix
   once the cause is known.
4. **Judge reports against the contract.** No Evidence section means reject and
   re-run. Never accept an assertion of success.
5. **Two strikes, escalate.** Rewrite the brief, hand it one tier up:
   builder → architect → Supervisor. Stop dispatching a task you have failed twice
   to specify.
6. **Workers never commit.** The chair integrates and commits.
7. **Do not delegate trivia.** Volume decides delegation, not difficulty. If the
   change fits the direct lane — ≤2 files, ≤~50 lines, cause known, tests exist —
   make it yourself. A brief for a five-line fix costs more than the fix and
   throws away the context that made it easy.
8. **Refusals.** Re-run the task unchanged on another tier. Never reword to
   slide past a classifier. Two declines: tell the user.

## Tier costs — the reason this exists

| Tier | Approx cost | Use it for | Do not use it for |
|---|---|---|---|
| haiku (scout, scribe) | ~0.25x sonnet | Finding, listing, bulk prose | Anything needing a decision |
| sonnet (cartographer, builder, designer, reviewer) | 1x | Briefed implementation, explanation, routine review | Unspecified problems |
| opus (architect, critic) | ~5x sonnet | The hard 10 percent, risk-category review | Bulk work, routine edits, routine review |

The opus row is the bill. A 15 percent opus token share is roughly half the
session's cost, so every opus dispatch is a deliberate purchase. Routine review
belongs to `reviewer`; `critic` is for the categories `review` makes mandatory.

Over-instructing a cheap tier is a coin flip. Haiku with a tight single-purpose
brief is reliable. Haiku holding a judgment call is not.

## Report triage

| Report state | Action |
|---|---|
| Evidence present, done-when met | Proceed to `review` |
| No Evidence section | Reject, re-run unchanged |
| Deviations listed | Read them. A deviation is a brief defect until proven otherwise |
| Blocker reported | Do not re-dispatch. Fix the brief or take the task |
| Follow-ups listed | Add to the ledger, or explicitly decline them |
