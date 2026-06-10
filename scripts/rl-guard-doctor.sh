#!/usr/bin/env bash
# rl-guard-doctor — diagnostics for the rl-guard plugin
# Zero dependencies: grep|sed|bash only (no jq needed)
set -u

PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [OK]   $1"; }
warn() { WARN=$((WARN+1)); echo "  [WARN] $1"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
heading() { echo "═══ $1 ═══"; }

# --- Locate plugin root ---
ROOT=""
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && ROOT="$CLAUDE_PLUGIN_ROOT"
[ -z "$ROOT" ] && [ -f "$(dirname "$0")/../plugin.json" ] && ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -z "$ROOT" ] && [ -d "$HOME/.claude/plugins/rl-guard" ] && ROOT="$HOME/.claude/plugins/rl-guard"
[ -z "$ROOT" ] && { fail "Plugin root not found"; exit 1; }

heading "INSTALLATION"
[ -f "$ROOT/plugin.json" ] && ok "Plugin manifest" || fail "plugin.json missing"
VER=$(grep -m1 '"version"' "$ROOT/plugin.json" 2>/dev/null | sed 's/.*"version": *"\([^"]*\)".*/\1/')
[ -n "$VER" ] && ok "Version: $VER" || warn "Version not found"
[ -d "$ROOT/commands" ] && ok "Commands directory" || warn "No commands/"
[ -d "$ROOT/hooks" ] && ok "Hooks directory" || fail "No hooks/"
[ -d "$ROOT/scripts" ] && ok "Scripts directory" || fail "No scripts/"

heading "FILES & STRUCTURE"
for f in "plugin.json" "hooks/hooks.json" "scripts/rate-limit-guard.sh"; do
  [ -f "$ROOT/$f" ] && ok "File: $f" || fail "Missing: $f"
done
[ -f "$ROOT/scripts/rate-limit-guard.sh" ] && [ -x "$ROOT/scripts/rate-limit-guard.sh" ] && ok "Guard script executable" || fail "Guard script not executable"

heading "HOOKS"
if [ -f "$ROOT/hooks/hooks.json" ]; then
  grep -q '"PreToolUse"' "$ROOT/hooks/hooks.json" && ok "Hook: PreToolUse" || fail "Hook PreToolUse missing"
  grep -q '"Task"' "$ROOT/hooks/hooks.json" && ok "Matcher: Task" || fail "Task matcher missing"
fi

heading "CACHE"
CACHE_FILE="/tmp/claude_rl_pct"
if [ -f "$CACHE_FILE" ]; then
  PCT=$(cat "$CACHE_FILE" 2>/dev/null || echo "0")
  echo "$PCT" | grep -qE '^[0-9]+$' && ok "Cache: $PCT%" || warn "Cache: non-numeric ($PCT)"
else
  warn "Cache missing — guard always passes"
fi

heading "CONFIG"
THRESHOLD="${RL_GUARD_THRESHOLD:-90}"
echo "$THRESHOLD" | grep -qE '^[0-9]+$' && ok "Threshold: $THRESHOLD%" || warn "Threshold non-numeric: $THRESHOLD"

heading "DEPENDENCIES"
command -v jq &>/dev/null && ok "jq available" || warn "jq not found — guard will still work (agent_id check skipped)"

heading "ENVIRONMENT"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  grep -q '"rl-guard"' "$SETTINGS" 2>/dev/null && ok "Plugin enabled in settings.json" || warn "rl-guard not listed in settings.json"
else
  warn "settings.json not found"
fi

heading "FUNCTIONAL TEST"
TEST_OUT=$(echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' | bash "$ROOT/scripts/rate-limit-guard.sh" 2>/dev/null; echo $?)
GUARD_EXIT=$(echo "$TEST_OUT" | tail -1)
if [ "$GUARD_EXIT" = "2" ] || [ "$GUARD_EXIT" = "0" ]; then
  ok "Guard responds: exit $GUARD_EXIT"
else
  warn "Guard returned unexpected exit: $GUARD_EXIT"
fi

heading "SUMMARY"
TOTAL=$((PASS+WARN+FAIL))
if [ $FAIL -gt 0 ]; then
  echo "  ❌ $FAIL failed, $WARN warnings, $PASS passed (of $TOTAL)"
elif [ $WARN -gt 0 ]; then
  echo "  ⚠️  $WARN warnings, $PASS passed (of $TOTAL)"
else
  echo "  ✅ All $PASS checks passed"
fi
