# Supervisor

A Claude Code orchestration framework. The strongest model holds the judgment;
everything mechanical runs one or two tiers down, in its own context.

Install it into a project repo:

```bash
git clone https://github.com/wrightmipdx/cc-supervisor-framework.git ~/src/supervisor
~/src/supervisor/install.sh /path/to/your/repo
```

## Upgrading

```bash
git -C ~/src/supervisor pull
~/src/supervisor/install.sh /path/to/your/repo --dry-run   # see the plan
~/src/supervisor/install.sh /path/to/your/repo
```

The install writes `.claude/.framework-manifest`: the version, the stack, and a
hash per file. That is what lets an upgrade tell **your** edits from the
previous version's files, which is the whole problem — a "never overwrite
anything" installer cannot upgrade, because every changed file piles up as
`.new` while the old one keeps running.

| Case | What happens |
|---|---|
| Unchanged since install | Overwritten with the new version |
| You edited it | Yours is kept, the new one written as `.new`, flagged as a conflict |
| Removed in the new release | Deleted — unless you had edited it, then kept and flagged |
| `CLAUDE.md` | Only the marked framework block is replaced. Your own sections are untouched |
| `settings.json`, `LEDGER`, `LESSONS`, `INTENT`, `.gitignore` | Yours. Seeded once, then never touched |

Because `settings.json` is seeded once, a key a later release adds to it never
reaches an existing install. Any switch the kit ships therefore has to behave
correctly when its key is **absent** — `ACCEPT_GATE` does: absent means the
acceptance gate is on. To turn it off, add `"ACCEPT_GATE": "off"` to the `env`
block of your own `.claude/settings.json`; upgrades will neither add it nor
take it away.

The promise is *nothing you wrote is overwritten* — not *nothing is
overwritten*. `--force` overwrites your edits too; `--dry-run` prints the plan
and writes nothing.

`.claude/install-check.sh` reports local drift, so you can see which framework
files you have customized before an upgrade turns them into conflicts.

### Migrating an install that predates manifests

An older install has no manifest, so the installer refuses rather than guess,
and tells you to migrate:

```bash
~/src/supervisor/install.sh /path/to/your/repo --adopt --dry-run
~/src/supervisor/install.sh /path/to/your/repo --adopt
```

Your own agents, skills and hooks are safe: `.claude/agents/` and
`.claude/skills/` are shared directories, so `--adopt` never treats an unknown
file there as the framework's. It removes only paths listed in the kit's
`retired-paths.txt`, and prints everything it left alone.

`--adopt` declares the framework files currently in your repo to be unmodified,
writes a manifest, and upgrades — deleting what the new release dropped and
replacing an unmarked constitution in `CLAUDE.md` with a marked block, so later
upgrades land cleanly. **Commit first.** If you had customized a framework file,
`--adopt` overwrites it; `git diff` afterwards is the safety net. If content
follows the old constitution in `CLAUDE.md`, the installer will not guess where
it ends — it says so and leaves the file alone.

### If you renamed the framework

A fork that renamed the chair — `# FABLE — the chair` in place of
`# SUPERVISOR` — is not recognized as this framework. The migration keys on that
heading, so it would leave your constitution in place and append the new one
below it: two live constitutions with contradictory routing tables, and an
install-check that reports all green. The installer now refuses instead, before
writing anything, and names the fork it found.

Reconcile by hand first — your renamed agents and skills are still there too,
and you will otherwise end up with a second parallel copy under the canonical
names. `--force` proceeds anyway if you would rather clean up afterwards. The
check is a single heading, so a fork that also renamed
`## Where the detail lives` still slips through.

## What it actually buys you

**Context isolation, mostly.** A worker reads twenty files and returns forty
lines. The Supervisor's context grows by forty lines instead of twenty files —
and that context is re-billed on every subsequent turn. Compounding avoided
growth in the most expensive context is where the saving lives. Model tiering
is the smaller, second effect.

Be honest about the baseline. Against an all-opus single-agent session this is
roughly a 3x cost cut. Against *sonnet-as-main-agent with subagents* — what
most people actually run — the cost saving is small and can be negative. What
it buys against that baseline is **quality**: judgment held on the strongest
model, fresh eyes on every close, and requirements that survive compaction.
That is the claim worth defending.

**And a close the sponsor can check.** Whoever is briefing the work may not
read diffs — increasingly they do not. `review` verifies the diff against the
brief; `accept` demonstrates the built thing against acceptance criteria the
sponsor wrote in their own language, as observed behavior rather than a green
test log. Capture goes down-tier, adjudication stays in the chair. It is on by
default and `ACCEPT_GATE=off` removes it, which is the right setting for an
operator who reads their own diffs.

`docs/kit/ROUTING.md` has the arithmetic, the provenance of each practice, and the
failure modes.

## The tiers

| Agent | Model | For |
|---|---|---|
| `scout` | haiku | Locate, list, bulk grep. Batched |
| `scribe` | haiku | Bulk prose — changelogs, doc sweeps |
| `cartographer` | sonnet | Explain a subsystem. Depth, not lookup |
| `builder` | sonnet | Briefed implementation. The default |
| `designer` | sonnet | UI against an approved mockup |
| `reviewer` | sonnet | Fresh-eyes review. The default review lane |
| `architect` | opus | The hard 10% and the escalation lane |
| `critic` | opus | Review of security, money, data loss, public API, concurrency |

