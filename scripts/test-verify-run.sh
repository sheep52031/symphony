#!/usr/bin/env bash
# Self-test for scripts/verify-run.sh: builds throwaway git workspaces and checks the verdicts. No network, no real
# gh/Linear: the dry cases use VERIFY_RUN_DRY=1, the live-path case puts fake `gh` and `curl` first on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export VERIFY_RUNS_DIR="$TMP/runs" VERIFY_WORKFLOW="$TMP/no-workflow.md"
unset LINEAR_API_KEY

failures=0
check() { # description, command...
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; failures=$((failures + 1)); fi
}
json_is() { [ "$(jq -r "$2" "$TMP/runs/$1/verify.json")" = "$3" ]; }

# A bare "remote" plus a clone, so `@{u}` exists. $1 name, $2 test script body.
make_workspace() {
  local name="$1" test_body="$2"
  git init -q --bare "$TMP/$name.git"
  git clone -q "$TMP/$name.git" "$TMP/ws/$name" 2>/dev/null
  git -C "$TMP/ws/$name" checkout -q -b feature
  printf '#!/bin/sh\n%s\n' "$test_body" >"$TMP/ws/$name/run-tests.sh"
  git -C "$TMP/ws/$name" add run-tests.sh
  git -C "$TMP/ws/$name" commit -q -m "initial"
  git -C "$TMP/ws/$name" push -q -u origin feature 2>/dev/null
}
mkdir -p "$TMP/ws"

# --- 1. failing workspace: failing tests, uncommitted file, unpushed commit -> fail --------------------------------
make_workspace bad 'echo "1 test, 1 failure"; exit 1'
echo change >"$TMP/ws/bad/more.txt"; git -C "$TMP/ws/bad" add more.txt; git -C "$TMP/ws/bad" commit -q -m "unpushed"
echo scratch >"$TMP/ws/bad/untracked.txt"
set +e
VERIFY_RUN_DRY=1 VERIFY_TEST_COMMAND="sh run-tests.sh" bash "$VERIFY" "$TMP/ws/bad" BAD-1 >"$TMP/bad.out" 2>&1
bad_rc=$?
set -e
check "bad workspace exits 1" [ "$bad_rc" = 1 ]
check "bad verdict is fail" json_is BAD-1 .verdict fail
check "bad: dirty tree detected" json_is BAD-1 '.facts[] | select(.name == "clean_tree") | .ok' false
check "bad: unpushed commit detected" json_is BAD-1 '.facts[] | select(.name == "pushed") | .ok' false
check "bad: failing tests detected" json_is BAD-1 '.facts[] | select(.name == "tests") | .ok' false
check "bad: test exit code and tail kept" json_is BAD-1 '[.tests.exit_code, (.tests.tail | contains("1 failure"))] | @csv' '1,true'
check "bad: comment is signed and says Rework" grep -q 'Next state: Rework' "$TMP/runs/BAD-1/comment.md"
check "bad: comment signature" grep -q '🤖 Symphony' "$TMP/runs/BAD-1/comment.md"

# --- 2. clean workspace: clean, pushed, tests pass -> pass --------------------------------------------------------
make_workspace good 'echo "3 tests, 0 failures"; exit 0'
VERIFY_RUN_DRY=1 VERIFY_TEST_COMMAND="sh run-tests.sh" bash "$VERIFY" "$TMP/ws/good" GOOD-2 >"$TMP/good.out" 2>&1
check "good verdict is pass" json_is GOOD-2 .verdict pass
check "good: head recorded" json_is GOOD-2 '.workspace_head == "'"$(git -C "$TMP/ws/good" rev-parse HEAD)"'"' true
check "good: schema keys" json_is GOOD-2 '[.verdict, .facts, .pr, .tests, .checked_at, .workspace_head] | map(type) | join(",")' 'string,array,null,object,string,string'
check "good: dry run is marked" json_is GOOD-2 .dry_run true
check "good: comment says Human Review" grep -q 'Next state: Human Review' "$TMP/runs/GOOD-2/comment.md"

