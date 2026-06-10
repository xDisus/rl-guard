# rl-guard 🛡️

**Rate Limit Guard** — plugin do Claude Code que bloqueia criação de novas tasks quando o limite diário de uso ultrapassa o threshold configurado.

Quando o limite está crítico (≥90%), o plugin faz o Claude Code **perguntar a você** antes de prosseguir — via prompt nativo, sem depender do modelo obedecer. Entre 80% e 90% ele apenas avisa o Claude para economizar.

## Como funciona

```
┌─────────────┐     ┌───────────────────────┐     ┌───────────────────────────────┐
│ TaskCreate  │ →   │ rl-guard (PreToolUse)  │ →   │ ≥ 90% → prompt nativo ("ask") │
│ (agente     │     │ lê /tmp/claude_rl_pct  │     │ ≥ 80% → nudge "economize"     │
│  principal) │     │                        │     │ < 80% → libera                │
└─────────────┘     └───────────────────────┘     └───────────────────────────────┘
```

- **Bloqueia** (≥ threshold) → emite `permissionDecision:"ask"` (JSON, exit 0) → o Claude Code te pergunta nativamente: continuar ou parar?
- **Avisa** (≥ warn, < threshold) → injeta `additionalContext` pedindo economia, sem bloquear
- **Libera** (< warn) → tudo normal, sem saída
- **Subagentes** são sempre liberados — só o agente principal é verificado
- **Fail-open** → cache ausente, velho (stale) ou com valor não-inteiro → libera

> **Nota:** o bloqueio agora usa o JSON nativo `permissionDecision:"ask"` (não mais `exit 2`). Requer uma versão do Claude Code que suporte os quatro resultados do `PreToolUse`. Em versões antigas o envelope é ignorado (fail-open).

## Pré-requisitos

O plugin depende de um cache `/tmp/claude_rl_pct` com o percentual usado do limite diário. **O plugin não cria esse arquivo** — você precisa de um produtor que o popule (ex: via `statusLine.command` no `settings.json`). Sem ele, o guard é um no-op (fail-open).

Há um exemplo pronto em [`examples/statusline-writer.sh`](examples/statusline-writer.sh) — copie, adapte a fonte do percentual (a origem do número é sua: `ccusage`, `/usage`, seu próprio medidor…) e aponte seu `settings.json` para ele:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/caminho/para/statusline-writer.sh",
    "padding": 0
  }
}
```

O contrato é simples: escrever um inteiro `0-100` (ex: `73`) em `/tmp/claude_rl_pct`, atualizado com frequência suficiente para não ficar stale (ver `RL_GUARD_STALE_MIN`).

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
| `RL_GUARD_THRESHOLD` | `90` | Percentual mínimo para **bloquear** (prompt nativo) |
| `RL_GUARD_WARN` | `80` | Percentual mínimo para **avisar** (sem bloquear) |
| `RL_GUARD_RESET` | `12:00 BRT` | Texto do horário de reset, mostrado no prompt |
| `RL_GUARD_STALE_MIN` | `10` | Minutos até o cache ser considerado velho (fail-open) |

```bash
# Exemplo: bloquear só aos 95%, avisar a partir de 85%, reset em UTC
RL_GUARD_THRESHOLD=95 RL_GUARD_WARN=85 RL_GUARD_RESET="09:00 UTC" claude
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

Rode a matriz de testes completa:
```bash
bash ~/.claude/plugins/rl-guard/scripts/test.sh   # sai 0 se tudo passa
```

Teste o bloqueio manualmente — o guard emite JSON `permissionDecision:"ask"` e sai com **exit 0** (não mais `exit 2`):
```bash
echo 93 > /tmp/claude_rl_pct
echo '{"tool_name":"Task","tool_input":{},"agent_id":""}' \
  | ~/.claude/plugins/rl-guard/scripts/rate-limit-guard.sh
# stdout: {"hookSpecificOutput":{...,"permissionDecision":"ask",...}}  | exit 0
rm /tmp/claude_rl_pct

## Estrutura

```
~/.claude/plugins/rl-guard/
├── plugin.json                    — Manifesto do plugin
├── hooks/hooks.json               — Registro do hook PreToolUse
├── scripts/
│   ├── rate-limit-guard.sh        — Script principal do guard
│   ├── rl-guard-doctor.sh         — Script de diagnóstico
│   └── test.sh                    — Matriz de testes comportamentais
├── commands/
│   └── rl-guard-doctor.md         — Slash command /rl-guard-doctor
├── examples/
│   └── statusline-writer.sh       — Produtor de cache opt-in (exemplo)
├── README.md
├── LICENSE
└── package.json
```

## Licença

MIT
