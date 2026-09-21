#!/usr/bin/env bash
# Report a plan's wave boundaries and which of them are clean break points.
#
# The rule lives in .claude/skills/plan/SKILL.md step 4; this script is the
# executable form of it, so the chair does not derive it by hand at every
# confirmation and so a change to the rule has something to fail against.
#
#   .claude/scripts/break-points.sh docs/plans/010-chunked-execution.md
#   .claude/scripts/break-points.sh --all
#   .claude/scripts/break-points.sh --self-test
#
# Exit 0 always for a report; --self-test exits non-zero on failure.

set -uo pipefail

report() {
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]
t = None; dep = {}; acc = {}; led = {}
for line in open(p):
    m = re.match(r'^### (T\d+)', line)
    if m:
        t = m.group(1); dep.setdefault(t, []); acc.setdefault(t, set()); led.setdefault(t, set())
    if not t:
        continue
    # "Depends on: decision 1 (closed - ...)" names no task and is not an edge.
    if line.startswith('- Depends on:'): dep[t] = re.findall(r'\bT\d+\b', line)
    if line.startswith('- Acceptance:'):   acc[t] = set(re.findall(r'AC-\d+', line))
    if line.startswith('- Ledger items:'): led[t] = set(re.findall(r'\b[EIX]\d+\b', line))

name = p.split('/')[-1]
if not dep:
    print(f"{name}: no tasks found"); sys.exit(0)

wave = {}
for _ in range(len(dep) + 1):
    for k, d in dep.items():
        d = [x for x in d if x in dep]          # drop non-task dependencies
        if not d: wave[k] = 1
        elif all(x in wave for x in d): wave[k] = max(wave[x] for x in d) + 1
if len(wave) != len(dep):
    print(f"{name}: dependency cycle or unknown task — cannot derive waves"); sys.exit(0)

depth = max(wave.values())
shape = " / ".join("{%s}" % ",".join(sorted((x for x in wave if wave[x] == i),
                                            key=lambda s: int(s[1:]))) for i in range(1, depth + 1))
print(f"{name}\n  waves: {shape}")
if depth < 2:
    print("  no wave boundary — nothing to offer"); sys.exit(0)

# A plan carrying neither field is unchecked by the second disqualifier, not cleared by it.
unchecked = not any(acc.values()) and not any(led.values())
clean = 0; total = 0
for k in range(1, depth):
    wk = {x for x in wave if wave[x] == k}
    later = [x for x in wave if wave[x] > k]
    if not any(set(dep[x]) & wk for x in later):
        continue                                  # no edge crosses here
    total += 1
    label = max((x for x in wk if any(x in dep[y] for y in later)), key=lambda s: int(s[1:]))
    before_a = set().union(*[acc[x] for x in wave if wave[x] <= k])
    after_a  = set().union(*[acc[x] for x in later])
    before_l = set().union(*[led[x] for x in wave if wave[x] <= k])
    after_l  = set().union(*[led[x] for x in later])
    span = sorted(before_a & after_a) + sorted(before_l & after_l)
    if span:
        print(f"  after {label:<4} NOT A BREAK POINT — spans {', '.join(span)}")
    else:
        clean += 1
        print(f"  after {label:<4} clean break point" + ("  (UNCHECKED: plan states no Acceptance or Ledger items)" if unchecked else ""))
print(f"  {clean} clean of {total} boundaries")
PY
}

case "${1:-}" in
  --all)
    for f in docs/plans/[0-9]*.md; do [ -f "$f" ] && report "$f"; done ;;
  --self-test)
    # Fixtures assert the rule, not any one plan: a plan's own text may change.
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; P=0; F=0
    mk() { printf '%s' "$2" > "$TMP/$1"; }
    check() { if printf '%s' "$2" | grep -q -- "$3"; then P=$((P+1)); printf 'ok   %s\n' "$1"
              else F=$((F+1)); printf 'FAIL %s\n  wanted: %s\n  got: %s\n' "$1" "$3" "$2"; fi; }

    mk clean.md '### T1
- Depends on: —
- Ledger items: E1
- Acceptance: AC-1
### T2
- Depends on: T1
- Ledger items: E2
- Acceptance: AC-2
'
    check "disjoint fields give a clean break" "$(report "$TMP/clean.md")" "after T1   clean break point"

    mk acspan.md '### T1
- Depends on: —
- Ledger items: E1
- Acceptance: AC-1
### T2
- Depends on: T1
- Ledger items: E2
- Acceptance: AC-1
'
    check "a shared AC-n disqualifies" "$(report "$TMP/acspan.md")" "NOT A BREAK POINT — spans AC-1"

    mk ledspan.md '### T1
- Depends on: —
- Ledger items: E1
- Acceptance: AC-1
### T2
- Depends on: T1
- Ledger items: E1
- Acceptance: AC-2
'
    check "a shared ledger item disqualifies (AC-n disjoint)" \
      "$(report "$TMP/ledspan.md")" "NOT A BREAK POINT — spans E1"

    mk nondep.md '### T1
- Depends on: —
- Ledger items: E1
- Acceptance: AC-1
### T2
- Depends on: decision 1 (closed — see Decisions)
- Ledger items: E2
- Acceptance: AC-2
'
    check "a non-task Depends on is not an edge" "$(report "$TMP/nondep.md")" "no wave boundary"

    mk dash.md '### T1
- Depends on: —
- Ledger items: E1
- Acceptance: —
### T2
- Depends on: T1
- Ledger items: E2
- Acceptance: —
'
    check "an em-dash field claims nothing" "$(report "$TMP/dash.md")" "after T1   clean break point"

    mk bare.md '### T1
- Depends on: —
### T2
- Depends on: T1
'
    check "neither field anywhere reports UNCHECKED" "$(report "$TMP/bare.md")" "UNCHECKED"

    mk trailer.md '### T1
- Depends on: —
- Ledger items: E1
### T2
- Depends on: —
- Ledger items: E2
### T5
- Depends on: —
- Ledger items: E5
### T3
- Depends on: T2
- Ledger items: E3
'
    check "label is the depended-on task, not the last id in the wave" \
      "$(report "$TMP/trailer.md")" "after T2"

    printf '\n%d passed, %d failed\n' "$P" "$F"
    [ "$F" -eq 0 ] ;;
  "")
    printf 'usage: %s <plan.md> | --all | --self-test\n' "$0" >&2; exit 2 ;;
  *)
    report "$1" ;;
esac
