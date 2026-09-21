# Stakeholder terminology glossary

Maps the Supervisor kit's internal role/process vocabulary to language for
anything shown to a non-engineering audience — an analyst, a product owner, a
sponsor — before or during implementation. This is a **translation layer**,
not a rename: `builder`, `reviewer`, `critic`, `wave`, `tripwire` etc. stay
exactly as they are inside `.claude/`, because hooks and skill files key off
those literal words (e.g. `60-dispatch-end.sh`). Nothing here changes the
kit's mechanics — it only changes what a preview document *says* out loud.

`plan/SKILL.md` step 4 reads this file for any plan with `audience: sponsor`
(the default). Seeded once at install — this file is yours to extend as your
own project grows role or mechanic names the kit doesn't have; a later kit
upgrade never overwrites it.

## Roles

| Kit term | Preview term | Why |
|---|---|---|
| Supervisor | Lead | The one accountable for the plan and the outcome. |
| builder | software builder | Does the hands-on work on one piece. |
| architect | software architect | The escalation tier for a harder problem. |
| reviewer | quality reviewer | Checks work before it's accepted. |
| critic | independent reviewer | A second, higher-scrutiny opinion — reserved for the riskier categories. |
| scout | researcher | Finds facts, doesn't decide anything. |
| scribe | writer | Produces or organizes prose/notes. |
| cartographer | orientation specialist | Maps unfamiliar territory before work starts on it. |
| designer | designer | Already plain — kept as-is. |

## Process & mechanics

| Kit term | Preview term | Why |
|---|---|---|
| dispatch / brief | assignment | The unit of work handed to a specialist. |
| wave | phase | A round of work that finishes before the next begins. |
| worktree isolation | separate workspace | Keeps specialists from stepping on each other's work-in-progress. |
| tripwire | guardrail | An automatic check that catches a specific known risk. |
| direct lane | handled personally | The Lead does it without a handoff — small enough not to need one. |
| two strikes, escalate | two tries, then hand up | Failure path when a specialist can't close something out. |
| fan out | split up the work | Parallel assignments instead of one large one. |
| resume | pick back up | Continuing an unfinished assignment once, rather than starting over. |
| break point | natural pause point | A place the work can stop cleanly and be picked back up later, because everything before it is finished and handed over. |
| disqualified break point | not a clean pause point | A phase boundary we could pause at on paper, but shouldn't: one of the checks on the "done" list is finished partly before it and partly after, so pausing there risks marking that check complete when only half of it is. Named anyway, so the choice stays visible. |

## Artifacts & status

| Kit term | Preview term | Why |
|---|---|---|
| ledger | requirements checklist | The list of commitments being tracked to closure. |
| plan | plan | Already plain — kept as-is. |
| evidence | proof of work | What backs up a claim of "done." |
| SHIP / blocker | ready to ship / blocker | Already common outside engineering — kept as-is. |

## Leave alone

Don't translate these — they're either already plain, or they're identifiers
that must stay exact so a reader can find the real thing:

- Acceptance criteria (**AC-1**, **AC-2**, ...) — already stakeholder
  language; keep the numbering so it maps back to the plan.
- File paths, table/column names, migration names, product/SKU codes
  (`CAN-12OZ`), command names — these point at real things and lose that
  function if paraphrased.
- Test/tool names (`typecheck`, `npm test`) when quoted as literal commands.

## Maintenance

When a new role or mechanic name appears in the kit (a new agent, a new gate),
add its row here before it shows up in a stakeholder-facing preview. This is
manual discipline, not a gate — a term missing from this table still renders,
literally, in a sponsor preview rather than being dropped or blocking
confirmation. See `docs/templates/preview-stakeholder-template.md` for the
rendering shape.
