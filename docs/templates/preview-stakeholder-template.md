# Stakeholder preview template

`plan/SKILL.md` step 4 renders this shape for any plan with `audience:
sponsor` (the default) — see the fact-to-section mapping there. Seeded once
at install; yours to adjust, a later kit upgrade never overwrites it.

Use this for the preview an analyst or product owner sees **before**
implementation starts on a plan — the moment the kit currently renders as a
"dispatch order" full of waves, builders, and tripwires. It replaces none of
that; it sits in front of it, using the glossary's terms. Engineers keep
using the technical execution order (the plan file, the ledger, the actual
dispatch briefs) unchanged — link to it in the Appendix rather than
translating it line by line.

Don't invent details this template doesn't have from the plan/ledger. If an
acceptance check's specifics aren't spelled out yet, name it by number and
say so rather than guessing at content.

---

## Template

```markdown
# <Plan name> — Preview

**What we're delivering:** <one or two sentences, outcomes not activities>

<When the plan has at least one pause point, append ", apart from the
pause-point choice below" inside this heading's parentheses. When it has
none, leave the heading exactly as written below.>

**Decisions already made (nothing further to approve here):**
- <each sponsor/stakeholder decision that's already closed, in plain terms>

**How the work is organized**

Phase 1 — <N> specialists working in parallel on separate, non-overlapping
parts of the system:
- Specialist: <what they're delivering, in plain terms — not the file path>
- Specialist: <...>
- Lead (handled personally, no handoff): <small item done directly>

Phase 2 — <what happens after Phase 1 closes, and why it waits>

Phase 3 — <final walkthrough / acceptance / close-out>

**Natural pause points:** <each phase boundary the work could pause at, named
by phase and never by task id, saying what finishes first — the whole phase
does, not part of it — then the trade-off and the choice: pausing costs a
short catch-up when we pick it back up, running through doesn't, and no
answer means run through. A boundary that is NOT a clean pause point is named
here too, never quietly dropped: say which item on the "done" list straddles
it and that you are not offering it — "Phase 2 isn't a clean pause point:
acceptance check 3 is finished partly before it and partly after." If no
boundary is clean, say that plainly and offer none. Omit this line entirely
only when the work has no phase boundary at all.>

**Checks along the way**
- Every change gets a quality review before it's accepted.
- <riskier item> gets an independent reviewer — <one line on why it's
  higher-risk>.
- Guardrails in place: <plain-language list, e.g. "a check that the database
  change matches what was intended", "a search to confirm no duplicate logic
  crept back in">.

**What "done" looks like**
- <acceptance checks, by number, described in plain terms where known>

**Appendix — technical execution order:** <link to the plan file and ledger
items; this is the source of truth for the specialists doing the work>
```

---

## Worked example

Applied to plan 007's dispatch order (the version an engineer would see):

> **T1 builder** — `packages/domain/src/inventory/on-hand.ts`, space
> re-expressed on it, `on-hand.test.ts`. Review: reviewer.
> Wave 2 (after T1 commit): **T2 builder** — M3 loader reads counts via the
> shared module... Review: critic (seam + new module + run-response field).
> Tripwire: no `packages/domain/test/materials-*` fixture changes.

Rendered with the template:

```markdown
# Plan 007 — Hardening Sweep — Preview

**What we're delivering:** Closing out gaps flagged in the last review round —
how on-hand inventory is calculated, capacity (peak pallets) tracking, a
size limit and clearer errors on file imports, navigation fixes across four
screens, and traceability for where a demand number came from.

**Decisions already made (nothing further to approve here, apart from the
pause-point choice below):**
- On-hand inventory is calculated as the latest physical count plus anything
  received since, with the previous method kept as a fallback.
- The specific check the sponsor asked for — that two reports agree on one
  product's count and pallet total — has been confirmed correct as their own
  sign-off test (this is acceptance check 1).

**How the work is organized**

Phase 1 — five specialists working in parallel on separate, non-overlapping
parts of the system:
- Specialist: the on-hand calculation logic and its tests
- Specialist: capacity (peak pallets) tracking and the database change it needs
- Specialist: a size limit on file imports, with a clearer error when it's hit
- Specialist: navigation fixes across four screens
- Lead (handled personally, no handoff): adding a "where this came from"
  reference to demand records

Each is reviewed by a quality reviewer and signed off before the next phase
starts.

Phase 2 — one specialist connects the on-hand logic to the live data feed,
once Phase 1's version of it has landed. This one gets an independent
reviewer, not just a quality reviewer — it's the seam between the old and new
calculation, and touches a data source other things depend on.

Phase 3 — the Lead runs a full walkthrough in a sandboxed copy of the system
(never touching the live one) against the six agreed acceptance checks, then
closes out the round: reconciling the requirements checklist, capturing
lessons learned, and archiving.

**Natural pause points:** There are two — after Phase 1, once all five pieces
in it are finished and handed over, and again after Phase 2, once the live
data feed is connected and Phase 3's walkthrough is all that's left. Either
one means the whole phase finishes first, not part of it, and we'd pick the
rest back up later instead of running all three phases in one go. Pausing
costs a short catch-up when we resume; running straight through doesn't.
Either is fine — say the word if you'd prefer to pause at one of them,
otherwise we'll run through.

**Checks along the way**
- Every change gets a quality review before it's accepted; the Phase 2 change
  gets an independent reviewer as well.
- Automated tests run after every change.
- Guardrails in place: a check that the database change matches what was
  intended, and a rule that Phase 2 must not touch the existing test data
  used to verify materials.

**What "done" looks like**
- Acceptance checks 1 through 6 pass, including the sponsor's own
  count-agreement check (acceptance check 1).

**Appendix — technical execution order:** `docs/plans/007-hardening.md` and
ledger items E41–E52, I31–I35, X39–X43 — this is what the specialists are
actually working from.
```
