---
name: fable-ui
description: Mockup-driven UI work — iterate a mockup to sign-off, convert the signed-off mockup into an element-inventory spec, then build and gate each phase on a screenshot diff. Use for any front-end change whose acceptance test is "it looks like the picture", and whenever built UI does not match a mockup.
argument-hint: [screen or feature]
---

The mockup is the specification of appearance. The written spec only binds it to
real code. Prose never overrides the picture.

## 1. Mockup to sign-off

- `fable-designer` in Mode A produces one self-contained HTML file per screen.
- Iterate with the user on the picture, not on prose. Fast rounds.
- Stop when the user signs off. Record the file path and the sign-off in the
  plan. That file is now frozen. It is the reference.

## 2. Element inventory — the only spec format

One table per screen. The final DOM in order. No descriptive prose.

| # | Element | Disposition | Literal CSS / JSX |
|---|---|---|---|
| 1 | Header bar | KEEP | — |
| 2 | Filter row | RESTYLE | `gap: 12px; font-size: 13px; color: var(--muted)` |
| 3 | Legacy export button | REMOVE | — |
| 4 | Status chip | NEW | `<Chip tone="warn">{status}</Chip>` |

Dispositions: KEEP, RESTYLE, MOVE, REMOVE, NEW.

Rules for the inventory:

- Anything on the built screen that is not a row gets removed.
- No "author's call". No "author's discretion". No "keep as-is". No "match the
  mockup". If the mockup depicts it, the inventory states it literally.
- Every open choice gets resolved with the user before the build. Never during.
- A row you cannot fill with a literal value is an unresolved question. Ask it.

## 3. Build order

Build the highest-risk screen first, so the first fidelity check lands early.
One screen per brief to `fable-designer` in Mode B.

## 4. Fidelity gate — every phase

- The worker returns a screenshot of the built screen.
- Put it side by side with the mockup.
- Produce a difference list.
- The phase closes only when that list is empty.
- Tests passing is necessary. It is not sufficient.

## 5. When the built UI does not match

The cause is the spec, not the effort. Say so plainly to the user. Then:

1. Find which inventory row was missing, ambiguous, or absent.
2. Fix the inventory row.
3. Re-dispatch that row alone.
4. Add the gap to `LESSONS.md` as a spec defect, not a build defect.
