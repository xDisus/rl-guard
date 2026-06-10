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

# Enable in settings.json if not already
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  if ! grep -q '"rl-guard"' "$SETTINGS" 2>/dev/null; then
    # Simple insert before the last closing brace
    sed -i 's|\([[:space:]]*\)\(}\)$|\1  "enabledPlugins": {\n\1    "rl-guard": true\n\1  },\n\1}|' "$SETTINGS" 2>/dev/null || true
    echo "  ✅ Enabled in settings.json"
  else
    echo "  ℹ️  Already enabled in settings.json"
  fi
fi

echo ""
echo "✅ rl-guard installed at:"
echo "   $PLUGIN_DIR"
echo ""
echo "Reinicie sua sessão do Claude Code (ou tmux) para ativar."
echo "Use /rl-guard-doctor para verificar se está tudo certo."
