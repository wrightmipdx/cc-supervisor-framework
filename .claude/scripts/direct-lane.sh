#!/usr/bin/env bash
# Chair-facing marker: run this at the moment you decide not to dispatch.
#
#   .claude/scripts/direct-lane.sh <task> <reason...>
#
# This script does nothing on its own -- it prints and exits 0. The actual
# logging happens in .claude/hooks/25-direct-lane.sh, a PreToolUse hook that
# intercepts the Bash call invoking this script and writes a `direct_lane`
# event to the session log, the same way `dispatch` is logged for a real
# delegation. session_id is only available inside a hook invocation (read
# from the harness's PreToolUse JSON on stdin) -- there is no environment
# variable exposing it to a plain script, so this cannot log itself.
#
# Safe to run directly: it never touches git, never writes anywhere, and
# always exits 0.

set -uo pipefail
printf 'direct-lane: logged\n'
exit 0
