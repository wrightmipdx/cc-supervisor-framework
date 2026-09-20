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
  printf 'self-test OK — dedupe (split + id-less rows), join, verdict, /clear skip, no content leak, per-turn ratio, chair-windows (with/without turns, before-priced-turn), inputs untouched\n'
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
elif [ "$(jq -r -c 'select(.event == "commit_landed") | 1' "$EVLOG" 2>/dev/null | head -1)" != "1" ]; then
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
  jq -r -s '
    [.[] | select(.event == "dispatch" or .event == "commit_landed")]
    | reduce .[] as $e (
        {seen: false, prev: null, out: []};
        if $e.event == "dispatch" then
          {seen: true, prev: .prev, out: .out}
        elif .seen then
          {seen: false, prev: $e.ts, out: .out}
        else
          {seen: false, prev: $e.ts,
           out: (.out + [{head: (($e.head // "")[0:8]), start: .prev, end: $e.ts}])}
        end)
    | .out[]
    | [.head, (.start // "-"), .end] | @tsv
  ' "$EVLOG" 2>/dev/null > "$TMP/windows"

  if [ ! -s "$TMP/windows" ]; then
    printf '   UNAVAILABLE — no commit_landed events in %s, nothing to window\n' "$EVLOG"
  else
    # Earliest main-lane turn carrying a real timestamp — the floor below which
    # a window cannot be priced because this transcript does not cover it.
    EARLIEST_MAIN=$(awk -F'\t' '$1 == "main" && $9 != "-" { print $9 }' "$TMP/priced" | sort | head -1)

    # Median of this session's own briefed-run costs (Change 2's $TMP/runcost,
    # untouched). Absent or empty means no worker runs this session at all.
    HAVE_MEDIAN=0
    if [ -s "$TMP/runcost" ]; then
      HAVE_MEDIAN=1
      MEDIAN=$(awk -F'\t' '{ print $2 }' "$TMP/runcost" | sort -n | awk '
        { a[NR] = $1 }
        END { if (NR == 0) { print 0 }
              else if (NR % 2 == 1) { print a[(NR+1)/2] }
              else { print (a[NR/2] + a[NR/2+1]) / 2 } }')
    fi

    while IFS=$'\t' read -r head start end; do
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
      if [ "$HAVE_MEDIAN" -eq 1 ]; then
        RATIO=$(awk -v c="$WCOST" -v m="$MEDIAN" 'BEGIN { if (m+0 == 0) print "n/a"; else printf "%.1fx", c/m }')
        printf '   %-10s %d turn(s), %d billable tok, API $est %.2f ceiling  (%s the session'"'"'s median briefed-task cost)\n' \
          "$head" "$WT" "$WTOK" "$WCOST" "$RATIO"
      else
        printf '   %-10s %d turn(s), %d billable tok, API $est %.2f ceiling  (UNAVAILABLE — no worker runs this session to compare against)\n' \
          "$head" "$WT" "$WTOK" "$WCOST"
      fi
    done < "$TMP/windows"
  fi
fi
