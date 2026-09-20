# Routing reference

Deep reference. Not loaded at session start. Read it when a rule is disputed,
when routing feels wrong, or when onboarding someone to this framework.

## Why this exists

The Supervisor pays for decisions. The cheap tiers pay for tokens.

### Where the saving actually comes from

Not from model tiering. From **context isolation**. A worker reads twenty files
and returns forty lines; the Supervisor's context grows by forty lines instead
of twenty files — and that context is re-billed on every subsequent Supervisor
turn. Compounding avoided growth in the most expensive context is most of the
win. Model tiering is the smaller, second effect.

### What the split really costs

A published measurement of this routing style recorded 14 percent of tokens on
the Supervisor (planning plus review), 71 percent on sonnet, and 15 percent on
haiku. **These are borrowed numbers**, measured on someone else's sessions, and
they are here only until this repo has its own: `.claude/scripts/metrics.sh`
now counts dispatches by tier every session, and the split below gets replaced
after two instrumented sessions. Treat it as an order of magnitude.

Tokens are not dollars. At roughly 5x sonnet for opus and roughly 0.25x for
haiku:

| Tier | Token share | Cost share |
|---|---|---|
| opus | 14% | **~48%** |
| sonnet | 71% | ~49% |
| haiku | 15% | ~3% |

Two things follow, and they are the reason this framework governs an opus
budget rather than a chair budget:

1. **Chair share is the wrong governor.** `critic` and `architect` are opus and
   are not counted in "Supervisor share", but they cost the same per token. A
   session at 15 percent chair share that dispatches an opus critic on every
   close is more expensive than one at 25 percent with none. Govern the combined
   opus share — Supervisor + architect + critic.
2. **Review is the largest discretionary line.** Opus review on every close is
   usually the single biggest purchase in a session. Hence `reviewer` on sonnet
   as the default lane, with `critic` reserved for the risk categories in the
   `review` skill. Line count is not a risk signal.

### Be honest about the baseline

The "3x cost cut" is measured against an all-opus single-agent session. Against
*sonnet-as-main-agent with subagents* — what most Claude Code users actually run
— the cost saving is small and can be negative. Against that baseline this
framework's claim is **quality**: judgment held on the strongest model, fresh
eyes on every close, requirements that survive compaction. That is a stronger
claim than cost, and it is the one to defend.

Treat every number here as a target shape, not a promise. The published split
came from a different codebase and task mix; calibrate yours over a few sessions
and record it in `docs/kit/LESSONS.md`.

### The counterpart the routing table assumes

Every rule above governs how the chair spends. None of them say who the chair
is answerable to. The kit defines eight worker contracts in
`.claude/agents/*.md` and, until 0.5.0, none for the human — who appears only
as an approval oracle at four gates, each handing over an artifact that assumes
an engineer is reading it.

That is a live failure mode when the operator is not one. A sponsor who cannot
read a diff cannot refuse a close, so every close is accepted, and "fresh eyes
on every close" quietly reduces to the chair reviewing itself through a worker
it briefed. Trust substitutes for verification because verification was never
offered in a form the sponsor could use.

`CLAUDE.md`'s **The chair and the sponsor** splits the decisions. The `accept`
skill makes the sponsor's column checkable: acceptance criteria written in
their language before the code exists, demonstrated afterwards as observed
behavior. Its cost discipline is the same as everything else here — capture is
volume and goes down-tier, adjudication is judgment and stays in the chair,
which is `ui`'s fidelity gate generalized rather than a new idea.

The gate is on by default and `ACCEPT_GATE=off` removes it, because an operator
who reads their own diffs is already doing the adjudication and the staging is
pure ceremony — the over-delegation failure above, wearing a different hat.

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
| 12 | Govern cost by opus-tier share, not chair share; tokens are not dollars | This framework's own arithmetic — see "What the split really costs" |
| 13 | A bounded direct lane: briefing a five-line fix costs more than the fix | Correction to #1 after review; volume decides delegation, difficulty decides tier |
| 14 | Verify the harness honors a frontmatter key before relying on it | `.claude/install-check.sh`; unsupported keys are ignored silently |
| 15 | An installer needs a manifest to distinguish the consumer's edits from the last release's files | Built after the first installer proved unable to upgrade anything |
| 16 | The sponsor's decisions are named, and made checkable by demonstration rather than by diff-reading | This framework, 0.5.0 — built when its own operator turned out not to be an SWE |

