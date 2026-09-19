#!/usr/bin/env bash
# Read one plan and its ledger, and report where the requirement trail breaks.
#
#   .claude/scripts/trace.sh                 # active plan under $DOCS/plans
#   .claude/scripts/trace.sh <plan-file>      # this plan file, any status
#   .claude/scripts/trace.sh --self-test      # hermetic self-test
#
# UNLIKE A HOOK, THIS FAILS LOUDLY. A hook that breaks costs you a session; a
# script that fails silent costs you the thing it exists to catch. This runs
# because a human asked it to, and a quiet report that skipped a check reads
# as "nothing to report" when it means "I could not tell" — the exact failure
# the retired 0.2.0 edit-budget hook was pulled for (docs/METRICS.md,
# .claude/hooks/README.md:103-108).
#
# Six things it looks for, all set-difference or presence checks against a
# plan and the ledger its frontmatter names:
#   orphan criterion    — an AC-n no task's `Acceptance:` field cites
#   unproven criterion  — an AC-n with no block in `## Acceptance record`
#   orphan requirement  — a ledger item WITH AN ID no task's `Ledger items:`
#                          field claims (id-less items can't be cited by id
#                          and are skipped, not counted)
#   untraced task        — a task missing `Ledger items:`, `Review:` or
#                          `Acceptance:` as a line
#   unclosed task        — a task whose `Outcome:` is absent or still carries
#                          the template's `<...>` placeholder
#   unapproved deferral  — a `[~]` ledger item whose bullet has no ISO date
#
# Where a question cannot be answered — no ledger frontmatter, no Acceptance
# criteria section, a missing file — the literal token UNAVAILABLE says so and
# why. It never prints a zero it cannot stand behind. Where a section has
# nothing to report, it prints one short "clean" line: never silence, which
# reads as "didn't check", and never a manufactured finding.
#
# No jq dependency: this parses only Markdown (plans and ledgers), never JSON.
#
# Dependency: .claude/hooks/lib/ledger.sh, sourced below. Unlike metrics.sh's
# optional sourcing (hooks fail open), this script's whole job depends on it.

set -uo pipefail

# ROOT anchors the library to this script's real location — always the kit
# checkout, never overridden, so the self-test can still find the real
# ledger.sh while it points DOCS at a fixture tree. PROJ_ROOT is the project
# whose docs/ we read, overridable the same way session-tokens.sh overrides
# CLAUDE_PROJECT_DIR for its own self-test.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/.claude/hooks/lib"
PROJ_ROOT="${CLAUDE_PROJECT_DIR:-$ROOT}"
DOCS="${DOCS:-docs}"

die() { printf 'trace: %s\n' "$1" >&2; exit 1; }

[ -f "$LIB/ledger.sh" ] || die "missing $LIB/ledger.sh — this script cannot parse a ledger without it"
# shellcheck disable=SC1091
. "$LIB/ledger.sh" || die "cannot source $LIB/ledger.sh"

SP='[[:space:]]'

# --- small helpers -----------------------------------------------------------

# Lines strictly between a heading matching <regex> and the next top-level
# "## " heading (or EOF). Used for "## Acceptance criteria" and "## Acceptance
# record" alike — both are bounded the same way.
#
# CALLERS MUST PASS A FULL-LINE-ANCHORED PATTERN (end with $, e.g.
# '^## Acceptance criteria$'), never a bare prefix. An unanchored pattern lets
# an unrelated earlier heading that merely STARTS WITH the same words (a stale
# "## Acceptance criteria draft" left over from a copy-paste) match as the
# section's start; the real heading then re-matches the same loose pattern too
# and is swallowed as content instead of closing the section, which folds a
# decoy's stray ids into what gets reported as the real one. Found by review.
section_after() {  # section_after <file> <heading-regex, full-line-anchored>
  awk -v pat="$2" '
    $0 ~ pat { insec=1; next }
    insec && /^## / { insec=0 }
    insec { print }
  ' "$1"
}

has_section() { grep -qE "$2" "$1" 2>/dev/null; }  # has_section <file> <heading-regex, full-line-anchored>

