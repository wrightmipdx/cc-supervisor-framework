# Metrics

The framework governs a budget. The rule that matters most — keep Supervisor +
`architect` + `critic` near or under ~25% — went unenforced for two versions:
first because there was no instrument, and then, worse, because there was one
reporting zeros it could not possibly have measured.

This document covers both halves of what exists now: hooks that log events, and
a reader that prices a session from its own transcript.

The instrument is deliberately small. Every field maps to a rule in `CLAUDE.md`
or in a skill. A field supporting no rule is noise, and noise in a governance
loop is worse than an empty page.

## What gets written

Hooks append one JSON line per event to `.metrics/session-<session_id>.jsonl`,
which is gitignored. Nothing else writes. The Supervisor in particular does not:
bookkeeping in the chair's context costs chair tokens, which is the thing being
measured.

Read it with `.claude/scripts/metrics.sh`, which the `retro` and `status` skills
both call. Read it by hand with `jq` whenever you want something the script does
not print.

### Events

| Event | Written by | Carries |
|---|---|---|
| `session_start` | `10-session-start.sh` | HEAD, branch, ledger open/verified/deferred, lesson count |
| `dispatch` | `20-pre-delegate.sh` | agent, tier, task id, brief size in bytes |
| `dispatch_launched` | `60-dispatch-end.sh` (PostToolUse) | agent, `agent_id` — the join key |
| `dispatch_end` | `60-dispatch-end.sh` (SubagentStop) | source, `duration_s` — real completion |
| `commit_attempt` | `30-commit-gate.sh` | staged files/insertions/deletions, commit type, ledger open |
| `commit_landed` | `70-commit-landed.sh` | HEAD, real files/insertions/deletions, commit type |
| `gate_block` | `30-commit-gate.sh` | which rule blocked: `blind_add` or `blind_commit` |

Every event also carries `event`, `ts`, `session` and `origin`.

**Sizes, counts and verdicts only.** Never a brief, never a report, never a
diff. `test-metrics.sh` asserts that no brief or report text reaches the log.

**Test runs never touch it.** The hook suites point `METRICS_DIR` at a temp
directory and assert they left the repo's log byte-for-byte as they found it. If
you see a `session-test.jsonl` in your `.metrics/`, it is residue from a version
before 0.3.2 and is safe to delete — as is any `session-nosession.jsonl`, which
comes from running a hook by hand with no session id.

### Commit → task: inferred, not joined

No event carries a task id on a `commit_landed` — workers never commit
(`dispatch` rule 6), so there is nothing analogous to `dispatch`'s `task` field
to write there, and the 005 round considered and rejected a commit trailer for
this reason (`docs/plans/005-traceability.md`, Decisions). What `metrics.sh`'s
direct-lane block and `trace.sh`'s chair-conduct pricing both compute instead is
**time order**: a `commit_landed` with no `dispatch` event since the previous
`commit_landed` had no worker precede it. That establishes no worker preceded
the commit — never who wrote the code, and never which task it closed. Do not
read "direct-lane" or "chair window" as an exact join; both report surfaces say
so in their own printed output, not only here.

### `origin`, and why some events refuse to name an agent

Hooks fire inside subagents as well as the main session. An earlier edit-budget
hook was removed from this framework for exactly that reason: a builder tripped
it unaided and the Supervisor was blamed. A number built on that kind of
confusion is worse than no number.

| `origin` | Meaning |
|---|---|
| `main` | Provably the main session. The source does not fire in a subagent, or no worker was in flight when it did |
| `ambiguous` | A worker was in flight. The Supervisor and the worker are indistinguishable here, and the event says so |
| `repo` | A fact about the repository rather than any agent: HEAD moved. Who ran the command is neither known nor interesting |

In-flight tracking is a counter incremented on `dispatch` and decremented on
`dispatch_end` — which, since 0.4.0, is written from `SubagentStop`, at real
completion. If your version fires no `SubagentStop`, the counter never returns
to zero and every event after the first dispatch reads `ambiguous`. That is
degraded, and honestly so.

**It was silently broken through 0.3.3, in the other direction.** The decrement
happened on `PostToolUse`, and once agents began launching asynchronously that
fires about a second after the dispatch — so the count returned to zero while
every worker was still running. Measured on the first real consumer: across 111
logged events, in sessions that ran up to eight concurrent builders, `origin`
was `ambiguous` **zero times**, and every `.inflight-*` file on disk read `0`.