## Architecture

```
                 +----------------------------------+
                 |      SUPERVISOR                   |
                 | judge - plan - arbitrate - verify |
                 |      integrate - commit          |
                 +----------------+-----------------+
       briefs down |  reports up (<= 40 lines, evidence required)
   +--------+------+--------+--------+--------+--------+--------+
   v        v      v        v        v        v        v        v
 scout  cartog- builder designer reviewer architect critic  scribe
        rapher
(haiku) (sonnet)(sonnet)(sonnet) (sonnet)  (opus)   (opus)  (haiku)
 find    map     build   mockup   routine   hard    risk-   bulk
 recon   explain test    fidelity review    migrate category prose
                                                    review
```

The two opus lanes are the bill. Everything else is comparatively free.

## Failure modes

**Opus lanes above roughly 25 percent of tokens.** Supervisor + architect +
critic together. Usually it is review: `critic` dispatched on routine closes
that `reviewer` would have handled. Second most likely: the Supervisor typing a
long implementation instead of briefing it.

This one is a goal, not a gate, and the distinction matters. Capping opus is
only correct if the opus was not earning its cost, so `metrics.sh` prints the
verdict and blocker count of every opus dispatch. A `critic` that returned SHIP
with no blockers on a routine close is the evidence for using `reviewer` next
time; one that returned BLOCK bought more than it cost. Judge the share against
what it found, not against the percentage alone.

**Over-delegation of small work.** The mirror failure, and the more common one
in practice. A brief for a five-line fix costs more than the fix, adds a spawn's
fixed overhead, and throws away the context that made it easy. Volume decides
whether to delegate; difficulty decides the tier. The direct lane in `intake`
exists for this.

**Mid-session model toggle.** Each switch invalidates the cached prefix and
re-bills the whole conversation. Delegate instead. The subagent builds its own
cache.

**Over-instructed cheap tiers.** Haiku with a tight single-purpose brief is
reliable. Haiku holding a judgment call is a coin flip.

**The built-in Explore agent.** In several releases it inherits the main
model, so it bills supervisor-tier tokens for reconnaissance. Use `scout`.
Shadowing it with a project agent of the same name is version-dependent and not
worth relying on; the routing table forbids it by name instead.

## When this framework is the wrong tool

- Short sessions. The overhead exceeds the saving.
- Uniformly hard work. Research-heavy debugging is all judgment; there is
  nothing to route down.
- Subscription billing where you would rather spend chair quota freely.

The file set still works in all three cases. The routing table just keeps you
honest.

## Optional knobs

Run `.claude/install-check.sh` before trusting any of these. It verifies the
wiring statically and prints a one-time probe for the keys only the harness can
answer for. An unsupported frontmatter key is ignored **silently**, so an
unverified knob is a knob you are guessing about.

- `maxTurns` on a subagent is a runaway guard.
- `skills` in subagent frontmatter preloads a skill into the worker's context.
  A convention you retype into every brief belongs here instead — see the
  commented example in `builder.md`.
- `effort` sizing: `low` for mechanical sweeps, `high` for implementation,
  `max` for architecture and security.
- `omitClaudeMd: true` keeps the chair's constitution out of worker contexts.
  Workers should not read instructions telling them to delegate. This is the
  key that bites when unsupported, which is why `CLAUDE.md` also opens with a
  banner telling subagents to ignore it. Keep the banner even if the probe says
  the key works — it costs six lines and survives an upgrade that the probe
  result does not.
- `isolation: "worktree"` on an Agent call gives the worker its own git
  worktree. It is what makes parallel implementers safe; see `dispatch`, which
  also carries the merge-back steps and the convention `worktrees.sh` and
  `status` use to find an open one — the Supervisor itself never works from a
  secondary worktree, so any worktree found besides the primary is a dispatch.

## Subagent files and reload

Whether edits to `.claude/agents/*.md` take effect without a restart has varied
between releases. If a change to an agent seems not to apply, restart the
session before you debug the file.
