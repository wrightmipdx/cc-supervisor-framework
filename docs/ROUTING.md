# Routing reference

Deep reference. Not loaded at session start. Read it when a rule is disputed,
when routing feels wrong, or when onboarding someone to this framework.

## Why this exists

The Supervisor pays for decisions. The cheap tiers pay for tokens. A published
measurement of this routing style recorded 14 percent of tokens on the Supervisor
(planning plus review), 71 percent on sonnet, and 15 percent on haiku — roughly
a 3x cost cut with an indistinguishable diff, and the Supervisor caught things the
plan missed.

Treat those numbers as a target shape, not a promise. Your ratio depends on
your work.

## Provenance of each practice

| # | Practice | Source |
|---|---|---|
| 1 | Judgment versus keystrokes: the Supervisor pays for decisions, cheap tiers pay for tokens | Community routing playbook |
| 2 | Explore, plan, code, commit — skip the plan only for one-sentence diffs | Anthropic Claude Code best practices |
| 3 | Briefs written for "a gifted engineer with bad judgment and no context"; fresh subagent per task | Jesse Vincent, Superpowers |
| 4 | Fresh-eyes verification on every close; the reviewer sees no prior rounds | Orchestrator plugins; Anthropic's own measurement of worker-plus-verifier |
| 5 | Requirements ledger on disk before delegation — files survive compaction, conversations do not | Anthropic context-engineering guidance |
| 6 | Verification loops: pass/fail checks plus evidence, never asserted success | Anthropic best practices |
| 7 | TDD red-green-refactor; root cause before fix; escalation ladder | Superpowers |
| 8 | Small increments — small changelists review well and revert well | Google engineering practices |
| 9 | Batching — every spawn pays fixed overhead, so five greps are one agent | Orchestrator plugin practice |
| 10 | Never toggle the Supervisor's model mid-session; the prompt cache is model-scoped | Community routing playbook |
| 11 | Over-instructing cheap tiers fails; stripping judgment out of briefs is the Supervisor's job | Community routing playbook |

## Architecture

```
                 +----------------------------------+
                 |      SUPERVISOR                   |
                 | judge - plan - arbitrate - verify |
                 |      integrate - commit          |
                 +----------------+-----------------+
       briefs down |  reports up (<= 40 lines, evidence required)
   +----------+----------+---------+----------+---------+---------+
   v          v          v         v          v         v         v
 scout   cartographer builder  designer  architect   critic    scribe
(haiku)    (sonnet)   (sonnet) (sonnet)   (opus)     (opus)    (haiku)
 find       map        build    mockup     hard     fresh-eyes  commit
 recon      explain    test     fidelity   migrate   review     changelog
```

## Failure modes

**Chair above roughly 20 percent of tokens.** Decomposition is leaking
keystrokes upward. Find the task where you stopped briefing and started typing.

**Mid-session model toggle.** Each switch invalidates the cached prefix and
re-bills the whole conversation. Delegate instead. The subagent builds its own
cache.

**Over-instructed cheap tiers.** Haiku with a tight single-purpose brief is
reliable. Haiku holding a judgment call is a coin flip.

**The built-in Explore agent.** In several releases it inherits the main
model, so it bills supervisor-tier tokens for reconnaissance. Use `scout`. The
project agent at `.claude/agents/explore.md` may or may not shadow the built-in
one depending on your version — do not depend on it.

**Subagent files and reload.** Whether edits to `.claude/agents/*.md` take
effect without a restart has varied between releases. If a change to an agent
seems not to apply, restart the session before you debug the file.

## When this framework is the wrong tool

- Short sessions. The overhead exceeds the saving.
- Uniformly hard work. Research-heavy debugging is all judgment; there is
  nothing to route down.
- Subscription billing where you would rather spend chair quota freely.

The file set still works in all three cases. The routing table just keeps you
honest.

## Optional knobs

- `maxTurns` on a subagent is a runaway guard.
- `skills` in subagent frontmatter preloads a skill into the worker's context.
- `effort` sizing: `low` for mechanical sweeps, `high` for implementation,
  `max` for architecture and security.
- `omitClaudeMd: true` keeps the chair's constitution out of worker contexts.
  Workers should not read instructions telling them to delegate. Verify your
  version supports this key; an unknown key is ignored.
