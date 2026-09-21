---
name: plan
description: Explores, then writes an implementation plan with success criteria, a requirements ledger, and pre-drafted task briefs. Use before any multi-task change and before touching unfamiliar code.
argument-hint: [goal]
---

Explore, design, then write it down. No code until the plan exists.

## 0. Enter plan mode

`EnterPlanMode` before you explore. The harness then refuses edits until you
call `ExitPlanMode`, which also puts the plan in front of the user for approval.

This is belt and braces with step 4, and worth it: "no code during planning" is
the rule most easily lost when a fix looks obvious mid-exploration, and
willpower is a weaker mechanism than a tool that refuses. Exploration is
read-only by nature, so the mode costs you nothing until it saves you.

If your version does not offer plan mode, step 4 still gates the dispatch —
you are just enforcing it yourself.

## 1. Explore — keep the Supervisor's context clean

- Scout briefs carry up to three related lookups each — seams, conventions,
  prior art, existing utilities. Past three, fan out parallel single-topic
  scouts rather than growing one brief; a scout that exhausts its turns returns
  nothing. See `dispatch` rule 1.
- One cartographer pass if the subsystem is unfamiliar.
- You keep the summaries. Bulk goes to `scratch/`.

## 2. Design — Supervisor work

- Choose the approach yourself.
- If the change is architecturally significant (new subsystem, breaking change,
  cross-cutting concern), get a short design note from `architect` first,
  then decide. The note informs you. It does not decide for you.
- Write down what you are NOT doing.

## 3. Write it down

- **Acceptance criteria first, before the ledger.** `AC-n` items in the
  sponsor's language: observable behavior an outsider could check, no commands.
  They are what `accept` demonstrates before commit, and a requirement with no
  acceptance criterion gets one or gets cut — if nobody can say what "working"
  looks like, nobody will be able to tell whether it does. Include the negative
  case wherever one exists.
- Requirements become checkboxes in `docs/kit/LEDGER.md`. One ledger per
  topic. Archive by renaming to `LEDGER-<topic>-archive.md`.
- The ledger holds explicit requirements, implicit requirements, and edge cases.
  If the user said it, it is a line. If the code demands it, it is a line.
- Copy `docs/plans/000-template.md` to
  `docs/plans/NNN-slug.md`.
- Every task names its worker tier, its review lane (`direct`, `reviewer`, or
  `critic` — see `review`), the `AC-n` items it demonstrates, and carries a
  pre-drafted brief. Choosing the review
  lane at plan time, when you can see the risk, stops it being chosen by reflex
  at close time, when opus looks like the safe default.
- **A task with no `Review:` lane is not dispatchable.** Not a convention — a
  gate. Across three real plans the field appeared zero times and every critic
  dispatch was decided at close time, which is how a routine diff ends up on
  opus. `status` reports any active-plan task that is missing one.
- A task you cannot brief yet is too vague. Split it or sharpen it until you
  can.

## 4. Confirm

Show the sponsor their own surface, in this order and contiguously:

1. the goal
2. the acceptance criteria
3. the scope cuts — what you are deliberately not doing
4. the risks, each with its tripwire
5. any decision you need from them before dispatch

That order is the point. Leading with tiers and lanes asks the sponsor to
approve decisions in your column, and what comes back is a rubber stamp
rather than a review — see `CLAUDE.md`, **The chair and the sponsor**.

**Where the plan can break is one of item 5's decisions.** Before you write
item 5, walk the task graph's `Depends on:` edges and name every real wave
boundary the plan already has:

**`.claude/scripts/break-points.sh <plan.md>` does the derivation** — waves,
boundaries, both disqualifiers, verdicts. Run it; do not work the graph by
hand. `--all` sweeps every plan, `--self-test` asserts the rules below. The
bullets here are what the script encodes, kept so you can explain an answer
and so a plan not yet on disk can still be read:

