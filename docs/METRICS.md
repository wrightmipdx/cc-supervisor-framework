# Metrics

The framework governs a budget. Until now it had no instrument, so the rule that
matters most — keep Supervisor + `architect` + `critic` near or under ~25% of
session tokens — was enforced by feel.

This document covers the instrument that exists, and the one that does not yet.

The instrument is deliberately small. Every field maps to a rule in `CLAUDE.md`
or in a skill. A field supporting no rule is noise, and noise in a governance
loop is worse than an empty page.

## What gets written

Hooks append one JSON line per event to `.metrics/session-<session_id>.jsonl`,
which is gitignored. Nothing else writes. The Supervisor in particular does not:
bookkeeping in the chair's context costs chair tokens, which is the thing being
measured.

Read it with `.claude/scripts/metrics.sh`, which the `retro` and `status` skills
both call. Read it by hand with `jq` whenever you want something the script does
not print.

### Events

| Event | Written by | Carries |
|---|---|---|
| `session_start` | `10-session-start.sh` | HEAD, branch, ledger open/verified/deferred, lesson count |
| `dispatch` | `20-pre-delegate.sh` | agent, tier, task id, brief size in bytes |
| `dispatch_end` | `60-dispatch-end.sh` | agent, source, report size, has-evidence, verdict, findings by severity |
| `commit_attempt` | `30-commit-gate.sh` | staged files/insertions/deletions, commit type, ledger open |
| `commit_landed` | `70-commit-landed.sh` | HEAD, real files/insertions/deletions, commit type |
| `gate_block` | `30-commit-gate.sh` | which rule blocked: `blind_add` or `blind_commit` |

Every event also carries `event`, `ts`, `session` and `origin`.

**Sizes, counts and verdicts only.** Never a brief, never a report, never a
diff. `test-metrics.sh` asserts that no brief or report text reaches the log.

**Test runs never touch it.** The hook suites point `METRICS_DIR` at a temp
directory and assert they left the repo's log byte-for-byte as they found it. If
you see a `session-test.jsonl` in your `.metrics/`, it is residue from a version
before 0.3.2 and is safe to delete — as is any `session-nosession.jsonl`, which
comes from running a hook by hand with no session id.

### `origin`, and why some events refuse to name an agent

Hooks fire inside subagents as well as the main session. An earlier edit-budget
hook was removed from this framework for exactly that reason: a builder tripped
it unaided and the Supervisor was blamed. A number built on that kind of
confusion is worse than no number.

| `origin` | Meaning |
|---|---|
| `main` | Provably the main session. The source does not fire in a subagent, or no worker was in flight when it did |
| `ambiguous` | A worker was in flight. The Supervisor and the worker are indistinguishable here, and the event says so |
| `repo` | A fact about the repository rather than any agent: HEAD moved. Who ran the command is neither known nor interesting |

In-flight tracking is a counter incremented on `dispatch` and decremented on
`dispatch_end`. If your Claude Code version fires neither dispatch-end source,
the counter never returns to zero and every event after the first dispatch reads
`ambiguous`. That is degraded, and honestly so.

### `verdict` and `findings` — the value fields

`reviewer` and `critic` already contract for a report shaped:

```
## Verdict: BLOCK | FIX FIRST | SHIP
## Findings
- [blocker] file:line — issue — what would satisfy
```

So `60-dispatch-end.sh` reads a documented format rather than guessing at prose.
This is what makes the opus question answerable: a `critic` dispatch returning
SHIP with zero blockers on a routine close is a downgrade candidate, and one
returning BLOCK paid for its 5x several times over. **Count and verdict, never
the finding text.**

### The dispatch-end source

`60-dispatch-end.sh` is wired to both `SubagentStop` and `PostToolUse` on
`Agent|Task`, because which one a given Claude Code version fires cannot be
determined from a script and `docs/INTENT.md` forbids depending on a feature
that is not verifiable at install time.

Each event records the `source` it came from, and `metrics.sh` counts one source
only — preferring `post_tool_use`, whose payload carries the report. Wiring both
therefore cannot double count. `install-check.sh --probe` prints the one-line
`jq` that tells you which your version fires.

If neither fires, `metrics.sh` reports the ratio and the value report as
UNAVAILABLE rather than computing them from a missing event.

### There is no `session_end`

`Stop` fires at the end of **every** assistant turn, not at the end of a
session. An event written there would be stamped at the end of turn one with a
duration, a dirty-file count and a ledger count that were all wrong.

`metrics.sh` prints an **observed span** instead — first event to last, labelled
as exactly that.

## Token cost per tier — NOT IMPLEMENTED

Deferred by the user on 2026-09-18. This section is the round that follows, not
a description of anything that runs today. `metrics.sh --cost` exits non-zero
and points here rather than guessing.

Guessing is the thing to avoid. A fabricated split inside a budget rule is how
the rule stops meaning anything, which is the position this framework already
takes about asserted success.

Three routes. Each needs verifying against the installed Claude Code version
before anything is built on it.

### 1. `/cost`, read once at retro

**Yields:** per-model totals for the session.

**Verify first:** that the breakdown is per model and not a single number.

**Good for:** the combined opus share, which is the rule that matters. In this
framework the model-to-tier mapping is nearly one-to-one — opus is the
Supervisor plus `architect` plus `critic`, sonnet is `builder`, `designer`,
`cartographer` and `reviewer`, haiku is `scout` and `scribe`.

**Cannot:** split `builder` from `reviewer`, or the Supervisor from `critic`.
Both pairs share a model. It answers "how much opus", never "which opus".

### 2. OpenTelemetry export

**Yields:** the richest per-request data of the three, exported continuously.

**Verify first:** the metric and attribute set actually emitted by the installed
version. Attribute names are not stable across versions, and a dashboard built
on a renamed attribute fails silently — which is the failure mode this whole
plan exists to remove.

**Cost:** a collector to run and keep running. Heavy for a one-person repo;
reasonable for a team already running one.

### 3. The local session transcript

**Yields:** potentially per-message usage, including per-subagent, which would
be the only route that answers "which opus".

**Verify first:** whether the installed version writes a transcript under
`~/.claude/` at all, and whether it records usage per message. Both vary.

**Cost:** none. It needs no new plumbing, which makes it the first one to check.

### When this round opens

After two instrumented sessions. By then the dispatch counts and the value
report will have shown whether the opus spend needs a finer instrument, or
whether counting dispatches and reading what they found was enough.

Revisit `docs/ROUTING.md`'s 14/71/15 split at the same time. That split is
borrowed from a published measurement of someone else's sessions; replacing it
with two sessions of this repo's own numbers is the entire point.
