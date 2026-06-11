#!/usr/bin/env bash
# Uninstall rl-guard — reverses the statusLine wiring done by bin/install.sh.
# Reversible by design: restores any preserved inner command, removes ours when
# we created it fresh. Leaves /tmp/claude_rl_pct alone (ephemeral, self-expires
# via staleness) and leaves plugin files in place (printed at the end).
set -eu

PLUGIN_DIR="$HOME/.claude/plugins/rl-guard"
PRODUCER="$PLUGIN_DIR/scripts/statusline-producer.sh"
SIDECAR="$PLUGIN_DIR/.statusline-inner"
SETTINGS="$HOME/.claude/settings.json"
BACKUP="$HOME/.claude/settings.json.rl-guard.uninstall.bak"

echo "🧹 Uninstalling rl-guard..."

if [ ! -f "$SETTINGS" ]; then
  echo "  ℹ️  No settings.json — nothing to unwire"
else
  if command -v jq >/dev/null 2>&1; then
    CUR=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || echo "")
    if [ "$CUR" != "$PRODUCER" ]; then
      echo "  ℹ️  statusLine is not wired to rl-guard — leaving it untouched"
    else
      cp "$SETTINGS" "$BACKUP"
      TMP="$(mktemp)"
      if [ -f "$SIDECAR" ] && [ -s "$SIDECAR" ]; then
        INNER=$(cat "$SIDECAR")
        if jq --arg cmd "$INNER" '.statusLine = {type:"command", command:$cmd, padding:0}' "$SETTINGS" > "$TMP" 2>/dev/null; then
          mv "$TMP" "$SETTINGS"
          rm -f "$SIDECAR"
          echo "  ✅ Restored your original statusLine ($INNER)"
        else
          rm -f "$TMP"
          echo "  ⚠️  Could not restore statusLine — restore manually from $BACKUP"
        fi
      else
        if jq 'del(.statusLine)' "$SETTINGS" > "$TMP" 2>/dev/null; then
          mv "$TMP" "$SETTINGS"
          echo "  ✅ Removed the rl-guard statusLine (none pre-existed)"
        else
          rm -f "$TMP"
          echo "  ⚠️  Could not edit statusLine — restore manually from $BACKUP"
        fi
      fi
    fi
    # Drop the plugin enablement too (jq path only; safe key delete).
    TMP="$(mktemp)"
    if jq 'if .enabledPlugins then .enabledPlugins |= del(.["rl-guard"]) else . end' "$SETTINGS" > "$TMP" 2>/dev/null; then
      mv "$TMP" "$SETTINGS"
      echo "  ✅ Disabled rl-guard in settings.json"
    else
      rm -f "$TMP"
    fi
  else
    echo "  ⚠️  jq not found — undo manually in $SETTINGS:"
    echo "      • set .statusLine back to your prior command (see $SIDECAR if present)"
    echo "      • remove \"rl-guard\" from .enabledPlugins"
  fi
fi

echo ""
echo "Plugin files left in place at:"
echo "   $PLUGIN_DIR"
echo "Remove them with:  rm -rf \"$PLUGIN_DIR\""
echo "Cache /tmp/claude_rl_pct is ephemeral and self-expires."
