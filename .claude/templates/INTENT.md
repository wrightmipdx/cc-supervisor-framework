# Intent

What this project is, for the Supervisor. `CLAUDE.md` holds *how the session
runs*; this file holds *what is being built*. Keep them separate — process
rules that drift into product context, or the reverse, are how both stop being
read.

Delete the prompts as you answer them. Keep it under a page: this file is
loaded often, and a page nobody trims stops being true.

## What it is

One paragraph. What the thing does and who uses it.

## Why it exists

The problem it solves, and what people did before it. This is the context that
tells a Supervisor which trade-offs are acceptable.

## Shape of the system

The handful of nouns a newcomer needs, and how they relate. Not an
architecture doc — `cartographer` produces those on demand. Five to ten lines.

## Constraints that are not negotiable

Compatibility promises, compliance, performance floors, platforms, data that
must never leave somewhere. The things a worker cannot discover by reading code
and would violate cheerfully.

## Conventions

Where they are written down, if they are. Point at the files rather than
restating them — and if a convention gets retyped into every brief, preload it
as a skill instead (see the `skills:` knob in `.claude/agents/builder.md`).

## Out of scope

What this project deliberately does not do. Saves relitigating it every time
someone notices the gap.