The two opus lanes are the bill. Everything else is comparatively free, which
is why the framework governs combined opus share rather than the Supervisor's
share — at the 14/71/15 token split `docs/kit/ROUTING.md` derives, that 14% is about
half the cost. It is a goal to measure against, not a cap to enforce:
`metrics.sh` reports what the opus spend bought.

## The rules that carry the weight

1. **Volume decides whether to delegate. Difficulty decides the tier.** A
   five-line fix in code you have already read is cheaper, faster and more
   accurate on your own desk than in a brief.
2. **No delegation without a brief.** Workers have blank contexts.
3. **No multi-task work without a ledger on disk.** Files survive compaction.
   Conversations do not.
4. **Evidence, never asserted success.** A report without pasted output is
   rejected and re-run.
5. **Small increments.** One brief, one reviewable, revertable commit.

## Skills

Loaded on demand, so the always-on context stays small.

`intake` · `plan` · `dispatch` · `ui` · `review` · `accept` · `debug` ·
`commit` · `retro` · `status`

## Hooks

Instructions are advice; hooks are mechanism. Six of them, and only one blocks.
See `.claude/hooks/README.md`.

| Hook | Fences |
|---|---|
| `10-session-start` | Context loss across sessions and compactions |
| `20-pre-delegate` | Delegating multi-task work without a ledger |
| `30-commit-gate` | Blind staging; closing with open requirements |
| `50-stop-retro` | Shipping work without reconciling the ledger |
| `60-dispatch-end` | Nothing — it measures what a dispatch returned |
| `70-commit-landed` | Nothing — it measures what actually got committed |

Their behavior is covered by 159 cases across five suites in
`.claude/hooks/test-*.sh`, which `install-check.sh` runs for you.

## Measurement

The last two hooks write a session event log to `.metrics/`, gitignored:
dispatches by tier, what each report contained, commits and their real sizes.
`.claude/scripts/metrics.sh` turns it into the block `retro` and `status` print,
including **what each opus dispatch actually found** — the number that says
whether an expensive lane earned its cost. `.claude/scripts/session-tokens.sh`
prices that session from its own local transcript, tier by tier, chair turn
against worker turn. `.claude/scripts/trace.sh` reads a plan and its ledger
instead of the event log — orphan criteria, unproven criteria, ledger items no
task claims, untraced or unclosed tasks, deferrals with no recorded approval —
so the sponsor can check the requirement trail without taking the chair's word
for it. `.claude/scripts/worktrees.sh` lists any git worktree an isolated
dispatch left open, since `git status` in the main tree cannot see one — see
`dispatch/SKILL.md` "Merging a worktree dispatch back". All four are
self-testing (`--self-test`), and `install-check.sh` runs every one of them.

## After installing

From the root of the repo you installed into:

```bash
.claude/install-check.sh          # wiring + the one-time probe
```

The leading `.claude/` matters — the script lives there, and shells do not
search the current directory. `--static` skips the probe; `--probe` reprints
just the probe brief.

Then three things:

1. **Fill in `docs/INTENT.md`.** `CLAUDE.md` points there for product context
   and it ships as a template.
2. **Check `permissions.allow` in `.claude/settings.json`.** The installer
   merges a stack fragment, but only you know your repo's real check commands.
   Wrong entries mean permission prompts in every session.
3. **Run the probe once and record the answer in `docs/kit/LESSONS.md`.** Some
   subagent frontmatter keys are honored in some versions and ignored —
   silently — in others. `omitClaudeMd` is the one that bites: unhonored, every
   worker reads the Supervisor constitution and starts trying to delegate the
   work it was hired to do. `CLAUDE.md` opens with a banner that covers this
   either way, but you want to know.

## When not to use it

`docs/kit/ROUTING.md` says this at more length, and it is worth reading before you
adopt it:

- **Short sessions.** The overhead exceeds the saving.
- **Uniformly hard work.** Research-heavy debugging is all judgment. There is
  nothing to route down.
- **Subscription billing** where you would rather spend top-tier quota freely.

The file set still works in all three cases. The routing table just keeps you
honest.

## Scope and direction

- **Claude Code only.** This is not a portable pattern meant to also run on
  Codex, Cursor, or Gemini. A feature that only earns its keep multi-platform
  is out of scope.
- **On-demand loading is the point, not incidental.** Ten skills, one loaded
  per phase of the session, is what keeps the always-on context (`CLAUDE.md`)
  small. Growing the skill or agent count without keeping it on-demand undoes
  the saving that makes the rest of this worth running.
- **Cost governance over scale.** The framework optimizes for a small,
  well-understood opus share on one Supervisor holding judgment — not for
  running many agents at once. A change that buys scale at the cost of that
  discipline belongs in a fork, not here.
- **Worth periodically checking against `claude-code-best-practice`** (the
  public reference for where common Claude Code practice is heading) — to
  diff the routing table and conventions against it occasionally, not to
  chase feature parity with tools built for a different goal.

## Requirements

`jq` for the hooks and the installer. `git`. Node plus Playwright only if you
use the UI fidelity gate's default capture path.
