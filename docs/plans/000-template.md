status: draft        # draft | active | done | abandoned
date: <YYYY-MM-DD>
ledger: docs/kit/LEDGER.md
target version: <x.y.z>   # if the plan ships a release
audience: sponsor    # sponsor | engineering -- default sponsor; per-plan, not per-session

<!-- `status:` must stay on its own line at column 0: the SessionStart hook
     finds the active plan with grep '^status:[[:space:]]*active'. -->

# <NNN> — <title>

## Goal

One paragraph. The outcome, not the activity. Name the evidence the plan is
built on — a measured session, a bug report, a user decision — so a later
reader can check the premises instead of trusting them.

## Acceptance criteria

What the sponsor asked for, in observable behavior an outsider could check. No
commands — those are the success criteria below, and the two are not the same
thing. Acceptance criteria are what was asked for; success criteria are what
proves the build is sound. Both are required, and a requirement with no
acceptance criterion gets one or gets cut.

The `accept` skill demonstrates these before commit. Give each an id: tasks
cite them, and so does the acceptance record.

- AC-1 <a user with X sees Y>
- AC-2 <and a user without X does not> — the negative case, where one exists

With `ACCEPT_GATE=off` this section is optional; the demonstration is what the
switch removes, not the criteria.

## Success criteria

Observable and runnable. The `retro` skill executes these literally, so write
commands, not intentions.

- [ ] `<command>` passes, including `<the new test>`
- [ ] <user-visible behavior an outsider could check>

## Approach

The two or three decisions that shape everything else, each with its reason.
Then what you considered and rejected:

Rejected: <alternative> — <why not>.

## Out of scope

Scope cuts, stated explicitly so a later session does not relitigate them.

-

## Decisions — closed by the user <date>

Questions that blocked planning and how the user settled them. A decision
recorded here does not get reopened by a worker mid-task.

1.

## Corrections applied before dispatch

Verify the plan's premises against the code before dispatching anything, and
record what did not hold. A worker sent to fix a defect that does not exist
burns a full dispatch and returns confused.

-

## Risks

Each risk carries a tripwire: the specific check that would catch it, and who
runs it.

- **<risk>.** Tripwire: <check>.

## Tasks

Every task names a worker, a review lane and the acceptance criteria it
demonstrates, and carries a brief that could be dispatched as-is. A task you
cannot brief yet is too vague — split it or sharpen it.

### T1 — <title>

- Worker: scout | cartographer | builder | designer | architect | scribe
- Review: direct | reviewer | critic   <!-- REQUIRED; without one it is not dispatchable -->
- Depends on: —
- Ledger items: <which checkboxes this closes>
- Acceptance: <which AC-n this demonstrates, or '—'>

- Brief:
  - Goal:
  - Context:       <file:line pointers, prior art, the constraint that matters>
  - Files:
  - Constraints:
  - Done when:
  - Evidence:      <commands whose output proves it>
  - Scratch:       `scratch/T1-<slug>.md`

- Outcome:         <filled in at review and accept — verdict, AC results,
                   residual risk, what changed>

### T2 — <title>

...

## Next steps

Written as the next session's opening line, and updated at every retro.
