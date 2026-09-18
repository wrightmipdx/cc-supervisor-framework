---
name: fable-review
description: Verification of a worker's close — the chair reads the diff and runs the checks, then a fresh-eyes critic pass on non-trivial changes. Use before every commit of substance.
allowed-tools: Read, Glob, Grep, Bash(git diff:*), Bash(git status:*), Bash(git show:*)
---

Fresh eyes on every close. Workers are confident, not correct.

## 1. Verify yourself — always

- Run `git diff` and `git status`. The change matches the brief: the whole
  brief, and nothing but the brief. No stray files.
- Run the done-when checks yourself. Output you saw with your own eyes, or it
  did not happen.
- A worker's pasted output is a claim. Your own run is evidence.

## 2. Fresh-eyes critic — non-trivial closes

Dispatch `fable-critic` with the diff and the brief it was built from. Nothing
else. The critic never sees the authoring conversation or a previous round.

Mandatory for:

- security, auth, money, data loss, public API contracts
- new modules
- concurrency
- more than roughly 50 changed lines
- anything you are not sure of

## 3. Fix loop

- BLOCK or FIX FIRST: send the findings verbatim back to the implementing
  worker. Do not paraphrase. Re-verify. Run a fresh critic pass each round.
- Maximum two loops. Then the chair takes the fix.
- Nits: batch them. Fix inline or via scribe. Never loop on a nit.

## 4. Reconcile

- Mark the ledger item `[x]` only now. Verified, not asserted.
- Record the verdict and any residual risk in the plan's task entry.

## For UI closes

Add the screenshot diff from `fable-ui` step 4. Tests passing is necessary. It
is not sufficient. The built screen either matches the mockup or it does not.
