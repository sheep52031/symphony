#!/usr/bin/env bash
# Self-test for scripts/after-run.sh: fake verify script and fake Operator, no network, no claude.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFTER="$SELF_DIR/after-run.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset VERIFY_RUNS_DIR OPERATOR_DISABLE LINEAR_API_KEY

failures=0
check() { local desc="$1"; shift; if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; failures=$((failures + 1)); fi; }

# Fake Operator: records its arguments and OPERATOR_LOCAL_REPO.
mkdir -p "$TMP/jp/scripts/operator"
cat >"$TMP/jp/scripts/operator/run.sh" <<'OP'
#!/usr/bin/env bash
sleep 1
echo "$1 $2 $OPERATOR_LOCAL_REPO" >>"$CALLS"
OP
# Fake verify: writes $RECORD_JSON into <runs>/<issue>/verify.json, exits $VERIFY_RC.
cat >"$TMP/verify.sh" <<'VF'
#!/usr/bin/env bash
issue="$(basename "$1" | sed -E 's/--[0-9a-f]{16}$//')"
mkdir -p "$VERIFY_RUNS_DIR/$issue"
[ -n "${RECORD_JSON:-}" ] && printf '%s' "$RECORD_JSON" >"$VERIFY_RUNS_DIR/$issue/verify.json"
echo "$VERIFY_RUNS_DIR" >"$VERIFY_RUNS_DIR/seen-runs-dir"
exit "${VERIFY_RC:-0}"
VF
export VERIFY_RUN_SCRIPT="$TMP/verify.sh" JARVIS_PERSONAL="$TMP/jp" SYMPHONY_REPO="$TMP/repo" CALLS="$TMP/calls"

run() { # workspace name, record json, verify rc
  mkdir -p "$TMP/root/$1"; : >"$CALLS"
  ( cd "$TMP/root/$1" && RECORD_JSON="$2" VERIFY_RC="$3" bash "$AFTER" ) >"$TMP/out" 2>&1
  echo $? >"$TMP/rc"
}
PASS='{"verdict":"pass","dry_run":false,"issue":"T-1","pr":{"number":7}}'

run T-1 "$PASS" 0; start=$SECONDS
check "pass: hook returns before the Operator finishes" [ ! -s "$CALLS" ]
check "pass: exit status is verify's" [ "$(cat "$TMP/rc")" = 0 ]
check "pass: runs dir is <workspace root>/runs" [ "$(cat "$TMP/root/runs/seen-runs-dir")" = "$TMP/root/runs" ]
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CALLS" ] && break; sleep 0.5; done
check "pass: Operator gets issue, PR and local repo" [ "$(cat "$CALLS")" = "T-1 7 $TMP/repo" ]

run T-2 '{"verdict":"fail","dry_run":false,"pr":{"number":7}}' 1; sleep 2
check "fail: Operator not started" [ ! -s "$CALLS" ]
check "fail: exit status is verify's" [ "$(cat "$TMP/rc")" = 1 ]

run T-3 '{"verdict":"pass","dry_run":true,"pr":null}' 0; sleep 2
check "dry run: Operator not started" [ ! -s "$CALLS" ]

run T-4 '{"verdict":"pass","dry_run":false,"pr":null}' 0; sleep 2
check "pass without PR: Operator not started" [ ! -s "$CALLS" ]

run T-5 "" 2; sleep 1
check "no record: Operator not started, status kept" [ ! -s "$CALLS" ] && [ "$(cat "$TMP/rc")" = 2 ]

mkdir -p "$TMP/root/T-6"; : >"$CALLS"
( cd "$TMP/root/T-6" && RECORD_JSON="$PASS" OPERATOR_DISABLE=1 bash "$AFTER" ) >/dev/null 2>&1; sleep 2
check "OPERATOR_DISABLE=1: Operator not started" [ ! -s "$CALLS" ]

mkdir -p "$TMP/root/T-8"; : >"$CALLS"
( cd "$TMP/root/T-8" && JARVIS_PERSONAL="$TMP/nowhere" RECORD_JSON="$PASS" bash "$AFTER" ) >"$TMP/out" 2>&1; echo $? >"$TMP/rc"; sleep 2
check "missing run.sh: no crash, status kept, message printed" [ "$(cat "$TMP/rc")" = 0 ] && grep -q 'missing' "$TMP/out"

echo; [ "$failures" = 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
