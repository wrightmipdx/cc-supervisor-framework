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
            the brief — or in a skill preloaded via the agent's `skills:` key,
            which is where a convention you keep retyping into every brief
            belongs.
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

1. **Batch mechanical work, but fan out past three.** Every spawn pays fixed
   overhead — system prompt, rules, tool schemas — before it does anything
   useful, so related lookups belong together. Up to three in one scout brief.
   Beyond that, fan out parallel single-topic scouts instead: measured in one
   session, a five-topic scout brief produced nothing in 30 turns while four
   single-topic scouts finished in about 15 turns each. Parallel haiku scouts
   are the cheapest thing in this framework; a scout that runs out of turns is
   the most expensive, because it returns nothing at all.
2. **Parallelize what cannot collide — and isolate what would.** Scouts fan out
   freely; they only read. Implementers collide in the working tree, so either
   prove their file sets are disjoint, or give each one `isolation: "worktree"`
   on the Agent call. That puts the worker in its own git worktree, which makes
   parallel implementation safe by construction instead of by your bookkeeping.
   Serializing implementers is the fallback, not the rule.

   The cost of a worktree is integration: you merge each branch yourself, and
   you review each diff separately. Two workers in worktrees editing the same
   module is a planning failure that surfaces late — split by module, not by
   convenience.
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

## Merging a worktree dispatch back

The Agent call with `isolation: "worktree"` hands back a path and a branch —
or neither, if the worker made no changes (it is auto-cleaned; there is
nothing to merge or remove). What follows is the rest of the lifecycle rule 2
starts.

1. **Review it exactly like any other worker's tree.** `git -C <path> diff
   <base>...HEAD` before touching anything else. A worktree does not skip
   `review` — "never commit a worker's tree you have not read"
   (`commit/SKILL.md`) applies unchanged.
2. **Merge from the main worktree, fast-forward when you can.** `git merge
   --ff-only <branch>`. Fall back to `--no-ff` only when a fast-forward is
   impossible, and say why in the commit message.
3. **Remove the worktree and the branch in the same step as the merge, in
   that order.** `git worktree remove <path>` before `git branch -d
   <branch>` — a branch checked out in a worktree cannot be deleted, so
   removing the worktree first is not stylistic. A merged worktree left on
   disk is a dangling reference nothing else here checks for.
4. **Two workers whose file sets turned out to collide anyway** — the planning
   failure rule 2 names — merge one at a time and resolve the conflict
   yourself. Never take the second branch over the first without reading both.
5. **Abandoned, twice-failed, or superseded** (see "Two strikes, escalate"):
   remove the worktree and branch the same way as a merge. A worktree is
   scratch space, not a place to leave unresolved work sitting.

**The convention `worktrees.sh` and `status` key on:** the Supervisor itself
never works from a secondary worktree — only an isolated dispatch creates one.
So any worktree in this repo besides the primary one *is* an open dispatch, by
construction, with no naming scheme to maintain or drift out of sync.

## Tier costs — the reason this exists

| Tier | Approx cost | Use it for | Do not use it for |
|---|---|---|---|
| haiku (scout, scribe) | ~0.25x sonnet | Finding, listing, bulk prose | Anything needing a decision |
| sonnet (cartographer, builder, designer, reviewer, acceptor) | 1x | Briefed implementation, explanation, routine review | Unspecified problems |
| opus (architect, critic) | ~5x sonnet | The hard 10 percent, risk-category review | Bulk work, routine edits, routine review |

The opus row is the bill. At the 14/71/15 token split `docs/kit/ROUTING.md` derives
from, that 14 percent on opus is roughly half the session's cost — so every opus
dispatch is a deliberate purchase. Routine review belongs to `reviewer`;
`critic` is for the categories `review` makes mandatory.

The ~25 percent ceiling in `CLAUDE.md` is a goal, not a gate. `metrics.sh`
prints what each opus dispatch found, and a critic that returns SHIP with no
blockers on a routine close is the signal to use `reviewer` next time. Judge the
spend against what it bought.

Over-instructing a cheap tier is a coin flip. Haiku with a tight single-purpose
brief is reliable. Haiku holding a judgment call is not.

## Resumes

Budget **one** resume per dispatch. A worker that lands the plane and reports
partial work can be resumed once to finish it.

A second resume means the brief was too large, not that the worker was slow.
Split it and re-dispatch as two briefs.

`metrics.sh` is where this shows up across a session, in two places: dispatches
against completions, and a run's **turn count** next to its cost. A run that
overran its agent's `maxTurns`, or that carried a large share of the session's
"spend past turn 30", was a brief that should have been two.

## Report triage

| Report state | Action |
|---|---|
| Evidence present, done-when met | Proceed to `review` |
| No Evidence section | Reject, re-run unchanged |
| Deviations listed | Read them. A deviation is a brief defect until proven otherwise |
| Blocker reported | Do not re-dispatch. Fix the brief or take the task |
| Follow-ups listed | Add to the ledger, or explicitly decline them |
