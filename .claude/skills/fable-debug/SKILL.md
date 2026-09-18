---
name: fable-debug
description: Hypothesis-driven debugging — reproduce, characterize, form falsifiable hypotheses, then delegate a mechanical fix with a regression test. Use on any failure whose cause is unknown, and after any failed fix attempt.
---

Root cause before fix. No fix proposals before a reproduction exists.

## Loop

1. **Reproduce.** Get a deterministic repro: a test, a script, exact steps.
   Intermittent? Set a scout or a Bash canary to watch for it. No repro? Say so.
   Do not "fix" what you cannot see.
2. **Characterize.** Batched scouts answer: where in the code (stack, logs),
   when it started (`git log` window), and the smallest failing input.
3. **Hypothesize.** One falsifiable statement. Take the cheapest disproof
   first: a log line, a one-off script, a bisection.
4. **Prove or kill.** Evidence, not vibes. Three dead hypotheses: stop.
   `fable-architect` re-maps the subsystem with you.
5. **Fix.** Once the cause is confirmed, brief the fix to builder — architect
   if it is gnarly. The repro becomes a regression test in the suite: red
   first where feasible, then green.
6. **Close.** Normal `fable-review` and `fable-commit`. Put the root cause in
   the commit body in one sentence. Cannot state it in one sentence? You have
   not found it.

## Hard rules

- Never suppress a symptom until you understand the mechanism. No swallowed
  exceptions. No blanket retries. No bumped timeouts.
- Diagnostics stay on the chair. Delegate only once the fix is mechanical.
- A fix without a regression test is a fix that comes back.

## Escalation

| Round | Action |
|---|---|
| 1–2 | Chair diagnoses, builder fixes |
| 3 | Architect re-maps the terrain with you |
| 4 | Stop. Report to the user with what is known and what is ruled out |
