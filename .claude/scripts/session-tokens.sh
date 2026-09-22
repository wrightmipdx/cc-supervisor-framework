#!/usr/bin/env bash
# What one session actually cost, split by lane, with each expensive dispatch
# shown next to what it returned.
#
#   .claude/scripts/session-tokens.sh [session-id]   # newest for this cwd if omitted
#   .claude/scripts/session-tokens.sh --self-test
#
# WHY THE TRANSCRIPT AND NOT A HOOK. Agents launch asynchronously on this Claude
# Code version: `Task` returns a receipt, not a report, so no hook payload ever
# contains a worker's output. docs/METRICS.md weighed three routes for token
# cost and called the local transcript "the only route that answers 'which
# opus'". It is, and it needs no new plumbing:
#
#   ~/.claude/projects/<slug>/<session>.jsonl                    main thread
#   ~/.claude/projects/<slug>/<session>/subagents/agent-*.jsonl  one per worker
#
# Each worker file carries per-turn `usage` AND the SubagentHandback the hook
# cannot see — the report, sitting next to the tokens that say what it cost.
#
# NEITHER SOURCE IS ENOUGH ALONE. A worker file is anonymous: the transcript
# does not know a run's role, its tier or its task id. The event log knows
# exactly that and nothing about cost. `agent_id` joins them, captured by
# 60-dispatch-end.sh out of the launch receipt.
#
# UNLIKE A HOOK, THIS FAILS LOUDLY. It runs because a human asked. Where a
# transcript is missing it says UNAVAILABLE and why, and never prints a zero it
# cannot stand behind.
#
# Reads only. Writes nothing outside $TMPDIR. Never prints brief, report,
# finding or diff text — counts and verdicts, the same rule as the event log.
#
# Dependencies: jq and git, the same as the hooks.

set -uo pipefail

die() { printf 'session-tokens: %s\n' "$1" >&2; exit 1; }
unavailable() { printf '   UNAVAILABLE — %s\n' "$1"; exit 0; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- rates -------------------------------------------------------------------
# List price per million tokens: input, output, cache read, cache write (5m).
#
# AN ASSUMPTION, DELIBERATELY VISIBLE. Tokens are what a rolling usage limit
# actually consumes, so tokens are what this report leads with and what the
# plan's criteria are written against. But a tiering decision is only legible in
# money — a haiku token and an opus token are identical against a turn count and
# 150x apart against a bill.
#
# These are LIST prices and subscription accounting is not list price. Checked
# against one real session's own cost readout, this table reproduced the Fable
# line almost exactly ($23.37 modelled vs $23.93 reported) and priced Opus about
# 1.8x what the client displayed. So: absolute dollars here are an estimate, and
# the SHARES between lanes are what carry a decision. The report ranks on shares
# and prints the date below on every run, because a stale rate table making a
# tiering decision two years from now is the failure this line exists to stop.
RATES_ASOF="2026-09-19"
rates_for() {  # rates_for <model> -> "in out cache_read cache_write" per Mtok
  case "$1" in
    *opus*)   printf '15 75 1.5 18.75' ;;
    *sonnet*) printf '3 15 0.3 3.75'   ;;
    *fable*)  printf '5 25 0.5 6.25'   ;;
    *haiku*)  printf '1 5 0.1 1.25'    ;;
    *)        printf '0 0 0 0'         ;;  # unpriced: tokens still counted
  esac
}
tier_of() {
  case "$1" in
    *opus*) printf opus ;; *sonnet*) printf sonnet ;;
    *fable*) printf fable ;; *haiku*) printf haiku ;; *) printf other ;;
  esac
}

# --- locate ------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" || ROOT="$PWD"
PROJ_ROOT="${CLAUDE_PROJECT_DIR:-$ROOT}"
METRICS_DIR="${METRICS_DIR:-$PROJ_ROOT/.metrics}"

# The transcript directory name is the project path with every `/` and `.`
# flattened to `-`, including the leading slash.
slug_of() { printf '%s' "$1" | sed 's|[/.]|-|g'; }
TRANSCRIPTS="${CLAUDE_TRANSCRIPT_DIR:-$HOME/.claude/projects/$(slug_of "$PROJ_ROOT")}"

SELFTEST=0
SESSION=""
for a in "$@"; do
  case "$a" in
    --self-test) SELFTEST=1 ;;
    -*) die "unknown option: $a" ;;
    *) SESSION="$a" ;;
  esac
done

