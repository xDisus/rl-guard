#!/usr/bin/env bash
# Example statusline producer for rl-guard (OPT-IN — copy & adapt).
#
# rl-guard reads the daily-usage percent from /tmp/claude_rl_pct but never
# creates it. Wire this script (or your own) as your Claude Code statusline so
# the cache stays fresh:
#
#   ~/.claude/settings.json
#   {
#     "statusLine": {
#       "type": "command",
#       "command": "/caminho/para/statusline-writer.sh",
#       "padding": 0
#     }
#   }
#
# Claude Code pipes the statusline JSON to this script on stdin and renders
# whatever it prints on stdout.
#
# IMPORTANT: the *percent source* is yours to supply. Claude Code's statusline
# JSON does NOT include a daily-usage percent. Replace `derive_pct` below with a
# real source (ccusage, a scraped /usage value, your own meter, etc.). The
# contract rl-guard depends on is only this: an integer 0-100 in
# /tmp/claude_rl_pct, refreshed often enough to stay within RL_GUARD_STALE_MIN.
set -eu

CACHE_FILE="/tmp/claude_rl_pct"
INPUT=$(cat)

# --- Replace this with your real usage source -------------------------------
# Must echo an integer 0-100, or nothing if unavailable.
derive_pct() {
    # Example: pull from `ccusage` if installed. Adapt to your own meter.
    if command -v ccusage >/dev/null 2>&1; then
        ccusage --json 2>/dev/null \
            | grep -oE '"daily_pct"[[:space:]]*:[[:space:]]*[0-9]+' \
            | grep -oE '[0-9]+$' \
            | head -1
    fi
}
# ---------------------------------------------------------------------------

PCT="$(derive_pct || true)"

# Only write a clean integer; leave a stale-but-valid cache untouched on failure
# so rl-guard's own staleness gate can fail open.
case "$PCT" in
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$PCT" > "$CACHE_FILE" ;;
esac

# --- Statusline passthrough -------------------------------------------------
# Render whatever you want. This pulls a couple of common fields if jq is
# present; falls back to a static label otherwise.
if command -v jq >/dev/null 2>&1; then
    MODEL=$(printf '%s' "$INPUT" | jq -r '.model.display_name // "claude"' 2>/dev/null || echo claude)
    DIR=$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // ""' 2>/dev/null || echo "")
    DIR="${DIR##*/}"
else
    MODEL="claude"; DIR=""
fi

if [ -n "${PCT:-}" ]; then
    printf '%s %s ⏱ %s%%' "$MODEL" "$DIR" "$PCT"
else
    printf '%s %s' "$MODEL" "$DIR"
fi
