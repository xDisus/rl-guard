#!/usr/bin/env bash
# Install rl-guard as a Claude Code plugin
set -eu

PLUGIN_DIR="$HOME/.claude/plugins/rl-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "📦 Installing rl-guard..."
mkdir -p "$PLUGIN_DIR"

# Copy plugin files (skip .git, node_modules, tests)
for item in plugin.json hooks scripts commands README.md LICENSE package.json; do
  [ -e "$SCRIPT_DIR/$item" ] && cp -r "$SCRIPT_DIR/$item" "$PLUGIN_DIR/$item"
done

chmod +x "$PLUGIN_DIR/scripts/"*.sh 2>/dev/null || true

# Enable in settings.json (idempotent, JSON-safe)
SETTINGS="$HOME/.claude/settings.json"
if command -v jq >/dev/null 2>&1; then
  # jq path: merge enabledPlugins["rl-guard"]=true without clobbering other keys
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  if jq -e '.enabledPlugins["rl-guard"] == true' "$SETTINGS" >/dev/null 2>&1; then
    echo "  ℹ️  Already enabled in settings.json"
  else
    TMP="$(mktemp)"
    if jq '.enabledPlugins["rl-guard"] = true' "$SETTINGS" > "$TMP" 2>/dev/null; then
      mv "$TMP" "$SETTINGS"
      echo "  ✅ Enabled in settings.json"
    else
      rm -f "$TMP"
      echo "  ⚠️  Could not edit settings.json — add manually:"
      echo '      "enabledPlugins": { "rl-guard": true }'
    fi
  fi
else
  # No jq: only safe to write a fresh file; never hand-edit existing JSON
  if [ ! -f "$SETTINGS" ]; then
    printf '{\n  "enabledPlugins": {\n    "rl-guard": true\n  }\n}\n' > "$SETTINGS"
    echo "  ✅ Created settings.json with rl-guard enabled"
  elif grep -q '"rl-guard"' "$SETTINGS" 2>/dev/null; then
    echo "  ℹ️  Already enabled in settings.json"
  else
    echo "  ⚠️  jq not found — enable manually in $SETTINGS:"
    echo '      "enabledPlugins": { "rl-guard": true }'
  fi
fi

# Auto-wire the statusLine producer so the guard works out-of-box (idempotent,
# jq-gated, composes with any existing statusLine instead of clobbering it).
PRODUCER="$PLUGIN_DIR/scripts/statusline-producer.sh"
SIDECAR="$PLUGIN_DIR/.statusline-inner"
BACKUP="$HOME/.claude/settings.json.rl-guard.bak"
if command -v jq >/dev/null 2>&1; then
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  CUR=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || echo "")
  if [ "$CUR" = "$PRODUCER" ]; then
    echo "  ℹ️  statusLine already wired to rl-guard producer"
  else
    cp "$SETTINGS" "$BACKUP"
    # Preserve any existing (non-ours) command as the chained inner statusLine.
    if [ -n "$CUR" ]; then
      printf '%s' "$CUR" > "$SIDECAR"
      echo "  ✅ Preserved your statusLine as inner command (sidecar)"
    fi
    TMP="$(mktemp)"
    if jq --arg cmd "$PRODUCER" '.statusLine = {type:"command", command:$cmd, padding:0}' "$SETTINGS" > "$TMP" 2>/dev/null; then
      mv "$TMP" "$SETTINGS"
      echo "  ✅ statusLine wired to producer (backup: $BACKUP)"
    else
      rm -f "$TMP"
      echo "  ⚠️  Could not edit statusLine — add manually:"
      echo "      \"statusLine\": { \"type\":\"command\", \"command\":\"$PRODUCER\", \"padding\":0 }"
    fi
  fi
else
  echo "  ⚠️  jq not found — wire the statusLine manually in $SETTINGS:"
  echo "      \"statusLine\": { \"type\": \"command\", \"command\": \"$PRODUCER\", \"padding\": 0 }"
fi

echo ""
echo "✅ rl-guard installed at:"
echo "   $PLUGIN_DIR"
echo ""
echo "Reinicie sua sessão do Claude Code (ou tmux) para ativar."
echo "Use /rl-guard-doctor para verificar se está tudo certo."
