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
    printf '⚠️  DAILY LIMIT CRITICAL — %s%%\n\n' "$PCT"
    printf 'Você já usou %s%% do limite diário do Claude Code.\n' "$PCT"
    printf 'O reset é às %s.\n\n' "$RESET"
    cat << 'EOF'
Antes de criar esta task, PERGUNTE ao usuário se deve prosseguir ou parar.

Opções para o usuário:
- "Sim, continua" → prossiga normalmente
- "Não, para por aqui" → cancele a task e encerre

Use a ferramenta AskUserQuestion para perguntar.
EOF
    exit 2
fi

exit 0