# --- 3. no upstream counts as unpushed; no test command fails closed ------------------------------------------------
git init -q "$TMP/ws/lonely"; echo x >"$TMP/ws/lonely/f"; git -C "$TMP/ws/lonely" add f; git -C "$TMP/ws/lonely" commit -q -m c
set +e; VERIFY_RUN_DRY=1 bash "$VERIFY" "$TMP/ws/lonely" LONELY-3 >/dev/null 2>&1; set -e
check "no upstream -> pushed=false" json_is LONELY-3 '.facts[] | select(.name == "pushed") | .ok' false
check "no test command -> tests=false" json_is LONELY-3 '.facts[] | select(.name == "tests") | .ok' false

# --- 4. issue id derived from the workspace dir name; test command read from WORKFLOW front matter -----------------
mkdir -p "$TMP/derive"
git clone -q "$TMP/good.git" "$TMP/derive/JARVIS-77--0123456789abcdef" 2>/dev/null
git -C "$TMP/derive/JARVIS-77--0123456789abcdef" checkout -q feature
cat >"$TMP/wf.md" <<'EOF'
---
tracker:
  kind: linear
verify:
  test_command: "sh run-tests.sh"
  test_timeout_s: 30
---
body
EOF
(cd "$TMP/derive/JARVIS-77--0123456789abcdef" && VERIFY_WORKFLOW="$TMP/wf.md" VERIFY_RUN_DRY=1 bash "$VERIFY" >/dev/null 2>&1)
check "issue id derived from workspace dir" json_is JARVIS-77 .verdict pass
check "test command read from WORKFLOW front matter" json_is JARVIS-77 .tests.command 'sh run-tests.sh'

# --- 5. live path with fake gh + curl: PR found, CI failing, Linear comment + state change ------------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/bin/sh
case "$*" in
  "pr list"*) echo '[{"number":42,"url":"https://github.com/o/r/pull/42","isDraft":false,"state":"OPEN"}]' ;;
  "pr checks"*) echo '[{"name":"build","bucket":"pass"},{"name":"lint","bucket":"fail"}]'; exit 8 ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
body=$(cat)
echo "$body" >>"$FAKE_CURL_LOG"
case "$body" in
  *'issue(id: $id)'*) echo '{"data":{"issue":{"id":"uuid-1","state":{"name":"In Progress"},"team":{"states":{"nodes":[{"id":"s-rw","name":"Rework"},{"id":"s-hr","name":"Human Review"}]}}}}}' ;;
  *) echo '{"data":{"success":true}}' ;;
esac
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"
export FAKE_CURL_LOG="$TMP/curl.log"; : >"$FAKE_CURL_LOG"
set +e
PATH="$TMP/bin:$PATH" LINEAR_API_KEY=lin_api_testtoken123456 VERIFY_TEST_COMMAND="sh run-tests.sh" \
  bash "$VERIFY" "$TMP/ws/good" LIVE-4 >"$TMP/live.out" 2>&1
live_rc=$?
set -e
check "live: failing CI -> fail" json_is LIVE-4 '.facts[] | select(.name == "ci") | .detail' 'failing: lint'
check "live: PR captured" json_is LIVE-4 .pr.number 42
check "live: exits 1" [ "$live_rc" = 1 ]
check "live: Linear comment sent with signature" grep -q 'commentCreate.*Symphony post-run verification: FAIL.*🤖 Symphony' "$FAKE_CURL_LOG"
check "live: issue moved to Rework" grep -q '"s":"s-rw"' "$FAKE_CURL_LOG"
check "live: token never printed" bash -c '! grep -q lin_api_testtoken "$1" "$2"' _ "$TMP/live.out" "$TMP/runs/LIVE-4/verify.json"

echo
if [ "$failures" = 0 ]; then echo "all verify-run checks passed"; else echo "$failures check(s) failed"; exit 1; fi