A safeguard that always answers `main` is worse than one that is missing. The
missing one shows up as a gap; this one showed up as confidence. That is the
failure direction to fear in an instrument built to say "I cannot tell".

### Where the verdict and the findings live — and why not here

`reviewer` and `critic` contract for a report shaped:

```
## Verdict: BLOCK | FIX FIRST | SHIP
## Findings
- [blocker] file:line — issue — what would satisfy
```

Through 0.3.3, `60-dispatch-end.sh` parsed that out of its hook payload. **It
never could, and the log said so on every line without anyone noticing.**

Agents on this Claude Code version launch asynchronously. `Task` returns a
receipt — `"Async agent launched successfully… agentId: <id>"` — and
`PostToolUse` fires against the receipt, one to two seconds after the dispatch,
while the worker is still starting. The report arrives much later through
`SubagentHandback`, which no hook is wired to and which raises no hook event.

The evidence, from 24 paired dispatches on the first real consumer:

- `dispatch` → `dispatch_end` was **1.0s** twenty times and **2.0s** four times
- `report_bytes` minus `brief_bytes` fell between **+353 and +428** on all 24

`report_bytes` was a function of the **brief**. So `verdict` came out `none` on
27 of 27 dispatches and `has_evidence` `false` on 27 of 27, while the session
transcripts showed critics returning FIX FIRST over real defects — an unseeded
scenario giving 404 on a fresh install, 400 error bodies dropped before the UI,
a `Promise.all` discarding a successful result.

Those fields are therefore **gone from the hook**. They were not fixable there
at any effort, and a field reporting a confident zero it cannot populate is
worse than a missing one: a missing field reads as a gap, a false zero reads as
an answer. `dispatch_end` now carries only what `SubagentStop` genuinely knows —
that a worker stopped, and how long the queue had been waiting.

The verdict and the finding counts are read instead by
`.claude/scripts/session-tokens.sh`, out of the `SubagentHandback` in the
session transcript, where they sit next to that run's token cost. **That pairing
is the point.** "This critic dispatch cost $3.91 and returned SHIP with no
blockers" is a decision; either half alone is trivia.

Counts and verdict, never the finding text — the same rule as before, now
enforced by `session-tokens.sh --self-test`, which asserts that no finding text
reaches the report.

### `agent_id` — the join key

A worker's transcript file is **anonymous**. It records tokens, turns and the
handback; it has no idea whether it was a `critic`, what tier it ran on, or
which task it was given. The event log knows all three and nothing about cost.

The launch receipt's one piece of real information is the `agentId`, and
`dispatch_launched` captures it. That is what turns "how much opus" into "which
opus" — the question `docs/ROUTING.md` says the budget rule actually needs, and
the one `/cost` can never answer, because the Supervisor, `architect` and
`critic` all share a model.

It is an opaque local handle. It goes to a gitignored log, nothing reads it but
`session-tokens.sh`, and it is never rendered into a reply. A run with no
matching `dispatch_launched` reports as **unjoined** — real cost, unknown role,
never attributed by timestamp proximity.

### The two wirings, and why neither is a fallback for the other

`60-dispatch-end.sh` is wired to both `PostToolUse` on `Agent|Task` and to
`SubagentStop`. Through 0.3.3 that was a hedge: which one a given Claude Code
version fires cannot be determined from a script, so both were wired and each
recorded its `source`.

**The hedge did not work, and it is worth knowing why.** Both wired sources fire
at launch on an async version — `PostToolUse` against the receipt, and
`SubagentStop` whenever it likes, including when nothing was dispatched. Two
sources for one fact is only a hedge if at least one of them has the fact.
Neither did.

Since 0.4.0 they are not alternatives. They are two different events:

| Wiring | Writes | Because it is the only one that knows |
|---|---|---|
| `PostToolUse` | `dispatch_launched` | the receipt, and the `agentId` in it |
| `SubagentStop` | `dispatch_end` | that a worker actually stopped |

`install-check.sh --probe` prints what to check after your next dispatching
session, and what each absence degrades.

**Measured 2026-09-18, still true:** `SubagentStop` fires on this version even
when nothing was dispatched — four times in a session with zero Agent calls. A
`SubagentStop` with no worker in flight is dropped, not logged: it did not end a
dispatch, whatever the harness calls it. That rule is unchanged. 0.4.0 only made
the counter it consults truthful.

