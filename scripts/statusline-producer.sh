#!/usr/bin/env bash
# rl-guard statusline producer — feeds the guard and renders the statusline.
#
# Wired automatically by bin/install.sh as settings.json .statusLine.command.
# The daily-usage percent comes from Claude Code's OFFICIAL statusLine payload
# field .rate_limits.{five_hour,seven_day}.used_percentage — not a user meter.
#
# Contract with the guard: an integer 0-100 in /tmp/claude_rl_pct. FAIL-OPEN:
# when rate_limits is absent (API/console plans, older Claude Code) or jq is
# missing, write NOTHING — the guard's staleness gate then fails open. The bar
# always renders (the user's prior one if install preserved it, else a minimal
# fallback) and the script always exits 0; a slow/broken producer would degrade
# the whole Claude Code UI.
set -eu

CACHE_FILE="/tmp/claude_rl_pct"
PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/rl-guard}"
SIDECAR="$PLUGIN_DIR/.statusline-inner"
SELF_BASE="$(basename "$0")"

INPUT=$(cat)

# --- Cache write: official rate_limits, max of windows, rounded integer ------
# Single jq pass: collect both windows, drop nulls, take max, round. Empty array
# (both windows absent) → jq emits nothing → the integer-validation case below
# rejects it → no write (fail-open, D6). jq absent → PCT empty → same no-write
# path. bash has no float math, so the max+round happens entirely in jq.
PCT=""
if command -v jq >/dev/null 2>&1; then
    PCT=$(printf '%s' "$INPUT" | jq -r '
        [.rate_limits.five_hour.used_percentage,
         .rate_limits.seven_day.used_percentage]
        | map(select(. != null))
        | if length == 0 then empty else (max | round) end
    ' 2>/dev/null || true)
fi

# Only write a clean 0-100 integer; otherwise leave any existing cache untouched
# so the guard's own staleness gate can fail open on a dead producer.
case "$PCT" in
    ''|*[!0-9]*) : ;;
    *) if [ "$PCT" -le 100 ]; then printf '%s' "$PCT" > "$CACHE_FILE"; fi ;;
esac

# --- Render -----------------------------------------------------------------
# Minimal, dependency-light bar so the statusline is never empty.
render_fallback() {
    local model="claude" dir=""
    if command -v jq >/dev/null 2>&1; then
        model=$(printf '%s' "$INPUT" | jq -r '.model.display_name // "claude"' 2>/dev/null || echo claude)
        dir=$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // ""' 2>/dev/null || echo "")
        dir="${dir##*/}"
    fi
    if [ -n "$PCT" ]; then
        printf '%s %s ⏱ %s%%' "$model" "$dir" "$PCT"
    else
        printf '%s %s' "$model" "$dir"
    fi
}

# Compose: if install preserved the user's prior statusLine command in the
# sidecar, run it verbatim and emit its output unchanged (their bar is kept
# byte-for-byte). eval trust note: the inner command is the user's OWN
# pre-existing settings.json .statusLine.command, saved by bin/install.sh — it
# is user-owned config, not untrusted input. The recursion guard below is the
# only adversarial case (an install bug that points the sidecar back at us).
if [ -f "$SIDECAR" ] && [ -s "$SIDECAR" ]; then
    INNER=$(cat "$SIDECAR")
    case "$INNER" in
        *"$SELF_BASE"*) render_fallback ;;
        *)
            if OUT=$(printf '%s' "$INPUT" | eval "$INNER" 2>/dev/null) && [ -n "$OUT" ]; then
                printf '%s' "$OUT"
            else
                render_fallback
            fi
            ;;
    esac
else
    render_fallback
fi

exit 0
