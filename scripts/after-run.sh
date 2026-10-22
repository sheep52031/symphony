#!/usr/bin/env bash
# `hooks.after_run` entry point (JARVIS-3793): verify the attempt, then hand a passing PR to the headless Operator.
# See docs/post-run-gate.md ("Operator") and jarvis-personal docs/operator.md.
#
#   after-run.sh [WORKSPACE]      (Symphony runs it as `sh -lc` with the workspace as cwd)
#
# 1. scripts/verify-run.sh writes <runs>/<issue>/verify.json. <runs> is `<workspace root>/runs`, the same file
#    `agent.verify_record_path` (default `runs/<issue>/verify.json`, relative to the workspace root) makes the
#    runtime read. The workspace root is the parent of the workspace.
# 2. Only a real (dry_run=false) `pass` with a PR starts the Operator: jarvis-personal scripts/operator/run.sh,
#    detached (setsid + nohup) so the hook returns at once and the claude -p run does not count against
#    hooks.timeout_ms. A fail verdict never starts it; the runtime already comments and moves the issue to Rework.
#
# Exit status is always verify-run.sh's (0 pass, 1 fail, 2 error); Symphony discards it.
#
# Environment (all optional):
#   SYMPHONY_REPO       operator checkout holding scripts/verify-run.sh (default ~/Developer/Project/symphony)
#   JARVIS_PERSONAL     jarvis-personal checkout holding scripts/operator/run.sh (default ~/Developer/Project/jarvis-personal)
#   VERIFY_RUNS_DIR     overrides <workspace root>/runs; set it to the same value as agent.verify_record_path's directory
#   OPERATOR_DISABLE=1  verify only, never start the Operator
#   OPERATOR_LOCAL_REPO checkout the Operator fast-forwards in step 4 (default $SYMPHONY_REPO)
#   VERIFY_RUN_SCRIPT   verify script to run (test seam)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${1:-$PWD}" && pwd)"
SYMPHONY_REPO="${SYMPHONY_REPO:-$HOME/Developer/Project/symphony}"
JARVIS_PERSONAL="${JARVIS_PERSONAL:-$HOME/Developer/Project/jarvis-personal}"
VERIFY_SCRIPT="${VERIFY_RUN_SCRIPT:-$SELF_DIR/verify-run.sh}"
export VERIFY_RUNS_DIR="${VERIFY_RUNS_DIR:-$(dirname "$WORKSPACE")/runs}"

bash "$VERIFY_SCRIPT" "$WORKSPACE"
rc=$?

[ "${OPERATOR_DISABLE:-0}" = 1 ] && exit "$rc"
command -v jq >/dev/null || { echo "after-run: jq is required to start the Operator" >&2; exit "$rc"; }

issue="$(basename "$WORKSPACE" | sed -E 's/--[0-9a-f]{16}$//')"
record="$VERIFY_RUNS_DIR/$issue/verify.json"
[ -f "$record" ] || { echo "after-run: no $record, Operator not started" >&2; exit "$rc"; }

pass="$(jq -r '(.verdict == "pass") and (.dry_run == false) and ((.pr.number // 0) > 0)' "$record" 2>/dev/null)"
if [ "$pass" != true ]; then
  echo "after-run: $issue verdict is not a real pass with a PR, Operator not started" >&2
  exit "$rc"
fi

operator="$JARVIS_PERSONAL/scripts/operator/run.sh"
[ -f "$operator" ] || { echo "after-run: $operator missing (set JARVIS_PERSONAL), Operator not started" >&2; exit "$rc"; }

pr="$(jq -r '.pr.number' "$record")"
export OPERATOR_LOCAL_REPO="${OPERATOR_LOCAL_REPO:-$SYMPHONY_REPO}"
export JARVIS_PERSONAL
setsid nohup bash "$operator" "$issue" "$pr" >>"$VERIFY_RUNS_DIR/$issue/operator-launch.log" 2>&1 </dev/null &
echo "after-run: Operator started for $issue PR #$pr (log: $VERIFY_RUNS_DIR/$issue/operator.log)" >&2
exit "$rc"
