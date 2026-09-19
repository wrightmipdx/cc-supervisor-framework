---
name: status
description: Show the current Supervisor state — open ledger items, active plan, recent lessons, working tree, and the cost health check. Use when resuming after a break, after a compaction, or when the user asks where things stand.
disable-model-invocation: false
allowed-tools: Read, Glob, Bash(git status:*), Bash(git log:*), Bash(ls:*)
---

Report the state in one screen. No action. No code.

## Gather

```!
echo "--- tree ---"; git status --short 2>/dev/null | head -20
echo "--- last 5 commits ---"; git log --oneline -5 2>/dev/null
echo "--- scratch ---"; ls -1 scratch 2>/dev/null | head -10
echo "--- trace ---"; .claude/scripts/trace.sh 2>&1
echo "--- session ---"; .claude/scripts/metrics.sh 2>&1 | head -60
```

Then read every live ledger — `docs/LEDGER.md` and any `docs/LEDGER-*.md`
that is not `*-archive.md`, which is the set the hooks count — plus the newest
10 lines of `docs/LESSONS.md`, and any plan with `status: active`.

## Report

```
## Ledger — <topic>
- open: N   verified: N   deferred: N
- next open item: …
## Active plan
- NNN-slug · status · task X of Y
- tasks with no Review: lane — N (a task without one is not dispatchable)
- trace.sh findings: N (clean, or named — see commit/SKILL.md "The handoff"
  for what governs these at session close)
## Tree
- clean | N files uncommitted (list them)
## Scratch
- N files (stale scratch means an unclosed task)
## Cost health   (from metrics.sh, not from memory)
- opus share of session cost, against the ~25% goal
- worker spend past turn 30 — the turn-budget lever
- the costliest run so far, with its verdict
- any critic dispatch that was not in a mandatory risk category
- any task where the Supervisor typed a long implementation itself
## Recommended next move
- one line
```

If the ledger has open items and the tree is clean, the next move is dispatch.
If the tree is dirty and the ledger is closed, the next move is `review`.