# One id per line from a task's comma-separated field value, dropping the
# em-dash / hyphen "none" placeholders and blank tokens.
split_ids() {
  printf '%s\n' "$1" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -vE '^(—|-)?$'
}

# --- select the plan -----------------------------------------------------

PLAN=""
ACTIVE_LIST=""

if [ "${1:-}" = "--self-test" ]; then
  : # handled below, after the helpers exist
elif [ -n "${1:-}" ]; then
  case "$1" in
    /*) PLAN="$1" ;;
    *)  PLAN="$PROJ_ROOT/$1" ;;
  esac
  [ -f "$PLAN" ] || die "no such plan file: $1"
  PLAN_SELECTION="explicit"
else
  PLANS_DIR="$PROJ_ROOT/$DOCS/plans"
  if [ -d "$PLANS_DIR" ]; then
    # Same pattern the SessionStart hook uses (.claude/hooks/10-session-start.sh):
    # no end-anchor, so a trailing "# comment" on the status line is free.
    ACTIVE_LIST=$(grep -l "^status:${SP}*active" "$PLANS_DIR"/*.md 2>/dev/null || true)
  fi
  N_ACTIVE=0
  [ -n "$ACTIVE_LIST" ] && N_ACTIVE=$(printf '%s\n' "$ACTIVE_LIST" | grep -c .)
  if [ "$N_ACTIVE" -eq 0 ]; then
    printf '## Active plan\n'
    printf '   none found under %s/plans — nothing to trace\n' "$DOCS"
    exit 0
  elif [ "$N_ACTIVE" -eq 1 ]; then
    PLAN="$ACTIVE_LIST"
    PLAN_SELECTION="active"
  else
    PLAN=$(printf '%s\n' "$ACTIVE_LIST" | head -1)
    PLAN_SELECTION="ambiguous"
  fi
fi

# --- report a plan --------------------------------------------------------
# Everything from here down is one plan's report. Self-test calls this
# script recursively (below) so it is exercised exactly as a real run is.

report() {
  local PLAN="$1"

  printf '## Active plan\n'
  case "$PLAN_SELECTION" in
    explicit)
      printf '   %s (given on the command line — analyzed regardless of status)\n' "$PLAN" ;;
    active)
      printf '   %s\n' "$PLAN" ;;
    ambiguous)
      printf '   %s plans marked active — this is itself a finding worth fixing:\n' "$N_ACTIVE"
      printf '%s\n' "$ACTIVE_LIST" | sed 's/^/   - /'
      printf '   analyzing the first (%s), by the same order the SessionStart hook uses\n' "$PLAN"
      ;;
  esac
  printf '\n'

  # --- ledger ----------------------------------------------------------------
  local LEDGER_REL LEDGER_PATH LEDGER_OK=1 LEDGER_REASON=""
  # A trailing "# comment" is tolerated the same way status: already tolerates
  # one (the template puts a comment on that line, not this one, but nothing
  # rules out a consumer copying the convention here too).
  LEDGER_REL=$(grep -m1 "^ledger:${SP}*" "$PLAN" 2>/dev/null \
    | sed -E "s/^ledger:${SP}*//; s/${SP}*#.*\$//; s/${SP}+\$//")
  if [ -z "$LEDGER_REL" ]; then
    LEDGER_OK=0
    LEDGER_REASON="no 'ledger:' line in $PLAN's frontmatter"
  else
    case "$LEDGER_REL" in
      /*) LEDGER_PATH="$LEDGER_REL" ;;
      *)  LEDGER_PATH="$PROJ_ROOT/$LEDGER_REL" ;;
    esac
    if [ ! -f "$LEDGER_PATH" ]; then
      LEDGER_OK=0
      LEDGER_REASON="ledger file named in frontmatter does not exist: $LEDGER_PATH"
    fi
  fi

  printf '## Ledger\n'
  if [ "$LEDGER_OK" -eq 1 ]; then
    printf '   %s\n' "$LEDGER_PATH"
  else
    printf '   UNAVAILABLE — %s\n' "$LEDGER_REASON"
  fi
  printf '\n'

  # --- acceptance criteria ----------------------------------------------------
  local AC_SECTION_OK=1
  local AC_IDS="" AC_RECORD_IDS=""
  if has_section "$PLAN" '^## Acceptance criteria[[:space:]]*$'; then
    AC_IDS=$(section_after "$PLAN" '^## Acceptance criteria[[:space:]]*$' | grep -oE '^- AC-[0-9]+' | sed -E 's/^- //' | sort -u)
  else
    AC_SECTION_OK=0
  fi
  AC_RECORD_IDS=$(section_after "$PLAN" '^## Acceptance record[[:space:]]*$' | grep -oE '^AC-[0-9]+' | sort -u)

  # --- ledger items ------------------------------------------------------------
  local LEDGER_ROWS=""
  if [ "$LEDGER_OK" -eq 1 ]; then
    LEDGER_ROWS=$(ledger_items "$LEDGER_PATH")
  fi

  # --- task stanzas ------------------------------------------------------------
  # One TSV row per task: id, has-ledger-line, has-review-line, has-acceptance-line,
  # ledger-ids-value, acceptance-ids-value, has-outcome-line, outcome-closed.
  local TASK_ROWS
  # `fold` tracks which field a plain indented continuation line folds into
  # (ledger.sh's ledger_items() does the same for a [~] approval date on a
  # wrapped bullet) — 004's real "- Worker:" field is known to wrap across
  # lines, and nothing rules out "- Ledger items:"/"- Acceptance:" doing the
  # same. Any other recognized line, or a blank one, closes it. The heading
  # regex also accepts a colon after the task number ("### T2: title", a
  # plausible deviation from the template's em-dash) as well as the em-dash
  # form; either way $2 can carry a trailing colon, stripped below.
  TASK_ROWS=$(section_after "$PLAN" '^## Tasks[[:space:]]*$' | awk '
    /^### T[0-9]+([[:space:]:]|$)/ {
      if (id != "") emit()
      id = $2; sub(/:$/, "", id)
      hasledger=0; hasreview=0; hasacc=0; ledgerids=""; accids=""; hasoutcome=0; outcomeclosed=0
      fold=""
      next
    }
    id == "" { next }
    /^- Ledger items:/ {
      hasledger=1
      val=$0; sub(/^- Ledger items:[[:space:]]*/, "", val); gsub(/[[:space:]]+$/, "", val)
      ledgerids=val; fold="ledger"; next
    }
    /^- Review:/ { hasreview=1; fold=""; next }
    /^- Acceptance:/ {
      hasacc=1
      val=$0; sub(/^- Acceptance:[[:space:]]*/, "", val); gsub(/[[:space:]]+$/, "", val)
      accids=val; fold="acc"; next
    }
    /^- Outcome:/ {
      hasoutcome=1
      outcomeclosed = ($0 ~ /</) ? 0 : 1
      fold=""; next
    }
    /^-[[:space:]]/ { fold=""; next }
    fold != "" && /^[[:space:]]+[^[:space:]]/ {
      val=$0; sub(/^[[:space:]]+/, "", val); gsub(/[[:space:]]+$/, "", val)
      if (fold == "ledger") ledgerids = ledgerids " " val; else if (fold == "acc") accids = accids " " val
      next
    }
    { fold="" }
    END { if (id != "") emit() }
    function emit() {
      printf "%s\t%d\t%d\t%d\t%s\t%s\t%d\t%d\n", id, hasledger, hasreview, hasacc, ledgerids, accids, hasoutcome, outcomeclosed
    }
  ')

  # Union of ids every task claims, for the two orphan checks. `cut`, not a
  # shell `read` loop: a task missing Ledger items or Acceptance entirely —
  # exactly the untraced-task case — leaves that TSV field genuinely EMPTY,
  # and `IFS=$'\t' read` squeezes an empty middle field like any other run of
  # IFS whitespace (the 003 defect, same class session-tokens.sh guards
  # against with its own "-" fallback), silently shifting every field after
  # it left. `cut -f<n>` has no such collapsing behavior. Found by review.
  local CLAIMED_LEDGER_IDS="" CLAIMED_AC_IDS=""
  if [ -n "$TASK_ROWS" ]; then
    CLAIMED_LEDGER_IDS=$(printf '%s\n' "$TASK_ROWS" | cut -f5 | while IFS= read -r lids; do split_ids "$lids"; done | sort -u)
    CLAIMED_AC_IDS=$(printf '%s\n' "$TASK_ROWS" | cut -f6 | while IFS= read -r aids; do split_ids "$aids"; done | sort -u)
  fi

  # --- orphan criterion --------------------------------------------------------
  printf '## Orphan criteria\n'
  if [ "$AC_SECTION_OK" -eq 0 ]; then
    printf '   UNAVAILABLE — no ## Acceptance criteria section in %s\n' "$PLAN"
  elif [ -z "$AC_IDS" ]; then
    printf '   clean — no acceptance criteria defined\n'
  else
    ORPHAN_CRIT=$(comm -23 <(printf '%s\n' "$AC_IDS") <(printf '%s\n' "$CLAIMED_AC_IDS"))
    if [ -z "$ORPHAN_CRIT" ]; then
      printf '   clean — every acceptance criterion is cited by a task\n'
    else
      printf '   cited by no task: %s\n' "$(printf '%s\n' "$ORPHAN_CRIT" | tr '\n' ' ')"
    fi
  fi
  printf '\n'

  # --- unproven criterion -------------------------------------------------------
  printf '## Unproven criteria\n'
  if [ "$AC_SECTION_OK" -eq 0 ]; then
    printf '   UNAVAILABLE — no ## Acceptance criteria section in %s\n' "$PLAN"
  elif [ -z "$AC_IDS" ]; then
    printf '   clean — no acceptance criteria defined\n'
  else
    UNPROVEN=$(comm -23 <(printf '%s\n' "$AC_IDS") <(printf '%s\n' "$AC_RECORD_IDS"))
    if [ -z "$UNPROVEN" ]; then
      printf '   clean — every acceptance criterion has a block in ## Acceptance record\n'
    else
      printf '   no block in ## Acceptance record: %s\n' "$(printf '%s\n' "$UNPROVEN" | tr '\n' ' ')"
    fi
  fi
  printf '\n'

  # --- orphan requirement --------------------------------------------------------
  printf '## Orphan requirements\n'
  if [ "$LEDGER_OK" -eq 0 ]; then
    printf '   UNAVAILABLE — %s\n' "$LEDGER_REASON"
  else
    LEDGER_IDS=$(printf '%s\n' "$LEDGER_ROWS" | awk -F'\t' '$1 != "-" && $1 != "" { print $1 }' | sort -u)
    if [ -z "$LEDGER_IDS" ]; then
      printf '   clean — no ledger items carry an id\n'
    else
      ORPHAN_REQ=$(comm -23 <(printf '%s\n' "$LEDGER_IDS") <(printf '%s\n' "$CLAIMED_LEDGER_IDS"))
      if [ -z "$ORPHAN_REQ" ]; then
        printf '   clean — every ledger item with an id is claimed by a task\n'
      else
        printf '   claimed by no task: %s\n' "$(printf '%s\n' "$ORPHAN_REQ" | tr '\n' ' ')"
      fi
    fi
  fi
  printf '\n'

  # --- untraced / unclosed tasks --------------------------------------------------
  printf '## Untraced tasks\n'
  if [ -z "$TASK_ROWS" ]; then
    printf '   clean — no tasks found under ## Tasks\n'
  else
    UNTRACED=$(printf '%s\n' "$TASK_ROWS" | while IFS=$'\t' read -r tid hl hr ha _ _ _ _; do
      missing=""
      [ "$hl" -eq 0 ] && missing="${missing}Ledger items, "
      [ "$hr" -eq 0 ] && missing="${missing}Review, "
      [ "$ha" -eq 0 ] && missing="${missing}Acceptance, "
      [ -n "$missing" ] && printf '   %s — missing: %s\n' "$tid" "${missing%, }"
    done)
    if [ -z "$UNTRACED" ]; then
      printf '   clean — every task has Ledger items, Review and Acceptance as a line\n'
    else
      printf '%s\n' "$UNTRACED"
    fi
  fi
  printf '\n'

  printf '## Unclosed tasks\n'
  if [ -z "$TASK_ROWS" ]; then
    printf '   clean — no tasks found under ## Tasks\n'
  else
    # cut, not a positional read spanning fields 5-6 (ledgerids/accids): a task
    # missing BOTH those fields (T2-shaped — no Ledger items, no Acceptance
    # line at all) leaves two consecutive empty TSV fields, and `IFS=$'\t'
    # read` squeezes them, shifting ho/oc left and corrupting this exact
    # check. Same defect class as CLAIMED_LEDGER_IDS above, different call
    # site — found by hand-testing the fix for the first one against scenario
    # E's T2, not by the review that found the original.
    UNCLOSED=$(printf '%s\n' "$TASK_ROWS" | cut -f1,7,8 | while IFS=$'\t' read -r tid ho oc; do
      if [ "$ho" -eq 0 ]; then
        printf '   %s — no Outcome line\n' "$tid"
      elif [ "$oc" -eq 0 ]; then
        printf '   %s — Outcome still carries a template <...> placeholder\n' "$tid"
      fi
    done)
    if [ -z "$UNCLOSED" ]; then
      printf '   clean — every task has a filled-in Outcome\n'
    else
      printf '%s\n' "$UNCLOSED"
    fi
  fi
  printf '\n'

  # --- unapproved deferral ---------------------------------------------------
  printf '## Unapproved deferrals\n'
  if [ "$LEDGER_OK" -eq 0 ]; then
    printf '   UNAVAILABLE — %s\n' "$LEDGER_REASON"
  else
    DEFERRED=$(printf '%s\n' "$LEDGER_ROWS" | awk -F'\t' '$2 == "deferred"')
    if [ -z "$DEFERRED" ]; then
      printf '   clean — no deferred items\n'
    else
      UNAPPROVED=$(printf '%s\n' "$DEFERRED" | while IFS=$'\t' read -r did _ dtext; do
        date=$(ledger_deferred_date "$dtext")
        if [ -z "$date" ]; then
          label="$did"
          [ "$label" = "-" ] && label="$(printf '%s' "$dtext" | cut -c1-60)..."
          printf '   %s — no approval date in: %s\n' "$label" "$(printf '%s' "$dtext" | cut -c1-80)"
        fi
      done)
      if [ -z "$UNAPPROVED" ]; then
        printf '   clean — every deferred item carries an approval date\n'
      else
        printf '%s\n' "$UNAPPROVED"
      fi
    fi
  fi
}

