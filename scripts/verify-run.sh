#!/usr/bin/env bash
# Post-run gate: after a worker attempt ends, re-derive the facts instead of trusting the worker's own report.
# Wired in as `hooks.after_run` of elixir/WORKFLOW.md. See docs/post-run-gate.md.
#
#   verify-run.sh [WORKSPACE] [ISSUE_ID]
#
# The after_run hook is run by Symphony as `sh -lc <command>` with the workspace as cwd and no hook-specific
# arguments or environment, so both parameters are optional: WORKSPACE defaults to $PWD and ISSUE_ID is derived from
# the workspace directory name (Workspace.workspace_key: the identifier, or "<safe id>--<16 hex>" when sanitised).
#
# Facts checked: clean_tree, pushed, pr, ci, tests. Result: <runs>/<issue>/verify.json (+ comment.md, test.log).
# Unless VERIFY_RUN_DRY=1 it also comments on the Linear issue and moves it to Rework (fail) or Human Review (pass).
# Exit status: 0 pass, 1 fail, 2 usage/internal error (Symphony ignores after_run exit codes; the log shows them).
#
# Environment (all optional):
#   VERIFY_RUN_DRY=1          skip gh and Linear; the pr/ci facts are recorded as skipped, verdict stays honest
#   VERIFY_TEST_COMMAND       overrides `verify.test_command` of the WORKFLOW front matter
#   VERIFY_TEST_TIMEOUT_S     overrides `verify.test_timeout_s` (default 1500)
#   VERIFY_CI_WAIT_S          overrides `verify.ci_wait_s`: poll pending checks this long (default 0)
#   VERIFY_WORKER_LOG         overrides `verify.worker_log`: Symphony log file to take the worker tail from
#   VERIFY_WORKFLOW           WORKFLOW.md to read the settings from (default <repo>/elixir/WORKFLOW.md)
#   VERIFY_RUNS_DIR           where runs/<issue>/ lives (default <repo>/runs; kept outside the workspace on purpose)
#   VERIFY_ISSUE_ID           issue identifier when ISSUE_ID is not passed
#   LINEAR_API_KEY            token for the Linear GraphQL API; never printed or written
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$(cd "${1:-$PWD}" && pwd)"
DRY="${VERIFY_RUN_DRY:-0}"
WORKFLOW="${VERIFY_WORKFLOW:-$REPO_ROOT/elixir/WORKFLOW.md}"
LINEAR_ENDPOINT="${VERIFY_LINEAR_ENDPOINT:-https://api.linear.app/graphql}"

for tool in git jq; do
  command -v "$tool" >/dev/null || { echo "verify-run: $tool is required" >&2; exit 2; }
done

ISSUE="${2:-${VERIFY_ISSUE_ID:-}}"
if [ -z "$ISSUE" ]; then
  ISSUE="$(basename "$WORKSPACE" | sed -E 's/--[0-9a-f]{16}$//')"
fi
case "$ISSUE" in ''|*[!A-Za-z0-9._-]*) echo "verify-run: unusable issue id '$ISSUE'" >&2; exit 2 ;; esac

RUN_DIR="${VERIFY_RUNS_DIR:-$REPO_ROOT/runs}/$ISSUE"
mkdir -p "$RUN_DIR"
FACTS="$RUN_DIR/.facts.jsonl"
: >"$FACTS"

