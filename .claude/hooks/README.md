# Supervisor hooks

Instructions are advice. Hooks are mechanism. These fence the failure modes that
discipline alone does not survive.

| Hook | Event | Fences |
|---|---|---|
| `10-session-start.sh` | SessionStart | Context loss across sessions and compactions |
| `20-pre-delegate.sh` | PreToolUse `Agent\|Task` | Delegating without a ledger |
| `30-commit-gate.sh` | PreToolUse `Bash` | Blind staging; closing with open requirements |
| `50-stop-retro.sh` | Stop | Ending a session without a retro |
| `60-dispatch-end.sh` | SubagentStop, PostToolUse `Agent\|Task` | Nothing — it only measures |
| `70-commit-landed.sh` | PostToolUse `Bash` | Nothing — it only measures |

Shared code lives in `lib/`: `ledger.sh` parses requirement checkboxes,
`lessons.sh` reassembles wrapped lessons, `metrics.sh` writes the event log.
Every hook sources what it needs and exits 0 if the source fails.

## The event log

`10`, `20`, `30`, `60` and `70` append one JSON line per event to
`.metrics/session-<id>.jsonl`, which is gitignored.
`.claude/scripts/metrics.sh` reads it and `docs/METRICS.md` documents it. The
Supervisor never writes a metric: bookkeeping in the chair's context costs
chair tokens, which is the thing being measured.

**A test run is not a session.** Every suite that invokes a hook points
`METRICS_DIR` at a temp directory, so running the tests never appends fixture
events to the repo's real log. `install.sh` runs `install-check.sh`, which runs
the suites, so without that isolation installing the framework wrote about a
hundred fake events straight into the consumer's live data.

**Sizes, counts and verdicts only.** Never a brief, never a report, never a
diff. A test asserts that no brief or report text reaches the log.

**Attribution is stated, never guessed.** Hooks fire inside subagents too, which
is why the old edit-budget hook was removed. Every event carries an `origin`:

| origin | Meaning |
|---|---|
| `main` | Provably the main session — the source does not fire in a subagent, or no worker was in flight |
| `ambiguous` | A worker was in flight, so the Supervisor and the worker are indistinguishable here |
| `repo` | A fact about the repository, not any agent: HEAD moved |

`30-commit-gate.sh` runs on every Bash call including a worker's, so its
`commit_attempt` events are the ones that go `ambiguous`. If the dispatch-end
source does not fire in your version, the in-flight count never returns to zero
and everything after the first dispatch reads `ambiguous` — degraded, and
honestly so.

A `SubagentStop` that arrives with no worker in flight is dropped. This version
fires that event even when nothing was dispatched, and a phantom report poisons
the one metric with a target attached to it.

`60-dispatch-end.sh` is wired to two events on purpose. Which one a given Claude
Code version fires cannot be checked from a script, and `docs/INTENT.md` forbids
depending on a feature that cannot be verified at install time. Each event
records its `source`, and `metrics.sh` counts one source only, so wiring both
can never double count.

## Related

`.claude/install-check.sh` checks that every hook here is wired into
`settings.json`, executable, and syntactically valid, and runs the commit-gate
suite. Run it after an upgrade.

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
- `.claude/hooks/test-commit-gate.sh` covers that behavior — 26 cases: blind
  staging, the commands a heredoc must not hide, and the false positives that an
  earlier substring-matching version denied. Run it after touching the gate.
- The pre-delegate hook warns once per session, tracked by a flag file in
  `$TMPDIR` keyed on the session ID. It still logs every dispatch: logging
  happens before the early exits, not after them.
- The stop hook rate-limits rather than firing once. `Stop` runs at the end of
  every assistant turn, so a once-per-session flag delivered the nudge at the
  end of turn one and then went quiet for the close it was written for. It
  re-arms after `RETRO_NUDGE_SECONDS` (default 1800), and raises the wording
  from a reminder to a warning on the real signature of the failure: commits
  landed this session with the ledger not moved.
- There is deliberately no edit-budget hook. An earlier version counted
  Edit/Write calls to catch the Supervisor implementing solo, but hooks fire
  inside subagents too, so one builder tripped it unaided. A hook that fires on
  toast trains you to ignore hook output generally — which is expensive when the
  other four are load-bearing. The `status` and `retro` skills count opus
  dispatches instead, which is a number that means something.

## Tuning

- Docs location: `DOCS` in the `env` block of `settings.json`.
- Event log location: `METRICS_DIR`, default `.metrics`.
- Retro nudge interval: `RETRO_NUDGE_SECONDS`, default 1800.
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