# --- self-test ---------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
  T=$(mktemp -d) || die "cannot make a temp dir"
  trap 'rm -rf "$T"' EXIT

  fail() { printf 'self-test FAIL: %s\n' "$1" >&2; printf '%s\n' "${OUT:-}" >&2; exit 1; }

  # --- scenario A: clean ------------------------------------------------------
  mkdir -p "$T/a/docs/plans"
  cat > "$T/a/docs/plans/001-clean.md" <<'EOF'
status: active
date: 2026-01-01
ledger: docs/LEDGER-clean.md
target version: 1.0.0

# 001 — clean

## Goal

A round with nothing to report.

## Acceptance criteria

- AC-1 a user sees the thing
- AC-2 a user without it does not

## Tasks

### T1 — do the thing

- Worker: builder
- Review: reviewer
- Depends on: —
- Ledger items: E1, E2
- Acceptance: AC-1, AC-2

- Outcome: shipped, both criteria demonstrated.

## Acceptance record

```text
AC-1: "a user sees the thing"
  ran: it
  observed: it happened                                       [PASS]

AC-2: "a user without it does not"
  ran: it
  observed: it did not happen                                 [PASS]
```
EOF
  cat > "$T/a/docs/LEDGER-clean.md" <<'EOF'
# Ledger
- E1 [x] first requirement
- E2 [x] second requirement

