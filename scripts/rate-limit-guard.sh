#!/usr/bin/env bash
# Rate Limit Guard — blocks Task tool calls when daily limit > threshold
# Requires: /tmp/claude_rl_pct (cached by a statusline producer; see examples/)
set -eu

INPUT=$(cat)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)

# Only gate main-agent task creation; subagents always pass.
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

CACHE_FILE="/tmp/claude_rl_pct"
THRESHOLD="${RL_GUARD_THRESHOLD:-90}"
WARN="${RL_GUARD_WARN:-80}"
RESET="${RL_GUARD_RESET:-12:00 BRT}"
STALE_MIN="${RL_GUARD_STALE_MIN:-10}"

# Minimal JSON string escape (backslash + double-quote). Reason/context copy is
# controlled and single-line, so this is sufficient to keep jq a soft dependency.
json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

# Emit a PreToolUse hookSpecificOutput envelope with a permission decision.
# $1=decision ("ask"), $2=reason shown to the user.
emit_decision() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$(json_escape "$2")"
}

# Emit a context-only envelope (no permissionDecision → normal permission flow
# is untouched; Claude just sees the nudge). $1=context string.
emit_context() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$(json_escape "$1")"
}

# Fail-open: no cache → allow.
if [ ! -f "$CACHE_FILE" ]; then
    exit 0
fi

# Fail-open: stale cache (producer may have died) → allow.
if [ -n "$(find "$CACHE_FILE" -mmin +"$STALE_MIN" 2>/dev/null)" ]; then
    exit 0
fi

PCT=$(cat "$CACHE_FILE")

# Fail-open: non-integer value → allow.
case "$PCT" in
    ''|*[!0-9]*) exit 0 ;;
esac

if [ "$PCT" -ge "$THRESHOLD" ]; then
    emit_decision "ask" "⚠️ Limite diário do Claude Code em ${PCT}% (reset às ${RESET}). Criar esta task mesmo assim?"
    exit 0
fi

if [ "$PCT" -ge "$WARN" ]; then
    emit_context "Atenção: limite diário do Claude Code em ${PCT}% (bloqueio em ${THRESHOLD}%). Seja econômico — evite tasks desnecessárias."
    exit 0
fi

exit 0
