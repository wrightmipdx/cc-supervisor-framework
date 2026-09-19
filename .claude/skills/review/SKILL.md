---
name: review
description: Verification of a worker's close — the Supervisor reads the diff and runs the checks, then a fresh-eyes review pass. Routine diffs go to reviewer (sonnet); risk-category diffs go to critic (opus). Use before every commit of substance.
allowed-tools: Read, Glob, Grep, Bash(git diff:*), Bash(git status:*), Bash(git show:*)
---

Fresh eyes on every close. Workers are confident, not correct.

## 1. Verify yourself — always

- Run `git diff` and `git status`. The change matches the brief: the whole
  brief, and nothing but the brief. No stray files.
- Run the done-when checks yourself. Output you saw with your own eyes, or it
  did not happen.
- A worker's pasted output is a claim. Your own run is evidence.
- **Keep the output small.** You are the most expensive context in the session
  and everything you read is re-billed on every later turn. Use quiet
  reporters and tail the result — `npm test -- --reporter=dot | tail -20`. You
  need the pass/fail lines, not the log.

## 2. Fresh eyes — every non-trivial close

The reviewer gets the diff and the brief it was built from. Nothing else. It
never sees the authoring conversation or a previous round.

Pick the lane by **risk, not by size**. A 300-line test fixture is routine; a
12-line auth change is not.

| Lane | When |
|---|---|
| None | The change went through the direct lane: ≤2 files, ≤~50 lines, cause known, tests already existed |
| `reviewer` (sonnet) | The default. Any other non-trivial close |
| `critic` (opus) | Mandatory for the risk categories below, and for anything you are genuinely unsure of |

**Critic is mandatory for:**

- security, auth, permissions, secrets
- money, billing, quotas
- data loss, migrations, destructive operations
- public API contracts and wire formats
- concurrency, locking, async ordering
- a new module or subsystem

If `reviewer` returns "Escalate to critic: yes", escalate. Do not overrule it.

Line count is not a trigger. Size tells you how long the review takes, not how
much it matters.

## 3. Fix loop

- BLOCK or FIX FIRST: send the findings verbatim back to the implementing
  worker. Do not paraphrase. Re-verify. Run a fresh review pass each round, in
  the same lane.
- Maximum two loops. Then the Supervisor takes the fix.
- Nits: batch them. Fix inline. Never loop on a nit.

## 4. Reconcile

- Mark the ledger item `[x]` only now — verified **and accepted**. Verified is
  this skill: the diff does what the brief said. Accepted is `accept`: the
  thing does what the sponsor asked, shown. A close that has only the first is
  not done, unless `ACCEPT_GATE=off`.
- Record the lane used, the verdict, the acceptance record's location, and any
  residual risk in the plan's task entry. The lane is part of the audit trail:
  a later session needs to know a close was reviewed on sonnet.

## 5. Then accept

`review` is the engineering check. `accept` is the sponsor's, and it runs next
— demonstrate the `AC-n` items this close claims before you commit. Skipped on
the direct lane and whenever `ACCEPT_GATE=off`.

A criterion that fails **after** a passing review is a spec defect, not a build
defect: the code did what the brief said and the brief was wrong. Do not send
it round the fix loop as though the worker erred.

## For UI closes

Add the screenshot diff from `ui` step 4. Tests passing is necessary. It
is not sufficient. The built screen either matches the mockup or it does not.