## Deferred

- [~] something deferred, approved 2026-01-01
EOF

  # --- scenario B: broken (orphan criterion, orphan requirement, unapproved deferral) --
  mkdir -p "$T/b/docs/plans"
  cat > "$T/b/docs/plans/002-broken.md" <<'EOF'
status: active
date: 2026-01-01
ledger: docs/LEDGER-broken.md
target version: 1.0.0

# 002 — broken

## Goal

A round with real gaps.

## Acceptance criteria

- AC-1 a user sees the thing
- AC-2 a user without it does not

## Tasks

### T1 — do the thing

- Worker: builder
- Review: reviewer
- Depends on: —
- Ledger items: E1
- Acceptance: AC-1

- Outcome: shipped, AC-1 demonstrated.

## Acceptance record

```text
AC-1: "a user sees the thing"
  ran: it
  observed: it happened                                       [PASS]
```
EOF
  cat > "$T/b/docs/LEDGER-broken.md" <<'EOF'
# Ledger
- E1 [x] first requirement, cited
- E2 [x] second requirement, cited by nothing

## Deferred

- [~] something deferred with no recorded date
EOF

  # --- scenario C: zero active plans -----------------------------------------
  mkdir -p "$T/c/docs/plans"
  cat > "$T/c/docs/plans/003-draft.md" <<'EOF'
