---
name: status
description: Show the current Supervisor state — open ledger items, active plan, recent lessons, working tree, and the routing health check. Use when resuming after a break, after a compaction, or when the user asks where things stand.
disable-model-invocation: false
allowed-tools: Read, Glob, Bash(git status:*), Bash(git log:*), Bash(ls:*)
---

Report the state in one screen. No action. No code.

## Gather

```!
echo "--- tree ---"; git status --short 2>/dev/null | head -20
echo "--- last 5 commits ---"; git log --oneline -5 2>/dev/null
echo "--- scratch ---"; ls -1 scratch 2>/dev/null | head -10
```

Then read `docs/LEDGER.md`, the newest 10 lines of
`docs/LESSONS.md`, and any plan with `status: active`.

## Report

```
## Ledger — <topic>
- open: N   verified: N   deferred: N
- next open item: …
## Active plan
- NNN-slug · status · task X of Y
## Tree
- clean | N files uncommitted (list them)
## Scratch
- N files (stale scratch means an unclosed task)
## Routing health
- Supervisor share estimate, and any task that leaked keystrokes upward
## Recommended next move
- one line
```

If the ledger has open items and the tree is clean, the next move is dispatch.
If the tree is dirty and the ledger is closed, the next move is `review`.
