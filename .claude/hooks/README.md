# Supervisor hooks

Instructions are advice. Hooks are mechanism. These five fence the three
failure modes that discipline alone does not survive.

| Hook | Event | Fences |
|---|---|---|
| `10-session-start.sh` | SessionStart | Context loss across sessions and compactions |
| `20-pre-delegate.sh` | PreToolUse `Agent\|Task` | Delegating without a ledger |
| `30-commit-gate.sh` | PreToolUse `Bash` | Blind staging; closing with open requirements |
| `40-supervisor-budget.sh` | PostToolUse `Edit\|Write` | The Supervisor silently implementing solo |
| `50-stop-retro.sh` | Stop | Ending a session without a retro |

## Requirements

- `jq`. Install it with `brew install jq` or `apt install jq`.
- Every hook exits 0 and stays silent if `jq` is missing. A missing dependency
  never breaks a session.

## Behavior

- Only `30-commit-gate.sh` blocks, and only on blind staging. Its matching is
  token-based: it ignores heredoc bodies, strips quoted spans, inspects only
  segments that actually invoke git, and requires an exact token to call a
  staging target blind. An explicit path (`git add .gitignore`), a commit
  message quoting the phrase, or a grep for it all pass. Everything else injects
  context.
- `.claude/hooks/test-commit-gate.sh` covers that behavior — 22 cases, blind
  staging and the false positives that an earlier substring-matching version
  denied. Run it after touching the gate.
- The pre-delegate and stop hooks fire once per session, tracked by a flag file
  in `$TMPDIR` keyed on the session ID.
- `40-supervisor-budget.sh` counts edits from workers too, because hooks fire inside
  subagents. Treat the number as a smoke alarm, not an audit.

## Tuning

- Edit budget: change `EDIT_BUDGET` under `env` in
  `.claude/settings.json`.
- Docs location: change `DOCS` in the same place.
- Turn one off: delete its block from the `hooks` key in `settings.json`.
- Turn all off for one session: set `"disableAllHooks": true`.

## Testing a hook by hand

```bash
.claude/hooks/test-commit-gate.sh          # the whole suite
```

For a single case, feed it a payload on stdin and expect a
`permissionDecision: "deny"` JSON object on stdout:

```bash
jq -n '{session_id:"test",tool_name:"Bash",tool_input:{command:$ARGS.positional[0]}}' \
  --args 'git add --all' | .claude/hooks/30-commit-gate.sh
```

## Field-name note

Claude Code has used both `tool_name` and `tool` for the tool field across
versions. These hooks read `.tool_input.command`, which has been stable. If a
hook goes quiet after an upgrade, dump stdin to a file and check the field
names:

```bash
# temporary first line of any hook
cat > /tmp/hook-input.json && exec < /tmp/hook-input.json
```