status: draft
date: 2026-01-01
ledger: docs/LEDGER-draft.md
target version: 1.0.0

# 003 — draft
EOF

  # --- scenario D: two active plans, and the first is missing pieces gracefully --
  mkdir -p "$T/d/docs/plans"
  cat > "$T/d/docs/plans/004-a.md" <<'EOF'
status: active
date: 2026-01-01
target version: 1.0.0

# 004 — a, no ledger line, no acceptance criteria section
EOF
  cat > "$T/d/docs/plans/005-b.md" <<'EOF'
status: active
date: 2026-01-01
target version: 1.0.0

# 005 — b, also active
EOF

  # --- scenario E: decoy heading, wrapped fields, colon-headed task, squeeze --
  # Everything found by independent review in one fixture: a decoy
  # "## Acceptance criteria draft" section before the real one (must not leak
  # its AC-9 anywhere); T1's Ledger items and Acceptance both wrap onto a
  # continuation line (must still be read whole, not truncated); T2 uses a
  # colon after its number instead of the template's em-dash (must still be
  # recognized as its own task, not folded into T1); and T2 has NEITHER a
  # Ledger items NOR an Acceptance line at all, so those TSV fields are
  # genuinely empty — the exact shape that broke the old `IFS=$'\t' read`
  # extraction (an empty middle field silently swallowed, everything after it
  # shifted left) and must now report T2, and only T2, as untraced.
  mkdir -p "$T/e/docs/plans"
  cat > "$T/e/docs/plans/006-decoys.md" <<'EOF'
