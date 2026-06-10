# rl-guard 🛡️

**Rate Limit Guard** — plugin do Claude Code que bloqueia criação de novas tasks quando o limite diário de uso ultrapassa o threshold configurado.

Quando o limite está crítico (≥90%), o plugin faz o Claude **perguntar a você** antes de prosseguir — evitando estourar o reset do dia sem querer.

## Como funciona

```
┌─────────────┐     ┌─────────────────────┐     ┌──────────────┐
│ TaskCreate  │ →   │ rl-guard (PreToolUse)│ →   │ ≥ 90%?       │
│ (qualquer   │     │ lê /tmp/claude_rl_pct│     │  SIM → exit 2│
│  ferramenta)│     │                      │     │  NÃO → exit 0│
└─────────────┘     └─────────────────────┘     └──────────────┘
```

- **Bloqueia** (exit 2) → Claude te pergunta: quer continuar ou parar?
- **Libera** (exit 0) → tudo normal
- **Subagentes** são sempre liberados — só o agente principal é verificado

## Pré-requisitos

O plugin depende de um cache `/tmp/claude_rl_pct` com o percentual usado do limite diário. Você precisa de um script que popule esse arquivo (ex: via `statusLine.command` no `settings.json`).

Exemplo de `~/.claude/settings.json`:
```json
{
  "statusLine": {
    "type": "command",
    "command": "/caminho/para/seu/statusline-wrap.sh",
    "padding": 0
  }
}
```

Esse script deve escrever o percentual (ex: `73`) em `/tmp/claude_rl_pct`.

## Instalação

```bash
# Via npm (em breve)
npx rl-guard

# Via git
git clone https://github.com/xDisus/rl-guard.git ~/.claude/plugins/rl-guard
claude plugin enable rl-guard
```

Habilite no `settings.json`:
```json
{
  "enabledPlugins": {
    "rl-guard": true
  }
}
```

Reinicie a sessão do Claude Code (ou tmux).

## Configuração

| Variável | Default | Descrição |
|----------|---------|-----------|
| `RL_GUARD_THRESHOLD` | `90` | Percentual mínimo para bloquear (0-100) |

```bash
# Exemplo: bloquear só aos 95%
RL_GUARD_THRESHOLD=95 claude
```

## Diagnóstico

No Claude Code, digite:

```
/rl-guard-doctor
```

Ou rode manualmente:
```bash
~/.claude/plugins/rl-guard/scripts/rl-guard-doctor.sh
```

Teste o bloqueio:
```bash
echo 93 > /tmp/claude_rl_pct
echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' \
  | ~/.claude/plugins/rl-guard/scripts/rate-limit-guard.sh
echo $?   # deve retornar 2
```

## Estrutura

```
~/.claude/plugins/rl-guard/
├── plugin.json                    — Manifesto do plugin
├── hooks/hooks.json               — Registro do hook PreToolUse
├── scripts/
│   ├── rate-limit-guard.sh        — Script principal do guard
│   └── rl-guard-doctor.sh         — Script de diagnóstico
├── commands/
│   └── rl-guard-doctor.md         — Slash command /rl-guard-doctor
├── README.md
├── LICENSE
└── package.json
```

## Licença

MIT
