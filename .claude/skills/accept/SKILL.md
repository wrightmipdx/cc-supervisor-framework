---
name: accept
description: Demonstrate the built thing against the acceptance criteria the sponsor wrote, as observed behavior rather than an assertion. Runs after review and before commit on every close of substance. Use when a task claims an AC-n item, and whenever someone needs to confirm a change works without reading the diff.
argument-hint: [task id]
---

`review` asks whether the code does what the brief said. This asks whether the
thing does what the sponsor asked, **shown**. Different question, different
evidence, different reader.

Skipped entirely when `ACCEPT_GATE=off` — see the end of this file.

## 1. When it applies

Every close of substance that claims an `AC-n` item from the plan.

Skipped on the direct lane, the same bound `review` uses for its "None" lane:
≤2 files, ≤~50 lines, cause known, tests already existed. Briefing or staging a
demonstration for a two-line fix costs more than the fix.

## 2. What a demonstration is

**It exercises the product the way a user does.** A CLI invocation, an HTTP
request, a rendered screen, a script's output, a query against the real schema.

**The unit suite is not admissible here.** A green suite is `review`'s evidence
and was already collected there; re-presenting it as a demonstration is the
failure this skill exists to prevent, because it is the one a reader who cannot
read the diff has no way to detect. If the only thing you can show is `npm
test`, you have not demonstrated anything — say so and treat the criterion as
not demonstrable by run, below.

**Negative cases are required where one exists.** That a lapsed subscriber sees
the banner is half the criterion. That an active subscriber does not is the
other half, and it is the half that catches a hardcoded return.

## 3. Who does what

Capture is delegable. Adjudication is not. This is `ui` §4 generalized — the
worker returns the screenshot, the chair puts it beside the mockup.

| Step | Who |
|---|---|
| Name the demonstration steps for each `AC-n` | **You.** Judgment, and low volume — a few lines |
| Execute them and capture to `scratch/` | **`builder`** (sonnet), or **`scout`** (haiku) when you can name the exact commands. Yourself, if you already hold the context and the output is small |
| Execute them against a scratch environment **and** render a mechanical PASS/FAIL per criterion against the brief's own stated expected values | **`acceptor`** (sonnet) — see the `acceptor` agent and the note below |
| Read the artifact and decide PASS or FAIL | **You.** This is the sponsor's judgment, exercised on their behalf |

**Fix the steps before you dispatch.** A screenshot has almost no degrees of
freedom, which is why `ui` lets the implementing worker capture its own build.
A general demonstration has one large one — *choosing what to run* — and that is
the freedom a passing path gets steered through. Put the exact steps in the
brief's `Done when` and who executes stops mattering. Prefer a worker other
than the implementer anyway.

**A worker returns an artifact, never a verdict.** A staging report carrying
PASS, FAIL or "works as expected" is out of contract: reject and re-run, as
`dispatch` triage treats a missing Evidence section and as `ui` §4 refuses to
close on a prose description of the screen. A worker that judged was doing more
than it was hired for. You read the artifact with your own eyes — that is
`review` §1 satisfied, not bypassed, because what came back is evidence rather
than a claim. This still applies to `builder` and `scout`: neither renders a
verdict, ever.

`acceptor` is the one named exception, and a narrow one: it renders a
mechanical PASS/FAIL/BLOCK per `AC-n` against the brief's own stated expected
value — the same shape `reviewer` and `critic` already use when they render
SHIP/BLOCK against a brief's done-when items, not the open-ended judgment the
rule above is guarding against. This does not change who tells the sponsor the
plan is accepted: the chair still reads `acceptor`'s report and owns that
call, same as it owns reading a `critic` BLOCK today.

**Keep the output small.** Yours is the most expensive context in the session
and everything in it is re-billed on every later turn. Bulk goes to
`scratch/<task-id>-<ac>.…`; you take the tail and the artifact path.

## 4. The record

One block per criterion, in an `## Acceptance record` section of the plan. Not
in the task entries: a criterion is the sponsor's unit and routinely spans
several tasks, so filing it under one of them buries it and invites the same
criterion being recorded twice. Each task cites the ids it demonstrated; the
record holds the evidence.

```text
AC-2: "a lapsed subscriber sees the renewal banner"
  ran:      seed lapsed user, GET /account
  observed: banner present, copy matches AC text
  artifact: scratch/T4-ac2.png                        [PASS]

AC-3: "an active subscriber does not"
  ran:      seed active user, GET /account
  observed: no banner in rendered output
  artifact: scratch/T4-ac3.txt                        [PASS]
```

`ran` and `observed` are separate lines on purpose. A record where they say the
same thing is an assertion wearing a demonstration's clothes.

## 5. Not demonstrable by run

Some criteria cannot be shown by exercising the product: a performance floor, a
security property, a migration's safety, anything about what must *not* happen
over time. Name them:

```text
AC-5: "list view stays under 200ms at 10k rows"   [NOT DEMONSTRABLE BY RUN]
  substitute: bench output, 41ms at 10k — scratch/T4-ac5.txt
```

Never prove one of these silently with a test and file it as a PASS. The point
of naming it is that the sponsor learns which of their criteria rest on
evidence they cannot personally check.

## 6. Visual closes

Route to `ui` §4 and the capture paths in `designer`;
`.claude/scripts/screenshot.mjs` is the default. The artifact is the screenshot
and the adjudication is the difference list. Do not build a second capture path
here.

## 7. On FAIL

Back into `review` §3's fix loop, same two-loop bound, same lane. Send the
observed behavior verbatim — what you saw, not your reading of it.

A criterion that fails **after a passing review** is a spec defect, not a build
defect. The code did what the brief said and the brief was wrong. Follow `ui`
§5: find which criterion was missing, ambiguous or silent, fix that, re-dispatch
that one item alone, and record it at retro as a spec defect.

## 8. When the gate is off

`ACCEPT_GATE=off` in `.claude/settings.json` disables this gate; the close runs
`review` → `commit` and this skill is not loaded. The session-start hook
announces the OFF state when it applies. Absent means on.

The switch governs the demonstration, not the criteria. `AC-n` items are four
lines and they are what a review lane checks against; an operator who reads
their own diffs still benefits from a sponsor stating observable outcomes.
