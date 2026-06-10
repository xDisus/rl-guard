#!/usr/bin/env bash
# Rate Limit Guard — blocks Task tool calls when daily limit > threshold
# Requires: /tmp/claude_rl_pct (cached by statusline-wrap.sh or similar)
set -eu

INPUT=$(cat)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)

# Only block main-agent task creation
if [ -n "$AGENT_ID" ]; then
    exit 0
fi

CACHE_FILE="/tmp/claude_rl_pct"
THRESHOLD="${RL_GUARD_THRESHOLD:-90}"

if [ ! -f "$CACHE_FILE" ]; then
    exit 0
fi

PCT=$(cat "$CACHE_FILE")

if [ "$PCT" -ge "$THRESHOLD" ] 2>/dev/null; then
    printf '⚠️  DAILY LIMIT CRITICAL — %s%%\n\n' "$PCT"
    printf 'Você já usou %s%% do limite diário do Claude Code.\n' "$PCT"
    cat << 'EOF'
O reset é às 12:00 BRT.

Antes de criar esta task, PERGUNTE ao usuário se deve prosseguir ou parar.

Opções para o usuário:
- "Sim, continua" → prossiga normalmente
- "Não, para por aqui" → cancele a task e encerre

Use a ferramenta AskUserQuestion para perguntar.
EOF
    exit 2
fi

exit 0