status: active
date: 2026-01-01
ledger: docs/LEDGER-e.md
target version: 1.0.0

# 006 — decoys and edge cases

## Acceptance criteria draft

- AC-9 a decoy criterion that must never be reported

## Acceptance criteria

- AC-1 a user sees the thing
- AC-2 a user without it does not
- AC-3 cited only by a task with no Ledger items field at all

## Tasks

### T1 — wraps its fields across lines

- Worker: builder
- Review: reviewer
- Depends on: —
- Ledger items: E1,
  E2
- Acceptance: AC-1,
  AC-2

- Outcome: shipped, both criteria demonstrated.

### T2: colon-headed, no ledger items or acceptance field at all

- Worker: builder
- Review: reviewer
- Depends on: —

- Outcome: shipped, nothing of its own to trace.

### T3 — has Acceptance but no Ledger items field

- Worker: builder
- Review: reviewer
- Depends on: —
- Acceptance: AC-3

- Outcome: shipped, AC-3 demonstrated.

## Acceptance record

AC-1: "a user sees the thing"
  ran: it
  observed: it happened                                       [PASS]

AC-2: "a user without it does not"
  ran: it
  observed: it did not happen                                 [PASS]

AC-3: "cited only by a task with no Ledger items field at all"
  ran: it
  observed: it happened                                       [PASS]