- Waves come from the edges. Wave 1 is every task whose `Depends on:` names
  no task; every other task sits one wave after the latest wave holding a
  task it names. A range names each task in it — `T1–T4` is T1, T2, T3, T4
  (`docs/plans/002`'s T5). A `Depends on:` naming something that is not a
  task — a closed decision, an external event — is not an edge and creates no
  boundary (`docs/plans/010`'s T2, `Depends on: decision 1`).
- A boundary exists after wave *k* when some later task depends on a wave-*k*
  task. Label it by **the highest-numbered wave-*k* task a later task depends
  on** — numerically, so T11 outranks T8, not by position in the file, which
  already diverges from id order (`docs/plans/004` lists T6 first). A task
  nothing depends on blocks nothing and never supplies the label.
- **The label is not the cut line.** The break falls after *every* task in
  wave *k*, including the ones nothing depends on. Say that cut out loud, or
  a sponsor reads "break after T2" as "dispatch up to T2 and stop" and a
  sibling task is left unstarted — the unresumable state the disqualifiers
  below exist to prevent.
- First disqualifier: a wave is not a break point if a task in it **states in
  its own brief that it lands no commit**, leaving a resuming session nothing
  to resume from (the shape `LEDGER-010` I2 was written for). `Review: direct`
  emphatically does not disqualify a wave —
  `CLAUDE.md`'s routing table defines that lane as "edit, run the checks,
  commit," and `commit/SKILL.md` makes one brief one committed increment, so
  every task commits by construction. No brief in this repo currently makes
  that statement, so the test is inert here. It is kept because it is
  decidable when it runs — you read the brief, at confirmation time — and
  because the state it rules out fails silently.
- Second disqualifier: a boundary after wave *k* is not a break point if **a
  single `AC-n` or a single ledger item is claimed by tasks on both sides of
  it**. Union the `Acceptance:` and `Ledger items:` lines of every task at or
  before wave *k*; union them for every task after it; any id in both kills
  that boundary. Check both fields — a shared ledger item is the more direct
  hazard, because `[x]` is what gets ticked early, and `docs/plans/007` proves
  the fields are not interchangeable: its boundary after T2 has disjoint
  `AC-n` sets but E2 and X5 both span it. Dependencies do not see any of this,
  so the edge walk above cannot catch it.
  Why: a claim split across the break gets demonstrated in halves, and a half
  is what gets recorded. Measured in `LEDGER-010` X4 / AC-5 — the closing
  chunk ticked the item on its half, and the resuming chunk, reading only the
  committed records and the handoff brief as a real resume does, appended its
  own half instead of correcting the early tick. Neither chunk did anything
  wrong; each saw a complete-looking picture.
  A task whose field reads `—` or is absent claims nothing and can never
  disqualify a boundary. A plan with no `Acceptance:` and no `Ledger items:`
  lines at all is **unchecked by this test, not cleared by it** — say so
  rather than reporting a clean break you did not verify.
  Nothing else disqualifies a boundary. Neither field subsumes the other —
  007's boundary is killed by ledger items alone, 005's after T5 and T6 by
  `AC-n` alone — so both are checked, and both already exist.
- **A disqualified boundary is still named, flagged, never silently dropped**,
  and no task count or dependency depth gates any of this. Say which check
  failed and on what id. The chair's job is to say which boundaries are real
  and which are not safe, not to quietly shorten the list — a sponsor reading
  three candidates cannot tell you removed two. Every boundary appears, in
  wave order, earliest first, clean and flagged together in one list; the ids
  will not be consecutive and are not meant to be (`docs/plans/002` comes out
  T3, T2, T4). You do not pre-select and you do not argue for one. A plan
  where every task reads `Depends on: —` has no boundary at all and renders
  exactly as it did before this paragraph existed — no line, no mention.

Then ask once — the fact, the cut, its cost, the choice:

> This plan can break cleanly after T2 — T1 and T2 both land first.
> Breaking means the rest starts in a fresh session, which pays a session
> start plus a handoff-brief and lessons re-read that running straight through
> does not. End-to-end, or break after T2?

That is `docs/plans/010-chunked-execution.md`'s own shape, and it is clean on
both checks. A boundary that fails one is named in the same breath, with the
check that killed it, so the sponsor sees the whole graph rather than an
edited one:

> This plan has one wave boundary, after T2, and it is not a clean break:
> ledger items E2 and X5 are each claimed by a task on both sides of it, so
> closing there would tick one of them on half its evidence. I am not
> offering it. End-to-end is the only safe run.

That is `docs/plans/007-chair-overhead.md`, verified — the plan whose cost
motivated this whole mechanism turns out to have no safe break point at all.
Do not soften that into "it would be better to run through"; say which ids
span the boundary, because the sponsor can overrule you and should be able to
see what they would be accepting.

**If the sponsor takes a flagged break anyway** — their call, and a legitimate
one — the spanning ids are the thing that must survive. Name them in
`docs/kit/HANDOFF.md`, and leave every one of them **un-ticked** at the close
even where the closing chunk did its half: a `[ ]` the next session re-checks
costs minutes, and the `[x]` it would otherwise inherit is the failure this
whole rule exists to prevent.

Most plans are mixed — some boundaries clean, some flagged. They take the same
single ask, a clause each, clean and flagged in one wave-ordered list. You
never show a subset and you never trim to keep the ask short:

> This plan has five wave boundaries and only one is a clean break: after T9,
> once everything before it lands. I am not offering the other four — ledger
> items I5 and X8 are claimed on both sides of all of them, and after T5 also
> splits E4, E10, I8 and X6. Breaking at T9 starts the rest in a fresh
> session, which pays a session start plus a handoff-brief and lessons
> re-read; running straight through does not. End-to-end, or break after T9?

That is `docs/plans/001`'s real shape — five boundaries, one clean, every
disqualification from a ledger item and not one from an `AC-n`. Naming the
four is not padding: it is the difference between a sponsor who knows the plan
is nearly unsplittable and one who thinks it has a single natural pause. When
one id spans almost everything, as I5 does here, that is itself the finding.

Illustrative shape, not literal copy. State the cost; never estimate the
saving — nothing is dispatched yet, so there is no transcript to price. No
answer means end-to-end, and you do not ask again: this is advisory, never a
gate. A sponsor who declines the break has declined only the break —
direct-lane reporting still applies in full, and matters most on exactly the
long single-session run a decline produces.

**Branch on the plan's `audience:` field** (`docs/plans/000-template.md`
frontmatter; missing field on a plan written before this line existed counts
as `sponsor`, never as `engineering` and never as an error — an older plan
should not lose the sponsor-facing behavior just because it predates the
field):

- `audience: engineering` — render the five items above exactly as written,
  in the kit's own vocabulary. No translation.
- `audience: sponsor` (the default) — render the same five facts, in the same
  order, through `docs/GLOSSARY-stakeholder-terms.md` and the shape in
  `docs/templates/preview-stakeholder-template.md`. This is a vocabulary
  translation only — never drop, reorder, merge, or add to the five facts.
  The mapping onto the template's own section names:

  | Step 4 fact | Template section |
  |---|---|
  | goal | What we're delivering |
  | decisions needed from them | Decisions already made (nothing further to approve here) |
  | scope cuts + task breakdown | How the work is organized |
  | risks and tripwires | Checks along the way |
  | acceptance criteria | What "done" looks like |

  The break-point offer is part of fact 5 but renders under **How the work is
  organized**, on the template's `**Natural pause points:**` line — it is
  about how the work is staged, and staging is where a sponsor reads it. The
  other row sends fact 5 to "Decisions already made," and the break point is
  the one decision that is not, so when a candidate exists that section's
  heading carries "apart from the pause-point choice below" — the preview
  must not claim nothing needs approving while asking for a decision. Wave
  *k* is Phase *k* in the preview (the glossary's `wave` → `phase` row), so
  the kit's "break after T2" becomes "pause after Phase 1" — the phase, never
  the task id — and it still names what finishes first, since the cut is the
  whole phase. Plain terms only: never "chunk", "split", or "session". A plan
  with no candidate omits that line entirely and leaves the heading
  unchanged.

  Link the technical plan and ledger in the template's Appendix — that stays
  the source of truth; the translated preview is a front door onto it, not a
  replacement.

  **No-glossary-row fallback:** a role or mechanic name with no row in
  `docs/GLOSSARY-stakeholder-terms.md` renders literally, in the kit's own
  word, rather than being omitted or blocking confirmation — the glossary is
  maintained by hand (no lint yet), so a gap must be visible, not silent.

Then the engineering, as detail below it: tasks, tiers, review lanes, in the
kit's own vocabulary regardless of `audience:` — this detail is for whoever
dispatches, not the sponsor.

`ExitPlanMode` carries this to them for approval. Get a go before any dispatch.
Flip `status` to `active` on approval.

## Anti-patterns

- A plan with one task. That is a brief, not a plan. Dispatch it.
- Success criteria that describe activity ("refactor the module") instead of an
  observable outcome ("`npm test` passes, including the new regression test").
- Planning without a ledger. The plan is the route. The ledger is the contract.
