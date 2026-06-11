#!/usr/bin/env bash
# test-statusline.sh — regression matrix for the v1.2 statusline producer and
# the install/uninstall wiring. Sandboxed: producer cache tests back up and
# restore the real /tmp/claude_rl_pct; wiring tests run against a throwaway
# HOME. jq-optional asserts SKIP without jq; the no-jq fallbacks are exercised
# with a coreutils-only PATH that masks jq. Exits non-zero on any failure.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
PRODUCER="$DIR/statusline-producer.sh"
INSTALL="$REPO/bin/install.sh"
UNINSTALL="$REPO/bin/uninstall.sh"
CACHE_FILE="/tmp/claude_rl_pct"

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
BASH_BIN="$(command -v bash)"   # absolute, so PATH-masked invocations still find bash

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
skip() { echo "  SKIP: $1"; }
ck()   { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2' want '$3')"; fi; }

# Back up any real cache; restore on exit.
BACKUP=""
[ -f "$CACHE_FILE" ] && { BACKUP="$(mktemp)"; cp "$CACHE_FILE" "$BACKUP"; }
cleanup() { if [ -n "$BACKUP" ]; then mv "$BACKUP" "$CACHE_FILE"; else rm -f "$CACHE_FILE"; fi; }
trap cleanup EXIT

# Build a coreutils-only PATH that does NOT contain jq, for no-jq fallback tests.
MASK="$(mktemp -d)"
for b in cat basename dirname mktemp cp mv rm mkdir chmod grep sed env touch find sort head; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -s "$src" "$MASK/$b" 2>/dev/null || true
done

echo "═══ statusline producer ═══"

# Producer cache write — needs jq (float math + JSON parse).
if [ "$HAS_JQ" = 1 ]; then
  ROOT="$(mktemp -d)"   # empty plugin root → no sidecar → fallback render

  rm -f "$CACHE_FILE"
  echo '{"rate_limits":{"five_hour":{"used_percentage":23.5},"seven_day":{"used_percentage":41.2}}}' \
    | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PRODUCER" >/dev/null
  ck "max+round (23.5,41.2)->41" "$(cat "$CACHE_FILE" 2>/dev/null)" "41"

  rm -f "$CACHE_FILE"
  echo '{"rate_limits":{"five_hour":{"used_percentage":90.6},"seven_day":{"used_percentage":10}}}' \
    | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PRODUCER" >/dev/null
  ck "round-up max (90.6,10)->91" "$(cat "$CACHE_FILE" 2>/dev/null)" "91"

  rm -f "$CACHE_FILE"
  echo '{"rate_limits":{"seven_day":{"used_percentage":55.0}}}' \
    | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PRODUCER" >/dev/null
  ck "single window (seven_day)->55" "$(cat "$CACHE_FILE" 2>/dev/null)" "55"

  printf '77' > "$CACHE_FILE"
  echo '{"model":{"display_name":"X"}}' | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PRODUCER" >/dev/null
  ck "absent rate_limits leaves cache" "$(cat "$CACHE_FILE" 2>/dev/null)" "77"

  printf '77' > "$CACHE_FILE"
  OUT=$(echo 'not json' | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PRODUCER"); EC=$?
  ck "malformed: exit 0" "$EC" "0"
  ck "malformed: cache untouched" "$(cat "$CACHE_FILE" 2>/dev/null)" "77"
  [ -n "$OUT" ] && pass "malformed: bar non-empty" || fail "malformed: bar empty"

  # Compose: sidecar inner command rendered verbatim, recursion-guarded.
  J='{"rate_limits":{"five_hour":{"used_percentage":30}},"model":{"display_name":"Op"},"workspace":{"current_dir":"/a/proj"}}'
  printf "printf 'MYBAR'" > "$ROOT/.statusline-inner"
  ck "sidecar verbatim" "$(echo "$J" | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PRODUCER")" "MYBAR"
  printf "exit 3" > "$ROOT/.statusline-inner"
  OUT=$(echo "$J" | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PRODUCER")
  [ -n "$OUT" ] && pass "inner-fail -> fallback bar" || fail "inner-fail empty"
  printf 'statusline-producer.sh x' > "$ROOT/.statusline-inner"
  OUT=$(echo "$J" | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PRODUCER")
  case "$OUT" in *Op*|*proj*) pass "recursion guard -> fallback";; *) fail "recursion guard ($OUT)";; esac
  rm -rf "$ROOT"
else
  skip "producer cache + compose (jq absent)"
fi

# Producer no-jq: no cache write, fallback bar still prints, exit 0.
ROOT="$(mktemp -d)"
printf '88' > "$CACHE_FILE"
OUT=$(echo '{"rate_limits":{"five_hour":{"used_percentage":95}}}' \
  | CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$MASK" "$BASH_BIN" "$PRODUCER"); EC=$?
ck "no-jq: exit 0" "$EC" "0"
ck "no-jq: cache untouched" "$(cat "$CACHE_FILE" 2>/dev/null)" "88"
[ -n "$OUT" ] && pass "no-jq: bar non-empty" || fail "no-jq: bar empty"
rm -rf "$ROOT"; rm -f "$CACHE_FILE"

echo "═══ install / uninstall wiring ═══"

if [ "$HAS_JQ" = 1 ]; then
  # Fresh HOME, no settings.json.
  H="$(mktemp -d)"; mkdir -p "$H/.claude"
  HOME="$H" bash "$INSTALL" >/dev/null 2>&1
  PROD="$H/.claude/plugins/rl-guard/scripts/statusline-producer.sh"
  ck "fresh: command=producer" "$(jq -r '.statusLine.command' "$H/.claude/settings.json")" "$PROD"
  ck "fresh: no sidecar" "$([ -f "$H/.claude/plugins/rl-guard/.statusline-inner" ] && echo y || echo n)" "n"
  HOME="$H" bash "$UNINSTALL" >/dev/null 2>&1
  ck "fresh: uninstall removes statusLine" "$(jq -r 'has("statusLine")' "$H/.claude/settings.json")" "false"
  rm -rf "$H"

  # Existing bar preserved + backup + idempotent + restore.
  H="$(mktemp -d)"; mkdir -p "$H/.claude"
  echo '{"statusLine":{"type":"command","command":"/my/bar.sh","padding":1},"k":1}' > "$H/.claude/settings.json"
  HOME="$H" bash "$INSTALL" >/dev/null 2>&1
  PROD="$H/.claude/plugins/rl-guard/scripts/statusline-producer.sh"
  ck "compose: command rewired" "$(jq -r '.statusLine.command' "$H/.claude/settings.json")" "$PROD"
  ck "compose: sidecar holds original" "$(cat "$H/.claude/plugins/rl-guard/.statusline-inner" 2>/dev/null)" "/my/bar.sh"
  ck "compose: backup has original" "$(jq -r '.statusLine.command' "$H/.claude/settings.json.rl-guard.bak")" "/my/bar.sh"
  ck "compose: other key intact" "$(jq -r '.k' "$H/.claude/settings.json")" "1"
  HOME="$H" bash "$INSTALL" >/dev/null 2>&1   # idempotent re-run
  ck "idempotent: still producer" "$(jq -r '.statusLine.command' "$H/.claude/settings.json")" "$PROD"
  ck "idempotent: sidecar unchanged" "$(cat "$H/.claude/plugins/rl-guard/.statusline-inner" 2>/dev/null)" "/my/bar.sh"
  HOME="$H" bash "$UNINSTALL" >/dev/null 2>&1
  ck "restore: original command back" "$(jq -r '.statusLine.command' "$H/.claude/settings.json")" "/my/bar.sh"
  ck "restore: sidecar gone" "$([ -f "$H/.claude/plugins/rl-guard/.statusline-inner" ] && echo y || echo n)" "n"
  rm -rf "$H"

  # No-jq install: settings.json must stay byte-identical.
  H="$(mktemp -d)"; mkdir -p "$H/.claude"
  echo '{"statusLine":{"command":"/keep.sh"}}' > "$H/.claude/settings.json"
  BEFORE="$(cat "$H/.claude/settings.json")"
  HOME="$H" PATH="$MASK" "$BASH_BIN" "$INSTALL" >/dev/null 2>&1
  ck "no-jq install: settings untouched" "$(cat "$H/.claude/settings.json")" "$BEFORE"
  rm -rf "$H"
else
  skip "install/uninstall wiring (jq absent)"
fi

rm -rf "$MASK"

echo "═══ SUMMARY ═══"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
