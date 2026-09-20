# Intent

## What it is

A Claude Code orchestration framework, packaged as a starter kit. A developer
clones it and runs `install.sh` against a project repo; it installs a
constitution (`CLAUDE.md`), eight subagents, ten skills, seven hooks and a docs
skeleton. The product is the file set and its installer, not an application.

## Why it exists

Single-agent Claude Code sessions put every token — reconnaissance, bulk
implementation, review — in one context on one model. That context is re-billed
on every turn, so it is both the largest cost and the place quality degrades as
it fills. This framework keeps judgment on the strongest model and pushes
volume into isolated worker contexts that return forty-line reports.

## Shape of the system

- `CLAUDE.md` — the always-loaded constitution: routing table, prime rules.
  Kept slim on purpose; detail lives in skills.
- `.claude/agents/*.md` — one file per tier. Model, tools, report contract.
- `.claude/skills/*/SKILL.md` — loaded on demand, one per phase of the session.
- `.claude/hooks/*.sh` — mechanism where instructions are only advice.
- `docs/` — LEDGER (requirements that survive compaction), LESSONS, ROUTING
  (the deep reference and the arithmetic), plans.
- `install.sh` / `.claude/install-check.sh` — install, upgrade, verify.

## Constraints that are not negotiable

- **`install.sh` must never destroy a consumer's work — and must still be able
  to upgrade.** Those pull against each other, which is why the manifest exists:
  files unchanged since install are the framework's to replace, files the
  consumer edited are theirs to keep. An installer that overwrites nothing is
  safe and useless; the first version of this one was exactly that.
- **The installer never infers ownership.** It removes only what a manifest or
  `retired-paths.txt` says it put there. `.claude/agents/` and
  `.claude/skills/` are shared with the consumer; inferring from directory
  contents is how an installer deletes someone's work. When you delete a file
  the framework used to install, add it to `retired-paths.txt` — CI checks the
  list against what the release ships.
- **Idempotence is not upgrade.** Re-running the same release and upgrading from
  an older one look alike and fail differently. CI must cover both.
- **Hooks fail open.** A missing `jq` makes a hook silent, never broken.
- **No claim without evidence.** Anything asserted in the docs about token cost
  or harness behavior is either measured, arithmetic shown, or marked as
  unverified. Borrowed constants get labelled as borrowed.
- Portable to BSD (macOS) and GNU userlands. No hard dependency beyond `jq`
  and `git`.

## Conventions

Shell: `set -uo pipefail`, fail open, comment *why* rather than *what*. Every
behavioral claim about a hook has a test in `.claude/hooks/test-*.sh`. CI runs
the static check, the gate tests, and a full install into a fresh repo.

## Out of scope

- Language- or framework-specific tooling beyond the permission fragments in
  `.claude/settings.examples/`.
- Anything that depends on a Claude Code feature that is not verifiable at
  install time. Unverifiable keys get a probe and a fallback, not a dependency.