EOF
  cat > "$T/e/docs/LEDGER-e.md" <<'EOF'
# Ledger
- E1 [x] first requirement
- E2 [x] second requirement
EOF

  BEFORE=$(find "$T" -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(wc -c <"$f")"; done)

  # A — clean
  OUT=$(CLAUDE_PROJECT_DIR="$T/a" DOCS=docs "$0" docs/plans/001-clean.md 2>&1) \
    || fail "scenario A exited non-zero"
  printf '%s' "$OUT" | grep -q 'clean — every acceptance criterion is cited by a task' \
    || fail "A: orphan criteria should be clean"
  printf '%s' "$OUT" | grep -q 'clean — every acceptance criterion has a block' \
    || fail "A: unproven criteria should be clean"
  printf '%s' "$OUT" | grep -q 'clean — every ledger item with an id is claimed by a task' \
    || fail "A: orphan requirements should be clean"
  printf '%s' "$OUT" | grep -q 'clean — every task has Ledger items, Review and Acceptance' \
    || fail "A: untraced tasks should be clean"
  printf '%s' "$OUT" | grep -q 'clean — every task has a filled-in Outcome' \
    || fail "A: unclosed tasks should be clean"
  printf '%s' "$OUT" | grep -q 'clean — every deferred item carries an approval date' \
    || fail "A: unapproved deferrals should be clean"
  printf '%s' "$OUT" | grep -qi 'UNAVAILABLE' && fail "A: a clean, fully-specified plan should report no UNAVAILABLE"

  # B — broken
  OUT=$(CLAUDE_PROJECT_DIR="$T/b" DOCS=docs "$0" docs/plans/002-broken.md 2>&1) \
    || fail "scenario B exited non-zero"
  printf '%s' "$OUT" | awk '/^## Orphan criteria/{f=1;next} /^## /{f=0} f' | grep -q 'AC-2' \
    || fail "B: AC-2 should be an orphan criterion"
  printf '%s' "$OUT" | awk '/^## Orphan requirements/{f=1;next} /^## /{f=0} f' | grep -q 'E2' \
    || fail "B: E2 should be an orphan requirement"
  printf '%s' "$OUT" | awk '/^## Unapproved deferrals/{f=1;next} /^## /{f=0} f' | grep -qi 'no approval date' \
    || fail "B: the undated deferral should be named"

  # C — zero active plans
  OUT=$(CLAUDE_PROJECT_DIR="$T/c" DOCS=docs "$0" 2>&1)
  RC=$?
  [ "$RC" -eq 0 ] || fail "scenario C should exit 0, got $RC"
  printf '%s' "$OUT" | grep -q '^## Active plan$' || fail "C: missing Active plan heading"
  printf '%s' "$OUT" | grep -q 'none found under docs/plans — nothing to trace' \
    || fail "C: zero-active message wrong"

  # D — two active plans
  OUT=$(CLAUDE_PROJECT_DIR="$T/d" DOCS=docs "$0" 2>&1) || fail "scenario D exited non-zero"
  printf '%s' "$OUT" | grep -q 'plans marked active' || fail "D: ambiguity not reported"
  printf '%s' "$OUT" | grep -q 'docs/plans/004-a.md' || fail "D: first active plan not named"
  printf '%s' "$OUT" | grep -q 'docs/plans/005-b.md' || fail "D: second active plan not named"
  printf '%s' "$OUT" | grep -q 'analyzing the first' || fail "D: did not say which one it analyzes"
  printf '%s' "$OUT" | grep -qi 'UNAVAILABLE — no .* Acceptance criteria section' \
    || fail "D: an old-shape active plan should degrade to UNAVAILABLE, not crash"
  printf '%s' "$OUT" | grep -qi "UNAVAILABLE — no 'ledger:' line" \
    || fail "D: a plan with no ledger: frontmatter should degrade to UNAVAILABLE, not crash"

  # E — decoy heading, wrapped fields, colon-headed task, squeeze (all found by review)
  OUT=$(CLAUDE_PROJECT_DIR="$T/e" DOCS=docs "$0" docs/plans/006-decoys.md 2>&1) \
    || fail "scenario E exited non-zero"
  printf '%s' "$OUT" | grep -q 'AC-9' \
    && fail "E: the decoy '## Acceptance criteria draft' section leaked AC-9 into the report"
  # AC-3 is cited ONLY by T3, whose row has an EMPTY Ledger-items field (5)
  # immediately before its real Acceptance field (6) — the exact shape that
  # shifts a real value into the wrong read position under the unfixed
  # `IFS=$'\t' read _ _ _ _ _ aids _ _`, losing AC-3's citation entirely and
  # reporting it as a false orphan. This is the reviewer's #1 finding,
  # reproduced precisely rather than incidentally.
  printf '%s' "$OUT" | grep -q 'clean — every acceptance criterion is cited by a task' \
    || fail "E: orphan criteria should be clean (AC-1/AC-2 via T1's wrapped line, AC-3 via T3 despite its empty Ledger-items field)"
  printf '%s' "$OUT" | grep -q 'clean — every acceptance criterion has a block' \
    || fail "E: unproven criteria should be clean"
  printf '%s' "$OUT" | grep -q 'clean — every ledger item with an id is claimed by a task' \
    || fail "E: orphan requirements should be clean (E1/E2 both cited by T1, wrapped line included)"
  UNTRACED_E=$(printf '%s' "$OUT" | awk '/^## Untraced tasks/{f=1;next} /^## /{f=0} f')
  printf '%s\n' "$UNTRACED_E" | grep -q 'T1' \
    && fail "E: T1 wrongly reported untraced — its own fields must not be corrupted by T2/T3's empty fields"
  printf '%s\n' "$UNTRACED_E" | grep -q 'T2' \
    || fail "E: T2 (colon-headed) should be recognized as its own task and reported untraced"
  printf '%s\n' "$UNTRACED_E" | grep -qE 'T2.*Ledger items' \
    || fail "E: T2 is missing Ledger items and should say so"
  printf '%s\n' "$UNTRACED_E" | grep -qE 'T2.*Acceptance' \
    || fail "E: T2 is missing Acceptance and should say so"
  printf '%s\n' "$UNTRACED_E" | grep -qE 'T3.*Ledger items' \
    || fail "E: T3 is missing Ledger items and should say so"
  printf '%s\n' "$UNTRACED_E" | grep -qE 'T3.*Acceptance' \
    && fail "E: T3 HAS an Acceptance field — it must not be reported missing"
  # T2's two consecutive empty fields (ledgerids, accids) are exactly what
  # squeezes ho/oc leftward in an unfixed `IFS=$'\t' read` — this must not
  # leak a bash arithmetic error, and all three tasks have a real Outcome line.
  printf '%s' "$OUT" | grep -q 'integer expression expected' \
    && fail "E: unclosed-tasks check crashed (ho/oc squeezed left by T2's empty fields)"
  printf '%s' "$OUT" | grep -q 'clean — every task has a filled-in Outcome' \
    || fail "E: unclosed tasks should be clean — T1, T2 and T3 all have a real Outcome line"

  AFTER=$(find "$T" -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(wc -c <"$f")"; done)
  [ "$BEFORE" = "$AFTER" ] || fail "the reader modified its fixture tree"

  printf 'self-test OK — clean round, orphan criterion, orphan requirement, unapproved\n'
  printf 'deferral, zero active plans, two active plans (with graceful UNAVAILABLE on an\n'
  printf 'old-shape plan), decoy heading, wrapped fields, colon-headed task, empty-field\n'
  printf 'squeeze, fixtures left untouched\n'
  exit 0
fi

[ -n "$PLAN" ] || die "no plan resolved — this should not happen"
report "$PLAN"