# --- settings: env > WORKFLOW.md `verify:` block (flat `key: value` lines, quotes optional) -----------------------
verify_setting() {
  [ -f "$WORKFLOW" ] || return 0
  awk -v key="$1" '
    /^---[[:space:]]*$/ { fences++; if (fences == 2) exit; next }
    fences == 1 && /^verify:[[:space:]]*$/ { in_verify = 1; next }
    fences == 1 && in_verify && /^[^[:space:]#]/ { in_verify = 0 }
    fences == 1 && in_verify {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (index(line, key ":") == 1) {
        value = substr(line, length(key) + 2)
        sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
        if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
        print value; exit
      }
    }' "$WORKFLOW"
}
TEST_COMMAND="${VERIFY_TEST_COMMAND:-$(verify_setting test_command)}"
TEST_TIMEOUT_S="${VERIFY_TEST_TIMEOUT_S:-$(verify_setting test_timeout_s)}"; TEST_TIMEOUT_S="${TEST_TIMEOUT_S:-1500}"
CI_WAIT_S="${VERIFY_CI_WAIT_S:-$(verify_setting ci_wait_s)}"; CI_WAIT_S="${CI_WAIT_S:-0}"
WORKER_LOG="${VERIFY_WORKER_LOG:-$(verify_setting worker_log)}"
WORKER_LOG="${WORKER_LOG/#\~/$HOME}"

# Tails end up in Linear comments and JSON: scrub the token shapes we know.
redact() { sed -E 's/(lin_api_|ghp_|gho_|github_pat_|sk-)[A-Za-z0-9_-]{8,}/\1[redacted]/g'; }

add_fact() { # name ok(true|false) detail
  jq -cn --arg name "$1" --argjson ok "$2" --arg detail "$3" '{name: $name, ok: $ok, detail: $detail}' >>"$FACTS"
}

git_ws() { git -C "$WORKSPACE" "$@"; }

# --- attempt counter ---------------------------------------------------------------------------------------------
ATTEMPT=$(( $(cat "$RUN_DIR/attempt" 2>/dev/null || echo 0) + 1 ))
echo "$ATTEMPT" >"$RUN_DIR/attempt"

# --- (a) git: clean tree, nothing unpushed -----------------------------------------------------------------------
HEAD_SHA="unknown"; BRANCH=""
if git_ws rev-parse --git-dir >/dev/null 2>&1; then
  HEAD_SHA="$(git_ws rev-parse HEAD 2>/dev/null || echo unborn)"
  BRANCH="$(git_ws rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  DIRTY="$(git_ws status --porcelain)"
  if [ -z "$DIRTY" ]; then
    add_fact clean_tree true "no uncommitted changes"
  else
    add_fact clean_tree false "$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ') uncommitted path(s): $(printf '%s\n' "$DIRTY" | head -5 | tr '\n' ';')"
  fi
  if UPSTREAM="$(git_ws rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
    AHEAD="$(git_ws rev-list --count '@{u}..HEAD')"
    if [ "$AHEAD" = 0 ]; then
      add_fact pushed true "HEAD is on $UPSTREAM"
    else
      add_fact pushed false "$AHEAD commit(s) ahead of $UPSTREAM"
    fi
  else
    add_fact pushed false "branch '${BRANCH:-?}' has no upstream, so its commits count as unpushed"
  fi
else
  add_fact clean_tree false "$WORKSPACE is not a git repository"
  add_fact pushed false "not a git repository"
fi

# --- (b) PR and CI -----------------------------------------------------------------------------------------------
PR_JSON='null'
if [ "$DRY" = 1 ]; then
  add_fact pr true "skipped: VERIFY_RUN_DRY=1"
  add_fact ci true "skipped: VERIFY_RUN_DRY=1"
elif ! command -v gh >/dev/null; then
  add_fact pr false "gh is not installed"
  add_fact ci false "gh is not installed"
elif [ -z "$BRANCH" ] || [ "$BRANCH" = HEAD ]; then
  add_fact pr false "workspace is on a detached HEAD, no branch to look a PR up by"
  add_fact ci false "no PR"
else
  if PR_LIST="$(cd "$WORKSPACE" && gh pr list --head "$BRANCH" --state all --json number,url,isDraft,state 2>&1)"; then
    # Prefer an open PR; otherwise the most recent one.
    PR_JSON="$(printf '%s' "$PR_LIST" | jq -c '(map(select(.state == "OPEN")) + (sort_by(.number) | reverse)) | (.[0] // null)')"
  else
    PR_JSON='null'
    add_fact pr false "gh pr list failed: $(printf '%s' "$PR_LIST" | head -1 | redact)"
  fi
  if [ "$PR_JSON" = null ]; then
    # Only add the "no PR" fact when gh itself did not fail.
    grep -q '"name":"pr"' "$FACTS" || add_fact pr false "no pull request for branch '$BRANCH'"
    add_fact ci false "no PR to read checks from"
  else
    PR_NUM="$(jq -r .number <<<"$PR_JSON")"; PR_URL="$(jq -r .url <<<"$PR_JSON")"
    PR_STATE="$(jq -r .state <<<"$PR_JSON")"; PR_DRAFT="$(jq -r .isDraft <<<"$PR_JSON")"
    if [ "$PR_DRAFT" = true ]; then
      add_fact pr false "PR #$PR_NUM is a draft ($PR_URL)"
    elif [ "$PR_STATE" = CLOSED ]; then
      add_fact pr false "PR #$PR_NUM is closed without merge ($PR_URL)"
    else
      add_fact pr true "PR #$PR_NUM $PR_STATE ($PR_URL)"
    fi
    deadline=$(( $(date +%s) + CI_WAIT_S ))
    while :; do
      CHECKS="$(cd "$WORKSPACE" && gh pr checks "$PR_NUM" --json name,bucket 2>&1)" || true
      if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$CHECKS"; then
        # `gh pr checks` also exits non-zero with "no checks reported"; that is a repo without CI, not a failure.
        if grep -qi 'no checks reported' <<<"$CHECKS"; then CI_OK=true; CI_DETAIL="no checks reported"; else CI_OK=false; CI_DETAIL="gh pr checks failed: $(head -1 <<<"$CHECKS" | redact)"; fi
        break
      fi
      BAD="$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")' <<<"$CHECKS")"
      PENDING="$(jq -r '[.[] | select(.bucket == "pending") | .name] | join(", ")' <<<"$CHECKS")"
      TOTAL="$(jq 'length' <<<"$CHECKS")"
      if [ -n "$BAD" ]; then CI_OK=false; CI_DETAIL="failing: $BAD"; break; fi
      if [ -z "$PENDING" ]; then CI_OK=true; CI_DETAIL="$TOTAL check(s) passing or skipped"; [ "$TOTAL" = 0 ] && CI_DETAIL="no checks reported"; break; fi
      if [ "$(date +%s)" -ge "$deadline" ]; then CI_OK=false; CI_DETAIL="still pending after ${CI_WAIT_S}s: $PENDING"; break; fi
      sleep 15
    done
    add_fact ci "$CI_OK" "$CI_DETAIL"
  fi