### There is no `session_end`

`Stop` fires at the end of **every** assistant turn, not at the end of a
session. An event written there would be stamped at the end of turn one with a
duration, a dirty-file count and a ledger count that were all wrong.

`metrics.sh` prints an **observed span** instead — first event to last, labelled
as exactly that.

## Token cost per tier — route 3, built 2026-09-19

Read by `.claude/scripts/session-tokens.sh`, which `metrics.sh` calls for its
last block and which `metrics.sh --cost` runs on its own.

```
~/.claude/projects/<slug>/<session>.jsonl                    main thread, per-turn usage
~/.claude/projects/<slug>/<session>/subagents/agent-*.jsonl  one file per worker
```

`<slug>` is the project path with every `/` and `.` flattened to `-`. Each
worker file carries `agentId`, per-turn `usage`, and the `SubagentHandback` the
hook cannot see. Joined to the event log on `agent_id`, that gives per-session,
per-worker, per-tier cost with each run's verdict beside it.

### What it reports, and the rule each number serves

The standing rule in this document is that a field supporting no rule is noise,
and noise in a governance loop is worse than an empty page. Four derived
numbers, each of which moved a decision during the review that produced this
round, and no others:

| Number | The rule it serves |
|---|---|
| Combined opus share of cost | `CLAUDE.md` prime rule 2 — Supervisor + `architect` + `critic`, ~25% goal |
| Worker spend past turn 30 | every agent's `maxTurns`, and whether a brief was too large |
| Chair share of billable tokens | `ROUTING.md`'s claim that the saving is context isolation, not tiering |
| Each run's cost beside its verdict | the review lane — is `critic` on opus earning its 5x on this close |

### Tokens lead; dollars are a labelled assumption

A rolling usage limit is consumed in **tokens**, so tokens are what the report
leads with. But a tiering decision is only legible in money: a haiku token and
an opus token are identical against a turn count and 150x apart against a bill.

So the script carries a list-price table with the date it was written, and
prints that date on every run. Checked against one real session's own cost
readout, the table reproduced the Fable line almost exactly ($23.37 modelled vs
$23.93 reported) and priced Opus about **1.8x** what the client displayed —
subscription accounting is not list price. **Absolute dollars are an estimate;
the shares between lanes are what carry a decision**, and the report ranks on
shares.

This is the "do not guess" rule honoured, not abandoned. What 0.3.x refused to
guess was a *split* — a fabricated attribution of cost across lanes. What is
asserted here is a *price*: stated as an assumption, dated, and in one editable
place.

### Cache TTL — measured 2026-09-19, and deliberately left alone

Claude Code assigns a prompt-cache TTL per request from two fixed buckets. On a
Claude subscription within plan usage, the **main conversation** gets one hour;
**everything else** — subagents, workflows, forks, compaction, session titles —
gets five minutes. This is documented behaviour, not a regression:
<https://code.claude.com/docs/en/prompt-caching>. It is visible directly in any
transcript, because each turn's `usage.cache_creation` splits the write:

```sh
jq -r 'select(.type=="assistant" and .message.usage.cache_creation!=null)
       | "\(.message.model) 5m=\(.message.usage.cache_creation.ephemeral_5m_input_tokens) 1h=\(.message.usage.cache_creation.ephemeral_1h_input_tokens)"' \
   ~/.claude/projects/<slug>/<session>.jsonl
```

Measured over the two 0.4.1 sessions in `~/projects/opanalyst`, the split is
total: the chair wrote 909,307 one-hour tokens and zero five-minute; the 22
worker runs wrote 3,666,585 five-minute tokens and zero one-hour.

**This has cost the framework nothing, and buying the hour would cost money.**
A worker here is burst-shaped: it reads a brief, runs hot for ten to seventy
back-to-back turns, and exits. Across all 22 runs in both sessions, **zero**
inter-turn gaps exceeded 300s; the longest was 254s and the next was 104s. The
worker write/read ratio is 0.03 — the five-minute cache is hitting on
essentially every turn. A one-hour TTL bills writes at 2x base instead of 1.25x,
so setting `subagentPromptCacheTtl: 1h` would have added roughly **$6 to a $62
session for no additional cache hit**. No setting is changed, and none should
be on this evidence.

Re-measure before overriding that, from the project whose sessions you are
judging:

