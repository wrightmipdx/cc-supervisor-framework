# Fable hooks

Instructions are advice. Hooks are mechanism. These five fence the three
failure modes that discipline alone does not survive.

| Hook | Event | Fences |
|---|---|---|
| `10-session-start.sh` | SessionStart | Context loss across sessions and compactions |
| `20-pre-delegate.sh` | PreToolUse `Agent\|Task` | Delegating without a ledger |
| `30-commit-gate.sh` | PreToolUse `Bash` | Blind staging; closing with open requirements |
| `40-chair-budget.sh` | PostToolUse `Edit\|Write` | The chair silently implementing solo |
| `50-stop-retro.sh` | Stop | Ending a session without a retro |

## Requirements

- `jq`. Install it with `brew install jq` or `apt install jq`.
- Every hook exits 0 and stays silent if `jq` is missing. A missing dependency
  never breaks a session.

## Behavior

- Only `30-commit-gate.sh` blocks, and only on blind staging
  (`git add -A`, `git add .`, `git commit -a`). Everything else injects context.
- The pre-delegate and stop hooks fire once per session, tracked by a flag file
  in `$TMPDIR` keyed on the session ID.
- `40-chair-budget.sh` counts edits from workers too, because hooks fire inside
  subagents. Treat the number as a smoke alarm, not an audit.

## Tuning

- Edit budget: change `FABLE_CHAIR_EDIT_BUDGET` under `env` in
  `.claude/settings.json`.
- Docs location: change `FABLE_DOCS` in the same place.
- Turn one off: delete its block from the `hooks` key in `settings.json`.
- Turn all off for one session: set `"disableAllHooks": true`.

## Testing a hook by hand

```bash
echo '{"session_id":"test","tool_name":"Bash","tool_input":{"command":"git add -A"}}' \
  | .claude/hooks/30-commit-gate.sh
```

Expect a `permissionDecision: "deny"` JSON object on stdout.

## Field-name note

Claude Code has used both `tool_name` and `tool` for the tool field across
versions. These hooks read `.tool_input.command`, which has been stable. If a
hook goes quiet after an upgrade, dump stdin to a file and check the field
names:

```bash
# temporary first line of any hook
cat > /tmp/fable-hook-input.json && exec < /tmp/fable-hook-input.json
```