fi

# --- (c) tests: re-run, never trust the worker ---------------------------------------------------------------------
TEST_EXIT=null; TEST_TAIL=""
if [ -z "$TEST_COMMAND" ]; then
  add_fact tests false "no verify.test_command configured (WORKFLOW.md front matter or VERIFY_TEST_COMMAND)"
else
  set +e
  ( cd "$WORKSPACE" && timeout "${TEST_TIMEOUT_S}s" bash -lc "$TEST_COMMAND" ) >"$RUN_DIR/test.log" 2>&1
  TEST_EXIT=$?
  set -e
  TEST_TAIL="$(tail -n 40 "$RUN_DIR/test.log" | redact)"
  if [ "$TEST_EXIT" = 0 ]; then
    add_fact tests true "exit 0"
  elif [ "$TEST_EXIT" = 124 ]; then
    add_fact tests false "timed out after ${TEST_TIMEOUT_S}s"
  else
    add_fact tests false "exit $TEST_EXIT"
  fi
fi

# --- (d) diagnostic tail of the worker's own output ---------------------------------------------------------------
WORKER_TAIL=""
if [ -n "$WORKER_LOG" ] && [ -f "$WORKER_LOG" ]; then
  WORKER_TAIL="$(grep -F -- "$ISSUE" "$WORKER_LOG" 2>/dev/null | tail -n 40 | redact || true)"
fi
printf '%s\n' "$WORKER_TAIL" >"$RUN_DIR/worker-tail.txt"

# --- (e) verify.json -----------------------------------------------------------------------------------------------
CHECKED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -s \
  --arg issue "$ISSUE" --arg workspace "$WORKSPACE" --arg branch "$BRANCH" --arg head "$HEAD_SHA" \
  --arg checked "$CHECKED_AT" --argjson attempt "$ATTEMPT" --argjson dry "$([ "$DRY" = 1 ] && echo true || echo false)" \
  --argjson pr "$PR_JSON" --arg cmd "$TEST_COMMAND" --argjson exit "$TEST_EXIT" --arg tail "$TEST_TAIL" --arg wtail "$WORKER_TAIL" '
  {
    verdict: (if all(.[]; .ok) then "pass" else "fail" end),
    issue: $issue,
    attempt: $attempt,
    facts: .,
    pr: $pr,
    tests: {command: $cmd, exit_code: $exit, tail: $tail},
    worker_tail: $wtail,
    dry_run: $dry,
    branch: $branch,
    workspace: $workspace,
    workspace_head: $head,
    checked_at: $checked
  }' "$FACTS" >"$RUN_DIR/verify.json.tmp"
mv "$RUN_DIR/verify.json.tmp" "$RUN_DIR/verify.json"
jq -c '{checked_at, attempt, verdict, facts: [.facts[] | {name, ok}]}' "$RUN_DIR/verify.json" >>"$RUN_DIR/history.jsonl"
rm -f "$FACTS"
VERDICT="$(jq -r .verdict "$RUN_DIR/verify.json")"