```sh
for f in ~/.claude/projects/<slug>/<session>/subagents/agent-*.jsonl; do
  jq -r 'select(.type=="assistant" and .message.usage!=null)
         | [.timestamp,(.message.usage.cache_creation_input_tokens//0),
                       (.message.usage.cache_read_input_tokens//0)] | @tsv' "$f" \
  | awk -F'\t' -v n="$(basename "$f")" '
      { cmd = "date -j -f %Y-%m-%dT%H:%M:%S " substr($1,1,19) " +%s"
        cmd | getline t; close(cmd)
        if (NR > 1) { g = t - pt; if (g > m) m = g; if (g > 300) big++ }
        pt = t; w += $2; r += $3 }
      END { printf "%s maxgap=%ds gaps>300s=%d write/read=%.2f\n", n, m, big+0, w/r }'
done
```

**The one case that flips the verdict is a resumed worker.** A run resumed after
a human-length gap starts cold, and so does any run whose brief contains a tool
call longer than five minutes — a full build, a browser pass, a large suite. If
that becomes routine, the answer is `experimental.cacheTtl: 1h` on the one agent
that needs it (`.claude/agents/<name>.md`, Claude Code v2.1.248+), never the
global `subagentPromptCacheTtl`. Run the command above at any retro where a
worker overran its wall-clock, and record what it said.

### What it does not do

No cross-session or cross-project rollup — the instrument is session-specific by
design. No hook blocks, warns or downgrades a tier on a budget reading; the
instrument reports and the human decides. A governor built on an instrument this
young is how a rule stops meaning anything.

### What would send us back to the other routes

The transcript path and schema belong to the harness, not to this framework.
`install-check.sh --probe` prints the directory it expects; if it is not there,
`metrics.sh` says UNAVAILABLE and names the path it looked in. That is route 3's
known cost, accepted because it is the only route that answers "which opus", and
because the failure is loud rather than silent.

## The three routes, as weighed on 2026-09-18

Kept as the record of why route 3 was chosen, and of what to reach for if it
ever stops working.


Guessing was the thing to avoid: a fabricated split inside a budget rule is how
the rule stops meaning anything, which is the position this framework already
takes about asserted success. Each route needed verifying against the installed
Claude Code version before anything was built on it.

### 1. `/cost`, read once at retro

**Yields:** per-model totals for the session.

**Verify first:** that the breakdown is per model and not a single number.

**Good for:** the combined opus share, which is the rule that matters. In this
framework the model-to-tier mapping is nearly one-to-one — opus is the
Supervisor plus `architect` plus `critic`, sonnet is `builder`, `designer`,
`cartographer` and `reviewer`, haiku is `scout` and `scribe`.

**Cannot:** split `builder` from `reviewer`, or the Supervisor from `critic`.
Both pairs share a model. It answers "how much opus", never "which opus".

### 2. OpenTelemetry export

**Yields:** the richest per-request data of the three, exported continuously.

**Verify first:** the metric and attribute set actually emitted by the installed
version. Attribute names are not stable across versions, and a dashboard built
on a renamed attribute fails silently — which is the failure mode this whole
plan exists to remove.

**Cost:** a collector to run and keep running. Heavy for a one-person repo;
reasonable for a team already running one.

### 3. The local session transcript

**Yields:** potentially per-message usage, including per-subagent, which would
be the only route that answers "which opus".

**Verify first:** whether the installed version writes a transcript under
`~/.claude/` at all, and whether it records usage per message. Both vary.

**Cost:** none. It needs no new plumbing, which makes it the first one to check.

**Verified and built, 2026-09-19.** The directory exists, usage is recorded per
message, and subagents get their own files carrying `agentId` and the handback.
It answered "which opus" on the first try.

### Recalibrating `ROUTING.md`

`docs/ROUTING.md` still carries a 14/71/15 token split borrowed from a published
measurement of someone else's sessions. The first real consumer measured very
differently — opus took roughly half of session cost, not a seventh of tokens —
and the turn-budget effect that measurement revealed is not in that table at
all.

**It has deliberately not been replaced.** One project, one task mix, three
days; and a green-field monorepo scaffold is builder-heavy and review-heavy in
ways steady-state maintenance is not. Retuning the framework's routing guidance
on a single codebase would repeat the original error with fresher numbers.

User decision, 2026-09-19: gather more data, then review again. The goal is
lower tiers wherever quality allows, and this instrument is how that gets
decided rather than argued.
