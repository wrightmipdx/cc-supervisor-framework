---
name: ui
description: Mockup-driven UI work — iterate a mockup to sign-off, convert the signed-off mockup into an element-inventory spec, then build and gate each phase on a screenshot diff. Use for any front-end change whose acceptance test is "it looks like the picture", and whenever built UI does not match a mockup.
argument-hint: [screen or feature]
---

The mockup is the specification of appearance, and it is a file the worker can
read. The written spec binds it to real code and fills what a static picture
cannot show. Prose never overrides the picture.

## 1. Mockup to sign-off

- `designer` in Mode A produces one self-contained HTML file per screen.
- Iterate with the user on the picture, not on prose. Fast rounds.
- Stop when the user signs off. Record the file path and the sign-off in the
  plan. That file is now frozen — it is the reference, and every later brief
  passes its path. Never paraphrase a frozen mockup into a brief.

## 2. Element inventory — the only spec format

The signed-off mockup is a real file with real CSS. **It is the literal
specification, and the designer reads it directly.** Do not transcribe it into
prose or into a table — copying every declaration out of the mockup so a worker
can copy it back into code means the most expensive tier in the session is
producing keystrokes the cheap tier was hired for.

The inventory does the one thing the mockup cannot: bind the picture to real
code, and resolve what the picture leaves open.

One table per screen. The final DOM in order.

| # | Element | Mockup ref | Disposition | Binding / delta |
|---|---|---|---|---|
| 1 | Header bar | `.hdr` | KEEP | — |
| 2 | Filter row | `.filters` | RESTYLE | per mockup |
| 3 | Legacy export button | — | REMOVE | — |
| 4 | Status chip | `.chip--warn` | NEW | `<Chip tone="warn">{row.status}</Chip>`, tone from `row.severity` |
| 5 | Row hover | `.row:hover` | NEW | mockup is static — use `--surface-hover`, 120ms ease |

Dispositions: KEEP, RESTYLE, MOVE, REMOVE, NEW.

Rules for the inventory:

- **Mockup ref** is a selector or element in the frozen mockup file. Every row
  that appears in the picture has one. The designer reads the real declarations
  from there.
- **Binding / delta** carries only what the mockup cannot express: the data
  binding, the component to use, the design token that replaces a hardcoded
  value, and any behavior a static picture has no way to show — hover, focus,
  transition, scroll, responsive breakpoints, motion.
- `per mockup` is a complete and correct entry for appearance. It points the
  designer at the frozen file. It is not a shrug.
- Anything on the built screen that is not a row gets removed.
- No "author's call". No "author's discretion". Those are about *judgment*, and
  the designer has none here — but pointing at the mockup is not judgment, it is
  a citation.
- A row whose Binding cannot be filled is an unresolved question. Ask it, before
  the build, never during. The mockup being silent is the common case: a static
  picture cannot show a hover state or an error toast, so those are exactly the
  rows that need a literal value.

## 3. Build order

Build the highest-risk screen first, so the first fidelity check lands early.
One screen per brief to `designer` in Mode B.

## 4. Fidelity gate — every phase

- The worker returns a screenshot of the built screen — see the capture paths
  in `designer`. If it reports that no capture path exists in this project,
  that is a setup defect and it is yours to fix: the fidelity gate is the only
  acceptance test this skill has, and without a capture there is no gate. Do
  not close the phase on a prose description of the screen.
- Put it side by side with the mockup.
- Produce a difference list.
- The phase closes only when that list is empty.
- Tests passing is necessary. It is not sufficient.

## 5. When the built UI does not match

The cause is the spec, not the effort. Say so plainly to the user. Then:

1. Find which inventory row was missing, ambiguous, or absent — or whether the
   mockup itself was silent on what the built screen got wrong.
2. Fix the inventory row, or the mockup, whichever was actually mute.
3. Re-dispatch that row alone.
4. Add the gap to `LESSONS.md` as a spec defect, not a build defect.