# --- comment body (fixed format) -----------------------------------------------------------------------------------
{
  echo "## Symphony post-run verification: $(echo "$VERDICT" | tr '[:lower:]' '[:upper:]') (attempt $ATTEMPT)"
  echo
  echo "| Fact | Result | Detail |"
  echo "| --- | --- | --- |"
  jq -r '.facts[] | "| \(.name) | \(if .ok then "pass" else "FAIL" end) | \(.detail | gsub("[|\n]"; " ")) |"' "$RUN_DIR/verify.json"
  echo
  echo "Workspace HEAD \`${HEAD_SHA:0:12}\` on \`${BRANCH:-?}\`, checked $CHECKED_AT. The tests above were re-run by the runtime, not reported by the worker."
  if [ "$VERDICT" = fail ] && [ -n "$TEST_TAIL" ] && [ "$TEST_EXIT" != 0 ]; then
    echo
    echo "Last lines of the test run:"
    echo '```'
    printf '%s\n' "$TEST_TAIL" | tail -n 15
    echo '```'
  fi
  echo
  echo "Next state: $([ "$VERDICT" = pass ] && echo 'Human Review' || echo 'Rework')."
  echo
  echo "🤖 Symphony"
} >"$RUN_DIR/comment.md"

# --- Linear: comment + state --------------------------------------------------------------------------------------
linear() { # query variables-json -> response json on stdout
  jq -cn --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}' |
    curl -sS --max-time 30 -X POST "$LINEAR_ENDPOINT" -H "Content-Type: application/json" \
      -H "Authorization: $LINEAR_API_KEY" --data-binary @-
}

LINEAR_NOTE="skipped (dry run)"
if [ "$DRY" != 1 ]; then
  if [ -z "${LINEAR_API_KEY:-}" ] || ! command -v curl >/dev/null; then
    LINEAR_NOTE="skipped: LINEAR_API_KEY or curl missing"
  else
    TARGET=$([ "$VERDICT" = pass ] && echo "Human Review" || echo "Rework")
    LOOKUP="$(linear 'query($id: String!) { issue(id: $id) { id state { name } team { states { nodes { id name } } } } }' \
      "$(jq -cn --arg id "$ISSUE" '{id: $id}')")" || LOOKUP=''
    LINEAR_ID="$(jq -r '.data.issue.id // empty' <<<"$LOOKUP" 2>/dev/null || true)"
    if [ -z "$LINEAR_ID" ]; then
      LINEAR_NOTE="issue lookup failed"
    else
      CURRENT="$(jq -r '.data.issue.state.name' <<<"$LOOKUP")"
      linear 'mutation($i: String!, $b: String!) { commentCreate(input: {issueId: $i, body: $b}) { success } }' \
        "$(jq -cn --arg i "$LINEAR_ID" --rawfile b "$RUN_DIR/comment.md" '{i: $i, b: $b}')" >/dev/null &&
        LINEAR_NOTE="commented" || LINEAR_NOTE="comment failed"
      # Only move issues the worker was still driving; never pull Done/Cancelled/Human Review/Merging back.
      case "$CURRENT" in
        Todo|"In Progress"|Rework)
          STATE_ID="$(jq -r --arg n "$TARGET" '.data.issue.team.states.nodes[] | select(.name == $n) | .id' <<<"$LOOKUP" | head -1)"
          if [ -n "$STATE_ID" ] && [ "$CURRENT" != "$TARGET" ]; then
            linear 'mutation($i: String!, $s: String!) { issueUpdate(id: $i, input: {stateId: $s}) { success } }' \
              "$(jq -cn --arg i "$LINEAR_ID" --arg s "$STATE_ID" '{i: $i, s: $s}')" >/dev/null &&
              LINEAR_NOTE="$LINEAR_NOTE; state $CURRENT -> $TARGET" || LINEAR_NOTE="$LINEAR_NOTE; state change failed"
          fi ;;
        *) LINEAR_NOTE="$LINEAR_NOTE; state '$CURRENT' left alone" ;;
      esac
    fi
  fi
fi

echo "verify-run: $ISSUE attempt $ATTEMPT verdict=$VERDICT linear=[$LINEAR_NOTE] -> $RUN_DIR/verify.json"
[ "$VERDICT" = pass ]