# --- extraction --------------------------------------------------------------
# One TSV row per assistant turn. STREAMED, never slurped: the largest real
# session transcript measured so far is 17MB and `jq -s` on that is a needless
# resident copy.
emit_usage() {  # emit_usage <lane> <run-key> <file>
  jq -c -r --arg lane "$1" --arg run "$2" '
    select(.type == "assistant" and (.message.usage != null))
    | [ $lane, $run,
        (.requestId // .uuid // "-"),
        (.message.model // "unknown"),
        (.message.usage.input_tokens // 0),
        (.message.usage.output_tokens // 0),
        (.message.usage.cache_read_input_tokens // 0),
        (.message.usage.cache_creation_input_tokens // 0),
        (.timestamp // "-") ]
    | @tsv' "$3" 2>/dev/null || true
}
# The dedupe key is emitted as "-" rather than "" when a row carries neither a
# requestId nor a uuid. AN EMPTY FIELD CANNOT SURVIVE THE READ LOOP: `read` with
# IFS set to a tab still applies the IFS-whitespace rule, so a run of tabs
# collapses to one delimiter and every field after the empty one shifts left. A
# 25-output-token turn then priced as if `output_tokens` were the model name.
# Found by the 0.4.2 self-test; latent since the reader was written.
# `.timestamp` (appended last, field 9, never inserted mid-row) is real ISO
# 8601 on every assistant turn in a real transcript; "-" is only a fixture/
# malformed-row fallback, kept for the same reason as `rid` above.

# The agentId a worker file belongs to — the join key back to the event log.
agent_id_of() { jq -r -c 'select(.agentId != null) | .agentId' "$1" 2>/dev/null | head -1; }

# Verdict and finding counts from the run's SubagentHandback. Reads the
# documented report contract only — `## Verdict:` and `- [blocker]` — exactly
# the format 60-dispatch-end.sh used to parse before async launch put the report
# out of a hook's reach. COUNTS AND VERDICT, NEVER THE FINDING TEXT.
verdict_of() {  # -> "verdict blockers should_fix nits evidence"
  local report v b s n e
  report=$(jq -r -c '
      select(.type == "assistant")
      | .message.content[]?
      | select(type == "object" and .type == "tool_use" and .name == "SubagentHandback")
      | (.input.message // .input.report // (.input | tostring))' "$1" 2>/dev/null) || report=""
  if [ -z "$report" ]; then printf 'no-handback 0 0 0 false'; return 0; fi
  v=none
  case "$(printf '%s' "$report" | grep -i -m1 'Verdict:' || true)" in
    *[Bb][Ll][Oo][Cc][Kk]*)              v=block ;;
    *[Ff][Ii][Xx]*[Ff][Ii][Rr][Ss][Tt]*) v=fix_first ;;
    *[Ss][Hh][Ii][Pp]*)                  v=ship ;;
  esac
  b=$(printf '%s' "$report" | grep -c '\[blocker\]'    || true)
  s=$(printf '%s' "$report" | grep -c '\[should-fix\]' || true)
  n=$(printf '%s' "$report" | grep -c '\[nit\]'        || true)
  e=false
  printf '%s' "$report" | grep -qi 'Evidence' && e=true
  printf '%s %s %s %s %s' "$v" "${b:-0}" "${s:-0}" "${n:-0}" "$e"
}

# --- self-test ---------------------------------------------------------------
# Hermetic: fixtures under $TMPDIR, and it asserts it left them and nothing else
# behind. The 0.3.2 lesson — a suite that leans on the real environment either
# fails somewhere else or corrupts it, and both happened.
if [ "$SELFTEST" -eq 1 ]; then
  T=$(mktemp -d) || die "cannot make a temp dir"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/proj" "$T/tx/sess-1/subagents"
  cat > "$T/tx/sess-1.jsonl" <<'FIX'
{"type":"assistant","requestId":"r1","timestamp":"2026-09-19T01:05:00.000Z","message":{"model":"claude-fable-5-1","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"r1","timestamp":"2026-09-19T01:05:00.000Z","message":{"model":"claude-fable-5-1","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0}}}
{"type":"user","message":{"role":"user","content":"ignored"}}
FIX
  cat > "$T/tx/sess-1/subagents/agent-abc123def456.jsonl" <<'FIX'
{"type":"user","isSidechain":true,"agentId":"abc123def456","message":{"role":"user","content":"brief"}}
{"type":"assistant","requestId":"w1","agentId":"abc123def456","timestamp":"2026-09-19T01:15:05.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":50,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0}}}
{"type":"assistant","agentId":"abc123def456","timestamp":"2026-09-19T01:15:10.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":25,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"w2","agentId":"abc123def456","timestamp":"2026-09-19T01:20:00.000Z","message":{"model":"claude-opus-5","content":[{"type":"thinking","thinking":"..."}],"usage":{"input_tokens":5,"output_tokens":4,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"w2","agentId":"abc123def456","timestamp":"2026-09-19T01:20:01.000Z","message":{"model":"claude-opus-5","content":[{"type":"tool_use","name":"SubagentHandback","input":{"message":"## Verdict: FIX FIRST\n## Findings\n- [blocker] a.ts:1 - boom - fix it\n- [nit] b.ts:2 - meh - tidy\n## Evidence\nran the tests"}}],"usage":{"input_tokens":5,"output_tokens":50,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0}}}
FIX
  # A /clear leaves this: a real transcript, newer, with no billed turns. The
  # reader must skip it — picking it reports "nothing happened" about a session
  # where plenty did.
  cat > "$T/tx/sess-2-cleared.jsonl" <<'FIX'
{"type":"mode","mode":"normal","sessionId":"sess-2-cleared"}
{"type":"file-history-snapshot","messageId":"x","snapshot":{"trackedFileBackups":{}}}
FIX
  touch "$T/tx/sess-2-cleared.jsonl"

  mkdir -p "$T/proj/.metrics"
  # commit_landed x3, ordered to cover the three cases the plan requires:
  #   c3c3c3c3 — first event in the log, direct-lane, but its ts (00:50) is
  #     BEFORE the earliest priced main-lane turn (r1 @ 01:05) — the "commit
  #     landed before any priced turn" UNAVAILABLE case.
  #   c1c1c1c1 — direct-lane (still no dispatch event has been seen), window
  #     (00:50, 01:10] — catches r1 @ 01:05. A window WITH main-lane turns.
  #   c2c2c2c2 — direct-lane, window (01:10, 01:12] — catches nothing (r1
  #     already fell in the previous window). A window with none.
  # The dispatch/dispatch_launched/dispatch_end trio comes AFTER all three
  # commits, so none of them is preceded by a dispatch and all three stay
  # direct-lane; it still exists so the join/verdict assertions below hold.
  cat > "$T/proj/.metrics/session-sess-1.jsonl" <<'FIX'
{"event":"commit_landed","ts":"2026-09-19T00:50:00Z","session":"sess-1","head":"c3c3c3c3deadbeef","commit_type":"fix","files":1,"insertions":10}
{"event":"commit_landed","ts":"2026-09-19T01:10:00Z","session":"sess-1","head":"c1c1c1c1cafebabe","commit_type":"feat","files":2,"insertions":30}
{"event":"commit_landed","ts":"2026-09-19T01:12:00Z","session":"sess-1","head":"c2c2c2c2feedface","commit_type":"fix","files":1,"insertions":5}
{"event":"dispatch","ts":"2026-09-19T01:15:00Z","session":"sess-1","origin":"main","agent":"critic","tier":"opus","task":"T7","brief_bytes":100}
{"event":"dispatch_launched","ts":"2026-09-19T01:15:01Z","session":"sess-1","origin":"main","agent":"critic","agent_id":"abc123def456"}
{"event":"dispatch_end","ts":"2026-09-19T01:35:00Z","session":"sess-1","origin":"main","source":"subagent_stop","duration_s":1199}
FIX

  # A second, separate fixture: one commit, one preceding turn, and that
  # commit is the FIRST (and only) commit_landed in its own log — unlike
  # sess-1's c3c3c3c3, this one has a real turn before it and must NOT report
  # UNAVAILABLE. Used below to assert the IFS-tab squeeze stays fixed.
  mkdir -p "$T/proj2/.metrics" "$T/tx2"
  cat > "$T/tx2/sess-2.jsonl" <<'FIX'
{"type":"assistant","requestId":"z1","timestamp":"2026-09-19T00:30:00.000Z","message":{"model":"claude-fable-5-1","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
FIX
  cat > "$T/proj2/.metrics/session-sess-2.jsonl" <<'FIX'
{"event":"commit_landed","ts":"2026-09-19T01:00:00Z","session":"sess-2","head":"onlycommit00000","commit_type":"fix","files":1,"insertions":5}
FIX

  # plans/013-phase-accounting.md fixtures — "Main-thread turns by phase".
  #
  # sess-3: the rich case. Nine main-lane turns (110 billable tok each — i=10,
  # o=100 — so every phase total below is a clean multiple of 110, checkable
  # by eye) around a landmark sequence built to hit every required edge:
  #   - D1 is the session's FIRST landmark AND its `task` field is genuinely
  #     absent (X1's historical shape, generalized: an empty/omitted field at
  #     the very first landmark must not shift later columns — same class as
  #     the emit_usage IFS-tab squeeze, now against this block's own TSV).
  #   - D2 -> D2b -> C3, two dispatches inside ONE tainted stretch: D2's
  #     window must close using D2's OWN label at the instant D2b fires, not
  #     D2b's — state carried across the transition, not sandwiched (the
  #     second historical bug class, generalized).
  #   - D2b -> C3 land one turn-slot apart with NOTHING between them: a
  #     near-zero orchestration window that must still print "turns 0", not
  #     vanish or get folded into a neighbour (X4).
  #   - C3 -> D3 has two real turns with NO commit between them and D3 is
  #     alpha's... no, gamma's only dispatch, with no matching
  #     dispatch_launched at all: those two turns must land in D3's
  #     orchestration row (the tainted-span gap-absorption AC-2 forces, see
  #     the comment above price_main_range in the main script), and D3 must
  #     print "unjoined" rather than trust its own (unconfirmed) fields.
  #   - D4 is alpha's SECOND dispatch (occurrence tracking) AND the session's
  #     LAST landmark: its own window absorbs the C4->D4 gap (zero turns
  #     here) and the open tail after it (t6, t7) must price as close, not
  #     as more orchestration — the open-ended close tail.
  #   - C1->C2 is the one clean (untainted) inter-commit span: the ONLY turn
  #     in it must land in direct-lane, sourced from $TMP/windows verbatim
  #     (AC-2).
  mkdir -p "$T/proj3/.metrics" "$T/tx3"
  cat > "$T/tx3/sess-3.jsonl" <<'FIX'
{"type":"assistant","requestId":"q1","timestamp":"2026-09-19T02:00:00.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"q2","timestamp":"2026-09-19T02:00:20.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"q2b","timestamp":"2026-09-19T02:00:25.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"q3","timestamp":"2026-09-19T02:00:35.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"q3b","timestamp":"2026-09-19T02:00:43.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"q4","timestamp":"2026-09-19T02:00:50.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"q5","timestamp":"2026-09-19T02:00:58.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"q6","timestamp":"2026-09-19T02:01:20.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","requestId":"q7","timestamp":"2026-09-19T02:01:30.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
FIX
  cat > "$T/proj3/.metrics/session-sess-3.jsonl" <<'FIX'
{"event":"dispatch","ts":"2026-09-19T02:00:10Z","session":"sess-3","origin":"main","agent":"alpha","tier":"sonnet","brief_bytes":10}
{"event":"dispatch_launched","ts":"2026-09-19T02:00:11Z","session":"sess-3","origin":"main","agent":"alpha","agent_id":"aaaa1111"}
{"event":"commit_landed","ts":"2026-09-19T02:00:30Z","session":"sess-3","head":"c1111111aaaa","commit_type":"fix","files":1,"insertions":1}
{"event":"commit_landed","ts":"2026-09-19T02:00:40Z","session":"sess-3","head":"c2222222bbbb","commit_type":"fix","files":1,"insertions":1}
{"event":"dispatch","ts":"2026-09-19T02:00:41Z","session":"sess-3","origin":"main","agent":"beta","tier":"haiku","task":"T2","brief_bytes":10}
{"event":"dispatch_launched","ts":"2026-09-19T02:00:41Z","session":"sess-3","origin":"main","agent":"beta","agent_id":"bbbb1111"}
{"event":"dispatch","ts":"2026-09-19T02:00:44Z","session":"sess-3","origin":"main","agent":"delta","tier":"fable","task":"T2b","brief_bytes":10}
{"event":"dispatch_launched","ts":"2026-09-19T02:00:44Z","session":"sess-3","origin":"main","agent":"delta","agent_id":"dddd1111"}
{"event":"commit_landed","ts":"2026-09-19T02:00:45Z","session":"sess-3","head":"c3333333cccc","commit_type":"fix","files":1,"insertions":1}
{"event":"dispatch","ts":"2026-09-19T02:00:55Z","session":"sess-3","origin":"main","agent":"gamma","tier":"opus","task":"T3","brief_bytes":10}
{"event":"commit_landed","ts":"2026-09-19T02:01:00Z","session":"sess-3","head":"c4444444dddd","commit_type":"fix","files":1,"insertions":1}
{"event":"dispatch","ts":"2026-09-19T02:01:05Z","session":"sess-3","origin":"main","agent":"alpha","tier":"sonnet","task":"T4","brief_bytes":10}
{"event":"dispatch_launched","ts":"2026-09-19T02:01:06Z","session":"sess-3","origin":"main","agent":"alpha","agent_id":"aaaa2222"}
FIX

  # sess-4: X1 generalized — a dispatch (the session's only landmark) lands
  # before any priced main-lane turn, so `setup` cannot know what preceded
  # it. UNAVAILABLE for that phase specifically, not a wrong 0 and not a
  # crash on the rest of the block.
  mkdir -p "$T/proj4/.metrics" "$T/tx4"
  cat > "$T/tx4/sess-4.jsonl" <<'FIX'
{"type":"assistant","requestId":"u1","timestamp":"2026-09-19T05:00:00.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
FIX
  cat > "$T/proj4/.metrics/session-sess-4.jsonl" <<'FIX'
{"event":"dispatch","ts":"2026-09-19T04:00:00Z","session":"sess-4","origin":"main","agent":"zeta","tier":"sonnet","task":"T9","brief_bytes":10}
FIX

  # sess-6: X2's other half — no dispatch AND no commit_landed at all (a
  # session with no event log for it, the pre-0.4.0 shape). Every priced
  # turn must still land somewhere (setup, by the zero-landmarks rule), not
  # vanish.
  mkdir -p "$T/proj6/.metrics" "$T/tx6"
  cat > "$T/tx6/sess-6.jsonl" <<'FIX'
{"type":"assistant","requestId":"v1","timestamp":"2026-09-19T06:00:00.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
FIX

  BEFORE=$(find "$T" -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(wc -c <"$f")"; done)

  OUT=$(CLAUDE_PROJECT_DIR="$T/proj" CLAUDE_TRANSCRIPT_DIR="$T/tx" METRICS_DIR="$T/proj/.metrics" \
        "$0" sess-1 2>&1) || { printf '%s\n' "$OUT"; die "self-test: reader exited non-zero"; }

  fail() { printf 'self-test FAIL: %s\n' "$1" >&2; printf '%s\n' "$OUT" >&2; exit 1; }
  # Dedupe on requestId: r1 appears twice and must be counted once. 100 output
  # tokens, not 200. A resumed session copies prior turns into the new file, so
  # without this every long session double counts its own history.
  printf '%s' "$OUT" | grep -q 'main .*  *100 ' || fail "main output should be 100 (dedupe on requestId)"
  # THE 0.4.2 DEFECTS, ASSERTED TOGETHER. Three worker turns: w1 is a single row
  # (50 output), the id-less row stands alone (25), and w2 spans two rows — a
  # thinking block carrying 4, then the tool_use carrying the real 50 — which
  # must merge to its LAST value. So: 3 turns, 125 output tokens.
  #   Keeping w2's FIRST row instead reads 79, which is what 0.4.1 did.
  #   Merging the id-less row into another would read 2 turns.
  printf '%s' "$OUT" | grep -qE 'worker +opus +3 +125 ' \
    || fail "split requests must report their LAST usage; an id-less row stands alone"
  printf '%s' "$OUT" | grep -q 'critic'      || fail "worker run not joined to its role via agent_id"
  printf '%s' "$OUT" | grep -q 'T7'          || fail "task id not joined"
  printf '%s' "$OUT" | grep -q 'fix_first'   || fail "verdict not read from SubagentHandback"
  printf '%s' "$OUT" | grep -q '1 blocker'   || fail "blocker count not parsed"
  printf '%s' "$OUT" | grep -qi 'boom'       && fail "finding TEXT leaked into the report"
  printf '%s' "$OUT" | grep -q "$RATES_ASOF" || fail "rates date not printed"

  # T5 CHANGE 2: the per-turn price ratio — main vs. the worker tier present.
  printf '%s' "$OUT" | grep -q 'Per-turn price ratio' \
    || fail "per-turn price ratio block missing"
  printf '%s' "$OUT" | grep -qE 'worker opus.*\(main is [0-9.]+x\)' \
    || fail "per-turn price ratio did not state a ratio against the opus worker tier"

  # T5 CHANGE 3: the chair-windows block (AC-6, AC-7). Three fixture commits,
  # three required cases: a window with main-lane turns in it (c1c1c1c1), a
  # window with none (c2c2c2c2), and a commit landing before any priced turn
  # (c3c3c3c3) — UNAVAILABLE for THAT window only, not the whole block.
  printf '%s' "$OUT" | grep -qi 'ceiling' \
    || fail "chair-windows block did not state the ceiling wording in its printed output"
  printf '%s' "$OUT" | grep -q 'never an attribution' \
    || fail "chair-windows block did not state the never-an-attribution wording"
  printf '%s' "$OUT" | grep -qE 'c1c1c1c1 +1 turn' \
    || fail "chair-windows: c1c1c1c1's window should catch the one main-lane turn in range"
  printf '%s' "$OUT" | grep -qE 'c2c2c2c2 +0 turn' \
    || fail "chair-windows: c2c2c2c2's window should catch no main-lane turns"
  printf '%s' "$OUT" | grep -qE 'c3c3c3c3 +UNAVAILABLE — commit landed before any priced turn' \
    || fail "chair-windows: c3c3c3c3 should report UNAVAILABLE (its ts predates the earliest priced turn)"
  # The other two windows must NOT be swallowed by that one window's UNAVAILABLE.
  printf '%s' "$OUT" | grep -qE 'c1c1c1c1 +1 turn.*ceiling' \
    || fail "chair-windows: c1c1c1c1's window should still price, unaffected by c3c3c3c3's UNAVAILABLE"

  # THE IFS-TAB SQUEEZE DEFECT, ASSERTED DIRECTLY. The windows TSV's `start`
  # field is genuinely empty ("-") for the FIRST commit_landed in any log — no
  # prior commit exists to bound the window's start. `read -r head start end`
  # over a tab-delimited row with an empty middle field is exactly the 003
  # defect documented above emit_usage: IFS set to a tab still squeezes a run
  # of tabs to one delimiter, so the blank field vanishes and every field
  # after it shifts left — `end` silently becomes "", which then compares as
  # less than any real EARLIEST_MAIN and every first commit misreports
  # UNAVAILABLE even when real turns preceded it. sess-1 above cannot catch
  # this: its own first commit (c3c3c3c3) genuinely deserves UNAVAILABLE, so
  # the bug would produce the right answer by the wrong mechanism. sess-2's
  # fixture (written above, before BEFORE) does NOT deserve it — a real turn
  # precedes its one and only commit — so this assertion fails if the squeeze
  # regresses.
  OUT3=$(CLAUDE_PROJECT_DIR="$T/proj2" CLAUDE_TRANSCRIPT_DIR="$T/tx2" METRICS_DIR="$T/proj2/.metrics" \
         "$0" sess-2 2>&1) || { printf '%s\n' "$OUT3"; die "self-test: sess-2 run exited non-zero"; }
  printf '%s' "$OUT3" | grep -qE 'onlycomm +1 turn' \
    || { printf '%s\n' "$OUT3" >&2; fail "chair-windows: a real turn preceding the log's first commit must be counted, not squeezed into UNAVAILABLE"; }
  printf '%s' "$OUT3" | grep -q 'onlycomm.*before any priced turn' \
    && { printf '%s\n' "$OUT3" >&2; fail "chair-windows: the log's first commit wrongly reported UNAVAILABLE despite a real preceding turn (IFS-tab squeeze regressed)"; }

  # plans/013-phase-accounting.md — X2 (zero-dispatch half): sess-2's own
  # fixture (one commit, no dispatch ever) also drives the new phase block.
  # No dispatch this session, so no setup row (the first landmark is a
  # commit) and no orchestration rows; direct-lane must equal what the
  # windows block above already counted for the SAME commit (AC-2, X2).
  printf '%s' "$OUT3" | grep -q "first landmark was a commit" \
    || fail "phase: sess-2 (no dispatch) should report 0-turn setup, not a guess"
  printf '%s' "$OUT3" | grep -q 'orchestration  no dispatches this session' \
    || fail "phase: sess-2 should report no dispatches"
  printf '%s' "$OUT3" | grep -qE 'direct-lane +1 turn' \
    || fail "phase: sess-2's direct-lane total should match the 1-turn window above (AC-2)"
  printf '%s' "$OUT3" | grep -qE 'close +0 turn' \
    || fail "phase: sess-2 has nothing after its one commit — close should be 0, not omitted"

  # plans/013-phase-accounting.md T1 — sess-3: the rich fixture. See the
  # comment beside its construction above for what each landmark is for.
  OUT4=$(CLAUDE_PROJECT_DIR="$T/proj3" CLAUDE_TRANSCRIPT_DIR="$T/tx3" METRICS_DIR="$T/proj3/.metrics" \
         "$0" sess-3 2>&1) || { printf '%s\n' "$OUT4"; die "self-test: sess-3 run exited non-zero"; }
  fail4() { printf 'self-test FAIL: %s\n' "$1" >&2; printf '%s\n' "$OUT4" >&2; exit 1; }
  printf '%s' "$OUT4" | grep -qE 'setup +1 turn.*110 billable' \
    || fail4 "phase: sess-3 setup should be the one turn before D1 (110 billable tok) — D1's own missing task field must not shift it"
  # D1: the session's first landmark, task genuinely absent — must still
  # print as its own row (agent/tier real, task "-"), not corrupt the row
  # after it (the generalized IFS-tab-squeeze shape).
  printf '%s' "$OUT4" | grep -qE 'orchestration alpha +sonnet +-  *turns +2 +tok +220' \
    || fail4 "phase: D1's orchestration row (alpha/sonnet, no task) should show 2 turns / 220 tok"
  # The one clean inter-commit span (C1->C2) is direct-lane, sourced from the
  # SAME windows the block above prints (AC-2) — not re-derived.
  printf '%s' "$OUT4" | grep -qE 'direct-lane +1 turn.*110 billable' \
    || fail4 "phase: sess-3 direct-lane should be the one C1->C2 turn (110 billable tok), matching the windows block"
  # D2 then D2b inside ONE tainted stretch: D2's window must close on D2's
  # OWN label the instant D2b fires (state carried across the transition,
  # not sandwiched — the generalized second historical bug).
  printf '%s' "$OUT4" | grep -qE 'orchestration beta +haiku +T2 +turns +1 +tok +110' \
    || fail4 "phase: D2's own window (1 turn) must not be lost or merged into D2b's"
  # D2b -> C3: adjacent, nothing between them — a near-zero orchestration
  # window that must still print, not vanish or double count (X4).
  printf '%s' "$OUT4" | grep -qE 'orchestration delta +fable +T2b +turns +0 +tok +0' \
    || fail4 "phase: D2b's near-zero window (X4) must print 0 turns, not disappear"
  # D3: unjoined (no dispatch_launched) — real turns still shown, role is
  # not guessed. Its window absorbs the C3->D3 gap (two real turns) because
  # AC-2 requires direct-lane to match the windows block exactly, and that
  # block drops the WHOLE C3..C4 span once D3 taints it.
  printf '%s' "$OUT4" | grep -qE 'orchestration unjoined +\? +- +turns +2 +tok +220' \
    || fail4 "phase: D3 (unjoined) should still show its 2 real turns, role reported as unjoined, never a guess"
  # D4: alpha's SECOND dispatch (occurrence tracking) and the session's LAST
  # landmark — its own absorbed window is real but empty here, and the open
  # tail after it (2 turns) must price as close, not more orchestration.
  printf '%s' "$OUT4" | grep -qE "orchestration alpha +sonnet +T4 +turns +0 +tok +0.*session's last landmark" \
    || fail4 "phase: D4 (alpha's 2nd dispatch, last landmark) should show 0 turns with the close-tail note"
  printf '%s' "$OUT4" | grep -qE 'close +2 turn.*220 billable' \
    || fail4 "phase: the open-ended tail after D4 (2 turns, 220 tok) should price as close"
  # AC-2 is scoped to committed windows (decision 2): the windows block's
  # trailing ceiling after C4 (2 turns) is NOT direct-lane here, and the block
  # must say where those turns went rather than disagree silently.
  printf '%s' "$OUT4" | grep -q 'note: the windows-block tail after the last commit (2 turn(s)) is not direct-lane here — 2 in close, 0 in orchestration' \
    || fail4 "phase: sess-3's trailing ceiling (2 turns after C4) should be reconciled by a note naming 2 in close"
  # X3, asserted arithmetically, not just that every label appears: phase
  # turn/token sums must equal the main-lane totals printed at the top.
  # `$1=="main"` (an exact field match, not a grep substring) is what keeps
  # this off the "main thread :" summary line further down the same report.
  MAIN_TURNS=$(printf '%s' "$OUT4" | awk '$1=="main" && $2 ~ /^[a-z]+$/ && $3 ~ /^[0-9]+$/ { s+=$3 } END { print s+0 }')
  MAIN_TOK=$(printf '%s' "$OUT4" | awk '$1=="main" && $2 ~ /^[a-z]+$/ && $3 ~ /^[0-9]+$/ { s+=$5 } END { print s+0 }')
  [ "$MAIN_TURNS" = "9" ] || fail4 "phase: sess-3 should have 9 main-lane turns, got $MAIN_TURNS"
  [ "$MAIN_TOK" = "990" ] || fail4 "phase: sess-3 should have 990 billable tok, got $MAIN_TOK"
  # setup/close/direct-lane share one printf shape: label, turns($2), "turn(s),", tok($4).
  SETUP_T=$(printf '%s' "$OUT4" | awk '/^   setup +[0-9]/ {print $2}')
  SETUP_TOK=$(printf '%s' "$OUT4" | awk '/^   setup +[0-9]/ {print $4}')
  CLOSE_T=$(printf '%s' "$OUT4" | awk '/^   close +[0-9]/ {print $2}')
  CLOSE_TOK=$(printf '%s' "$OUT4" | awk '/^   close +[0-9]/ {print $4}')
  DL_T4=$(printf '%s' "$OUT4" | awk '/^   direct-lane +[0-9]/ {print $2}')
  DL_TOK4=$(printf '%s' "$OUT4" | awk '/^   direct-lane +[0-9]/ {print $4}')
  # orchestration TOTAL: "orchestration TOTAL: turns" $4 "tok" $6 — already the
  # roll-up AC-1 requires, reused here rather than re-summing every row.
  ORC_T4=$(printf '%s' "$OUT4" | awk '/orchestration TOTAL:/ {print $4}')
  ORC_TOK4=$(printf '%s' "$OUT4" | awk '/orchestration TOTAL:/ {print $6}')
  PHASE_TURNS=$((SETUP_T + ORC_T4 + DL_T4 + CLOSE_T))
  PHASE_TOK=$((SETUP_TOK + ORC_TOK4 + DL_TOK4 + CLOSE_TOK))
  [ "$PHASE_TURNS" = "$MAIN_TURNS" ] \
    || fail4 "X3: phase turn sum ($PHASE_TURNS = setup $SETUP_T + orch $ORC_T4 + direct-lane $DL_T4 + close $CLOSE_T) does not equal the main-lane total ($MAIN_TURNS) — a turn was dropped or double-counted at a boundary"
  [ "$PHASE_TOK" = "$MAIN_TOK" ] \
    || fail4 "X3: phase billable-tok sum ($PHASE_TOK) does not equal the main-lane total ($MAIN_TOK)"

  # plans/013-phase-accounting.md X1 — a dispatch (the session's only
  # landmark) lands before any priced turn: setup must say UNAVAILABLE, not
  # print a confident wrong 0, and the rest of the block must still print.
  OUT5=$(CLAUDE_PROJECT_DIR="$T/proj4" CLAUDE_TRANSCRIPT_DIR="$T/tx4" METRICS_DIR="$T/proj4/.metrics" \
         "$0" sess-4 2>&1) || { printf '%s\n' "$OUT5"; die "self-test: sess-4 run exited non-zero"; }
  printf '%s' "$OUT5" | grep -q 'setup          UNAVAILABLE — the first dispatch landed before any priced turn' \
    || { printf '%s\n' "$OUT5" >&2; fail "X1 (phase, setup): a dispatch before any priced turn should report UNAVAILABLE, not a wrong 0"; }
  printf '%s' "$OUT5" | grep -qE 'close +1 turn' \
    || { printf '%s\n' "$OUT5" >&2; fail "X1 (phase): the one real turn after the dispatch should still land in close"; }
  printf '%s' "$OUT5" | grep -q 'note: the windows-block tail after the last commit (1 turn(s)) is not direct-lane here — 1 in close, 0 in setup/orchestration' \
    || { printf '%s\n' "$OUT5" >&2; fail "phase (sess-4): the no-commit trailing ceiling should be reconciled by a note"; }

  # plans/013-phase-accounting.md X2 (other half) — no dispatch and no
  # commit_landed at all: every priced turn must still resolve to a phase.
  OUT6=$(CLAUDE_PROJECT_DIR="$T/proj6" CLAUDE_TRANSCRIPT_DIR="$T/tx6" METRICS_DIR="$T/proj6/.metrics" \
         "$0" sess-6 2>&1) || { printf '%s\n' "$OUT6"; die "self-test: sess-6 run exited non-zero"; }
  printf '%s' "$OUT6" | grep -qE 'setup +1 turn' \
    || { printf '%s\n' "$OUT6" >&2; fail "X2 (no landmarks at all): the session's one turn should land in setup, not vanish"; }
  printf '%s' "$OUT6" | grep -qE 'close +0 turn' \
    || { printf '%s\n' "$OUT6" >&2; fail "X2 (no landmarks at all): close should be 0, not omitted"; }
  printf '%s' "$OUT6" | grep -q 'orchestration  no dispatches this session' \
    || { printf '%s\n' "$OUT6" >&2; fail "X2 (no landmarks at all): should report no dispatches"; }

  # THE 0.4.1 DEFECT, ASSERTED DIRECTLY. With no session named, the reader must
  # skip the newer /clear transcript and land on the one that billed something.
  OUT2=$(CLAUDE_PROJECT_DIR="$T/proj" CLAUDE_TRANSCRIPT_DIR="$T/tx" METRICS_DIR="$T/proj/.metrics" \
         "$0" 2>&1) || { printf '%s\n' "$OUT2"; die "self-test: default-session run exited non-zero"; }
  printf '%s' "$OUT2" | grep -q 'session: sess-1' \
    || { printf '%s\n' "$OUT2" >&2; fail "a /clear transcript was picked over the real session"; }
  printf '%s' "$OUT2" | grep -q 'skipped 1 newer transcript' \
    || { printf '%s\n' "$OUT2" >&2; fail "the skip was not reported"; }

  AFTER=$(find "$T" -type f | sort | while read -r f; do printf '%s %s\n' "$f" "$(wc -c <"$f")"; done)
  [ "$BEFORE" = "$AFTER" ] || fail "the reader modified its input tree"
  printf 'self-test OK — dedupe (split + id-less rows), join, verdict, /clear skip, no content leak, per-turn ratio, chair-windows (with/without turns, before-priced-turn), phase-by-turn (X1 UNAVAILABLE landmark, X2 zero-dispatch both halves, X3 arithmetic sum, X4 adjacent/near-zero window, gap-absorption state carry, open close tail, trailing-ceiling note), inputs untouched\n'
  exit 0
fi

# --- resolve the session -----------------------------------------------------
[ -d "$TRANSCRIPTS" ] || unavailable "no transcript directory for this project at
   $TRANSCRIPTS
   Token cost is read from the local session transcript (docs/kit/METRICS.md,
   route 3). Nothing else in this report depends on it."

# Same trap as metrics.sh, one layer down: a `/clear` leaves a transcript with
# no assistant turns at all, and it is newer than the one you worked in. Pick
# the newest transcript that actually billed something, and say how many were
# skipped to get there.
SKIPPED=0
if [ -z "$SESSION" ]; then
  # shellcheck disable=SC2012
  ALL=$(ls -t "$TRANSCRIPTS"/*.jsonl 2>/dev/null)
  [ -n "$ALL" ] || unavailable "no session transcripts under $TRANSCRIPTS"
  for CAND in $ALL; do
    if [ "$(jq -r -c 'select(.type == "assistant" and (.message.usage != null)) | 1' "$CAND" 2>/dev/null | head -1)" = "1" ]; then
      SESSION=$(basename "$CAND" .jsonl); break
    fi
    SKIPPED=$((SKIPPED + 1))
  done
  if [ -z "$SESSION" ]; then
    SESSION=$(basename "$(printf '%s\n' "$ALL" | head -1)" .jsonl); SKIPPED=0
  fi
fi
MAIN="$TRANSCRIPTS/$SESSION.jsonl"
[ -f "$MAIN" ] || unavailable "no transcript for session $SESSION under $TRANSCRIPTS"

WORKDIR="$TRANSCRIPTS/$SESSION/subagents"
EVLOG="$METRICS_DIR/session-$SESSION.jsonl"

TMP=$(mktemp -d) || die "cannot make a temp dir"
trap 'rm -rf "$TMP"' EXIT

# --- gather ------------------------------------------------------------------
emit_usage main main "$MAIN" > "$TMP/rows"

: > "$TMP/runs"          # run-key <TAB> agent_id <TAB> verdict b s n evidence
if [ -d "$WORKDIR" ]; then
  for f in "$WORKDIR"/agent-*.jsonl; do
    [ -f "$f" ] || continue
    key=$(basename "$f" .jsonl); key=${key#agent-}
    aid=$(agent_id_of "$f"); [ -n "$aid" ] || aid="$key"
    emit_usage worker "$aid" "$f" >> "$TMP/rows"
    printf '%s\t%s\n' "$aid" "$(verdict_of "$f" | tr ' ' '\t')" >> "$TMP/runs"
  done
fi

# Join: agent_id -> agent role, tier, task id.
#
# `dispatch_launched` names the agent and carries the id. `dispatch` names the
# agent, its tier and its task but is written before the id exists. They are
# paired BY ORDER WITHIN AN AGENT NAME, which is what the log supports and no
# more: two concurrent critics completing out of order would swap a pair of task
# labels and change nothing else. A run with no matching event is reported as
# unjoined — never attributed by timestamp proximity.
: > "$TMP/join"
if [ -f "$EVLOG" ]; then
  jq -r -c 'select(.event == "dispatch") | [.agent // "unknown", .tier // "?", .task // "-"] | @tsv' \
     "$EVLOG" 2>/dev/null > "$TMP/disp" || :
  jq -r -c 'select(.event == "dispatch_launched" and .agent_id != null) | [.agent // "unknown", .agent_id] | @tsv' \
     "$EVLOG" 2>/dev/null > "$TMP/launch" || :
  awk -F'\t' '
    NR == FNR { n[$1]++; tier[$1 SUBSEP n[$1]] = $2; task[$1 SUBSEP n[$1]] = $3; next }
    { m[$1]++; print $2 "\t" $1 "\t" (tier[$1 SUBSEP m[$1]] ? tier[$1 SUBSEP m[$1]] : "?") \
            "\t" (task[$1 SUBSEP m[$1]] ? task[$1 SUBSEP m[$1]] : "-") }
  ' "$TMP/disp" "$TMP/launch" > "$TMP/join" 2>/dev/null || :
fi

# --- price -------------------------------------------------------------------
# Dedupe on requestId here, once, for every lane — KEEPING THE LAST ROW, not the
# first.
#
# ONE API REQUEST WRITES SEVERAL TRANSCRIPT ROWS: a thinking block, then one per
# tool_use, each carrying a partial `usage`. Only the last holds the complete
# `output_tokens`. 0.4.1 kept the first and so read the thinking block's count —
# on a real 18-run session that was 30,557 sonnet worker output tokens against a
# true 310,356, and 26,022 opus against 150,489. Output is the priciest token
# class, so the undercount tilted every share toward the chair and away from
# opus: 40/26/34 reported where the truth was 45/27/28.
#
# It survived 002's review because the main thread does not split the same way.
# The fable line matched the client's own /usage to within 1% either way, and
# that was the lane that got checked.
#
# First-seen POSITION is preserved and last-seen VALUES win, because the
# "past turn 30" lever below indexes on row order within a run. A row with no
# requestId (the `.uuid` fallback returned nothing) gets a key of its own and is
# never merged with another.
: > "$TMP/priced"
# `rid` is read but unused: every tab-delimited field must be consumed in order
# or the ones after it shift left — the 003 defect where an empty requestId was
# priced with the output count read as the model name.
# `set -- $(rates_for ...)` splits four numbers on purpose; quoting it would
# make them one argument.
# shellcheck disable=SC2034,SC2046
awk -F'\t' '
  { k = ($3 != "" && $3 != "-" ? $3 : "\001" NR)
    if (!(k in pos)) pos[k] = ++n
    row[k] = $0 }
  END { for (k in row) printf "%09d\t%s\n", pos[k], row[k] }
' "$TMP/rows" | sort -n | cut -f2- | while IFS=$'\t' read -r lane run rid model i o cr cw ts; do
  set -- $(rates_for "$model")
  cost=$(awk -v i="$i" -v o="$o" -v cr="$cr" -v cw="$cw" \
             -v a="$1" -v b="$2" -v c="$3" -v d="$4" \
             'BEGIN { printf "%.6f", (i*a + o*b + cr*c + cw*d) / 1000000 }')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$lane" "$run" "$(tier_of "$model")" "$i" "$o" "$cr" "$cw" "$cost" "$ts" >> "$TMP/priced"
done

TURNS=$(wc -l < "$TMP/priced" | tr -d ' ')
[ "$TURNS" -gt 0 ] || unavailable "session $SESSION has no assistant turns carrying usage"

# --- report ------------------------------------------------------------------
printf '   session: %s\n' "$SESSION"
[ "${SKIPPED:-0}" -gt 0 ] && \
  printf '   skipped %s newer transcript(s) with no billed turns (a /clear leaves one)\n' "$SKIPPED"
printf '   transcript: %s\n' "$TRANSCRIPTS"
printf '   list-price rates as of %s — dollars are an ESTIMATE; the shares carry the decision\n\n' "$RATES_ASOF"

awk -F'\t' '
  { t[$1 "\t" $3] += $8; tt[$1 "\t" $3] += $4+$5+$6+$7; n[$1 "\t" $3]++
    out[$1 "\t" $3] += $5; total += $8; lane[$1] += $8; ltok[$1] += $4+$5+$6+$7
    tier[$3] += $8; ttok[$3] += $4+$5+$6+$7; alltok += $4+$5+$6+$7
    if ($1 == "worker") runs[$2] = 1 }
  END {
    printf "   %-10s %-8s %6s %10s %14s %9s %6s\n", "lane","tier","turns","out tok","billable tok","API $est","share"
    for (k in n) { split(k, p, "\t")
      printf "SORT%09d   %-10s %-8s %6d %10d %14d %9.2f %5.0f%%\n", 1000000-t[k]*1000, p[1], p[2], n[k], out[k], tt[k], t[k], 100*t[k]/(total?total:1) | "sort" }
    close("sort")
    printf "\n   main thread : %9.2f  (%.0f%% of cost, %.0f%% of billable tokens)\n", lane["main"], 100*lane["main"]/(total?total:1), 100*ltok["main"]/(alltok?alltok:1)
    printf "   workers     : %9.2f  (%.0f%% of cost, %.0f%% of billable tokens)\n", lane["worker"], 100*lane["worker"]/(total?total:1), 100*ltok["worker"]/(alltok?alltok:1)
    printf "   TOTAL       : %9.2f   %d billable tokens over %d worker run(s)\n", total, alltok, length(runs)
    printf "\n   opus share of cost: %.0f%%   (CLAUDE.md prime rule 2 governs the combined\n", 100*tier["opus"]/(total?total:1)
    printf "   opus share — Supervisor + architect + critic — against a ~25%% goal)\n"
  }' "$TMP/priced" | sed 's/^SORT[0-9]*//'

# --- the turn-budget lever ---------------------------------------------------
# Per lane, not only "worker": the chair's own thread ($2 is the constant key
# "main", so idx[] there counts the WHOLE thread's turn order) accumulates
# context the same way a worker run does, and the same late-turn cost bloat is
# honest to show for both.
printf '\n   Spend past turn 30 of a run\n'
awk -F'\t' '
  { l = $1; idx[l SUBSEP $2]++; tot[l] += $8
    if (idx[l SUBSEP $2] > 30) late[l] += $8
    if (idx[l SUBSEP $2] > 40) late40[l] += $8 }
  END {
    n_lanes = 0
    if ("main" in tot) {
      n_lanes++
      if (tot["main"] == 0) printf "   %-8s no turns this session\n", "main"
      else printf "   %-8s %.0f%% of spend landed after turn 30, %.0f%% after turn 40.\n", \
                   "main", 100*late["main"]/tot["main"], 100*late40["main"]/tot["main"]
    }
    if ("worker" in tot) {
      n_lanes++
      if (tot["worker"] == 0) printf "   %-8s no turns this session\n", "worker"
      else printf "   %-8s %.0f%% of spend landed after turn 30, %.0f%% after turn 40.\n", \
                   "worker", 100*late["worker"]/tot["worker"], 100*late40["worker"]/tot["worker"]
    }
    if (n_lanes == 0) { print "   no turns this session"; exit }
    print  "   Context grows through a run and every turn re-reads all of it, so late"
    print  "   turns cost multiples of early ones. A high number here is an argument for"
    print  "   a tighter maxTurns or a narrower brief, not for a cheaper model."
  }' "$TMP/priced"

# --- what the expensive lanes returned ---------------------------------------
printf '\n   What each worker run cost, and what it returned\n'
if [ ! -s "$TMP/runs" ]; then
  printf '   no worker runs in this session'"'"'s transcript\n'
else
  # cost and turn count per run id, from the priced rows
  awk -F'\t' '$1 == "worker" { c[$2] += $8; n[$2]++ }
               END { for (k in c) printf "%s\t%.4f\t%d\n", k, c[k], n[k] }' \
      "$TMP/priced" > "$TMP/runcost"

  # runs + cost + role, sorted most expensive first. Tier and task come from the
  # event log via agent_id; a run with no join prints as unjoined and is counted.
  awk -F'\t' '
    FILENAME == ARGV[1] { cost[$1] = $2; turns[$1] = $3; next }
    FILENAME == ARGV[2] { role[$1] = $2; tier[$1] = $3; task[$1] = $4; next }
    {
      id = $1; r = role[id]; if (r == "") { r = "unjoined"; unjoined++ }
      printf "%012d\t   %-12s %-7s %-5s turns %3d  API $est %8.2f  verdict %-10s %d blocker(s), %d should-fix\n", \
             999999999 - int((cost[id]+0) * 100), \
             r, (tier[id] ? tier[id] : "?"), (task[id] ? task[id] : "-"), \
             turns[id]+0, cost[id]+0, $2, $3, $4
    }
    END { if (unjoined > 0) print unjoined > "/dev/stderr" }
  ' "$TMP/runcost" "$TMP/join" "$TMP/runs" 2> "$TMP/unjoined" | sort | cut -f2-

  # The join's honesty line. A log written before 0.4.0 carries no
  # dispatch_launched, so every run reports unjoined — which is the visible
  # failure the plan asked for, not a silent one.
  U=$(cat "$TMP/unjoined" 2>/dev/null | head -1)
  if [ -n "${U:-}" ]; then
    printf '\n   unjoined runs: %s — no dispatch_launched event carried their agent_id.\n' "$U"
    printf '   Their turns and costs above are real; their roles are not known, and\n'
    printf '   nothing is attributed by guess. A log written before 0.4.0 has none.\n'
  fi
fi

# --- the per-turn price ratio -------------------------------------------------
# A turn is a comparable unit of work across lanes, where a run or a dollar is
# not: a worker run's turn count is bounded by maxTurns and its own brief, and
# the main thread's is bounded by nothing. This prices the chair's own thread
# against each worker TIER present (grouped by $3 in $TMP/priced, not by
# individual run — a tier is what a tiering decision is actually made over).
# billable tok/turn reuses the summary table's own shape, sum($4+$5+$6+$7)/n.
#
# The ratio this produces is computed fresh, every run, from whatever session
# it is pointed at — never hardcoded. A real prior session once measured chair
# ~247k billable/turn vs sonnet worker ~87k/turn (~2.8x), with output/turn
# nearly identical across lanes; that number belongs to that session, not this
# script.
printf '\n   Per-turn price ratio (a turn is a comparable unit of work across lanes)\n'
awk -F'\t' '
  $1 == "main"   { n_main++; tok_main += $4+$5+$6+$7; out_main += $5 }
  $1 == "worker" { n[$3]++;  tok[$3]  += $4+$5+$6+$7; out[$3]  += $5 }
  END {
    if (n_main == 0) { print "   main : 0 turns this session — nothing to compare"; exit }
    avg_main = tok_main / n_main; avgout_main = out_main / n_main
    printf "   %-14s: %d turns, avg %.0f billable tok/turn, avg %.0f out tok/turn\n", \
           "main", n_main, avg_main, avgout_main

    have_worker = 0
    order = "opus sonnet fable haiku other"
    split(order, tiers, " ")
    for (i = 1; i <= 5; i++) {
      t = tiers[i]
      if (!(t in n) || n[t] == 0) continue
      have_worker = 1
      avg_t = tok[t] / n[t]; avgout_t = out[t] / n[t]
      label = "worker " t
      if (avg_t > 0) ratio = sprintf("(main is %.1fx)", avg_main / avg_t)
      else           ratio = "(no billable tokens this tier — no ratio)"
      printf "   %-14s: %d turns, avg %.0f billable tok/turn, avg %.0f out tok/turn   %s\n", \
             label, n[t], avg_t, avgout_t, ratio
    }
    if (!have_worker) print "   no worker turns this session — no tier to compare against"
  }' "$TMP/priced"

# --- chair-authored windows (AC-6, AC-7) --------------------------------------
# What the chair's OWN hands-on windows could have cost, priced against
# comparable briefed work in the same session — a CEILING on that window's
# work, never what it actually cost and never an attribution of it: the same
# window also holds planning, reading reports and talking to the sponsor, not
# only the commit that closed it.
#
# A window is direct-lane work: a commit_landed event with no dispatch event
# between it and the previous commit_landed. Same definition, same jq reduce
# shape, as metrics.sh's own "## Commits" direct-lane block (just landed this
# session) — no shared library function for one call site each.
printf '\n   Chair-authored windows — a CEILING on cost, never an attribution\n'
printf '   Prices the main-lane turns between one landed commit and the last. This is\n'
printf '   the MOST that window'"'"'s work could have cost, not what it did cost: the\n'
printf '   same window also holds planning, reading reports and talking to the\n'
printf '   sponsor, not only the commit that closed it.\n'

if [ ! -f "$EVLOG" ]; then
  printf '   UNAVAILABLE — no commit_landed events in %s, nothing to window\n' "$EVLOG"
else
  # "-" for a missing start below, never "": an EMPTY tab-delimited field is
  # the exact 003 IFS-tab defect documented above emit_usage — read with IFS
  # set to a tab still squeezes a run of tabs to one delimiter, so a commit
  # with no prior window (the first commit_landed in the log) would have its
  # blank start field silently absorbed and every field after it shift left,
  # corrupting `end` and misreporting a real window as UNAVAILABLE. Found by
  # hand-testing this block directly, not by the self-test as first written:
  # the original fixture's own first commit genuinely deserved UNAVAILABLE,
  # so the bug produced the right answer by the wrong mechanism. See the
  # added self-test case below, which does not have that property.
  # `reason` travels alongside `seen`/`prev`, same contract as metrics.sh's
  # DIRECT_ROWS reduce (and the same sandwich-ordering fix applied there): a
  # dropped, dispatch-attributed commit_landed must NOT wipe a reason a
  # direct_lane event logged for a LATER, still-open commit — only `dispatch`
  # and a commit that actually CONSUMES the reason reset it to null.
  jq -r -s '
    [.[] | select(.event == "dispatch" or .event == "direct_lane" or .event == "commit_landed")]
    | reduce .[] as $e (
        {seen: false, prev: null, reason: null, out: []};
        if $e.event == "dispatch" then
          {seen: true, prev: .prev, reason: null, out: .out}
        elif $e.event == "direct_lane" then
          {seen: .seen, prev: .prev,
           reason: (if (($e.reason // "") | length) > 0 then $e.reason else .reason end),
           out: .out}
        elif .seen then
          {seen: false, prev: $e.ts, reason: .reason, out: .out}
        else
          {seen: false, prev: $e.ts, reason: null,
           out: (.out + [{head: (($e.head // "")[0:8]), start: .prev, end: $e.ts, reason: .reason}])}
        end)
    | .out[]
    | [.head, (.start // "-"), .end, (.reason // "-")] | @tsv
  ' "$EVLOG" 2>/dev/null > "$TMP/windows"

  # I1's blind spot (X5/T7-shape): a `direct_lane` decision (or a dispatch)
  # that closes NO commit at all — a verification pass, a diagnosis-only
  # detour — used to vanish here, because the reduce above only grows `out`
  # on a KEPT (direct-lane-attributed) commit_landed. This second pass looks
  # at the TRAILING state only, and MUST track the exact same {seen, reason}
  # state machine as the main reduce above — not just "did anything at all
  # follow the last commit_landed". An earlier version treated ANY
  # commit_landed as fully closing the window, including a DROPPED
  # (dispatch-attributed) one — so `dispatch(A) -> direct_lane(B, reason) ->
  # commit_landed(A's, dropped)` with B's own commit never landing lost B's
  # reason entirely: the main reduce never emits a row for it (A's commit was
  # dropped, B's never landed) and the old TRAIL saw A's commit_landed and
  # called the window fully closed, so neither report surface showed it.
  # Reason survives a DROPPED commit_landed here for the same reason it does
  # above: that commit was never what the reason was for.
  TRAIL=$(jq -r -s '
    [.[] | select(.event == "dispatch" or .event == "direct_lane" or .event == "commit_landed")]
    | reduce .[] as $e (
        {seen: false, prev: null, reason: null};
        if $e.event == "dispatch" then
          {seen: true, prev: .prev, reason: null}
        elif $e.event == "direct_lane" then
          {seen: .seen, prev: .prev,
           reason: (if (($e.reason // "") | length) > 0 then $e.reason else .reason end)}
        elif .seen then
          {seen: false, prev: $e.ts, reason: .reason}
        else
          {seen: false, prev: $e.ts, reason: null}
        end)
    | if (.seen or (.reason != null)) then [(.prev // "-"), (.reason // "-")] | @tsv else empty end
  ' "$EVLOG" 2>/dev/null)

  if [ ! -s "$TMP/windows" ] && [ -z "$TRAIL" ]; then
    printf '   UNAVAILABLE — no commit_landed events in %s, nothing to window\n' "$EVLOG"
  else
    # Earliest main-lane turn carrying a real timestamp — the floor below which
    # a window cannot be priced because this transcript does not cover it.
    EARLIEST_MAIN=$(awk -F'\t' '$1 == "main" && $9 != "-" { print $9 }' "$TMP/priced" | sort | head -1)

    # Median of this session's own briefed-run costs (Change 2's $TMP/runcost,
    # untouched). Absent or empty means no worker runs this session at all.
    # Reused below by the trailing window too — same "?:" -guarded ratio, never
    # a bare division, whether or not a dispatch happened this session (X4).
    HAVE_MEDIAN=0
    if [ -s "$TMP/runcost" ]; then
      HAVE_MEDIAN=1
      MEDIAN=$(awk -F'\t' '{ print $2 }' "$TMP/runcost" | sort -n | awk '
        { a[NR] = $1 }
        END { if (NR == 0) { print 0 }
              else if (NR % 2 == 1) { print a[(NR+1)/2] }
              else { print (a[NR/2] + a[NR/2+1]) / 2 } }')
    fi

    if [ -s "$TMP/windows" ]; then
      while IFS=$'\t' read -r head start end wreason; do
        if [ -z "$EARLIEST_MAIN" ] || [[ "$end" < "$EARLIEST_MAIN" ]]; then
          printf '   %-10s UNAVAILABLE — commit landed before any priced turn, window start unknown\n' "$head"
          continue
        fi
        if [ "$start" != "-" ]; then
          READOUT=$(awk -F'\t' -v s="$start" -v e="$end" '
            $1 == "main" && $9 != "-" && $9 > s && $9 <= e { n++; tok += $4+$5+$6+$7; cost += $8 }
            END { printf "%d\t%d\t%.4f", n+0, tok+0, cost+0 }' "$TMP/priced")
        else
          READOUT=$(awk -F'\t' -v e="$end" '
            $1 == "main" && $9 != "-" && $9 <= e { n++; tok += $4+$5+$6+$7; cost += $8 }
            END { printf "%d\t%d\t%.4f", n+0, tok+0, cost+0 }' "$TMP/priced")
        fi
        IFS=$'\t' read -r WT WTOK WCOST <<< "$READOUT"
        WREASON_TXT="$wreason"
        [ "$WREASON_TXT" = "-" ] && WREASON_TXT="(no reason logged)"
        if [ "$HAVE_MEDIAN" -eq 1 ]; then
          RATIO=$(awk -v c="$WCOST" -v m="$MEDIAN" 'BEGIN { if (m+0 == 0) print "n/a"; else printf "%.1fx", c/m }')
          printf '   %-10s %d turn(s), %d billable tok, API $est %.2f ceiling  (%s the session'"'"'s median briefed-task cost)  reason: %s\n' \
            "$head" "$WT" "$WTOK" "$WCOST" "$RATIO" "$WREASON_TXT"
        else
          printf '   %-10s %d turn(s), %d billable tok, API $est %.2f ceiling  (UNAVAILABLE — no worker runs this session to compare against)  reason: %s\n' \
            "$head" "$WT" "$WTOK" "$WCOST" "$WREASON_TXT"
        fi
      done < "$TMP/windows"
    fi

    if [ -n "$TRAIL" ]; then
      IFS=$'\t' read -r TSTART TREASON <<< "$TRAIL"
      if [ "$TSTART" != "-" ]; then
        READOUT=$(awk -F'\t' -v s="$TSTART" '
          $1 == "main" && $9 != "-" && $9 > s { n++; tok += $4+$5+$6+$7; cost += $8 }
          END { printf "%d\t%d\t%.4f", n+0, tok+0, cost+0 }' "$TMP/priced")
      else
        READOUT=$(awk -F'\t' '
          $1 == "main" && $9 != "-" { n++; tok += $4+$5+$6+$7; cost += $8 }
          END { printf "%d\t%d\t%.4f", n+0, tok+0, cost+0 }' "$TMP/priced")
      fi
      IFS=$'\t' read -r WT WTOK WCOST <<< "$READOUT"
      REASON_TXT="$TREASON"
      [ "$REASON_TXT" = "-" ] && REASON_TXT="(no reason logged)"
      if [ "$HAVE_MEDIAN" -eq 1 ]; then
        RATIO=$(awk -v c="$WCOST" -v m="$MEDIAN" 'BEGIN { if (m+0 == 0) print "n/a"; else printf "%.1fx", c/m }')
        printf '   %-10s %d turn(s), %d billable tok, API $est %.2f ceiling  (%s the session'"'"'s median briefed-task cost)  reason: %s\n' \
          "trailing" "$WT" "$WTOK" "$WCOST" "$RATIO" "$REASON_TXT"
      else
        printf '   %-10s %d turn(s), %d billable tok, API $est %.2f ceiling  (UNAVAILABLE — no worker runs this session to compare against)  reason: %s\n' \
          "trailing" "$WT" "$WTOK" "$WCOST" "$REASON_TXT"
      fi
      printf '   ^ open-ended: no commit_landed closed this window — I1'"'"'s blind spot, a\n'
      printf '     direct-lane decision (or dispatch) still in flight when the session log\n'
      printf '     was read, priced anyway rather than silently vanishing.\n'
    fi
  fi
fi

# --- main-thread turns by phase (plans/013-phase-accounting.md) --------------
# What the block above does NOT show: everything that is not a direct-lane
# commit window. This one partitions the WHOLE main lane — every priced turn,
# no exceptions (AC-4) — into: setup (before the session's first landmark),
# one row per dispatch ("orchestration" — turns spent on that dispatch's
# result), direct-lane (the exact windows above, summed to one line), and
# close (after the session's last landmark). Landmarks are dispatch and
# commit_landed only (I2) — dispatch_launched/dispatch_end are worker-side
# timing, not boundaries on the CHAIR's own thread.
#
# ONE BOUNDARY LIST, TWO CONSUMERS (I3). "Direct-lane" here must not be a
# second, independently-maintained definition of the windows block above. So
# it isn't one: this block sums $TMP/windows verbatim — the exact same file
# the block above already built and printed from. Whatever that block calls a
# direct-lane window, this block calls direct-lane too, by construction, not
# by coincidence (AC-2's "match to the cent" follows for free).
#
# WHAT THAT MEANS FOR "ORCHESTRATION". The windows reduce above only advances
# `prev` on a commit_landed — a dispatch never moves it, so ANY dispatch
# between two commits taints the WHOLE inter-commit span, not just the part
# after it fires (confirmed against a real session: a commit-to-commit span
# containing one dispatch had priced main-lane turns on BOTH sides of that
# dispatch's own timestamp). Reusing $TMP/windows verbatim for direct-lane
# only works if orchestration absorbs that entire tainted span, not just
# [dispatch.ts, next landmark) — so the FIRST dispatch since the last commit
# (or session start) gets a window starting at that PREVIOUS landmark, not at
# its own timestamp; each dispatch after it, within the same tainted span,
# starts a fresh window at its own timestamp, ending at the next landmark of
# either kind. This is the one deliberate divergence from the simpler "split
# strictly on every landmark" reading of the boundary list — recorded here
# and in scratch/T1-phase-accounting.md because AC-2 forces it, not because
# it is the only defensible reading.
#
# THE OPEN TAIL IS ALWAYS "close", never an extended orchestration window —
# even when the session's last landmark is a dispatch with nothing after it.
# Nothing beyond that dispatch is a landmark, so nothing distinguishes
# "still handling that dispatch's result" from "session-ending ritual"; this
# block does not invent a signal I2 forbids it from logging. That dispatch's
# own row still prints — one row per dispatch, unconditionally (Decision 1) —
# with 0 turns and a note that its trailing time is priced as close instead.
printf '\n   Main-thread turns by phase\n'
printf '   Every priced main-lane turn lands in exactly one phase below: setup, one\n'
printf '   row per dispatch (orchestration), direct-lane (the windows above, summed),\n'
printf '   and close. The four sums equal the main-lane turns/tokens printed at the\n'
printf '   top of this report — a mismatch means a boundary bug, not a rounding gap.\n'

EARLIEST_MAIN=$(awk -F'\t' '$1 == "main" && $9 != "-" { print $9 }' "$TMP/priced" | sort | head -1)

# Bounded on neither, either or both sides — "-" means unbounded, same
# sentinel I1's own windows/TRAIL blocks use for "no prior commit" and "no
# closing commit". A fourth copy of the same four-way awk (F1 leaves
# deduplicating this and the two copies above out of scope for this plan).
price_main_range() {  # price_main_range <start|-> <end|-> -> "turns\ttok\tcost"
  local s="$1" e="$2"
  if [ "$s" != "-" ] && [ "$e" != "-" ]; then
    awk -F'\t' -v s="$s" -v e="$e" '
      $1 == "main" && $9 != "-" && $9 > s && $9 <= e { n++; tok += $4+$5+$6+$7; cost += $8 }
      END { printf "%d\t%d\t%.4f", n+0, tok+0, cost+0 }' "$TMP/priced"
  elif [ "$s" = "-" ] && [ "$e" != "-" ]; then
    awk -F'\t' -v e="$e" '
      $1 == "main" && $9 != "-" && $9 <= e { n++; tok += $4+$5+$6+$7; cost += $8 }
      END { printf "%d\t%d\t%.4f", n+0, tok+0, cost+0 }' "$TMP/priced"
  elif [ "$s" != "-" ] && [ "$e" = "-" ]; then
    awk -F'\t' -v s="$s" '
      $1 == "main" && $9 != "-" && $9 > s { n++; tok += $4+$5+$6+$7; cost += $8 }
      END { printf "%d\t%d\t%.4f", n+0, tok+0, cost+0 }' "$TMP/priced"
  else
    awk -F'\t' '
      $1 == "main" && $9 != "-" { n++; tok += $4+$5+$6+$7; cost += $8 }
      END { printf "%d\t%d\t%.4f", n+0, tok+0, cost+0 }' "$TMP/priced"
  fi
}

# The shared boundary list (I3). Columns: kind (setup|orch|close), the
# dispatch's own agent/tier/task ("-" when the row carries none), its
# occurrence number for that agent name (matching $TMP/join's own pairing —
# see below), and the window's start/end ("-" = unbounded). `lab_ts` (kept
# separate from `orch_start`, which a gap-absorbing dispatch pulls back to an
# earlier landmark) is the dispatch's OWN timestamp — needed so a trailing
# dispatch's absorbed turns still get priced into ITS row (not silently
# zero-width) while "close" still starts at that dispatch's own ts, not at
# the absorbed one. A version of this that reused orch_start for both lost
# the absorbed turns entirely — caught by X4's fixture below, not by hand.
: > "$TMP/phaserows"
if [ -f "$EVLOG" ]; then
  jq -r -s '
    [.[] | select(.event == "dispatch" or .event == "commit_landed")]
    | (reduce .[] as $e (
        {seen:false, prev:null, first:false, orch_start:null, occ:{},
         lab_agent:null, lab_tier:null, lab_task:null, lab_occ:null, lab_ts:null, out:[]};
        if $e.event == "dispatch" then
          ($e.agent // "unknown") as $a
          | ((.occ[$a] // 0) + 1) as $n
          | (.occ + {($a): $n}) as $occ2
          | if .seen then
              { seen:true, prev:.prev, first:true, orch_start:$e.ts, occ:$occ2,
                lab_agent:$a, lab_tier:($e.tier // "?"), lab_task:($e.task // "-"), lab_occ:$n, lab_ts:$e.ts,
                out: (.out + [{kind:"orch", agent:.lab_agent, tier:.lab_tier, task:.lab_task,
                               occ:.lab_occ, start:.orch_start, end:$e.ts}]) }
            else
              if .first then
                { seen:true, prev:.prev, first:true, orch_start:(.prev // $e.ts), occ:$occ2,
                  lab_agent:$a, lab_tier:($e.tier // "?"), lab_task:($e.task // "-"), lab_occ:$n, lab_ts:$e.ts,
                  out:.out }
              else
                { seen:true, prev:.prev, first:true, orch_start:$e.ts, occ:$occ2,
                  lab_agent:$a, lab_tier:($e.tier // "?"), lab_task:($e.task // "-"), lab_occ:$n, lab_ts:$e.ts,
                  out: (.out + [{kind:"setup", agent:null, tier:null, task:null, occ:null,
                                 start:"-", end:$e.ts}]) }
              end
            end
        else
          if .seen then
            { seen:false, prev:$e.ts, first:true, orch_start:null, occ:.occ,
              lab_agent:null, lab_tier:null, lab_task:null, lab_occ:null, lab_ts:null,
              out: (.out + [{kind:"orch", agent:.lab_agent, tier:.lab_tier, task:.lab_task,
                             occ:.lab_occ, start:.orch_start, end:$e.ts}]) }
          else
            { seen:false, prev:$e.ts, first:true, orch_start:null, occ:.occ,
              lab_agent:null, lab_tier:null, lab_task:null, lab_occ:null, lab_ts:null, out:.out }
          end
        end
      )) as $r
    | (if ($r.first | not) then
         [{kind:"setup", agent:null, tier:null, task:null, occ:null, start:"-", end:"-"}]
       elif $r.seen then
         # last landmark was a dispatch: its window is [orch_start, its own
         # ts) — real, possibly nonzero if it absorbed a leading gap — and
         # "close" starts at ITS OWN ts, never at the absorbed one.
         ($r.out + [{kind:"orch", agent:$r.lab_agent, tier:$r.lab_tier, task:$r.lab_task,
                      occ:$r.lab_occ, start:$r.orch_start, end:$r.lab_ts, last:true},
                     {kind:"close", agent:null, tier:null, task:null, occ:null,
                      start:$r.lab_ts, end:"-"}])
       else
         ($r.out + [{kind:"close", agent:null, tier:null, task:null, occ:null,
                      start:$r.prev, end:"-"}])
       end)
    | .[]
    | [.kind, (.agent // "-"), (.tier // "-"), (.task // "-"),
       (if .occ == null then "-" else (.occ|tostring) end), .start, .end,
       (if .last then "last" else "-" end)] | @tsv
  ' "$EVLOG" 2>/dev/null > "$TMP/phaserows" || :
fi
# Degenerate case: no dispatch and no commit_landed at all (X2) — the reduce
# above never runs its body, so `first` stays false and nothing is written.
# Same rule as the empty-EVLOG case: the whole main lane is setup.
if [ ! -s "$TMP/phaserows" ]; then
  printf 'setup\t-\t-\t-\t-\t-\t-\t-\n' > "$TMP/phaserows"
fi

# Unjoined the same way "What each worker run cost, and what it returned"
# already is (lines ~489-497): a dispatch's Nth occurrence for its agent name
# is joined only if $TMP/join (built above from dispatch + dispatch_launched,
# paired BY ORDER WITHIN AN AGENT NAME) has that many entries for the name —
# never a guess from the dispatch event's own (unconfirmed) fields alone.
: > "$TMP/joincount"
[ -s "$TMP/join" ] && awk -F'\t' '{c[$2]++} END{for (a in c) print a"\t"c[a]}' "$TMP/join" > "$TMP/joincount"

SAW_SETUP=0; SAW_CLOSE=0; SETUP_T=0; CLOSE_T=0
ORC_ANY=0; ORC_T=0; ORC_TOK=0; ORC_COST="0.0000"; ORC_UNJOINED=0
while IFS=$'\t' read -r kind agent tier task occ start end last; do
  case "$kind" in
    setup)
      SAW_SETUP=1
      if [ "$end" = "-" ]; then
        READOUT=$(price_main_range - -)
      elif [ -z "$EARLIEST_MAIN" ] || [[ "$end" < "$EARLIEST_MAIN" ]]; then
        printf '   setup          UNAVAILABLE — the first dispatch landed before any priced turn, setup window end unknown\n'
        continue
      else
        READOUT=$(price_main_range - "$end")
      fi
      IFS=$'\t' read -r T TOK COST <<< "$READOUT"
      SETUP_T=$T
      printf '   setup        %3d turn(s), %10d billable tok, API $est %8.2f\n' "$T" "$TOK" "$COST"
      ;;
    close)
      SAW_CLOSE=1
      READOUT=$(price_main_range "$start" -)
      IFS=$'\t' read -r T TOK COST <<< "$READOUT"
      CLOSE_T=$T
      printf '   close        %3d turn(s), %10d billable tok, API $est %8.2f\n' "$T" "$TOK" "$COST"
      ;;
    orch)
      ORC_ANY=1
      JC=$(awk -F'\t' -v a="$agent" '$1 == a { print $2 }' "$TMP/joincount" 2>/dev/null | head -1)
      if [ -n "$JC" ] && [ "$occ" -le "$JC" ] 2>/dev/null; then
        ROLE="$agent"; RTIER="$tier"; RTASK="$task"
      else
        ROLE="unjoined"; RTIER="?"; RTASK="-"; ORC_UNJOINED=$((ORC_UNJOINED + 1))
      fi
      if [ "$last" = "last" ]; then
        NOTE="  (session's last landmark — turns after its own timestamp are close, not orchestration)"
      else
        NOTE=""
      fi
      if [ -z "$EARLIEST_MAIN" ] || [[ "$end" < "$EARLIEST_MAIN" ]]; then
        printf '   orchestration %-12s %-7s %-5s UNAVAILABLE — dispatch landed before any priced turn, window end unknown\n' \
          "$ROLE" "$RTIER" "$RTASK"
        continue
      fi
      READOUT=$(price_main_range "$start" "$end")
      IFS=$'\t' read -r T TOK COST <<< "$READOUT"
      ORC_T=$((ORC_T + T)); ORC_TOK=$((ORC_TOK + TOK))
      ORC_COST=$(awk -v a="$ORC_COST" -v b="$COST" 'BEGIN { printf "%.4f", a+b }')
      printf '   orchestration %-12s %-7s %-5s turns %3d  tok %10d  API $est %8.2f%s\n' \
        "$ROLE" "$RTIER" "$RTASK" "$T" "$TOK" "$COST" "$NOTE"
      ;;
  esac
done < "$TMP/phaserows"
[ "$SAW_SETUP" -eq 1 ] || printf '   setup          0 turn(s) — the session'"'"'s first landmark was a commit, not a dispatch\n'
[ "$ORC_ANY" -eq 1 ] || printf '   orchestration  no dispatches this session\n'
if [ "$ORC_ANY" -eq 1 ]; then
  printf '   orchestration TOTAL: turns %3d  tok %10d  API $est %8.2f\n' "$ORC_T" "$ORC_TOK" "$ORC_COST"
  if [ "$ORC_UNJOINED" -gt 0 ]; then
    printf '   unjoined dispatches: %d — no dispatch_launched event carried their agent_id.\n' "$ORC_UNJOINED"
    printf '   Their turns and costs above are real; their roles are not, and nothing is\n'
    printf '   attributed by guess.\n'
  fi
fi

DL_T=0; DL_TOK=0; DL_COST="0.0000"
if [ -s "$TMP/windows" ]; then
  while IFS=$'\t' read -r _wh wstart wend _wr; do
    READOUT=$(price_main_range "$wstart" "$wend")
    IFS=$'\t' read -r T TOK COST <<< "$READOUT"
    DL_T=$((DL_T + T)); DL_TOK=$((DL_TOK + TOK))
    DL_COST=$(awk -v a="$DL_COST" -v b="$COST" 'BEGIN { printf "%.4f", a+b }')
  done < "$TMP/windows"
fi
printf '   direct-lane  %3d turn(s), %10d billable tok, API $est %8.2f  (same windows as "Chair-authored windows" above, summed — AC-2)\n' \
  "$DL_T" "$DL_TOK" "$DL_COST"

[ "$SAW_CLOSE" -eq 1 ] || printf '   close          0 turn(s)\n'

# AC-2 COVERS COMMITTED WINDOWS ONLY (plan 013, decision 2). The windows block's
# "trailing" row is a ceiling on chair work after the last commit that closed
# no commit — including the tail after a dispatch. This block does not count it
# as direct-lane: those turns fall to close (after the last landmark) and
# orchestration (a dispatch between the last commit and the last landmark), or
# setup when no commit ever landed. Say so, with the split, rather than let the
# two blocks disagree silently.
if [ -n "${TRAIL:-}" ]; then
  IFS=$'\t' read -r TR_START _tr_reason <<< "$TRAIL"
  IFS=$'\t' read -r TR_T _tr_tok _tr_cost <<< "$(price_main_range "$TR_START" -)"
  if [ "$TR_T" -gt 0 ]; then
    if [ "$TR_START" = "-" ]; then
      printf '   note: the windows-block tail after the last commit (%d turn(s)) is not direct-lane here — %d in close, %d in setup/orchestration\n' \
        "$TR_T" "$CLOSE_T" "$((TR_T - CLOSE_T))"
    else
      printf '   note: the windows-block tail after the last commit (%d turn(s)) is not direct-lane here — %d in close, %d in orchestration\n' \
        "$TR_T" "$CLOSE_T" "$((TR_T - CLOSE_T))"
    fi
  fi
fi
