#!/usr/bin/env bash
# test.sh — behavioral matrix for rl-guard. No CI; this is the regression check.
# Drives scripts/rate-limit-guard.sh through every path and exits non-zero if
# any case regresses. jq-optional: JSON-shape asserts SKIP when jq is absent,
# mirroring the plugin's soft-jq stance.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$DIR/rate-limit-guard.sh"
CACHE_FILE="/tmp/claude_rl_pct"
MAIN='{"tool_name":"Task","tool_input":{},"agent_id":""}'
SUB='{"tool_name":"Task","tool_input":{},"agent_id":"sub-123"}'

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
skip() { echo "  SKIP: $1"; }

# Back up any real cache; restore on exit so we never clobber the user's value.
BACKUP=""
[ -f "$CACHE_FILE" ] && { BACKUP="$(mktemp)"; cp "$CACHE_FILE" "$BACKUP"; }
cleanup() {
  if [ -n "$BACKUP" ]; then mv "$BACKUP" "$CACHE_FILE"; else rm -f "$CACHE_FILE"; fi
}
trap cleanup EXIT

# run <input-json> [env=val ...]  → sets globals OUT and EC
run() {
  local input="$1"; shift
  OUT=$(printf '%s' "$input" | env "$@" bash "$GUARD" 2>/dev/null); EC=$?
}

# Assert helpers operating on last run.
assert_ec()       { [ "$EC" = "$2" ] && pass "$1 (exit $2)" || fail "$1 (exit $EC, expected $2)"; }
assert_empty()    { [ -z "$OUT" ] && pass "$1 (no output)" || fail "$1 (got output: $OUT)"; }
assert_has()      { case "$OUT" in *"$2"*) pass "$1";; *) fail "$1 (missing '$2' in: $OUT)";; esac; }
assert_absent()   { case "$OUT" in *"$2"*) fail "$1 (unexpected '$2')";; *) pass "$1";; esac; }
assert_json_ask() {
  if [ "$HAS_JQ" = 1 ]; then
    echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision=="ask"' >/dev/null 2>&1 \
      && pass "$1 (valid JSON ask)" || fail "$1 (JSON ask invalid: $OUT)"
  else skip "$1 (jq absent)"; fi
}
assert_json_ctx() {
  if [ "$HAS_JQ" = 1 ]; then
    echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext and (.hookSpecificOutput|has("permissionDecision")|not)' >/dev/null 2>&1 \
      && pass "$1 (context, no permissionDecision)" || fail "$1 (JSON ctx invalid: $OUT)"
  else skip "$1 (jq absent)"; fi
}

echo "═══ rl-guard behavioral matrix ═══"

# 1. Subagent bypass — high pct must NOT gate a subagent.
# The bypass reads agent_id via jq; without jq it cannot fire (documented soft
# dependency), so this case is only asserted when jq is present.
if [ "$HAS_JQ" = 1 ]; then
  printf '99' > "$CACHE_FILE"
  run "$SUB"
  assert_ec "subagent bypass" 0
  assert_empty "subagent bypass: silent"
else
  skip "subagent bypass (jq absent — bypass needs jq)"
fi

# 2. Missing cache → fail open.
rm -f "$CACHE_FILE"
run "$MAIN"
assert_ec "missing cache" 0
assert_empty "missing cache: silent"

# 3. Junk value → fail open.
printf 'abc' > "$CACHE_FILE"
run "$MAIN"
assert_ec "junk value" 0
assert_empty "junk value: silent"

# 4. Stale cache (mtime old) → fail open even when high.
printf '99' > "$CACHE_FILE"; touch -d '30 minutes ago' "$CACHE_FILE"
run "$MAIN"
assert_ec "stale cache" 0
assert_empty "stale cache: silent"

# 5. Below warn → plain allow.
printf '50' > "$CACHE_FILE"
run "$MAIN"
assert_ec "below warn (50)" 0
assert_empty "below warn: silent"

# 6. Warn band (85, defaults) → additionalContext, no permissionDecision.
printf '85' > "$CACHE_FILE"
run "$MAIN"
assert_ec "warn band (85)" 0
assert_absent "warn band: not ask" '"permissionDecision"'
assert_json_ctx "warn band: context"

# 6b. Warn boundary — exactly WARN default (80) must warn (>= boundary).
printf '80' > "$CACHE_FILE"
run "$MAIN"
assert_absent "warn boundary (80): not ask" '"permissionDecision"'
assert_json_ctx "warn boundary (80): context"

# 7. Block (95, defaults) → permissionDecision ask, exit 0.
printf '95' > "$CACHE_FILE"
run "$MAIN"
assert_ec "block (95)" 0
assert_has "block: reason has pct" '95'
assert_json_ask "block: ask"

# 7b. Block boundary — exactly THRESHOLD default (90) must block (>= boundary).
# Catches a -ge → -gt regression that higher values would miss.
printf '90' > "$CACHE_FILE"
run "$MAIN"
assert_has "block boundary (90): ask" '"permissionDecision":"ask"'
assert_json_ask "block boundary (90): valid"

# 8. Env override — raised threshold turns a would-be block into a warn.
printf '92' > "$CACHE_FILE"
run "$MAIN" RL_GUARD_THRESHOLD=95
assert_ec "override threshold=95 @92" 0
assert_absent "override: 92 not block" '"permissionDecision"'
assert_json_ctx "override: 92 warns instead"

# 9. Env override — lowered warn fires earlier.
printf '75' > "$CACHE_FILE"
run "$MAIN" RL_GUARD_WARN=70
assert_json_ctx "override warn=70 @75"

# 10. Env override — custom reset string appears in block reason.
printf '95' > "$CACHE_FILE"
run "$MAIN" RL_GUARD_RESET="09:00 UTC"
assert_has "override reset copy" '09:00 UTC'

# 11. Escaping — reset string with a double-quote stays valid JSON.
printf '95' > "$CACHE_FILE"
run "$MAIN" RL_GUARD_RESET='a "quoted" reset'
assert_json_ask "escaped quote: still valid JSON"

echo "═══ SUMMARY ═══"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
